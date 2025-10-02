#-------------------------------------------------------#
#               Virtualizacion de Hardware              #
#                                                       #
#   APL1                                                #
#   Nro ejercicio: 2                                    #
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
    Genera un informe de análisis de red de transporte basado en una matriz de costos.

.DESCRIPTION
    Este script lee un archivo con una matriz de costos que representa una red de transporte,
    verifica que sea válida (cuadrada, simétrica, con ceros en la diagonal principal),
    y genera un informe con el mejor costo y las rutas óptimas. Soporta opciones para calcular
    hubs o caminos óptimos, con modo de depuración opcional.

.PARAMETER Mapa
    Ruta al archivo de texto que contiene la matriz de costos. Por defecto, "mapa.txt".

.PARAMETER Sep
    Carácter separador usado en el archivo de matriz. Por defecto, "|".

.PARAMETER Hub
    Indica si se debe calcular el análisis de hubs (nodos centrales).

.PARAMETER Camino
    Indica si se debe calcular el camino óptimo que recorre todos los nodos.

.PARAMETER DebugMode
    Activa el modo de depuración, mostrando información detallada durante la ejecución.

.EXAMPLE
    .\ejercicio2_informe.ps1 -Mapa "mapa.txt" -Sep "," -Camino
    Genera un informe con el camino óptimo usando el archivo "red.txt" y el separador ",".

.EXAMPLE
    .\ejercicio2_informe.ps1 -Hub -DebugMode
    Calcula el análisis de hubs con depuración activada, usando el archivo por defecto "mapa.txt".

.NOTES
    El archivo de entrada debe contener una matriz cuadrada de valores numéricos,
    con ceros en la diagonal principal y simetría en los costos.
    El informe se guarda en un archivo con el prefijo "informe." seguido del nombre del archivo de entrada.

.LINK
    https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_comment_based_help
#>
[CmdletBinding()]
param(
    # --- Mapa (obligatorio) ---
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Mapa,

    # --- Separador (obligatorio, un solo carácter, no puede ser ".") ---
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [ValidateScript({
        if ($_.Length -gt 1) {
            throw "Error: El separador debe tener un solo carácter"
        }
        if ($_ -eq ".") {
            throw "Error: No se puede usar '.' como separador (se confunde con los decimales)"
        }
        $true
    })]
    [string]$Sep,

    # --- Modo Hub ---
    [switch]$Hub,

    # --- Modo Camino ---
    [switch]$Camino,

    # --- Modo debug ---
    [switch]$DebugMode
)

# --- validaciones iniciales ---
# si me pasan camino y hub no dejo seguir
if ($Hub -and $Camino) {
    Write-Host "Error: No se pueden usar las opciones -Hub y -Camino al mismo tiempo." -ForegroundColor Red
    exit 1
}

# si no se pasó modo (-Hub o -Camino)
if (-not ($Hub -or $Camino)) {
    Write-Error "Debe elegir al menos uno: -Hub o -Camino"
    exit 1
}

# validar existencia del archivo mapa
if (-not (Test-Path $Mapa)) {
    Write-Error "No se encontró el archivo '$Mapa'. Verificá la ruta."
    exit 1
}

# validar que el separador no sea vacío (ya se valida en param, pero reforzamos)
if ([string]::IsNullOrWhiteSpace($Sep)) {
    Write-Error "Debe especificar un separador válido (por ejemplo: -Sep ',')"
    exit 1
}


# --- leer archivo ---
if (-Not (Test-Path $Mapa)) {
    Write-Error "Archivo no encontrado: $Mapa"
    exit 1
}
$lines = Get-Content $Mapa
$N = $lines.Count
if ($N -eq 0) { Write-Error "Archivo vacío"; exit 1 }

# --- leer matriz ---
$matriz = @()
for ($i=0; $i -lt $N; $i++) {
    $row = $lines[$i] -split [regex]::Escape($Sep)
    if ($row.Count -ne $N) {
        Write-Error "La matriz no es cuadrada: fila $($i+1) tiene $($row.Count) columnas (esperaba $N)."
        exit 1
    }
    for ($j=0; $j -lt $N; $j++) {
        $val = $row[$j].Trim()
        if (-Not ($val -match '^[-+]?[0-9]*\.?[0-9]+$')) {
            Write-Error "Valor no numérico en fila $($i+1), columna $($j+1): '$val'"
            exit 1
        }
        if ($i -eq $j -and $val -ne "0") {
            Write-Error "Diagonal principal debe ser 0 (fila $($i+1), col $($j+1))"
            exit 1
        }
        $matriz += [double]$val
    }
}

# --- verificar simetría ---
for ($i=0; $i -lt $N; $i++) {
    for ($j=$i+1; $j -lt $N; $j++) {
        $a = $matriz[$i*$N + $j]
        $b = $matriz[$j*$N + $i]
        if ($a -ne $b) {
            Write-Error "Matriz no simétrica en ($($i+1),$($j+1)) vs ($($j+1),$($i+1)): $a != $b"
            exit 1
        }
    }
}

for ($i = 0; $i -lt $N; $i++) {
    for ($j = 0; $j -lt $N; $j++) {
        if ($i -ne $j -and [double]$matriz[$i*$N + $j] -eq 0) {
            $matriz[$i*$N + $j] = [double]1e12
        } else {
            $matriz[$i*$N + $j] = [double]$matriz[$i*$N + $j]
        }
    }
}
# --- funciones ---
# --- estructura global para almacenar resultados ---
$script:MejorCostoGlobal = 1e12
$script:MejoresRutasGlobal = @()

