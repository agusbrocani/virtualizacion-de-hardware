#!/bin/bash
#-------------------------------------------------------#
#               Virtualizacion de Hardware              #
#                                                       #
#   APL1 - Ejercicio 1                                  #
#                                                       #
#   Integrantes:                                        #
#        BIANCHI, JUAN              30474902            #
#        BROCANI, AGUSTIN           40931870            #
#        PASCUAL, PABLO             39208705            #
#        SANZ, ELISEO               44690195            #
#        VARALDO, RODRIGO           42772765            #
#-------------------------------------------------------#

# Help
mostrar_ayuda() {
  echo "Uso: $0 -d <directorio> [-a <directorio_salida> | -p]"
  echo
  echo "Analiza archivos de encuestas y genera un resumen con promedios diarios por canal."
  echo
  echo "Parámetros:"
  echo "  -d, --directorio   Directorio que contiene los archivos .txt de encuestas"
  echo "  -a, --archivo      Directorio donde se guardará el archivo JSON"
  echo "  -p, --pantalla     Muestra el resultado por pantalla"
  echo "  -h, --help         Muestra esta ayuda"
  echo
  echo "Ejemplos:"
  echo "  $0 -d ./lotes -p"
  echo "  $0 -d ./lotes -a ./salidas"
  exit 0
}

# Validación de parámetros
directorio=""
archivo=""
pantalla="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--directorio)
      directorio="$2"
      shift 2
      ;;
    -a|--archivo)
      archivo="$2"
      shift 2
      ;;
    -p|--pantalla)
      pantalla="true"
      shift 1
      ;;
    -h|--help)
      mostrar_ayuda
      ;;
    *)
      echo "Error: parámetro desconocido '$1'. Usa -h para ayuda." >&2
      exit 1
      ;;
  esac
done

# Validaciones
if [[ -z "$directorio" ]]; then
  echo "Error: el parámetro -d/--directorio es obligatorio." >&2
  exit 1
fi

if [[ "$pantalla" == "true" && -n "$archivo" ]]; then
  echo "Error: no puede usarse -a y -p juntos." >&2
  exit 1
fi

if [[ "$pantalla" != "true" && -z "$archivo" ]]; then
  echo "Error: debe usarse uno de -a o -p." >&2
  exit 1
fi

# Resolver rutas absolutas
directorio=$(realpath "$directorio" 2>/dev/null)
if [[ ! -d "$directorio" ]]; then
  echo "Error: '$directorio' no es un directorio válido." >&2
  exit 1
fi

if [[ "$pantalla" != "true" ]]; then
  archivo=$(realpath "$archivo" 2>/dev/null)
  if [[ ! -d "$archivo" ]]; then
    echo "Error: '$archivo' no es un directorio válido." >&2
    exit 1
  fi
fi

# Procesar archivos
archivos=$(find "$directorio" -maxdepth 1 -type f -name "*.txt")
if [[ -z "$archivos" ]]; then
  echo "Error: no se encontraron archivos .txt en '$directorio'." >&2
  exit 1
fi

tmpfile=$(mktemp)
trap "rm -f $tmpfile" EXIT

# Leer todos los archivos y filtrar líneas válidas
for f in $archivos; do
  awk -F"|" '
  NF==5 && $3!="" {
    fecha=$2
    split(fecha, a, " ")
    dia=a[1]
    canal=$3
    dur=$4+0
    nota=$5+0
    if (dur >= 0 && nota >= 1 && nota <= 5) {
      print dia "|" canal "|" dur "|" nota
    } else {
      printf "Advertencia: registro inválido en %s: %s\n", FILENAME, $0 > "/dev/stderr"
    }
  }' "$f" >> "$tmpfile"
done

if [[ ! -s "$tmpfile" ]]; then
  echo "Error: no se encontraron registros válidos." >&2
  exit 1
fi

# GENERAR JSON CON AWK
json=$(awk -F"|" '
{
  key = $1 "|" $2
  count[key]++
  sumDur[key] += $3
  sumNota[key] += $4
  fechas[$1] = 1
  canales[$1,$2] = 1
}
END {
  printf "{\n"
  nF=0
  for (f in fechas) totalF++
  for (f in fechas) {
    nF++
    printf "  \"%s\": {\n", f

    # contar cuántos canales tiene esta fecha
    totalC = 0
    for (k in canales) {
      split(k, parts, SUBSEP)
      fecha = parts[1]
      if (fecha == f) totalC++
    }

    cIndex = 0
    for (k in canales) {
      split(k, parts, SUBSEP)
      fecha = parts[1]
      canal = parts[2]
      if (fecha != f) continue
      key = fecha "|" canal
      promDur = sumDur[key] / count[key]
      promNota = sumNota[key] / count[key]
      printf "    \"%s\": {\n", canal
      printf "      \"tiempo_respuesta_promedio\": %.2f,\n", promDur
      printf "      \"nota_satisfaccion_promedio\": %.2f\n", promNota
      cIndex++
      if (cIndex < totalC) printf "    },\n"; else printf "    }\n"
    }

    printf "  }"
    if (nF < totalF) printf ",\n"; else printf "\n"
  }
  printf "}\n"
}' "$tmpfile")

# Salida
if [[ "$pantalla" == "true" ]]; then
  echo "$json"
else
  nombre="analisis-resultado-encuestas-$(date '+%Y-%m-%d_%H-%M-%S').json"
  ruta="$archivo/$nombre"
  echo "$json" > "$ruta"
  echo "Archivo generado: $ruta"
fi
