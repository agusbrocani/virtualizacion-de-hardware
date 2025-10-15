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
    .\ejercicio4.ps1 -repo C:\mi-proyecto -configuracion .\lotes\patrones.conf -log .\security.log

.EXAMPLE
    .\ejercicio4.ps1 -repo C:\mi-proyecto -kill
#>
[CmdletBinding(DefaultParameterSetName='Run')]
param(
  [Parameter(Mandatory=$true, ParameterSetName='Run')]
  [Parameter(Mandatory=$true, ParameterSetName='Kill')]
  [ValidateScript({
    if (-not (Test-Path $_ -PathType Container)) { throw "El directorio '$_' no existe." }
    if (-not (Test-Path (Join-Path $_ '.git') -PathType Container)) { throw "El directorio '$_' no es un repositorio Git válido." }
    $true
  })]
  [string]$Repo,
  
  [Parameter(Mandatory=$true, ParameterSetName='Run')]
  [ValidateScript({
    if (-not (Test-Path $_ -PathType Leaf)) { throw "El archivo de configuración '$_' no existe." }
    $valid = Get-Content $_ | Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') }
    if ($valid.Count -eq 0) { throw "El archivo de configuración no contiene patrones válidos." }
    $true
  })]
  [string]$Configuracion,

  [Parameter(Mandatory=$true, ParameterSetName='Run')]
  [ValidateScript({
    if (Test-Path $_ -PathType Container) { return $true }
    $p = Split-Path $_ -Parent
    if ($p -and -not (Test-Path $p -PathType Container)) { throw "El directorio padre '$p' no existe." }
    $true
  })]
  [string]$Log,

  [Parameter(Mandatory=$true, ParameterSetName='Kill')]
  [switch]$Kill,

  [Parameter(Mandatory=$false, ParameterSetName='Run')]
  [switch]$__daemon,

  [int]$Interval = 5,

  [switch]$DebugRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- UI ----------
$RED="`e[0;31m"; $GREEN="`e[0;32m"; $YELLOW="`e[1;33m"; $CYAN="`e[0;36m"; $NC="`e[0m"
function log_error{ param([string]$m) Write-Host "$($RED)[ERROR]$($NC) $m" }
function log_info { param([string]$m) Write-Host  "$($GREEN)[INFO] $($NC)$m" }
function log_warn { param([string]$m) Write-Host  "$($YELLOW)[WARN] $($NC)$m" }
function dbg      { param([string]$m) if ($DebugRun) { Write-Host "$($CYAN)[DEBUG]$($NC) $m" } }
function ts{ (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }

# ---------- Normalización ----------
function Normalize-RepoPath {
  param([string]$p)
  dbg "Normalize-RepoPath: entrada='$p'"
  try { $rp = (Resolve-Path -LiteralPath $p -ErrorAction Stop).Path } catch { $rp = [IO.Path]::GetFullPath($p) }
  $rp = $rp.TrimEnd('\','/')
  dbg "Normalize-RepoPath: salida='$rp'"
  return $rp
}

# ---------- Utils ----------
function Get-TempPath { [IO.Path]::GetTempPath() }
function Get-PwshPath { (Get-Command pwsh -ErrorAction Stop).Source }
function Get-RepoName { param([string]$RepositoryPath) (Split-Path $RepositoryPath -Leaf) -replace '[\\/:*?"<>|]', '_' -replace '^\.+','' }

function Ensure-LogFilePath {
  param([string]$LogParam,[string]$RepositoryPath)
  if (Test-Path $LogParam -PathType Container) {
    $repoName = Get-RepoName $RepositoryPath
    $final = (Join-Path $LogParam "audit-$repoName.log")  # sin punto
    dbg "Ensure-LogFilePath: carpeta detectada. Log='$final'"
    return $final
  }
  $parent = Split-Path $LogParam -Parent
  if ($parent) {
    $final = (Join-Path (Resolve-Path $parent).Path (Split-Path $LogParam -Leaf))
    dbg "Ensure-LogFilePath: archivo con parent. Log='$final'"
    return $final
  }
  $final = Join-Path (Get-Location).Path $LogParam
  dbg "Ensure-LogFilePath: archivo relativo. Log='$final'"
  return $final
}

function Get-PidFilePath {
  param([Parameter(Mandatory=$true)][string]$RepositoryPath)
  $norm = Normalize-RepoPath $RepositoryPath
  $repoKey = ($norm -replace '[\\/:*?"<>|]', '_').ToLower()
  $pf = [IO.Path]::Combine((Get-TempPath), "git-security-daemon-$repoKey.pid")
  dbg "Get-PidFilePath: normRepo='$norm' pidfile='$pf'"
  return $pf
}

function Read-SecurityPatterns {
  param([Parameter(Mandatory=$true)][string]$ConfigurationPath)
  $patterns = @{ Simple=@(); Regex=@() }
  $lines = Get-Content $ConfigurationPath | Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') }
  foreach($l in $lines){
    $c=$l.Trim()
    if ($c.StartsWith('regex:')) { $patterns.Regex += $c.Substring(6) } else { $patterns.Simple += $c }
  }
  dbg "Read-SecurityPatterns: simples=$($patterns.Simple.Count) regex=$($patterns.Regex.Count)"
  $patterns
}

# --- LIMPIEZA TOTAL DE ARTEFACTOS DEL DAEMON ---
function Clear-DaemonGarbage {
  param(
    [Parameter(Mandatory=$true)][int]$DaemonPid,
    [Parameter(Mandatory=$true)][string]$RepositoryPath
  )
  try {
    $tmp = [IO.Path]::GetTempPath()
    $cfg  = Join-Path $tmp ("git-security-config-{0}.json"    -f $DaemonPid)
    $proc = Join-Path $tmp ("git-security-processed-{0}.json" -f $DaemonPid)
    $pidf = Get-PidFilePath -RepositoryPath $RepositoryPath

    foreach ($f in @($cfg,$proc,$pidf)) {
      if (Test-Path $f) {
        dbg "Clear-DaemonGarbage: removiendo '$f'"
        Remove-Item $f -Force -ErrorAction SilentlyContinue
      }
    }
  } catch {
    dbg "Clear-DaemonGarbage: error -> $($_.Exception.Message)"
  }
}

# ---------- Daemon: detección / kill (por pidfile) ----------
function Test-DaemonRunning {
  param([Parameter(Mandatory=$true)][string]$RepositoryPath)

  $pidFile = Get-PidFilePath -RepositoryPath $RepositoryPath
  dbg "Test-DaemonRunning: pidfile='$pidFile'"
  if (-not (Test-Path $pidFile)) { dbg "Test-DaemonRunning: pidfile inexistente"; return $false }

  # leer PID con reintentos cortos
  $daemonPid = $null
  $tries = 4
  for ($i=1; $i -le $tries; $i++) {
    try {
      $daemonPid = (Get-Content $pidFile -Raw).Trim()
      dbg "Test-DaemonRunning: intento $i pid leído='$daemonPid'"
      if ($daemonPid -match '^\d+$') { break }
    } catch {
      dbg "Test-DaemonRunning: error leyendo pidfile en intento $i -> $($_.Exception.Message)"
    }
    Start-Sleep -Milliseconds 120
  }

  if (-not $daemonPid -or $daemonPid -notmatch '^\d+$') {
    dbg "Test-DaemonRunning: contenido inválido en pidfile -> limpiar y permitir"
    Clear-DaemonGarbage -DaemonPid 0 -RepositoryPath $RepositoryPath
    return $false
  }

  # ¿Existe el proceso?
  try {
    Get-Process -Id $daemonPid -ErrorAction Stop | Out-Null
    dbg "Test-DaemonRunning: proceso $daemonPid existe"
    return $true
  } catch {
    dbg "Test-DaemonRunning: proceso $daemonPid NO existe -> limpiar y permitir"
    Clear-DaemonGarbage -DaemonPid ([int]$daemonPid) -RepositoryPath $RepositoryPath
    return $false
  }
}

function Stop-GitSecurityDaemon {
  param([Parameter(Mandatory=$true)][string]$RepositoryPath)

  $pidFile = Get-PidFilePath -RepositoryPath $RepositoryPath
  dbg "Stop: repoNorm='$RepositoryPath' pidfile='$pidFile'"
  if (-not (Test-Path $pidFile)) { throw "No se encontró un daemon activo para '$RepositoryPath'." }

  $daemonPid = $null
  $tries = 4
  for ($i=1; $i -le $tries; $i++) {
    try {
      $daemonPid = (Get-Content $pidFile -Raw).Trim()
      dbg "Stop: intento $i, PID leído='$daemonPid'"
      if ($daemonPid -match '^\d+$') { break }
    } catch {
      dbg "Stop: error leyendo pidfile intento $i -> $($_.Exception.Message)"
    }
    Start-Sleep -Milliseconds 120
  }

  if (-not $daemonPid -or $daemonPid -notmatch '^\d+$') {
    dbg "Stop: PID inválido; limpio basura sin intentar Stop-Process"
    Clear-DaemonGarbage -DaemonPid 0 -RepositoryPath $RepositoryPath
    log_info "Daemon detenido para: $RepositoryPath"
    return
  }

  log_info "Deteniendo daemon (PID $daemonPid) ..."
  try {
    Get-Process -Id $daemonPid -ErrorAction Stop | Out-Null
    dbg "Stop: proceso $daemonPid existe -> Stop-Process"
    Stop-Process -Id $daemonPid -Force -ErrorAction SilentlyContinue
  } catch {
    dbg "Stop: proceso $daemonPid NO existe (quizás ya había muerto)"
  }

  Clear-DaemonGarbage -DaemonPid ([int]$daemonPid) -RepositoryPath $RepositoryPath
  log_info "Daemon detenido para: $RepositoryPath"
}

# ---------- Lanzar hijo ----------
function Invoke-DaemonProcess {
  param(
    [Parameter(Mandatory=$true)][string]$RepositoryPath,
    [Parameter(Mandatory=$true)][hashtable]$RunArgs
  )
  $RepositoryPath = Normalize-RepoPath $RepositoryPath
  dbg "Invoke: repoNorm='$RepositoryPath'"

  if (Test-DaemonRunning -RepositoryPath $RepositoryPath) {
    throw "Ya existe un daemon activo para '$RepositoryPath'. Use -Kill para detenerlo."
  }

  $scriptPath = $PSCommandPath; if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }
  if (-not $scriptPath) { throw "No se pudo determinar la ruta del script actual." }
  try { $scriptPath = (Resolve-Path -LiteralPath $scriptPath -ErrorAction Stop).Path } catch { }  # ABSOLUTO
  dbg "Invoke: scriptPath abs='$scriptPath'"

  $RunArgs['Repo'] = $RepositoryPath

  $argumentList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$scriptPath`"")
  foreach ($k in $RunArgs.Keys) {
    $v = $RunArgs[$k]
    if ($v -is [switch]) { if ($v) { $argumentList += "-$k" } }
    elseif ($v -is [bool]) { if ($v) { $argumentList += "-$k" } }
    else { $argumentList += "-$k","`"$($v -replace '"','""')`"" }
  }
  $argumentList += '-__daemon'   # no duplicar -DebugRun acá

  $pwsh = Get-PwshPath
  dbg "Invoke: pwsh='$pwsh'"
  dbg "Invoke: cmdline=`"$pwsh $($argumentList -join ' ')`""

  $p = if ($IsWindows) {
    Start-Process -FilePath $pwsh -ArgumentList $argumentList -PassThru -WindowStyle Hidden
  } else {
    Start-Process -FilePath $pwsh -ArgumentList $argumentList -PassThru
  }
  dbg "Invoke: child PID=$($p.Id)"

  # El pidfile lo escribe SOLO el hijo.
  Start-Sleep -Milliseconds 150

  log_info "Daemon iniciado en segundo plano (pid $($p.Id))."
  $p.Id
}

# ---------- Git / Escaneo ----------
function Is-BinaryFile {
  param([string]$path)
  try {
    $fs=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
      $len=[Math]::Min(8192,[int]$fs.Length); $buf=New-Object byte[] $len; $n=$fs.Read($buf,0,$len)
      for($i=0;$i -lt $n;$i++){ if($buf[$i]-eq 0){return $true} } ; return $false
    } finally { $fs.Dispose() }
  } catch { return $true }
}

function Try-CreateWatcher {
  param([string]$path)
  try { $fsw = New-Object IO.FileSystemWatcher; $fsw.Path=$path; $fsw.IncludeSubdirectories=$true; $fsw.EnableRaisingEvents=$true; return $fsw } catch { return $null }
}

function Log-Line{ param([string]$line) Add-Content -LiteralPath $Log -Value $line -Encoding UTF8 }
function Log-Alert{ param([string]$pattern,[string]$file,[int]$line,[string]$tipo) Log-Line ("[{0}] Alerta: patrón '{1}' encontrado en el archivo '{2}' [Tipo: {4}]" -f (ts), $pattern, $file, $line, $tipo) }

function Scan-File-Patterns{
  param([string]$relPath,[hashtable]$PATTERNS)
  if ([string]::IsNullOrWhiteSpace($relPath)) { return }
  if ($relPath -like '.git/*') { return }
  $abs = Join-Path $Repo $relPath
  if (-not (Test-Path $abs -PathType Leaf)) { return }
  if (Is-BinaryFile $abs) { return }

  $content = Get-Content -LiteralPath $abs -Raw -ErrorAction SilentlyContinue
  if ($null -eq $content) { return }
  $content = $content -replace "`r",""
  $arr = $content -split "`n",-1

  foreach ($s in $PATTERNS.Simple) {
    $p = $s.Trim(); if ([string]::IsNullOrWhiteSpace($p)) { continue }
    for ($i=0; $i -lt $arr.Length; $i++) { if ($arr[$i] -like "*$p*") { Log-Alert $p $relPath ($i+1) "Simple" } }
  }
  foreach ($rx in $PATTERNS.Regex) {
    $r = $rx.Trim(); if ([string]::IsNullOrWhiteSpace($r)) { continue }
    for ($i=0; $i -lt $arr.Length; $i++) {
      if ([Text.RegularExpressions.Regex]::IsMatch($arr[$i], $r, 'IgnoreCase')) { Log-Alert $r $relPath ($i+1) "Regex" }
    }
  }
}

# ---------- Hijo (daemon real) ----------
function Start-GitSecurityWatcher {
  param([Parameter(Mandatory=$true)][string]$RepositoryPath,
        [Parameter(Mandatory=$true)][hashtable]$PATTERNS,
        [Parameter(Mandatory=$true)][string]$LogPath,
        [Parameter(Mandatory=$true)][int]$IntervalLocal)

  $RepositoryPath = Normalize-RepoPath $RepositoryPath
  $pidFile = Get-PidFilePath -RepositoryPath $RepositoryPath
  dbg "Child: repoNorm='$RepositoryPath'"
  dbg "Child: pidfile='$pidFile'"
  dbg "Child: escribir PID=$PID"
  $PID | Out-File -FilePath $pidFile -Force -Encoding ascii

  # cleanup automático al salir (cfg + processed + pidfile)
  Register-EngineEvent PowerShell.Exiting -Action {
    try {
      Clear-DaemonGarbage -DaemonPid $PID -RepositoryPath $using:RepositoryPath
    } catch {}
  } | Out-Null

  # rama para mostrar en logs (heurística main/master si HEAD no es una de ellas)
  $branch = (git -C "$RepositoryPath" symbolic-ref --quiet --short HEAD 2>$null)
  if ($branch -ne "main" -and $branch -ne "master") {
    if (git -C "$RepositoryPath" show-ref --verify --quiet "refs/heads/main") { $branch = "main" }
    elseif (git -C "$RepositoryPath" show-ref --verify --quiet "refs/heads/master") { $branch = "master" }
    else { $branch = "main" }
  }

  $watchPath = Join-Path $RepositoryPath ".git"
  $fsw = Try-CreateWatcher -path $watchPath
  $useWatcher = [bool]$fsw
  dbg "Child: watchPath='$watchPath' useWatcher=$useWatcher"
  if (-not $useWatcher) { log_warn "No se pudo crear FileSystemWatcher: se usará polling." }

  $createdReg=$changedReg=$deletedReg=$renamedReg=$null
  if ($useWatcher) {
    $trigger = { }  # despertar
    $createdReg = Register-ObjectEvent -InputObject $fsw -EventName Created -Action $trigger
    $changedReg = Register-ObjectEvent -InputObject $fsw -EventName Changed -Action $trigger
    $deletedReg = Register-ObjectEvent -InputObject $fsw -EventName Deleted -Action $trigger
    $renamedReg = Register-ObjectEvent -InputObject $fsw -EventName Renamed -Action $trigger
  }

  Log-Line ("[{0}] Patrones cargados: {1} simples, {2} regex" -f (ts), $PATTERNS.Simple.Count, $PATTERNS.Regex.Count)
  log_info "Monitoreando $RepositoryPath (rama $branch) | log: $LogPath"

  function __branch(){ (git -C "$RepositoryPath" symbolic-ref --quiet --short HEAD 2>$null) }
  function __head(){ (git -C "$RepositoryPath" rev-parse --verify -q HEAD 2>$null) }
  $lastCommit = __head
  dbg "Child: lastCommit inicial='$lastCommit'"

  while ($true) {
    if (-not (Test-Path $pidFile)) { log_warn "PID file eliminado. Saliendo..."; break }

    # dormir/esperar antes de cada ciclo
    if ($useWatcher) { Wait-Event -Timeout $IntervalLocal | Out-Null; Get-Event | Remove-Event }
    else { Start-Sleep -Seconds $IntervalLocal }

    # *** FILTRO DE RAMA: solo procesar en main/master ***
    $currBranch = __branch
    if ($null -eq $currBranch -or ($currBranch -ne 'main' -and $currBranch -ne 'master')) {
      dbg "Child: rama '$currBranch' fuera de allowlist (main/master). Saltando ciclo."
      continue
    }

    $current = __head
    dbg "Child: HEAD actual='$current' (previo='$lastCommit')"

    if (-not $lastCommit -and $current) {
      $all = @(git -C "$RepositoryPath" ls-tree -r --name-only $current 2>$null)
      dbg "Child: primer commit -> archivos=$($all.Count)"
      if ($all.Count -gt 0) {
        Log-Line ("[{0}] Detectados {1} archivos iniciales en {2} (primer commit)" -f (ts), $all.Count, $current.Substring(0,7))
        foreach($f in $all){ Scan-File-Patterns $f $PATTERNS }
      }
      $lastCommit = $current; continue
    }

    if ($current -and $lastCommit -and $current -ne $lastCommit) {
      $changed = @(git -C "$RepositoryPath" diff --name-only "$lastCommit..$current" -- 2>$null)
      if ($changed.Count -eq 0) { $changed = @(git -C "$RepositoryPath" diff-tree --no-commit-id --name-only -r $current 2>$null) }
      dbg "Child: changed count=$($changed.Count)"
      if ($changed.Count -gt 0) {
        Log-Line ("[{0}] Detectados {1} archivos modificados en {2}..{3}" -f (ts), $changed.Count, $lastCommit.Substring(0,7), $current.Substring(0,7))
        foreach($f in $changed){ Scan-File-Patterns $f $PATTERNS }
      } else {
        Log-Line ("[{0}] Commit {1}..{2} sin cambios detectables en archivos (diff vacío)" -f (ts), $lastCommit.Substring(0,7), $current.Substring(0,7))
      }
      $lastCommit = $current
    }
  }

  if ($useWatcher) {
    foreach ($r in @($createdReg,$changedReg,$deletedReg,$renamedReg)) { if ($r) { Unregister-Event -SourceIdentifier $r.Name -ErrorAction SilentlyContinue } }
    if ($fsw) { $fsw.EnableRaisingEvents = $false; $fsw.Dispose() }
  }
  # Por si quedara algo:
  Clear-DaemonGarbage -DaemonPid $PID -RepositoryPath $RepositoryPath
  log_info "Demonio detenido y recursos liberados."
}

# ---------- Main ----------
try {
  dbg "Main: ParamSet='$($PSCmdlet.ParameterSetName)'"
  dbg "Main: args: Repo='$Repo' Config='$Configuracion' Log='$Log' Kill=$Kill __daemon=$__daemon Interval=$Interval DebugRun=$DebugRun"

  # --- Validación explícita de -Kill ---
  if ($Kill) {
    if (-not $PSBoundParameters.ContainsKey('Repo')) {
      log_error "Con -Kill debe indicar -Repo."
      exit 1
    }
    if ($PSBoundParameters.ContainsKey('Configuracion') -or $PSBoundParameters.ContainsKey('Log')) {
      log_error "Con -Kill solo se permite -Repo (sin -Configuracion ni -Log)."
      exit 1
    }
  }

  $Repo = Normalize-RepoPath $Repo
  dbg "Main: Repo normalizado='$Repo'"

  if ($PSCmdlet.ParameterSetName -eq 'Kill') {
    Stop-GitSecurityDaemon -RepositoryPath $Repo
    exit 0
  }

  $Configuracion = (Resolve-Path -Path $Configuracion -ErrorAction Stop).Path
  $Log = Ensure-LogFilePath -LogParam $Log -RepositoryPath $Repo
  dbg "Main: Config='$Configuracion'"
  dbg "Main: Log final='$Log'"

  $logDir = Split-Path -Path $Log -Parent
  if ($logDir -and -not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
  try { Add-Content -LiteralPath $Log -Value "" -Encoding UTF8 } catch { log_error "No puedo escribir en '$Log' (¿es un directorio o falta permiso?)."; exit 1 }

  if ($__daemon) {
    dbg "Main: Entrando en hijo (daemon real)."
    $PATTERNS = Read-SecurityPatterns -ConfigurationPath $Configuracion
    Start-GitSecurityWatcher -RepositoryPath $Repo -PATTERNS $PATTERNS -LogPath $Log -IntervalLocal $Interval
  } else {
    dbg "Main: Proceso padre. Chequeo duplicados por pidfile."
    if (Test-DaemonRunning -RepositoryPath $Repo) {
      throw "Ya existe un daemon activo para '$Repo'. Use -Kill para detenerlo."
    }
    $args = @{ Repo=$Repo; Configuracion=$Configuracion; Log=$Log; Interval=$Interval }
    if ($DebugRun) { $args['DebugRun'] = $true }
    Invoke-DaemonProcess -RepositoryPath $Repo -RunArgs $args | Out-Null
    exit 0
  }
}
catch {
  log_error "Error: $_"
  exit 1
}
