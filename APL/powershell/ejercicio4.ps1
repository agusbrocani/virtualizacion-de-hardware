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
    [switch]$kill,

    [Parameter(Mandatory = $false)]
    [switch]$__daemon  # Parámetro interno para ejecución en background
)

function Invoke-DaemonProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Parameters,
        
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,
        
        [Parameter(Mandatory = $false)]
        [string]$DaemonName = "PowerShell Daemon",
        
        [Parameter(Mandatory = $true)]
        [bool]$IsDaemonMode
    )
    
    try {
        if ($IsDaemonMode) {
            # Ejecutar la acción directamente en modo demonio
            Write-Host "Ejecutando $DaemonName en modo demonio..." -ForegroundColor Green
            & $Action @Parameters
        }
        else {
            # Verificar que no haya otro demonio corriendo
            if (Test-DaemonRunning -RepositoryPath $RepositoryPath) {
                throw "Ya existe un demonio activo para el repositorio '$RepositoryPath'. Use -kill para detenerlo primero."
            }
            
            # Lanzar proceso en segundo plano
            $scriptPath = $PSCommandPath
            if (-not $scriptPath) {
                $scriptPath = $MyInvocation.MyCommand.Path
            }
            if (-not $scriptPath) {
                throw "No se pudo determinar la ruta del script actual"
            }
            
            # Construir argumentos para el proceso en background
            $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"")
            # Para debugging: agregar '-NoExit' para mantener ventana abierta
            
            # Agregar parámetros originales del script
            foreach ($key in $Parameters.Keys) {
                $value = $Parameters[$key]
                if ($value -is [switch] -and $value) {
                    $argumentList += "-$key"
                }
                else {
                    $escapedValue = $value -replace '"', '""'
                    $argumentList += "-$key", "`"$escapedValue`""
                }
            }
            
            # Agregar flag interno para modo demonio
            $argumentList += '-__daemon'
            
            Write-Host "Iniciando $DaemonName en segundo plano para repositorio: $RepositoryPath" -ForegroundColor Green
            Write-Host "Comando: pwsh.exe $($argumentList -join ' ')" -ForegroundColor Gray
            
            # Crear proceso en background - ventana oculta
            $process = Start-Process -FilePath 'pwsh.exe' -ArgumentList $argumentList -PassThru -WindowStyle Hidden
            
            # Crear archivo PID
            $pidFile = Get-PidFilePath -RepositoryPath $RepositoryPath
            $process.Id | Out-File -FilePath $pidFile -Force
            
            Write-Host "$DaemonName iniciado con PID: $($process.Id)" -ForegroundColor Cyan
            Write-Host "Archivo PID: $pidFile" -ForegroundColor Gray
            Write-Host "Use -kill para detener el demonio." -ForegroundColor Yellow
            
            # Verificar que el proceso se haya iniciado correctamente
            Start-Sleep -Seconds 2
            try {
                $runningProcess = Get-Process -Id $process.Id -ErrorAction Stop
                Write-Host "Proceso confirmado activo después de 2 segundos" -ForegroundColor Green
            }
            catch {
                Write-Host "ADVERTENCIA: El proceso pudo haber terminado inmediatamente" -ForegroundColor Yellow
                Write-Host "Verifying log file for errors..." -ForegroundColor Yellow
            }
            
            return $process.Id
        }
    }
    catch {
        throw "Error al iniciar demonio en background: $_"
    }
}

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

# Siempre se va a guardar el archivo en el directorio TEMP del usuario 
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
        
        # Ejecutar limpieza antes de detener el proceso
        Write-Host "Ejecutando limpieza de archivos temporales..." -ForegroundColor Yellow
        Clear-DaemonTempFiles -Force:$false
        
        Stop-Process -Id $processId -Force
        
        # Solo intentar eliminar el archivo PID si aún existe (la limpieza puede haberlo eliminado)
        if (Test-Path $pidFile) {
            Remove-Item $pidFile -Force
        }
        
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
    
    # NOTA: No verificamos demonio corriendo aquí porque esta función 
    # se llama tanto desde el proceso padre como desde el proceso demonio
    
    try {
        # Crear archivo PID y lo guardo en el file del PID
        $pidFile = Get-PidFilePath -RepositoryPath $RepositoryPath
        $PID | Out-File -FilePath $pidFile -Force
        
        Write-Host "Iniciando demonio de seguridad para repositorio: $RepositoryPath" -ForegroundColor Green
        Write-Host "PID del demonio: $PID" -ForegroundColor Cyan
        Write-Host "Archivo PID creado en: $pidFile" -ForegroundColor Gray
        
        $gitPath = Join-Path $RepositoryPath ".git"
        $watcher = New-Object System.IO.FileSystemWatcher
        $watcher.Path = $gitPath
        $watcher.IncludeSubdirectories = $true
        $watcher.EnableRaisingEvents = $true
        
        $watcher.Filter = "*"
        $watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::FileName
        
        # Enfoque simplificado: usar archivos temporales para pasar información al evento
        $configFile = Join-Path $env:TEMP "git-security-config-$PID.json"
        $config = @{
            RepositoryPath = $RepositoryPath
            SecurityPatterns = $SecurityPatterns
            LogPath = $LogPath
        }
        $config | ConvertTo-Json -Depth 10 | Out-File -FilePath $configFile -Encoding UTF8
        
        $action = {
            param($sender, $eventArgs)
            
            try {
                $changedFile = $eventArgs.FullPath
                $fileName = Split-Path $changedFile -Leaf
                
                Write-Verbose "Evento detectado: $($eventArgs.ChangeType) en $fileName"
                
                if ($fileName -eq "HEAD" -or 
                    $fileName -eq "COMMIT_EDITMSG" -or
                    $changedFile -like "*\refs\heads\*" -or 
                    $fileName -eq "packed-refs") {
                    
                    Write-Verbose "Cambio detectado en: $changedFile"
                    
                    # DEBOUNCE MECHANISM MEJORADO: Evitar procesamiento duplicado basado en commit hash
                    # Usar el PID específico del demonio actual en lugar de buscar todos los archivos
                    $configFile = "$env:TEMP\git-security-config-$PID.json"
                    if (-not (Test-Path $configFile)) {
                        Write-Verbose "ERROR: No se encontró archivo de configuración para PID $PID"
                        return
                    }
                    
                    $config = Get-Content $configFile | ConvertFrom-Json
                    $repoPath = $config.RepositoryPath
                    
                    # Voy al directorio del Repo, obtengo el hash del commit actual y vuelvo
                    Push-Location $repoPath
                    $currentCommitHash = git rev-parse HEAD 2>$null
                    Pop-Location
                    
                    if (-not $currentCommitHash) {
                        Write-Verbose "No se pudo obtener el hash del commit actual"
                        return
                    }
                    
                    # Crear archivo de control basado en commit hash usando el PID actual
                    $processedCommitsFile = "$env:TEMP\git-security-processed-$PID.json"
                    
                    # Cargar commits ya procesados
                    $processedCommits = @{}
                    if (Test-Path $processedCommitsFile) {
                        try {
                            $processedCommits = Get-Content $processedCommitsFile | ConvertFrom-Json -AsHashtable
                        }
                        catch {
                            $processedCommits = @{}
                        }
                    }
                    
                    # Verificar si este commit ya fue procesado
                    if ($processedCommits.ContainsKey($currentCommitHash)) {
                        Write-Verbose "DEBOUNCE: Commit $($currentCommitHash.Substring(0,7)) ya fue procesado, ignorando evento"
                        return
                    }
                    
                    # Marcar este commit como procesado ANTES de procesar
                    $processedCommits[$currentCommitHash] = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                    
                    # Limpiar commits antiguos (mantener solo los últimos 10)
                    if ($processedCommits.Count -gt 10) {
                        $sortedCommits = $processedCommits.GetEnumerator() | Sort-Object Value -Descending
                        $processedCommits = @{}
                        for ($i = 0; $i -lt 10; $i++) {
                            $processedCommits[$sortedCommits[$i].Key] = $sortedCommits[$i].Value
                        }
                    }
                    
                    # Guardar lista actualizada
                    $processedCommits | ConvertTo-Json | Out-File -FilePath $processedCommitsFile -Force
                    
                    Write-Verbose "PROCESANDO: Nuevo commit $($currentCommitHash.Substring(0,7)) detectado, iniciando escaneo"
                    
                    # Pequeño delay para que Git complete las operaciones
                    Start-Sleep -Milliseconds 500
                    
                    # Leer configuración del archivo temporal
                    $logFile = $config.LogPath
                    
                    # Convertir PSCustomObject a Hashtable para los patrones (me traigo los patrones a buscar y los guardo en una hashtable)
                    $patterns = @{
                        SimplePatterns = @($config.SecurityPatterns.SimplePatterns)
                        RegexPatterns = @($config.SecurityPatterns.RegexPatterns)
                    }
                    
                    Write-Verbose "Usando repositorio: '$repoPath'"
                    
                    if (-not $repoPath) {
                        Write-Verbose "ERROR: repoPath está vacío"
                        return
                    }
                    
                    # DEBUG: Verificar directamente git diff-tree (solo en modo verbose)
                    Write-Verbose "DEBUG: Ejecutando git diff-tree directamente..."
                    Push-Location $repoPath
                    $gitOutput = git diff-tree --no-commit-id --name-only -r HEAD 2>$null
                    Write-Verbose "DEBUG: Git output: '$gitOutput'"
                    Write-Verbose "DEBUG: LASTEXITCODE: $LASTEXITCODE"
                    Pop-Location
                    
                    # Get-Command me trae las funciones que definí en este script y con & ejecuto Get-ModifiedFiles
                    $modifiedFiles = & (Get-Command Get-ModifiedFiles) -RepositoryPath $repoPath
                    
                    Write-Verbose "Archivos modificados encontrados: $($modifiedFiles.Count)"
                    Write-Verbose "DEBUG: Lista de archivos: $($modifiedFiles -join ', ')"
                    
                    foreach ($file in $modifiedFiles) {
                        $fullPath = Join-Path $repoPath $file
                        Write-Verbose "Escaneando archivo: $file"
                        $alerts = & (Get-Command Scan-FileForSecrets) -FilePath $fullPath -SecurityPatterns $patterns
                        
                        Write-Verbose "Alertas encontradas en $file`: $($alerts.Count)"
                        
                        foreach ($alert in $alerts) {
                            & (Get-Command Write-SecurityAlert) -Alert $alert -LogPath $logFile
                        }
                    }
                }
            }
            catch {
                Write-Verbose "Error en el evento FileSystemWatcher: $_"
                Write-Verbose "Detalles del error: $($_.Exception.Message)"
            }
        }

        # Me suscribo a los eventos de cambio y creación del file watcher
        Register-ObjectEvent -InputObject $watcher -EventName "Changed" -Action $action
        Register-ObjectEvent -InputObject $watcher -EventName "Created" -Action $action
        
        # Limpiar archivo de configuración al finalizar. Escucha al motor de powershell y antes que se cierre ejecuta
        Register-EngineEvent PowerShell.Exiting -Action {
            try {
                # Usar la función centralizada de limpieza
                Write-Verbose "Evento PowerShell.Exiting activado - Limpiando archivos temporales del demonio"
                
                # Obtener archivos de configuración del PID actual
                $currentPidFiles = Get-ChildItem "$env:TEMP\git-security-config-$PID-*.json" -ErrorAction SilentlyContinue
                foreach ($file in $currentPidFiles) {
                    Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
                    Write-Verbose "Limpiado archivo de configuración: $($file.Name)"
                }
                
                # Obtener archivos de commits procesados del PID actual
                $currentCommitFiles = Get-ChildItem "$env:TEMP\git-security-processed-$PID-*.json" -ErrorAction SilentlyContinue
                foreach ($file in $currentCommitFiles) {
                    Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
                    Write-Verbose "Limpiado archivo de commits procesados: $($file.Name)"
                }
            }
            catch {
                Write-Verbose "Error durante limpieza en PowerShell.Exiting: $_"
            }
        } | Out-Null # Evitar salida en consola
        
        Write-Host "Demonio de seguridad activo. Monitoreando cambios en: $gitPath" -ForegroundColor Green
        Write-Host "Archivo de log: $LogPath" -ForegroundColor Gray
        
        Write-Host "Demonio iniciado correctamente. Use -kill para detenerlo." -ForegroundColor Green
        Write-Host "El demonio se ejecuta en segundo plano de forma continua." -ForegroundColor Cyan
        
        # Bucle principal del demonio
        $counter = 0
        try {
            while ($true) {
                # Esto es para que no se consuma CPU innecesariamente. Hacemos un sleep largo
                Start-Sleep -Seconds 10
                $counter++
                
                Write-Verbose "Demonio activo - Ciclo #$counter (PID: $PID)"
                
                # Verificar si el archivo PID aún existe (método de control)
                if (-not (Test-Path $pidFile)) {
                    Write-Host "Archivo PID eliminado. Deteniendo demonio..." -ForegroundColor Yellow
                    break
                }
            }
        }
        catch {
            # Manejo de errores específicos del bucle principal
            Write-Host "Error en el bucle principal del demonio: $_" -ForegroundColor Red
            Write-Verbose "Detalles del error: $($_.Exception.Message)"
            Write-Verbose "StackTrace: $($_.ScriptStackTrace)"
            
            # El demonio se detendrá, pero con información de diagnóstico
            throw $_ # Re-propagar para que el catch externo también lo maneje
        }
        finally {
            # Cleanup del FileSystemWatcher
            $watcher.EnableRaisingEvents = $false
            $watcher.Dispose()
            Get-EventSubscriber | Unregister-Event -ErrorAction SilentlyContinue
            
            Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
            Write-Host "Demonio detenido y recursos liberados." -ForegroundColor Red
        }
    }
    catch {
        # El cleanup del PID ya se maneja en el finally del bucle principal
        # Solo necesitamos propagar el error con contexto adicional
        throw "Error al iniciar el watcher: $_"
    }
}

