#!/bin/bash
set -euo pipefail

#-------------------------------------------------------#
#               Virtualizacion de Hardware              #
#                                                       #
#   APL1                                                #
#   Nro ejercicio: 3                                    #
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

# Uso: ./ejercicio3.sh -d <ruta_logs|archivo.log> -p "palabra1,palabra2"
# Ej:  ./ejercicio3.sh -d "./logs" -p "error,500"
#      ./ejercicio3.sh -d "./logs/system.log" -p "error,500"

mostrar_ayuda() {
  cat <<EOF
Uso: $0 -d <ruta_logs|archivo.log> -p <palabras>
Ejemplo: $0 -d ./logs -p 'error,500'

Parámetros:
  -d | --directorio   Directorio con .log o un archivo .log
  -p | --palabras     Palabras separadas por comas (ej: 'error,500')
  -h | --help         Muestra esta ayuda

Notas:
  - Búsqueda case-insensitive
  - Coincidencia por palabra completa (evita subcadenas)
  - Cuenta ocurrencias totales por palabra
EOF
  exit 0
}

# Parseo de parámetros (orden libre)
DIR=""
PALABRAS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--directorio) DIR="${2:-}"; shift 2;;
    -p|--palabras)   PALABRAS="${2:-}"; shift 2;;
    -h|--help)       mostrar_ayuda;;
    *)               mostrar_ayuda;;
  esac
done

# Validaciones básicas
[[ -z "$DIR" || -z "$PALABRAS" ]] && mostrar_ayuda

# Armar fuente: archivo único o find recursivo
if [[ -f "$DIR" ]]; then
  # Debe ser .log
  if [[ "${DIR##*.}" != "log" ]]; then
    echo "Error: el archivo debe tener extensión .log" >&2; exit 1
  fi
  SRC_CMD=(printf '%s\0' "$DIR")
elif [[ -d "$DIR" ]]; then
  # Debe existir al menos un .log
  if ! find "$DIR" -type f -name "*.log" -print -quit | grep -q .; then
    echo "Error: no se encontraron archivos .log en '$DIR'" >&2; exit 1
  fi
  SRC_CMD=(find "$DIR" -type f -name "*.log" -print0)
else
  echo "Error: ruta inexistente: $DIR" >&2; exit 1
fi

# Procesamiento portable (BSD awk compatible)
"${SRC_CMD[@]}" | xargs -0 awk -v words="$PALABRAS" '
BEGIN{
  n=split(words,a,/,/)
  for(i=1;i<=n;i++){
    gsub(/^ +| +$/,"",a[i])                 # trim
    if(a[i]!=""){
      key=a[i]
      b=tolower(key)                        # patrón en minúsculas
      gsub(/[][(){}.+*?^$|\\]/,"\\\\&",b)   # escapar metacaracteres
      rx[key]="(^|[^[:alnum:]_])" b "([^[:alnum:]_]|$)"  # “palabra completa”
      c[key]=0
    }
  }
}
{
  s=tolower($0)                             # línea en minúsculas
  for (k in c){
    tmp=s
    while (match(tmp, rx[k])) {
      c[k]++
      tmp=substr(tmp, RSTART+RLENGTH)
    }
  }
}
END{
  for (k in c) printf "%s: %d\n", k, c[k]
}
'
