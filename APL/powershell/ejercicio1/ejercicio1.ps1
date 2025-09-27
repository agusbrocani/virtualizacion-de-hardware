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
    # Convertir paths recibidos en absolutos, si no lo eran
    $directoryPath = (Resolve-Path -Path $directorio -ErrorAction Stop).Path

    # Validar existencia del archivo
    if (-not (Test-Path -Path $directoryPath -PathType Leaf)) {
        throw "El archivo en '$directoryPath' no existe."
    }

    if ($archivo) {
        $outputFilePath = (Resolve-Path -Path $archivo -ErrorAction Stop).Path
        $DateTime = Get-Date -Format "dd-MM-yyyy_HH-mm-ss"
        $outputFileName = "analisis-resultado-encuestas-$DateTime.json"
    
        # Combinar directorio resuelto + nombre del archivo
        $finalPath = Join-Path $outputFilePath $outputFileName
        # Crea archivo vacío o sobrescribir si ya existe
        New-Item -Path $finalPath -ItemType File -Force | Out-Null
        "{}" | Out-File -FilePath $finalPath -Encoding utf8
    }

    # Leer archivo
    $content = Get-Content -Path $directoryPath

    # Validar que haya líneas
    if ($content.Count -eq 0) {
        throw "El archivo está vacío."
    }

    # Inicializar primera línea
    $parts = ($content.Count -eq 1 ? $content : $content[0]) -split "\|"

    if ($parts.Count -ne 5) {
        throw "La línea leída del archivo no tiene los 5 campos requeridos. Línea: '$($content[0])'"
    }
    # Variables del grupo actual
    $ID_ENCUESTA = [int]$parts[0]
    $FECHA = [datetime]$parts[1]
    $TIEMPO_DE_RESPUESTA = [double]$parts[3]
    $NOTA_SATISFACCION = [int]$parts[4]
    $cantidad = 1  # contamos la primera línea

    # Recorrer desde la segunda línea
    for ($i = 1; $i -lt $content.Count; $i++) {
        $parts = $content[$i] -split "\|"

        if ($parts.Count -ne 5) {
            throw "La línea leída del archivo no tiene los 5 campos requeridos. Línea: '$($content[$i])'"
        }

        # Datos de la línea actual
        $Id = [int]$parts[0]
        $Fecha = [datetime]$parts[1]
        $Duracion = [double]$parts[3]
        $Puntaje = [int]$parts[4]

        # Verificar si pertenece al mismo grupo
        if (($Id -eq $ID_ENCUESTA) -and ($Fecha.Date -eq $FECHA.Date)) {
            # Acumular
            $TIEMPO_DE_RESPUESTA += $Duracion
            $NOTA_SATISFACCION += $Puntaje
            $cantidad++
        }
        else {
            # Corte de control: imprimir subtotal
            Write-Host "Subtotal para ID=$ID_ENCUESTA Fecha=$($FECHA.ToString('yyyy-MM-dd'))"
            Write-Host "  Promedio Tiempo de Respuesta: $($TIEMPO_DE_RESPUESTA / $cantidad)"
            Write-Host "  Promedio Nota Satisfacción:   $($NOTA_SATISFACCION / $cantidad)"
            Write-Host ""

            # Reiniciar acumuladores para nuevo grupo
            $ID_ENCUESTA = $Id
            $FECHA = $Fecha
            $TIEMPO_DE_RESPUESTA = $Duracion
            $NOTA_SATISFACCION = $Puntaje
            $cantidad = 1
        }
    }

    # Imprimir el último grupo
    Write-Host "Subtotal para ID=$ID_ENCUESTA Fecha=$($FECHA.ToString('yyyy-MM-dd'))"
    Write-Host "  Promedio Tiempo de Respuesta: $($TIEMPO_DE_RESPUESTA / $cantidad)"
    Write-Host "  Promedio Nota Satisfacción:   $($NOTA_SATISFACCION / $cantidad)"
    Write-Host ""
}
catch {
    Write-Host "Hubo un error: $_" -f Red
}
