#-------------------------------------------------------#
#               Virtualizacion de Hardware              #
#                                                       #
#   APL1                                                #
#   Nro ejercicio: 5                                    #
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
    Consultá información de países desde la API de RestCountries con soporte de caché local.

.DESCRIPTION
    Este script permite obtener información como capital, región, población y monedas de uno o más países.
    Los resultados se guardan en caché en un archivo temporal en %TEMP% para evitar múltiples consultas a la API.
    También se puede eliminar el archivo de caché al finalizar con un switch opcional.

.PARAMETER nombre
    Alias: -n
    Nombre o nombres de los países a consultar. Se puede ingresar más de uno (separados por coma o en array).

.PARAMETER ttl
    Alias: -t
    Tiempo en segundos que se mantendrán los datos en caché. Valor por defecto: 3600. Rango válido: 0 a 86400.

.PARAMETER dropCacheFile
    Alias: -d
    Si se incluye, elimina el archivo de caché al finalizar la ejecución del script.

.EXAMPLE
    Se envían los países Argentina y Uruguay, con un ttl de 1800 segundos, y se elimina el archivo de caché.
    .\ejercicio5.ps1 -nombre argentina,uruguay -ttl 1800 -dropCacheFile

.EXAMPLE
    Se envían los países 'El Salvador' y 'Vatican City', con un ttl de 120 segundos, sin eliminar el archivo de caché.
    .\ejercicio5.ps1 -n "El Salvador","Vatican City" -t 120

.INPUTS
    No se reciben entradas por pipeline.

.OUTPUTS
    Información textual en consola sobre los países solicitados (capital, región, moneda, población, etc.).

.NOTES
    Autores: BIANCHI, JUAN | BROCANI, AGUSTIN | PASCUAL, PABLO | SANZ, ELISEO | VARALDO, RODRIGO
    Versión: 1.0
    Fecha: 31-08-2025

.LINK
    https://restcountries.com
#>

param (
    [Parameter(Mandatory = $true)]
    [Alias("n")]
    [string[]]$nombre,

    [Parameter(Mandatory = $false)]
    [Alias("t")]
    [ValidateRange(0, 86400)]
    [int]$ttl = 3600,

    [Parameter(Mandatory = $false)]
    [Alias("d")]
    [switch]$dropCacheFile
)

function Get-FieldValue {
    param ([Parameter(Position = 0)] $field)
    return $field ?? '-'
}

function Show-CountryInfo {
    param ([Parameter(Mandatory = $true)] $country)

    Write-Host "`nPais: $(Get-FieldValue $country.name.common)"

    $label = if ($country.capital.Count -gt 1) { "Capitales" } else { "Capital" }
    Write-Host "${label}: $($country.capital -join ', ')"

    Write-Host "Región: $(Get-FieldValue $country.region)"

    $monedas = foreach ($currency in $country.currencies.PSObject.Properties) {
        $currencyCode = $currency.Name
        $currencyName = $currency.Value.name
        "$currencyName ($currencyCode)"
    }

    $label = if ($monedas.Count -gt 1) { "Monedas" } else { "Moneda" }
    Write-Host "${label}: $($monedas -join ', ')"

    Write-Host "Población: $(Get-FieldValue $country.population)"

    if ($country.PSObject.Properties.Name -contains 'expiresAt') {
        $cacheDate = [datetime]$country.cachedAt
        $expiryDate = [datetime]$country.expiresAt
        $format = 'dd/MM/yyyy HH:mm:ss'
        Write-Host "Cacheado:   $($cacheDate.ToString($format))"
        Write-Host "Expira:     $($expiryDate.ToString($format))  (ttl: $($country.ttlSeconds)s)"
    }

    Write-Host ("─" * 50) -ForegroundColor DarkGray
}

function Add-Expiry {
    param(
        [Parameter(Mandatory = $true)] $apiResponseObject,
        [Parameter(Mandatory = $true)] [int] $ttlSeconds
    )
    $now = Get-Date
    $expirationDate = $now.AddSeconds($ttlSeconds)
    # guardo ISO para parseo y una cadena legible
    $apiResponseObject | Add-Member -NotePropertyName 'cachedAt'     -NotePropertyValue $now.ToString('o') -Force
    $apiResponseObject | Add-Member -NotePropertyName 'expiresAt'    -NotePropertyValue $expirationDate.ToString('o') -Force
    $apiResponseObject | Add-Member -NotePropertyName 'ttlSeconds'   -NotePropertyValue $ttlSeconds -Force
    return $apiResponseObject
}