# Funciones de escaneo de seguridad
function Get-ModifiedFiles {
    # Obtiene archivos modificados en el último commit de Git
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,
        
        [Parameter(Mandatory = $false)]
        [string]$CommitHash = "HEAD"
    )
    
    try {
        Push-Location $RepositoryPath
        
        # Obtener archivos modificados en el commit especificado (post-commit)
        $modifiedFiles = git diff-tree --no-commit-id --name-only -r $CommitHash 2>$null
        
        Write-Verbose "Get-ModifiedFiles: git output = '$modifiedFiles'"
        Write-Verbose "Get-ModifiedFiles: LASTEXITCODE = $LASTEXITCODE"
        
        if ($LASTEXITCODE -ne 0) {
            Write-Verbose "No se pudo obtener archivos del commit $CommitHash"
            return @()
        }
        
        # Filtrar solo archivos de texto relevantes para escaneo de seguridad
        $validFiles = $modifiedFiles | Where-Object { 
            Write-Verbose "DEBUG: Evaluando archivo '$_'"
            $fullPath = Join-Path $RepositoryPath $_
            $exists = Test-Path $fullPath -PathType Leaf
            Write-Verbose "DEBUG: Archivo '$_' -> Path: '$fullPath' -> Exists: $exists"
            
            $_ -and 
            $exists -and
            $_ -notlike "*.exe" -and
            $_ -notlike "*.dll" -and
            $_ -notlike "*.bin" -and
            $_ -notlike "*.png" -and
            $_ -notlike "*.jpg" -and
            $_ -notlike "*.gif" -and
            $_ -notlike "*.pdf"
        }
        
        Write-Verbose "Encontrados $($validFiles.Count) archivos modificados válidos para escaneo"
        return $validFiles
    }
    catch {
        Write-Error "Error al obtener archivos modificados: $_"
        return @()
    }
    finally {
        Pop-Location
    }
}

