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
readonly CACHE_FILE_PATH="/tmp/${CACHE_FILE_NAME}"

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
    -n, --nombre NOMBRES       Países a consultar (obligatorio, varios permitidos)
    -t, --ttl SEGUNDOS         Tiempo en segundos que se mantendrán los datos en caché.
                               Valor por defecto: 3600. Rango válido: 0 a ${MAX_TTL}.
    -d, --dropCacheFile        Elimina el archivo de caché al finalizar la ejecución (opcional)
    -h, --help                 Muestra mensajes de ayuda.

EJEMPLOS:
    ./ejercicio5.sh -n Argentina Uruguay -t 1800 -d
    ./ejercicio5.sh -n "El Salvador" "Vatican City" -t 120

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
NOMBRES=()

# Parseo de argumentos
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--nombre)
      shift
      while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
        NOMBRES+=("$1")
        shift
      done
      ;;
    -t|--ttl)
      shift
      if ! [[ "$1" =~ ^[0-9]+$ ]]; then
        error "El TTL debe ser un número entero"
      elif (( $1 < 0 || $1 > MAX_TTL )); then
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
if [[ ${#NOMBRES[@]} -eq 0 ]]; then
  error "Debe especificar al menos un nombre con -n o --nombre"
fi

#! BORRAR AL FINAL
    success "Esto es una prueba de success"
    info "Esto es una prueba de info"
    warn "Esto es una advertencia"

    info "Parámetros recibidos:"
    echo "- Nombres: ${NOMBRES[*]}"
    echo "- TTL: $TTL"
    echo "- Drop Cache: $DROP_CACHE"
#!

# Crear el archivo si no existe
touch "$CACHE_FILE_PATH"

# Escribir en el archivo
echo '{"mensaje":"Hola mundo"}' > "$CACHE_FILE_PATH"

# Mostrar el contenido del archivo
cat "$CACHE_FILE_PATH"

# Opcional: borrar el archivo después
if [[ "$DROP_CACHE" == true ]]; then
  rm "$CACHE_FILE_PATH"
  success "Se ha eliminado '${CACHE_FILE_NAME}'."
fi
