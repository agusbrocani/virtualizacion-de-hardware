#-------------------------------------------------------#
#               Virtualizacion de Hardware              #
#                                                       #
#   APL1                                                #
#   Nro ejercicio: 4                                    #
#                                                       #
#   Integrantes:                                        #
#                                                       #
#        BIANCHI, JUAN              30474902            #
#        BROCANI, AGUSTIN           40931870            #
#        PASCUAL, PABLO             39208705            #
#        SANZ, ELISEO               44690195            #
#        VARALDO, RODRIGO           42772765            #
#                                                       #
#-------------------------------------------------------#

<#
.SYNOPSIS
    Demonio de monitoreo para detectar credenciales y datos sensibles en repositorios Git.

.DESCRIPTION
    Este script implementa un demonio que monitorea un repositorio Git en tiempo real para detectar credenciales
    o datos sensibles que se hayan subido por error. Utiliza FileSystemWatcher para detectar cambios en la rama
    principal y escanea archivos modificados usando patrones configurables. Las alertas se registran en un archivo
    de log con timestamp, patrón encontrado y archivo afectado.

.PARAMETER repo
    Ruta del repositorio Git a monitorear. Debe ser un directorio existente que contenga una carpeta .git válida.

.PARAMETER configuracion
    Ruta del archivo de configuración que contiene la lista de patrones a buscar. El archivo debe contener al menos
    un patrón válido (palabra clave simple o expresión regular con prefijo 'regex:').

.PARAMETER log
    Ruta del archivo de logs donde se registrarán las alertas encontradas. El directorio padre debe existir.

.PARAMETER kill
    Flag para detener el demonio en ejecución. Solo se usa junto con -repo y debe validar que exista un demonio
    activo para el repositorio especificado.

.EXAMPLE
    Iniciar el demonio para monitorear el repositorio actual con configuración por defecto.
    .\ejercicio4.ps1 -repo C:\mi-proyecto -configuracion .\resources\patrones.conf -log .\security.log

.EXAMPLE
    Detener el demonio activo para un repositorio específico.
    .\ejercicio4.ps1 -repo C:\mi-proyecto -kill

.INPUTS
    No se reciben entradas por pipeline.

.OUTPUTS
    Archivo de log con alertas de seguridad en formato:
    [YYYY-MM-DD HH:MM:SS] Alerta: patrón 'X' encontrado en el archivo 'Y'.

.NOTES
    - Solo puede ejecutarse un demonio por repositorio simultáneamente.
    - El demonio se ejecuta en segundo plano liberando la terminal.
    - Los patrones soportan palabras clave simples y expresiones regulares.
    - Se monitorean cambios en .git/refs/heads/, .git/HEAD y .git/packed-refs.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({
        if (-not (Test-Path $_ -PathType Container)) {
            throw "El directorio '$_' no existe."
        }
        if (-not (Test-Path (Join-Path $_ ".git") -PathType Container)) {
            throw "El directorio '$_' no es un repositorio Git válido."
        }
        return $true
    })]
    [string]$repo,

    [Parameter(Mandatory = $true)]
    [ValidateScript({
        if (-not (Test-Path $_ -PathType Leaf)) {
            throw "El archivo de configuración '$_' no existe."
        }
        
        # Leer el archivo y filtrar líneas válidas (no vacías, no comentarios)
        $validPatterns = Get-Content $_ | Where-Object { 
            $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') 
        }
        
        if ($validPatterns.Count -eq 0) {
            throw "El archivo de configuración '$_' no contiene patrones válidos. Debe tener al menos una entrada."
        }
        
        return $true
    })]
    [string]$configuracion,

    [Parameter(Mandatory = $true)]
    [ValidateScript({
        $parentDir = Split-Path $_ -Parent
        if ($parentDir -and -not (Test-Path $parentDir -PathType Container)) {
            throw "El directorio padre para el archivo de log '$parentDir' no existe."
        }
        return $true
    })]
    [string]$log,

    [Parameter(Mandatory = $false)]
    [switch]$kill
)

function Read-SecurityPatterns {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigurationPath
    )
    
    try {
        $patterns = @{
            SimplePatterns = @()
            RegexPatterns = @()
        }
        
        $configLines = Get-Content $ConfigurationPath | Where-Object { 
            $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') 
        }
        
        foreach ($line in $configLines) {
            $cleanLine = $line.Trim()
            
            if ($cleanLine.StartsWith('regex:')) {
                $regexPattern = $cleanLine.Substring(6)
                $patterns.RegexPatterns += $regexPattern
            }
            else {
                $patterns.SimplePatterns += $cleanLine
            }
        }
        
        Write-Verbose "Cargados $($patterns.SimplePatterns.Count) patrones simples y $($patterns.RegexPatterns.Count) patrones regex"
        return $patterns
    }
    catch {
        throw "Error al leer patrones de configuración: $_"
    }
}

function Get-PidFilePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath
    )
    
    $repoHash = ($RepositoryPath -replace '[\\/:*?"<>|]', '_').ToLower()
    $pidFileName = "git-security-daemon-$repoHash.pid"
    return Join-Path $env:TEMP $pidFileName
}

