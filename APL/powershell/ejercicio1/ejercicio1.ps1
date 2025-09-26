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

# --- tu bloque de parámetros ---
[CmdletBinding(DefaultParameterSetName = 'Archivo')]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [Alias("d")]
    [string]$directorio,

    [Parameter(Mandatory = $true, ParameterSetName = 'Archivo')]
    [Alias("a")]
    [string]$archivo,

    [Parameter(Mandatory = $true, ParameterSetName = 'Pantalla')]
    [Alias("p")]
    [string]$pantalla
)

try {
    # Convertir paths recibidos en absolutos, si no lo eran
    $directoryPath = (Resolve-Path -Path $directorio -ErrorAction Stop).Path
    Write-Host "Directorio resuelto: $directoryPath" -f Red

    $outputPath = $null
    switch ($PSCmdlet.ParameterSetName) {
        'Archivo' {
            $outputPath = (Resolve-Path -Path $archivo -ErrorAction Stop).Path
        }
        'Pantalla' {
            $outputPath = (Resolve-Path -Path $pantalla -ErrorAction Stop).Path
        }
    }

    Write-Host $outputPath -f Red
}
catch {
    Write-Host "Hubo un error: $_" -f Red
}