function Scan-FileForSecrets {
    # Escanea un archivo en busca de patrones de seguridad sospechosos
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$SecurityPatterns
    )
    
    $alerts = @()
    
    try {
        if (-not (Test-Path $FilePath -PathType Leaf)) {
            Write-Warning "Archivo no encontrado: $FilePath"
            return $alerts
        }
        
        # Leer archivo usando System.IO para evitar problemas de encoding
        $fileContent = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
        # Dividir por líneas correctamente usando operador -split con fuerza de array
        $lines = @($fileContent -split "`r?`n")
        
        Write-Verbose "Scan-FileForSecrets: Escaneando archivo $FilePath con $($lines.Count) líneas"
        Write-Verbose "Patrones simples: $($SecurityPatterns.SimplePatterns.Count)"
        Write-Verbose "Patrones regex: $($SecurityPatterns.RegexPatterns.Count)"
        
        # Escanear patrones simples - mantener números de línea originales
        foreach ($pattern in $SecurityPatterns.SimplePatterns) {
            Write-Verbose "Buscando patrón simple '$pattern'"
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $currentLine = $lines[$i]
                # Solo procesar líneas no vacías
                if ($currentLine -ne '' -and $currentLine -match [regex]::Escape($pattern)) {
                    $lineNumber = $i + 1  # Número de línea real en el archivo
                    Write-Verbose "MATCH ENCONTRADO! Patrón '$pattern' en línea $lineNumber"
                    $alerts += @{
                        File = $FilePath
                        Pattern = $pattern
                        LineNumber = $lineNumber
                        LineContent = $currentLine.Trim()
                        PatternType = "Simple"
                    }
                    Write-Verbose "Patrón simple encontrado: '$pattern' en línea $lineNumber"
                }
            }
        }
        
        # Escanear patrones regex - mantener números de línea originales
        foreach ($regexPattern in $SecurityPatterns.RegexPatterns) {
            try {
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    $currentLine = $lines[$i]
                    # Solo procesar líneas no vacías
                    if ($currentLine -ne '' -and $currentLine -match $regexPattern) {
                        $lineNumber = $i + 1  # Número de línea real en el archivo
                        $alerts += @{
                            File = $FilePath
                            Pattern = $regexPattern
                            LineNumber = $lineNumber
                            LineContent = $currentLine.Trim()
                            PatternType = "Regex"
                            Match = $matches[0]
                        }
                        Write-Verbose "Patrón regex encontrado: '$regexPattern' en línea $lineNumber"
                    }
                }
            }
            catch {
                Write-Warning "Patrón regex inválido: $regexPattern - $_"
            }
        }
        
        Write-Verbose "Escaneo completado: $($alerts.Count) alertas encontradas"
        return $alerts
    }
    catch {
        Write-Error "Error al escanear archivo ${FilePath}: $_"
        return $alerts
    }
}

