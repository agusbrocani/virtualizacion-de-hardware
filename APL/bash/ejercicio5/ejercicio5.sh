#! /bin/bash

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

# Colores ANSI
readonly RED='\e[31m'
readonly GREEN='\e[32m'
readonly YELLOW='\e[33m'
readonly BLUE='\e[34m'
readonly RESET='\e[0m'

# Constantes
readonly MAX_TTL=86400
readonly CACHE_FILE_NAME="restcountries-cache.json"
readonly CACHE_DIR="$HOME/.cache/ejercicio5"
readonly CACHE_FILE_PATH="$CACHE_DIR/$CACHE_FILE_NAME"

# asegurar directorio
mkdir -p "$CACHE_DIR"

# Funciones de salida
function info() {
  printf "${BLUE}%-8s${RESET}%s\n" "[INFO]" "$1"
}

function success() {
  printf "${GREEN}%-8s${RESET}%s\n" "[OK]" "$1"
}

function warn() {
  printf "${YELLOW}%-8s${RESET}%s\n" "[WARN]" "$1"
}

function error() {
  printf "${RED}%-8s${RESET}%s\n" "[ERROR]" "$1" >&2
  exit 1
}

function show_help() {
  cat << EOF
USO:
    $0 [opciones]

OPCIONES:
    -n, --nombre COUNTRIES_NAMES       Países a consultar (obligatorio, varios permitidos)
    -t, --ttl SEGUNDOS         Tiempo en segundos que se mantendrán los datos en caché.
                               Valor por defecto: 3600. Rango válido: 0 a ${MAX_TTL}.
    -d, --dropCacheFile        Elimina el archivo de caché al finalizar la ejecución (opcional)
    -h, --help                 Muestra mensajes de ayuda.

EJEMPLOS:
    ./ejercicio5.sh -n Argentina Uruguay -t 1800 -d
    ./ejercicio5.sh -n "El Salvador" "Vatican City" -t 120
    ./ejercicio5.sh --nombre "united states" --ttl 86400 --dropCacheFile

NOTAS:
    Los resultados se guardan en caché en '${CACHE_FILE_NAME}' para evitar múltiples consultas.
    
    Autores: BIANCHI, JUAN | BROCANI, AGUSTIN | PASCUAL, PABLO | SANZ, ELISEO | VARALDO, RODRIGO
    Versión: 1.0
    Fecha: 31-08-2025

LINK:
    https://restcountries.com
EOF
  exit 0
}

# Valores por defecto
TTL=3600
DROP_CACHE=false
COUNTRIES_NAMES=()

# Parseo de argumentos
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--nombre)
      shift
      while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
        COUNTRIES_NAMES+=("$1")
        shift
      done
      ;;
    -t|--ttl)
      shift
      if ! [[ "$1" =~ ^[0-9]+$ ]]; then
        error "El TTL debe ser un número entero"
      elif [[ $1 -lt 0 || $1 -gt $MAX_TTL ]]; then
        error "El TTL debe estar entre 0 y ${MAX_TTL}"
      fi
      TTL="$1"
      shift
      ;;
    -d|--dropCacheFile)
      DROP_CACHE=true
      shift
      ;;
    -h|--help)
      show_help
      ;;
    -*)
      error "Parámetro desconocido: $1"
      ;;
    *)
      shift
      ;;
  esac
done

