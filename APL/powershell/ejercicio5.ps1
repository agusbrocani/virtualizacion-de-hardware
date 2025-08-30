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
    param (
        [Parameter(Position = 0)]
        $field
    )
    return $field ?? '-'
}

function Show-CountryInfo {
    param (
        [Parameter(Mandatory = $true)]
        $country
    )
    
    Write-Host "País: $(Get-FieldValue $country.name.common)"
    Write-Host "Capital: $(Get-FieldValue $country.capital[0])"
    Write-Host "Región: $(Get-FieldValue $country.region)"
    
    $currencyCode = $country.currencies.PSObject.Properties.Name | Select-Object -First 1
    $currencyName = $country.currencies.$currencyCode.name
    
    Write-Host "Población: $(Get-FieldValue $country.population)"
    Write-Host "Moneda: $(Get-FieldValue $currencyName) ($(Get-FieldValue $currencyCode))"
}

try {
    if ($ttl -lt 0) {
        throw "No se puede enviar como TTL un tiempo negativo."
    }

    $countries = $nombre
    foreach ($countryName in $countries) {
        Write-Host "Buscando pais '$countryName'`n" -f Cyan
        
        # if (NO ESTÁ EN CACHÉ) {
        # 1. Definir la URL del endpoint
        $uri = "https://restcountries.com/v3.1/name/${countryName}?fields=name,capital,region,population,currencies"
    
        # } else {
    
        # }
        
        # 2. Realizar la solicitud HTTP GET
        $response = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing
        # 3. Obtener el contenido como cadena
        $content = $response.Content | ConvertFrom-Json
        $countryInfo = $content[0]   # la API devuelve un array
    
        Show-CountryInfo $countryInfo
    }
}
catch {
    Write-Host "Hubo un error: $_" -f Red
}