function Write-SecurityAlert {
    # Escribe una alerta de seguridad al archivo de log
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Alert,
        
        [Parameter(Mandatory = $true)]
        [string]$LogPath
    )
    
    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $fileName = Split-Path $Alert.File -Leaf
        
        # Formatear entrada del log según especificación
        $logEntry = "[$timestamp] Alerta: patrón '$($Alert.Pattern)' encontrado en el archivo '$fileName'"
        
        if ($Alert.LineNumber) {
            $logEntry += " (línea $($Alert.LineNumber))"
        }
        
        # Agregar información adicional si está disponible
        if ($Alert.PatternType) {
            $logEntry += " [Tipo: $($Alert.PatternType)]"
        }
        
        # Crear directorio padre si no existe
        $parentDir = Split-Path $LogPath -Parent
        if ($parentDir -and -not (Test-Path $parentDir)) {
            New-Item -Path $parentDir -ItemType Directory -Force | Out-Null
        }
        
        # Escribir al log
        Add-Content -Path $LogPath -Value $logEntry -Encoding UTF8
        
        # También mostrar en consola para feedback inmediato
        Write-Host $logEntry -ForegroundColor Red
        
        Write-Verbose "Alerta escrita al log: $LogPath"
    }
    catch {
        Write-Error "Error al escribir alerta al log: $_"
    }
}