function Get-CountriesSet {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$countriesNames
    )

    # Crear el HashSet
    $countriesSet = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($name in $countriesNames) {
        # Agregar en minúsculas
        [void]$countriesSet.Add($name.ToLowerInvariant())
    }

    return $countriesSet
}

function Format-CountryName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    return $culture.TextInfo.ToTitleCase($Name)
}

$fileCacheName = "restcountries-cache.json"
$cachePath = Join-Path -Path $env:LOCALAPPDATA -ChildPath $fileCacheName
try {
    # Si no existe el archivo de caché, lo crea
    if (-not (Test-Path $cachePath)) {
        '{}' | Out-File -FilePath $cachePath -Encoding utf8
        Write-Host "`nArchivo '$fileCacheName' creado." -f Magenta
    }

    # Carga en Hashtable del contenido del archivo de caché para realizar búsquedas
    $cacheContent = Get-Content $cachePath -Raw | ConvertFrom-Json

    # Set para almacenar los nombres de los paises recibidos por parámetro normalizados y sin repetidos
    $countriesSet = Get-CountriesSet -countriesNames $nombre
    
    # Para cada país ingresado, se realiza procesamiento para dar servicio con caché o API según el caso
    Write-Host ("─" * 50) -ForegroundColor DarkGray
    foreach ($countryName in $countriesSet) {
        # Formateo de país para visualización en consola (ya que está en minúsculas)
        $capitalizedName = Format-CountryName -Name $countryName
        Write-Host "Buscando información de '$capitalizedName'" -ForegroundColor Cyan

        # Lógica para ver si el país está en caché o debo pegarle a la API
        $isInCache = $cacheContent.PSObject.Properties.Name -contains $countryName
        $APImustBeCalled = -not $isInCache

        if ($isInCache) {
            $expiration = [datetime]($cacheContent | Select-Object -ExpandProperty $countryName).expiresAt
            if ((Get-Date) -ge $expiration) {
                $APImustBeCalled = $true
            }
        }

        # Respuesta del sistema según el caso
        $countryInfo = $null
        if (-not($APImustBeCalled)) {
            # Está en caché y no está expirado
            Write-Host "'$capitalizedName' está en la caché." -ForegroundColor Magenta
            $countryInfo = $cacheContent | Select-Object -ExpandProperty $countryName
        }
        else {
            Write-Host "'$capitalizedName' fue buscado en la API." -ForegroundColor Magenta
            # Request a la API
            $uri = "https://restcountries.com/v3.1/name/${countryName}?fields=name,capital,region,population,currencies"
            try {
                $response = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing
            }
            catch {
                $e = $_ | ConvertFrom-Json
                $statusCode = $e.status
                $statusMessage = $e.message
                
                if ($statusCode -eq 404) {
                    Write-Host  "[Status code: $statusCode] No se encontró el país '$capitalizedName' en la API." -f DarkYellow
                }
                else {
                    Write-Host  "[Status code: $statusCode] $statusMessage" -f DarkYellow
                }
                Write-Host ("─" * 50) -ForegroundColor DarkGray
                continue
            }

            $content = $response.Content | ConvertFrom-Json
            $countryInfo = $content[0]

            # Se agregan metadatos expiración según TTL
            $countryInfo = Add-Expiry -apiResponseObject $countryInfo -ttlSeconds $ttl
            
            # Agrega o reemplaza la información del país en el archivo de caché
            $cacheContent | Add-Member -NotePropertyName $countryName -NotePropertyValue $countryInfo -Force
            $cacheContent | ConvertTo-Json -Depth 10 | Set-Content -Path $cachePath -Encoding utf8
            
            $action = if ($isInCache) { 'actualizado' } else { 'agregado' }
            Write-Host "'$capitalizedName' fue $action en caché." -ForegroundColor Magenta
        }

        Show-CountryInfo $countryInfo
    }
}
catch {
    Write-Host "Hubo un error: $_" -ForegroundColor Red
}
finally {
    if ($dropCacheFile.IsPresent) {
        if (Test-Path $cachePath) {
            Remove-Item -Path $cachePath -Force
            Write-Host "Archivo de caché '$fileCacheName' eliminado." -ForegroundColor Magenta
        }
        else {
            Write-Host "Hubo un error: no se encontró archivo de caché para eliminar." -ForegroundColor Red
        }
    }
}