# --- variables globales ---
$script:MejorCostoGlobal = 1e12
$script:MejoresRutasGlobal = @()

# --- función para calcular caminos ---
function CalcularCamino {

    $INF = 1e12
    $mejorCosto = $INF
    $mejoresCaminos = @()

    function EvaluarRuta {
    param([int[]]$perm)
    $subtotal = 0.0
    $prev = 0
    $rutaCompleta = @(0) + $perm   # la coma asegura que sea array

    foreach ($x in $perm) {
        $peso = [double]$matriz[$prev*$N + $x]
        if ($prev -ne $x -and $peso -eq 0) { $peso = $INF }
        $subtotal += $peso
        if ($subtotal -ge $INF) { break }
        $prev = $x
    }

    if ($subtotal -ge $INF) {
        if ($DebugMode) { Write-Host "DEBUG: Ruta descartada por costo infinito: $($rutaCompleta -join ' ')" }
        return
    }

    if ($subtotal -lt $script:MejorCostoGlobal) {
		if ($DebugMode) { Write-Host "DEBUG: Nueva mejor ruta global con costo ${subtotal}: $($rutaCompleta -join ' ')" }
		$script:MejorCostoGlobal = $subtotal
		$script:MejoresRutasGlobal = @()
		$script:MejoresRutasGlobal += ,@($rutaCompleta.Clone())
    } elseif ($subtotal -eq $script:MejorCostoGlobal) {
		if ($DebugMode) { Write-Host "DEBUG: Ruta con igual costo al mejor global (${subtotal}): $($rutaCompleta -join ' ')" }
		$script:MejoresRutasGlobal += ,@($rutaCompleta.Clone())
    } else {
        if ($DebugMode) { Write-Host "DEBUG: Ruta descartada por costo mayor (${subtotal}): $($rutaCompleta -join ' ')" }
    }
}


    function Permutar {
        param([int[]]$array, [int]$l, [int]$r)
        if ($l -eq $r) { EvaluarRuta -perm $array }
        else {
            for ($i=$l; $i -le $r; $i++) {
                $temp = $array[$l]; $array[$l]=$array[$i]; $array[$i]=$temp
                Permutar -array $array -l ($l+1) -r $r
                $temp = $array[$l]; $array[$l]=$array[$i]; $array[$i]=$temp
            }
        }
    }

    $indices = 1..($N-1)
    Permutar -array $indices -l 0 -r ($indices.Count-1)

    # actualizar variables globales
    if ($mejorCosto -lt $script:MejorCostoGlobal) {
        if ($DebugMode) { Write-Host "DEBUG: Actualizando mejor costo global a $mejorCosto" }
        $script:MejorCostoGlobal = $mejorCosto
        $script:MejoresRutasGlobal.Clear()
        $script:MejoresRutasGlobal += $mejoresCaminos
    } elseif ($mejorCosto -eq $script:MejorCostoGlobal) {
        if ($DebugMode) { Write-Host "DEBUG: Agregando rutas al mejor costo global existente ($mejorCosto)" }
        $script:MejoresRutasGlobal += $mejoresCaminos
    }
}

# --- función para mostrar rutas ---
function MostrarMejoresRutas {
    param(
        [string]$archivo
    )

    $output = "## Informe de análisis de red de transporte`n`n"

    if ($script:MejoresRutasGlobal.Count -eq 0) {
        $output += "No existe camino válido que recorra todos los nodos.`n"
    } else {
        $output += "Mejor costo encontrado: $($script:MejorCostoGlobal)`n"
        foreach ($ruta in $script:MejoresRutasGlobal) {
            # sumamos +1 para que quede en base 1 en vez de 0
            $ruta1 = $ruta | ForEach-Object { $_ + 1 }
            $output += "Ruta: $($ruta1 -join ' ')`n"
        }
    }

    Set-Content -Path $archivo -Value $output -Encoding UTF8
}


if ($DebugMode) {
    Write-Host "DEBUG: Mejor costo encontrado: $mejorCosto"
    Write-Host "DEBUG: Mejores caminos encontrados:"
    foreach ($c in $mejoresCaminos) {
        Write-Host "  - $($c -join ' ')"
    }
}


# --- generar informe ---
$base = [System.IO.Path]::GetFileName($Mapa)
$informe = "informe.$base"

$contenido = "## Informe de análisis de red de transporte`n`n"

if ($Hub) { $contenido += CalcularHub + "`n" }
if ($Camino) {
	CalcularCamino
    if ($script:MejoresRutasGlobal.Count -eq 0) {
        $contenido += "No existe camino válido que recorra todos los nodos.`n"
    } else {
        $contenido += "Mejor costo encontrado: $($script:MejorCostoGlobal)`n"
        foreach ($ruta in $script:MejoresRutasGlobal) {
            # ajustar a base 1 si tu matriz es base 0
            $rutaBase1 = $ruta | ForEach-Object { $_ + 1 }
            $contenido += "Ruta: $($rutaBase1 -join ' ')`n"
        }
    }
}

# debug: mostrar en pantalla el contenido completo del informe
if ($DebugMode) {
    Write-Host "`nDEBUG: Contenido del informe:`n"
    Write-Host $contenido
}

Set-Content -Path $informe -Value $contenido -Encoding UTF8
Write-Host "Informe generado en $informe"