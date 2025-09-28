#-------------------------------------------------------#
#               Virtualizacion de Hardware              #
#                                                       #
#   APL1                                                #
#   Nro ejercicio: 1                                    #
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
  Analiza archivos de encuestas y genera un resumen con promedios diarios por canal.

.DESCRIPTION
  Procesa todos los archivos .txt de un directorio que contengan encuestas en formato:
  ID|FECHA|CANAL|TIEMPO_RESPUESTA|NOTA_SATISFACCION
  Calcula promedios por día y canal, y muestra el resultado en pantalla o lo guarda como JSON.

.PARAMETER directorio
  Directorio que contiene los archivos de encuestas a analizar.

.PARAMETER archivo
  Directorio de salida donde se guardará el archivo JSON resultante.

.PARAMETER pantalla
  Si se especifica, el resultado se mostrará por pantalla en lugar de guardarse.

.EXAMPLE
  ./ejercicio1.ps1 -d "./datos" -p
  ./ejercicio1.ps1 -d "./datos" -a "./salidas"

.NOTES
  Solo puede usarse una opción de salida: pantalla o archivo.
#>

[CmdletBinding(DefaultParameterSetName = 'Archivo')]
param(
  [Parameter(Mandatory = $true)]
  [Alias("d")]
  [string]$directorio,

  [Parameter(Mandatory = $true, ParameterSetName = 'Archivo')]
  [Alias("a")]
  [string]$archivo,

  [Parameter(Mandatory = $true, ParameterSetName = 'Pantalla')]
  [Alias("p")]
  [switch]$pantalla
)

try {
  $inputDir = (Resolve-Path -Path $directorio -ErrorAction Stop).Path
  if (-not (Test-Path -Path $inputDir -PathType Container)) {
    throw "La ruta '$inputDir' no es un directorio válido."
  }

  $archivos = Get-ChildItem -Path $inputDir -Filter *.txt -File
  if ($archivos.Count -eq 0) { throw "No se encontraron archivos .txt en '$inputDir'." }

  $datos = @()
  foreach ($f in $archivos) {
    $content = Get-Content -Path $f.FullName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($linea in $content) {
      $p = $linea.Trim() -split '\|'
      if ($p.Count -ne 5) { continue }
      $fecha = ([datetime]$p[1]).Date.ToString('yyyy-MM-dd')
      $canal = $p[2].Trim()
      $dur = [double]$p[3]
      $nota = [int]$p[4]
      $datos += [PSCustomObject]@{fecha = $fecha; canal = $canal; dur = $dur; nota = $nota }
    }
  }

  if ($datos.Count -eq 0) { throw "No se encontraron registros válidos." }

  # Agrupar por fecha y canal
  $agrupados = $datos | Group-Object -Property fecha, canal
  $json = @{}

  foreach ($g in $agrupados) {
    $fecha = $g.Group[0].fecha
    $canal = $g.Group[0].canal
    $promDur = [math]::Round(($g.Group | Measure-Object -Property dur -Average).Average, 2)
    $promNota = [math]::Round(($g.Group | Measure-Object -Property nota -Average).Average, 2)

    if (-not $json.ContainsKey($fecha)) { $json[$fecha] = @{} }
    $json[$fecha][$canal] = @{
      tiempo_respuesta_promedio  = $promDur
      nota_satisfaccion_promedio = $promNota
    }
  }

  if ($pantalla) {
    $jsonStr = $json | ConvertTo-Json -Depth 5
    Write-Output $jsonStr
  }
  else {
    $outputDir = (Resolve-Path -Path $archivo -ErrorAction Stop).Path
    if (-not (Test-Path -Path $outputDir -PathType Container)) {
      throw "La ruta '$outputDir' no es un directorio válido."
    }
    $fileName = "analisis-resultado-encuestas-$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').json"
    $path = Join-Path $outputDir $fileName
    ($json | ConvertTo-Json -Depth 5) | Out-File -FilePath $path -Encoding UTF8
    Write-Host "Archivo generado: $path" -ForegroundColor Green
  }
}
catch {
  Write-Host "Hubo un error: $($_.Exception.Message)" -ForegroundColor Red
}
