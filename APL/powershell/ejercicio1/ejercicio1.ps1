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
  Procesa archivos .txt que contengan encuestas en formato:
  ID|FECHA|CANAL|TIEMPO_RESPUESTA|NOTA_SATISFACCION
  Calcula promedios por día y canal, y muestra el resultado en pantalla o lo guarda como JSON.

.PARAMETER directorio
  Directorio que contiene los archivos de encuestas a analizar.

.PARAMETER archivo
  Directorio de salida donde se guardará el archivo JSON resultante.

.PARAMETER pantalla
  Si se especifica, el resultado se mostrará por pantalla en lugar de guardarse.

.EXAMPLE
  ./ejercicio1.ps1 -d "./lotes" -p
  ./ejercicio1.ps1 -d "./lotes" -a "./salidas"
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
  # Validación del directorio de entrada
  $inputDir = (Resolve-Path -Path $directorio -ErrorAction Stop).Path
  if (-not (Test-Path -Path $inputDir -PathType Container)) {
    throw "La ruta '$inputDir' no es un directorio válido."
  }

  # Procesar SOLO los archivos .txt de la carpeta
  $archivos = Get-ChildItem -Path $inputDir -Filter *.txt -File
  if ($archivos.Count -eq 0) {
    throw "No se encontraron archivos .txt en '$inputDir'."
  }

  $datos = @()
  foreach ($f in $archivos) {
    $content = Get-Content -Path $f.FullName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($linea in $content) {
      $p = $linea.Trim() -split '\|'
      if ($p.Count -ne 5) {
        Write-Warning "Línea inválida en '$($f.Name)': $linea"
        continue
      }

      try {
        $fecha = ([datetime]$p[1]).Date.ToString('yyyy-MM-dd')
        $canal = $p[2].Trim()
        $dur   = [double]$p[3]
        $nota  = [double]$p[4]

        if ($dur -lt 0 -or $nota -lt 1 -or $nota -gt 5) {
          Write-Warning "Registro inválido en '$($f.Name)': $linea"
          continue
        }

        $datos += [PSCustomObject]@{
          fecha = $fecha
          canal = $canal
          dur   = $dur
          nota  = $nota
        }
      }
      catch {
        Write-Warning "Error procesando línea: $linea"
      }
    }
  }

  if ($datos.Count -eq 0) {
    throw "No se encontraron registros válidos para procesar."
  }

  # Construir JSON ordenado por fecha ascendente
  $json = [ordered]@{}

  # Obtener todas las fechas únicas ordenadas
  $fechasOrdenadas = $datos | Select-Object -ExpandProperty fecha -Unique | Sort-Object

  foreach ($fecha in $fechasOrdenadas) {
    $json[$fecha] = [ordered]@{}

    # Obtener canales únicos para esa fecha
    $canales = $datos | Where-Object { $_.fecha -eq $fecha } | Select-Object -ExpandProperty canal -Unique | Sort-Object

    foreach ($canal in $canales) {
      $grupo = $datos | Where-Object { $_.fecha -eq $fecha -and $_.canal -eq $canal }

      $promDur = ($grupo | Measure-Object -Property dur -Average).Average
      $promNota = ($grupo | Measure-Object -Property nota -Average).Average

      $json[$fecha][$canal] = @{
        tiempo_respuesta_promedio  = [math]::Round($promDur, 2)
        nota_satisfaccion_promedio = [math]::Round($promNota, 2)
      }
    }
  }

  # Convertir a JSON
  $jsonStr = $json | ConvertTo-Json -Depth 5

  if ($pantalla) {
    Write-Output $jsonStr
  }
  else {
    # Validación del directorio de salida
    $outputDir = (Resolve-Path -Path $archivo -ErrorAction Stop).Path
    if (-not (Test-Path -Path $outputDir -PathType Container)) {
      throw "La ruta '$outputDir' no es un directorio válido."
    }

    $fileName = "analisis-resultado-encuestas-$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').json"
    $path = Join-Path $outputDir $fileName

    $jsonStr | Out-File -FilePath $path -Encoding UTF8
    Write-Host "Archivo generado: $path" -ForegroundColor Green
  }
}
catch {
  Write-Host "Hubo un error: $($_.Exception.Message)" -ForegroundColor Red
}