function Clear-DaemonTempFiles {
    # Limpia archivos temporales huérfanos del demonio
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$Force  # Forzar limpieza de todos los archivos, incluso de demonios activos
    )
    
    try {
        Write-Host "Iniciando limpieza de archivos temporales del demonio..." -ForegroundColor Yellow
        
        # Buscar todos los archivos temporales relacionados
        $configFiles = Get-ChildItem "$env:TEMP\git-security-config-*.json" -ErrorAction SilentlyContinue
        $processedFiles = Get-ChildItem "$env:TEMP\git-security-processed-*.json" -ErrorAction SilentlyContinue
        $pidFiles = Get-ChildItem "$env:TEMP\git-security-daemon-*.pid" -ErrorAction SilentlyContinue
        $debounceFiles = Get-ChildItem "$env:TEMP\git-security-debounce-*.tmp" -ErrorAction SilentlyContinue
        
        Write-Host "Archivos temporales encontrados:" -ForegroundColor Cyan
        Write-Host "  • Configuración: $($configFiles.Count)" -ForegroundColor Gray
        Write-Host "  • Commits procesados: $($processedFiles.Count)" -ForegroundColor Gray
        Write-Host "  • Archivos PID: $($pidFiles.Count)" -ForegroundColor Gray
        Write-Host "  • Archivos debounce obsoletos: $($debounceFiles.Count)" -ForegroundColor Gray
        
        $totalFiles = $configFiles.Count + $processedFiles.Count + $pidFiles.Count + $debounceFiles.Count
        if ($totalFiles -eq 0) {
            Write-Host "No se encontraron archivos temporales para limpiar." -ForegroundColor Green
            return
        }
        
        # Verificar qué PIDs están activos si no es limpieza forzada
        $activePids = @()
        if (-not $Force) {
            foreach ($pidFile in $pidFiles) {
                try {
                    $pid = Get-Content $pidFile.FullName -ErrorAction Stop
                    $process = Get-Process -Id $pid -ErrorAction Stop
                    $activePids += $pid
                    Write-Host "  ⚠️  PID $pid está activo - archivos relacionados serán preservados" -ForegroundColor Yellow
                }
                catch {
                    # PID no activo, se puede limpiar
                }
            }
        }
        
        $cleanedCount = 0
        
        # Limpiar archivos de configuración
        foreach ($file in $configFiles) {
            $pidFromFile = $file.BaseName.Split('-')[-1]
            if ($Force -or $pidFromFile -notin $activePids) {
                Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
                Write-Host "  ✓ Eliminado: $($file.Name)" -ForegroundColor Green
                $cleanedCount++
            }
            else {
                Write-Host "  → Preservado: $($file.Name) (demonio activo)" -ForegroundColor Yellow
            }
        }
        
        # Limpiar archivos de commits procesados
        foreach ($file in $processedFiles) {
            $pidFromFile = $file.BaseName.Split('-')[-1]
            if ($Force -or $pidFromFile -notin $activePids) {
                Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
                Write-Host "  ✓ Eliminado: $($file.Name)" -ForegroundColor Green
                $cleanedCount++
            }
            else {
                Write-Host "  → Preservado: $($file.Name) (demonio activo)" -ForegroundColor Yellow
            }
        }
        
        # Limpiar archivos PID (solo los huérfanos)
        foreach ($file in $pidFiles) {
            try {
                $pid = Get-Content $file.FullName -ErrorAction Stop
                $process = Get-Process -Id $pid -ErrorAction Stop
                if ($Force) {
                    Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
                    Write-Host "  ✓ Eliminado: $($file.Name) (forzado)" -ForegroundColor Green
                    $cleanedCount++
                }
                else {
                    Write-Host "  → Preservado: $($file.Name) (proceso activo PID $pid)" -ForegroundColor Yellow
                }
            }
            catch {
                # Archivo PID huérfano (proceso no existe)
                Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
                Write-Host "  ✓ Eliminado: $($file.Name) (proceso no existe)" -ForegroundColor Green
                $cleanedCount++
            }
        }
        
        # Limpiar archivos debounce obsoletos (de versiones anteriores)
        foreach ($file in $debounceFiles) {
            Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
            Write-Host "  ✓ Eliminado: $($file.Name) (obsoleto)" -ForegroundColor Green
            $cleanedCount++
        }
        
        Write-Host "Limpieza completada: $cleanedCount archivos eliminados de $totalFiles encontrados." -ForegroundColor Green
        
        if ($activePids.Count -gt 0 -and -not $Force) {
            Write-Host "Nota: Los archivos temporales huérfanos se limpian automáticamente." -ForegroundColor Cyan
        }
    }
    catch {
        Write-Error "Error durante la limpieza de archivos temporales: $_"
    }
}

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
        
        # Definir la acción del demonio como scriptblock
        $daemonAction = {
            param($RepositoryPath, $SecurityPatterns, $LogPath)
            Start-GitSecurityWatcher -RepositoryPath $RepositoryPath -SecurityPatterns $SecurityPatterns -LogPath $LogPath
        }
        
        # Preparar parámetros para el demonio
        $daemonParameters = @{
            repo = $repo
            configuracion = $configuracion
            log = $log
        }
        
        # Verificar si estamos en modo demonio
        if ($__daemon) {
            # Ejecutar directamente en modo demonio
            Write-Host "Modo demonio detectado. Ejecutando Start-GitSecurityWatcher directamente..." -ForegroundColor Cyan
            Start-GitSecurityWatcher -RepositoryPath $repo -SecurityPatterns $patterns -LogPath $log
        }
        else {
            # Usar el cmdlet personalizado para lanzar en background
            Invoke-DaemonProcess -Action $daemonAction -Parameters $daemonParameters -RepositoryPath $repo -DaemonName "Git Security Monitor" -IsDaemonMode $false
            exit 0
        }
    }
}
catch {
    Write-Host "Error: $_" -ForegroundColor Red
    exit 1
}