function Test-DaemonRunning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath
    )
    
    $pidFile = Get-PidFilePath -RepositoryPath $RepositoryPath
    
    if (-not (Test-Path $pidFile)) {
        return $false
    }
    
    try {
        $processId = Get-Content $pidFile -ErrorAction Stop
        $process = Get-Process -Id $processId -ErrorAction Stop
        return $true
    }
    catch {
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Stop-GitSecurityDaemon {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath
    )
    
    $pidFile = Get-PidFilePath -RepositoryPath $RepositoryPath
    
    if (-not (Test-Path $pidFile)) {
        throw "No se encontró un demonio activo para el repositorio '$RepositoryPath'"
    }
    
    try {
        $processId = Get-Content $pidFile -ErrorAction Stop
        $process = Get-Process -Id $processId -ErrorAction Stop
        
        Stop-Process -Id $processId -Force
        Remove-Item $pidFile -Force
        
        Write-Host "Demonio detenido para repositorio: $RepositoryPath" -ForegroundColor Green
    }
    catch {
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
        throw "Error al detener el demonio: $_"
    }
}

function Start-GitSecurityWatcher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$SecurityPatterns,
        
        [Parameter(Mandatory = $true)]
        [string]$LogPath
    )
    
    # Verificar que no haya otro demonio corriendo
    if (Test-DaemonRunning -RepositoryPath $RepositoryPath) {
        throw "Ya existe un demonio activo para el repositorio '$RepositoryPath'. Use -kill para detenerlo primero."
    }
    
    try {
        # Crear archivo PID
        $pidFile = Get-PidFilePath -RepositoryPath $RepositoryPath
        $PID | Out-File -FilePath $pidFile -Force
        
        Write-Host "Iniciando demonio de seguridad para repositorio: $RepositoryPath" -ForegroundColor Green
        Write-Host "PID del demonio: $PID" -ForegroundColor Cyan
        Write-Host "Archivo PID creado en: $pidFile" -ForegroundColor Gray
        
        # COMENTADO: FileSystemWatcher para pruebas
        <#
        $gitPath = Join-Path $RepositoryPath ".git"
        $watcher = New-Object System.IO.FileSystemWatcher
        $watcher.Path = $gitPath
        $watcher.IncludeSubdirectories = $true
        $watcher.EnableRaisingEvents = $true
        
        $watcher.Filter = "*"
        $watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::FileName
        
        $lastEventTime = [DateTime]::MinValue
        $debounceInterval = [TimeSpan]::FromSeconds(2)
        
        $action = {
            param($sender, $eventArgs)
            
            $now = [DateTime]::Now
            if (($now - $script:lastEventTime) -lt $script:debounceInterval) {
                return
            }
            $script:lastEventTime = $now
            
            $changedFile = $eventArgs.FullPath
            $fileName = Split-Path $changedFile -Leaf
            
            if ($fileName -eq "HEAD" -or 
                $changedFile -like "*\refs\heads\*" -or 
                $fileName -eq "packed-refs") {
                
                Write-Host "Cambio detectado en: $changedFile" -ForegroundColor Yellow
                
                # Aquí se llamarán las funciones de escaneo una vez implementadas
                # Get-ModifiedFiles y Scan-FileForSecrets
            }
        }
        
        Register-ObjectEvent -InputObject $watcher -EventName "Changed" -Action $action
        Register-ObjectEvent -InputObject $watcher -EventName "Created" -Action $action
        #>
        
        Write-Host "Demonio iniciado correctamente. Use -kill para detenerlo." -ForegroundColor Green
        Write-Host "Presione Ctrl+C para simular terminación manual del demonio." -ForegroundColor Cyan
        
        # Simulación simple del demonio para pruebas
        $counter = 0
        try {
            while ($true) {
                Start-Sleep -Seconds 3
                $counter++
                
                Write-Host "Demonio activo - Ciclo #$counter (PID: $PID)" -ForegroundColor DarkGreen
                
                # Verificar si el archivo PID aún existe (método de control)
                if (-not (Test-Path $pidFile)) {
                    Write-Host "Archivo PID eliminado. Deteniendo demonio..." -ForegroundColor Yellow
                    break
                }
                
                # Simular alguna actividad cada 5 ciclos
                if ($counter % 5 -eq 0) {
                    Write-Host "Verificando estado del repositorio..." -ForegroundColor Magenta
                }
            }
        }
        finally {
            # COMENTADO: Cleanup del FileSystemWatcher
            # $watcher.EnableRaisingEvents = $false
            # $watcher.Dispose()
            # Get-EventSubscriber | Unregister-Event -ErrorAction SilentlyContinue
            
            Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
            Write-Host "Demonio detenido y recursos liberados." -ForegroundColor Red
        }
    }
    catch {
        # Cleanup en caso de error
        $pidFile = Get-PidFilePath -RepositoryPath $RepositoryPath
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
        throw "Error al iniciar el watcher: $_"
    }
}

# TODO: Implementar escaneo de patrones (Get-ModifiedFiles, Scan-FileForSecrets)
# TODO: Implementar manejo de logs (Write-SecurityAlert)

# Lógica principal del script
try {
    if ($kill) {
        # Detener el demonio
        Stop-GitSecurityDaemon -RepositoryPath $repo
        exit 0
    }
    else {
        # Cargar patrones de configuración
        $patterns = Read-SecurityPatterns -ConfigurationPath $configuracion
        
        # Iniciar el demonio de monitoreo
        Start-GitSecurityWatcher -RepositoryPath $repo -SecurityPatterns $patterns -LogPath $log
    }
}
catch {
    Write-Host "Error: $_" -ForegroundColor Red
    exit 1
}
