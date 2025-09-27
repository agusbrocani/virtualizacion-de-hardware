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
    [string]$directorio,  # archivo .txt a procesar

    [Parameter(Mandatory = $true, ParameterSetName = 'Archivo')]
    [Alias("a")]
    [string]$archivo,     # directorio donde guardar JSON

    [Parameter(Mandatory = $true, ParameterSetName = 'Pantalla')]
    [Alias("p")]
    [switch]$pantalla     # mostrar por pantalla en lugar de guardar
)

try {
    # === Validación del archivo de entrada ===
    $inputFile = (Resolve-Path -Path $directorio -ErrorAction Stop).Path
    if (-not (Test-Path -Path $inputFile -PathType Leaf)) {
        throw "El archivo '$inputFile' no existe."
    }

    # === Lectura y limpieza ===
    $content = Get-Content -Path $inputFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($content.Count -eq 0) { throw "El archivo está vacío." }

    # === Ordenar por Fecha (día) y Canal ===
    $content = $content | Sort-Object -Stable -Property `
    @{ Expression = { ([datetime]($_.Split('|')[1])).Date } },
    @{ Expression = { ($_.Split('|')[2]).Trim() } }

    # === Inicializar primer grupo ===
    $parts = $content[0] -split '\|'
    if ($parts.Count -ne 5) { throw "La línea inicial no tiene 5 campos: '$($content[0])'" }

    $fechaGrupo = ([datetime]$parts[1]).Date
    $fechaGrupoKey = $fechaGrupo.ToString('yyyy-MM-dd')
    $canalGrupo = $parts[2].Trim()

    $sumaDur = [double]$parts[3]
    $sumaNota = [int]$parts[4]
    $cnt = 1

    # Acumulador JSON
    $resultados = @()

    # === Recorrido ===
    for ($i = 1; $i -lt $content.Count; $i++) {
        $p = $content[$i] -split '\|'
        if ($p.Count -ne 5) { throw "La línea $($i+1) no tiene 5 campos: '$($content[$i])'" }

        $fechaLinea = ([datetime]$p[1]).Date
        $fechaLineaKey = $fechaLinea.ToString('yyyy-MM-dd')
        $canalLinea = $p[2].Trim()
        $durLinea = [double]$p[3]
        $notaLinea = [int]$p[4]

        # Comparar por fecha y canal
        if (($canalLinea -eq $canalGrupo) -and ($fechaLineaKey -eq $fechaGrupoKey)) {
            $sumaDur += $durLinea
            $sumaNota += $notaLinea
            $cnt++
        }
        else {
            # === Corte de grupo ===
            $promDur = [math]::Round($sumaDur / $cnt, 2)
            $promNota = [math]::Round($sumaNota / $cnt, 2)

            Write-Host "Subtotal para '$canalGrupo' Fecha=$fechaGrupoKey"
            Write-Host "  Promedio Tiempo de Respuesta: $promDur"
            Write-Host "  Promedio Nota Satisfacción:   $promNota"
            Write-Host "  Cantidad de registros:        $cnt"
            Write-Host ""

            $resultados += [PSCustomObject]@{
                fecha                      = $fechaGrupoKey
                canal                      = $canalGrupo
                tiempo_respuesta_promedio  = $promDur
                nota_satisfaccion_promedio = $promNota
                cantidad                   = $cnt
            }

            # Reiniciar grupo
            $fechaGrupo = $fechaLinea
            $fechaGrupoKey = $fechaLineaKey
            $canalGrupo = $canalLinea
            $sumaDur = $durLinea
            $sumaNota = $notaLinea
            $cnt = 1
        }
    }

    # === Último grupo ===
    $promDur = [math]::Round($sumaDur / $cnt, 2)
    $promNota = [math]::Round($sumaNota / $cnt, 2)
    $resultados += [PSCustomObject]@{
        fecha                      = $fechaGrupoKey
        canal                      = $canalGrupo
        tiempo_respuesta_promedio  = $promDur
        nota_satisfaccion_promedio = $promNota
        cantidad                   = $cnt
    }

    Write-Host "Subtotal para '$canalGrupo' Fecha=$fechaGrupoKey"
    Write-Host "  Promedio Tiempo de Respuesta: $promDur"
    Write-Host "  Promedio Nota Satisfacción:   $promNota"
    Write-Host "  Cantidad de registros:        $cnt"
    Write-Host ""

    # === Salida ===
    $json = $resultados | ConvertTo-Json -Depth 5
    if ($pantalla) {
        Write-Output $json
    }
    else {
        $outputDir = (Resolve-Path -Path $archivo -ErrorAction Stop).Path
        if (-not (Test-Path -Path $outputDir -PathType Container)) {
            throw "La ruta '$outputDir' no es un directorio válido."
        }
        $fileName = "analisis-resultado-encuestas-$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').json"
        $path = Join-Path $outputDir $fileName
        $json | Out-File -FilePath $path -Encoding UTF8
        Write-Host "Archivo generado: $path" -ForegroundColor Green
    }
}
catch {
    Write-Host "Hubo un error: $($_.Exception.Message)" -ForegroundColor Red
}
