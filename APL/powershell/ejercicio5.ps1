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
param(
    [Parameter(Mandatory = $true)]
    [string[]]$nombre,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 86400)]
    [int]$ttl = 3600
)

function Get-FieldValue {
    param ([Parameter(Position = 0)] $field)
    return $field ?? '-'
}

function Show-CountryInfo {
    param ([Parameter(Mandatory = $true)] $country)

    Write-Host "Pais: $(Get-FieldValue $country.name.common)"

    if ($country.capital -and $country.capital.Count -gt 0) {
        Write-Host "Capital: $($country.capital -join ', ')"
    }
    else {
        Write-Host "Capital: -"
    }

    Write-Host "Region: $(Get-FieldValue $country.region)"

    $monedas = foreach ($currency in $country.currencies.PSObject.Properties) {
        $currencyCode = $currency.Name
        $currencyName = $currency.Value.name
        "$currencyName ($currencyCode)"
    }

    $label = if ($monedas.Count -gt 1) { "Monedas" } else { "Moneda" }
    Write-Host "${label}: $($monedas -join ', ')"

    Write-Host "Poblacion: $(Get-FieldValue $country.population)"

    if ($country.PSObject.Properties.Name -contains 'expiresAt') {
        $cacheDate = [datetime]$country.cachedAt
        $expiryDate = [datetime]$country.expiresAt
        $format = 'dd/MM/yyyy HH:mm:ss'
        Write-Host "Cacheado:   $($cacheDate.ToString($format))"
        Write-Host "Expira:     $($expiryDate.ToString($format))  (ttl: $($country.ttlSeconds)s)"
    }
}

function Add-Expiry {
    param(
        [Parameter(Mandatory = $true)] $obj,
        [Parameter(Mandatory = $true)] [int] $ttlSeconds
    )
    $now = Get-Date
    $expirationDate = $now.AddSeconds($ttlSeconds)
    # guardo ISO para parseo y una cadena legible
    $obj | Add-Member -NotePropertyName 'cachedAt'     -NotePropertyValue $now.ToString('o') -Force
    $obj | Add-Member -NotePropertyName 'expiresAt'    -NotePropertyValue $expirationDate.ToString('o') -Force
    $obj | Add-Member -NotePropertyName 'ttlSeconds'   -NotePropertyValue $ttlSeconds -Force
    return $obj
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

try {
    if ($ttl -lt 0) { throw "No se puede enviar como TTL un tiempo negativo." }

    $fileCacheName = "restcountries-cache.json"
    $cachePath = Join-Path -Path $env:TEMP -ChildPath $fileCacheName
    
    # Si no existe el archivo de caché, lo crea
    if (-not (Test-Path $cachePath)) {
        '{}' | Out-File -FilePath $cachePath -Encoding utf8
        Write-Host "Archivo '$fileCacheName' creado." -f Cyan
    }

    # Carga en Hashtable del contenido del archivo de caché para realizar búsquedas
    $cacheContent = Get-Content $cachePath -Raw | ConvertFrom-Json

    # Set para almacenar los nombres de los paises recibidos por parámetro normalizados y sin repetidos
    $countriesSet = Get-CountriesSet -countriesNames $nombre

    # Para cada pais ingresado, se realiza procesamiento para dar servicio con caché o API según el caso
    foreach ($countryName in $countriesSet) {
        # Formateo de pais para visualización en consola (ya que está en minúsculas)
        #! Mover a una función con semántica
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        $capitalizedName = $culture.TextInfo.ToTitleCase($countryName)
        Write-Host "Buscando información de '$capitalizedName'`n" -ForegroundColor Cyan

        # Lógica para ver si el pais está en caché o debo pegarle a la API
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
            #! ESTÁ EN CACHÉ y NO ESTÁ EXPIRADO
            Write-Host "'$capitalizedName' está en la caché." -ForegroundColor DarkGray
            $countryInfo = $cacheContent | Select-Object -ExpandProperty $countryName
        }
        else {
            Write-Host "'$capitalizedName' fue buscado en la API." -ForegroundColor DarkGray
            # Request a la API
            $uri = "https://restcountries.com/v3.1/name/${countryName}?fields=name,capital,region,population,currencies"
            $response = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing
            $content = $response.Content | ConvertFrom-Json
            $countryInfo = $content[0]

            # Se agregan metadatos expiración según TTL
            $countryInfo = Add-Expiry -obj $countryInfo -ttlSeconds $ttl
            
            # Agrega o reemplaza la información del pais en el archivo de caché
            $cacheContent
            | Add-Member -NotePropertyName $countryName -NotePropertyValue $countryInfo -Force
            | ConvertTo-Json -Depth 10
            | Set-Content -Path $cachePath -Encoding utf8
            
            $action = if ($isInCache) { 'actualizado' } else { 'agregado' }
            Write-Host "'$capitalizedName' fue $action en caché." -ForegroundColor DarkGray
        }

        Show-CountryInfo $countryInfo
    }
}
catch {
    Write-Host "Hubo un error: $_" -ForegroundColor Red
}