# Validaciones obligatorias
if [[ ${#COUNTRIES_NAMES[@]} -eq 0 ]]; then
  error "Debe especificar al menos un nombre de país con -n o --nombre"
fi

# Asegurar que exista el directorio de caché
mkdir -p "$CACHE_DIR"

# Crear el archivo de caché vacío solo si no existe
[[ -f "$CACHE_FILE_PATH" ]] || echo '{}' > "$CACHE_FILE_PATH"

# Declaración de array (que funciona como un set) de paises sin duplicados normalizados
declare -a COUNTRIES_SET=()
declare -A _SEEN=()

# trim + lowercase
normalize() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"   # trim inicio
  s="${s%"${s##*[![:space:]]}"}"   # trim fin
  LC_ALL=C s="${s,,}"               # a minusculas
  printf '%s' "$s"
}

add_to_set() {
  local value norm
  for value in "$@"; do
    norm="$(normalize "$value")"
    [[ -z "$norm" ]] && continue          # saltear vacios
    if [[ -z "${_SEEN[$norm]+x}" ]]; then # no visto -> agregar
      _SEEN["$norm"]=1
      COUNTRIES_SET+=("$norm")
    fi
  done
}

function show_country_info() {
  local country_json="$1"

  # Usamos jq para extraer los campos
  local name capital region population currencies cachedAt expiresAt ttlSeconds

  name="$(jq -r '.name.common' <<<"$country_json")"
  capital="$(jq -r '.capital | join(", ")' <<<"$country_json")"
  region="$(jq -r '.region' <<<"$country_json")"
  population="$(jq -r '.population' <<<"$country_json")"

  # Monedas -> "Nombre (Código)"
  currencies="$(jq -r '.currencies | to_entries[] | "\(.value.name) (\(.key))"' <<<"$country_json" | paste -sd ', ')"

  cachedAt="$(jq -r '.cachedAt // empty' <<<"$country_json")"
  expiresAt="$(jq -r '.expiresAt // empty' <<<"$country_json")"
  ttlSeconds="$(jq -r '.ttlSeconds // empty' <<<"$country_json")"

  printf "\nPais: %s\n" "$name"
  printf "Capital: %s\n" "$capital"
  printf "Region: %s\n" "$region"
  printf "Moneda: %s\n" "$currencies"
  printf "Poblacion: %s\n" "$population"

  if [[ -n "$cachedAt" && -n "$expiresAt" ]]; then
    # Convertimos a formato dd/MM/yyyy HH:mm:ss
    local cached_fmt expires_fmt
    cached_fmt="$(date -d "$cachedAt" +"%d/%m/%Y %H:%M:%S")"
    expires_fmt="$(date -d "$expiresAt" +"%d/%m/%Y %H:%M:%S")"

    printf "Cacheado:   %s\n" "$cached_fmt"
    printf "Expira:     %s  (ttl: %ss)\n" "$expires_fmt" "$ttlSeconds"
  fi

  printf '%s\n' "───────────────────────────────────────────────"
}

# Cargar set desde COUNTRIES_NAMES
add_to_set "${COUNTRIES_NAMES[@]}"

# Para cada país pasado por parametro, se define si está en caché o si debe consultarse a la API para dar respuesta.
for country in "${COUNTRIES_SET[@]}"; do
  # 1) Revisar si está en caché y no expirado
  cached_json="$(jq -ce --arg k "$country" '.[$k] // empty' "$CACHE_FILE_PATH" 2>/dev/null || true)"
  APImustBeCalled=true

  if [[ -n "$cached_json" ]]; then
    # Obtener fecha de expiración en formato ISO desde caché
    exp_iso="$(jq -r --arg k "$country" '.[$k].expiresAt // empty' "$CACHE_FILE_PATH")"
    now_iso="$(date +"%Y-%m-%dT%H:%M:%S.%N%:z" | sed -E 's/([0-9]{6})[0-9]+/\1/')"

    # Truncar a 6 decimales para que date -d lo acepte
    clean_exp_iso="$(sed -E 's/([0-9]{6})[0-9]+/\1/' <<< "$exp_iso")"

    # Convertir a epoch (segundos desde 1970)
    exp_epoch_sec="$(date -d "$clean_exp_iso" +%s 2>/dev/null)"
    now_epoch_sec="$(date -d "$now_iso" +%s 2>/dev/null)"

    # Verificar que ambas conversiones sean válidas antes de comparar
    if [[ -n "$exp_epoch_sec" && -n "$now_epoch_sec" ]]; then
      if (( exp_epoch_sec > now_epoch_sec )); then
        info "'$(jq -r '.name.common // empty' <<<"$cached_json")' está en la caché (válido)."
        show_country_info "$cached_json"
        APImustBeCalled=false
      fi
    else
      warn "No se pudo convertir a epoch correctamente:"
      [[ -z "$exp_epoch_sec" ]] && echo "expiresAt vacío o es inválido"
      [[ -z "$now_epoch_sec" ]] && echo "now_epoch vacío o es inválido"
    fi
  fi

  $APImustBeCalled || continue

  # 2) No está o venció => llamar a la API
  encoded_country="${country// /%20}"
  response="$(curl -s "https://restcountries.com/v3.1/name/$encoded_country?fields=name,capital,region,population,currencies")"

  # Detectar error (objeto con .message)
  error_msg="$(printf '%s' "$response" | jq -r 'if type=="array" then (.[0].message // empty) else (.message // empty) end')"
  if [[ -n "$error_msg" ]]; then
    warn "No se pudo obtener información para el país '$country': $error_msg"
    printf '%s\n' "───────────────────────────────────────────────"
    continue
  fi

  # 3) Armar entrada a guardar
  entry_json="$(printf '%s' "$response" | jq -c '.[0] | {
    name,
    capital: (.capital // []),
    region,
    population,
    currencies
  }')"

  if [[ -z "$entry_json" || "$entry_json" == "null" ]]; then
    warn "Respuesta inesperada para '$country' (sin datos parsables)"
    printf '%s\n' "───────────────────────────────────────────────"
    continue
  fi

  # 4) Timestamps en ISO 8601 con 7 decimales y zona
  now="$(date +"%Y-%m-%dT%H:%M:%S.%N%:z"                 | sed -E 's/([0-9]{7})[0-9]{2}/\1/')"
  exp="$(date -d "+$TTL seconds" +"%Y-%m-%dT%H:%M:%S.%N%:z" | sed -E 's/([0-9]{7})[0-9]{2}/\1/')"

  # 5) Upsert (Update + Insert) atómico en el caché para asegurar la consistencia
  tmp="$(mktemp "$CACHE_DIR/.cache.tmp.XXXXXX")" || { error "No se pudo crear el archivo temporal."; continue; }
  if jq \
      --arg k "$country" \
      --arg now "$now" \
      --arg exp "$exp" \
      --argjson ttl "$TTL" \
      --argjson entry "$entry_json" '
        ( . // {} )
        | .[$k] = (
            $entry + {
              cachedAt:  $now,
              expiresAt: $exp,
              ttlSeconds: $ttl
            }
          )
      ' "$CACHE_FILE_PATH" > "$tmp"; then
    mv -f "$tmp" "$CACHE_FILE_PATH"
  else
    rm -f "$tmp"
    error "No se pudo actualizar el archivo de caché."
    continue
  fi

  success "Archivo de caché actualizado para '$country'."

  # 6) Mostrar desde caché
  country_json="$(jq -c --arg k "$country" '.[$k]' "$CACHE_FILE_PATH")"
  show_country_info "$country_json"
done

# Paso opcional: borrar el archivo de caché después de la ejecución del script
if [[ "$DROP_CACHE" == true ]]; then
  rm "$CACHE_FILE_PATH"
  success "Archivo de caché '${CACHE_FILE_NAME}' eliminado."
fi
