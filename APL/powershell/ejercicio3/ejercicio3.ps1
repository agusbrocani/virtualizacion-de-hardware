#-------------------------------------------------------#
#               Virtualizacion de Hardware              #
#                                                       #
#   APL1                                                #
#   Nro ejercicio: 3                                    #
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
  Cuenta ocurrencias de términos en logs.
.DESCRIPTION
  Acepta un directorio (recursivo) o un archivo .log. Cuenta ocurrencias totales
  por término con coincidencia por palabra completa, sin distinguir mayúsculas.
.PARAMETER Directory
  Ruta a un directorio con .log o a un archivo .log.
.PARAMETER Palabras
  Términos separados por comas. Ej: 'error,500'
.PARAMETER Help
  Muestra la ayuda.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [Alias("d","directorio")]
  [ValidateScript({
    if (-not (Test-Path -LiteralPath $_)) { throw "La ruta '$_' no existe." }
    $isFile = Test-Path -LiteralPath $_ -PathType Leaf
    if ($isFile -and ([IO.Path]::GetExtension($_) -ne ".log")) { throw "El archivo debe tener extensión .log" }
    $true
  })]
  [string]$Directory,

  [Parameter(Mandatory=$true)]
  [Alias("p","palabra","terminos")]
  [ValidateNotNullOrEmpty()]
  [string]$Palabras
)


if ($Help) { Get-Help $MyInvocation.MyCommand.Path; exit 0 }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolver targets: archivo único o búsqueda recursiva
$targets = @()
if (Test-Path $Directory -PathType Leaf) {
  $targets = ,(Get-Item -LiteralPath $Directory)
} else {
  $targets = Get-ChildItem -Path $Directory -Filter *.log -File -Recurse
  if (-not $targets) {
    Write-Host "Error: no se encontraron archivos .log en '$Directory'." -ForegroundColor Red
    exit 1
  }
}

# Contadores
$counts = @{}
foreach ($w in ($Palabras -split ',')) {
  $t = $w.Trim()
  if ($t) { $counts[$t] = 0 }
}
if ($counts.Count -eq 0) {
  Write-Host "Error: no se especificaron términos válidos." -ForegroundColor Red
  exit 1
}

# Precompilar regex por término con límites de palabra
$regexes = @{}
foreach ($k in @($counts.Keys)) {
  $pat = [regex]::Escape($k)
  if ($k -match '^\w+$') { $pat = "\b$pat\b" } else { $pat = "(?<!\w)$pat(?!\w)" }
  $regexes[$k] = [regex]::new($pat, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

# Procesamiento (streaming)
foreach ($f in $targets) {
  try {
    Get-Content -LiteralPath $f.FullName -ReadCount 1000 | ForEach-Object {
      foreach ($chunk in $_) {
        foreach ($k in $regexes.Keys) {
          $counts[$k] += $regexes[$k].Matches($chunk).Count
        }
      }
    }
  } catch {
    Write-Host "Advertencia: no se pudo leer '$($f.Name)': $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

# Salida ordenada
$counts.GetEnumerator() | Sort-Object Key | ForEach-Object { "{0}: {1}" -f $_.Key, $_.Value }
