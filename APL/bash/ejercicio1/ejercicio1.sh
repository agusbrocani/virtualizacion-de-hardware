#! /bin/bash

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

# ============================================================
# Analiza archivos de encuestas y genera un resumen JSON
# ID|FECHA|CANAL|TIEMPO_RESPUESTA|NOTA_SATISFACCION
# ============================================================

mostrar_ayuda() {
  cat << EOF
Uso:
  ./ejercicio1.sh -d <directorio> (-a <directorio_salida> | -p)

Descripción:
  Procesa todos los archivos .txt en el directorio indicado,
  agrupando por fecha y canal, y calculando promedios.

Parámetros:
  -d, --directorio   Directorio con archivos .txt de encuestas
  -a, --archivo      Directorio donde guardar el JSON generado
  -p, --pantalla     Mostrar salida por pantalla (en lugar de archivo)
  -h, --help         Mostrar esta ayuda

Notas:
  No se puede usar -a y -p al mismo tiempo.
EOF
}

# --- Parseo de parámetros ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--directorio) DIRECTORIO="$2"; shift 2 ;;
    -a|--archivo) ARCHIVO="$2"; shift 2 ;;
    -p|--pantalla) PANTALLA=1; shift ;;
    -h|--help) mostrar_ayuda; exit 0 ;;
    *) echo "Error: parámetro desconocido '$1'"; mostrar_ayuda; exit 1 ;;
  esac
done

# --- Validaciones ---
if [[ -z "$DIRECTORIO" ]]; then
  echo "Error: debe indicar un directorio con -d." >&2
  exit 1
fi
if [[ -z "$ARCHIVO" && -z "$PANTALLA" ]]; then
  echo "Error: debe indicar -a o -p." >&2
  exit 1
fi
if [[ -n "$ARCHIVO" && -n "$PANTALLA" ]]; then
  echo "Error: no puede usar -a y -p al mismo tiempo." >&2
  exit 1
fi
if [[ ! -d "$DIRECTORIO" ]]; then
  echo "Error: el directorio '$DIRECTORIO' no existe." >&2
  exit 1
fi

# --- Procesamiento con AWK ---
JSON=$(awk -F'|' '
BEGIN {
  OFS="|"
}
{
  if (NF != 5) next

  fecha_full = $2
  canal = $3
  dur = $4
  nota = $5

  split(fecha_full, arr, " ")
  fecha = arr[1]

  key = fecha "|" canal
  sumaDur[key] += dur
  sumaNota[key] += nota
  count[key]++

  fechas[fecha] = 1
  canales[fecha, canal] = 1
}
END {
  printf "{\n"
  nf = 0
  PROCINFO["sorted_in"] = "@ind_str_asc"

  # Iterar fechas
  for (f in fechas) {
    if (nf++ > 0) printf ",\n"
    printf "  \"%s\": {\n", f

    nc = 0
    for (fc in canales) {
      split(fc, arr, SUBSEP)
      fecha = arr[1]; canal = arr[2]
      if (fecha != f) continue

      k = fecha "|" canal
      promDur = sprintf("%.2f", sumaDur[k] / count[k])
      promNota = sprintf("%.2f", sumaNota[k] / count[k])

      if (nc++ > 0) printf ",\n"
      printf "    \"%s\": { \"tiempo_respuesta_promedio\": %s, \"nota_satisfaccion_promedio\": %s }", canal, promDur, promNota
    }

    printf "\n  }"
  }

  printf "\n}\n"
}
' "$DIRECTORIO"/*.txt 2>/dev/null)

if [[ -z "$JSON" ]]; then
  echo "Error: no se encontraron registros válidos en '$DIRECTORIO'." >&2
  exit 1
fi

# --- Salida ---
if [[ -n "$PANTALLA" ]]; then
  echo "$JSON"
else
  if [[ ! -d "$ARCHIVO" ]]; then
    echo "Error: el directorio de salida '$ARCHIVO' no existe." >&2
    exit 1
  fi
  nombre="analisis-resultado-encuestas-$(date '+%Y-%m-%d_%H-%M-%S').json"
  ruta="$ARCHIVO/$nombre"
  echo "$JSON" > "$ruta"
  echo "Archivo generado: $ruta"
fi
