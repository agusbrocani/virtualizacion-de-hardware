#! /bin/bash

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

# ejercicio2.sh - Análisis de rutas en un mapa de transporte
#
# USO:
#   ./ejercicio2.sh -m <archivo> [-s <sep>] (-h | -c)
# OPCIONES:
#   -m, --matriz    Archivo con la matriz de costos (obligatorio)
#   -s, --separador Separador de columnas en la matriz (obligatorio)
#   -h, --hub       Analiza y muestra el hub de la red
#   -c, --camino    Calcula el camino más corto que recorra todos los nodos
#   --help          Muestra esta ayuda
#
# EJEMPLOS:
#   ./ejercicio2.sh -m mapa.txt -h
#   ./ejercicio2.sh -m mapa.txt -s "," -c

mostrar_ayuda() {
  grep '^#' "$0" | sed 's/^#//'
}
set -o errexit
set -o nounset
set -o pipefail

# --- parseo ---
MAPA=""
SEP=""
MODO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--matriz) MAPA="$2"; shift 2;;
    -s|--separador) SEP="$2"; shift 2;;
	-h|--hub)
	  if [[ -n "$MODO" && "$MODO" != "hub" ]]; then
		echo "Error: No se pueden usar las opciones -h (--hub) y -c (--camino) al mismo tiempo."
		exit 1
	  fi
	  MODO="hub"
	  shift
	  ;;
	-c|--camino)
	  if [[ -n "$MODO" && "$MODO" != "camino" ]]; then
		echo "Error: No se pueden usar las opciones -h (--hub) y -c (--camino) al mismo tiempo."
		exit 1
	  fi
	  MODO="camino"
	  shift
	  ;;
    --help) mostrar_ayuda; exit 0;;
    *) echo "Parámetro inválido: $1"; exit 1;;
  esac
done

# --- validación: no se pueden usar -h y -c al mismo tiempo ---
if [[ "$@" == *"-h"* && "$@" == *"-c"* ]] || [[ "$@" == *"--hub"* && "$@" == *"--camino"* ]]; then
  echo "Error: No se pueden usar las opciones -h (--hub) y -c (--camino) al mismo tiempo."
  echo "Debe elegir solo una de ellas."
  exit 1
fi

if [[ -z "$MAPA" ]]; then
  echo "Error: Debe indicar archivo con -m"
  exit 1
fi
if [[ ! -f "$MAPA" ]]; then
  echo "Error: Archivo no encontrado: $MAPA"
  exit 1
fi
if [[ -z "$MODO" ]]; then
  echo "Error: Debe elegir -h o -c"
  exit 1
fi

# --- validaciones adicionales del separador ---
if [[ -z "${SEP:-}" ]]; then
  echo "Error: No se especificó el separador (-s o --separador)."
  echo "Ejemplo: ./ejercicio2.sh -m mapa.txt -s '|' -c"
  exit 1
fi

if [[ "$SEP" == "." ]]; then
  echo "Error: No se puede usar el punto (.) como separador, se confunde con los decimales."
  echo "Usá otro separador, por ejemplo: '|' o ','"
  exit 1
fi

if [[ "${#SEP}" -gt 1 ]]; then
  echo "Error: El separador debe ser un solo carácter. Valor recibido: '$SEP'"
  exit 1
fi

# --- leer y validar matriz ---
mapfile -t LINES < "$MAPA"


# --- leer y validar matriz ---
mapfile -t LINES < "$MAPA"
N=${#LINES[@]}
if (( N == 0 )); then
  echo "Error: El archivo está vacío"
  return 1
fi

declare -a matriz
INF=9999

for ((i=0;i<N;i++)); do
  IFS="$SEP" read -r -a row <<< "${LINES[i]}"
  if (( ${#row[@]} != N )); then
    echo "Error: La matriz no es cuadrada, fila $((i+1)) tiene ${#row[@]} columnas (esperaba $N)."
    exit 1
  fi
  for ((j=0;j<N;j++)); do
    val="${row[j]}"
    if ! [[ "$val" =~ ^[-+]?[0-9]+(\.[0-9]+)?$ ]]; then
      echo "Error: Valor no numérico en fila $((i+1)), columna $((j+1)): '$val'."
      exit 1
    fi
    if (( i == j )) && [[ "$val" != "0" ]]; then
      echo "Error: En la diagonal principal (estación consigo misma) debe haber 0 (fila $((i+1)), col $((j+1)))."
      exit 1
    fi
    matriz[$((i*N + j))]=$val
  done
done

# verificar simetría
for ((i=0;i<N;i++)); do
  for ((j=i+1;j<N;j++)); do
    a=${matriz[$((i*N + j))]}
    b=${matriz[$((j*N + i))]}
    if [[ "$a" != "$b" ]]; then
      echo "Error: La matriz no es simétrica en ($((i+1)),$((j+1))) vs ($((j+1)),$((i+1))): $a != $b"
      exit 1
    fi
  done
done

# --- función hub ---
hub() {
  awk -v sep="$SEP" '
  BEGIN { FS=sep }
  {
      conexiones = 0
      for (i=1; i<=NF; i++) {
          if ($i != 0) {
              conexiones++
          }
      }
      if (conexiones > max) {
          max = conexiones
          hubs = NR
      } else if (conexiones == max) {
          hubs = hubs "," NR
      }
  }
  END {
      print "**Hub de la red:** Estación " hubs " (" max " conexiones)"
  }
  ' "$MAPA"
}

# --- función camino ---
camino() {
  if (( N == 1 )); then
    echo "Solo 1 nodo. Camino trivial: 1  Tiempo: 0"
    exit 0
  fi

  M=$((N-1))
  declare -a arr
  for ((i=0;i<M;i++)); do arr[i]=$((i+1)); done
  declare -a c
  for ((i=0;i<M;i++)); do c[i]=0; done

  best_cost=$INF
  declare -a best_paths=()

  eval_perm() {
    local subtotal=0
    local prev=0
    local x
    for ((k=0;k<M;k++)); do
      x=${arr[k]}
      weight=${matriz[$((prev*N + x))]}

	  if (( prev != x && weight == 0 )); then
	  	weight=$INF
	  fi
      # chequeo de "infinito": cero fuera de diagonal o >= INF
      # ahora evaluamos si weight >= INF
      if (( weight >= INF )); then
          subtotal=$INF
          break
      fi

      # suma decimal
      subtotal=$(awk -v a="$subtotal" -v b="$weight" 'BEGIN {print a+b}')

      # cortar si supera el mejor costo
      if awk -v a="$subtotal" -v b="$best_cost" 'BEGIN {exit !(a>b)}'; then
        subtotal=$INF
        break
      fi

      prev=$x
    done

    # actualizar mejor costo
    if awk -v a="$subtotal" -v b="$best_cost" 'BEGIN {exit !(a<b)}'; then
      best_cost=$subtotal
      best_paths=()
      best_paths+=("0 ${arr[*]}")
    elif awk -v a="$subtotal" -v b="$best_cost" 'BEGIN {exit !(a==b)}'; then
      best_paths+=("0 ${arr[*]}")
    fi
  }

  eval_perm

  # generar permutaciones (algoritmo de Heap)
  i=0
  while (( i < M )); do
    if (( c[i] < i )); then
      if (( i % 2 == 0 )); then
        tmp=${arr[0]}; arr[0]=${arr[i]}; arr[i]=$tmp
      else
        tmp=${arr[c[i]]}; arr[c[i]]=${arr[i]}; arr[i]=$tmp
      fi
      eval_perm
      c[i]=$((c[i]+1))
      i=0
    else
      c[i]=0
      i=$((i+1))
    fi
  done

  # verificar si existe camino válido
  if (( best_cost >= INF )); then
    echo "No existe camino válido que recorra todos los nodos sin volver al inicio."
    return 0
  fi

  # mostrar resultados
  echo "**Camino más corto(s) en tiempo $best_cost:**"
  for p in "${best_paths[@]}"; do
    ruta=()
    for nodo in $p; do
      ruta+=($((nodo+1)))
    done
    echo "  Ruta: ${ruta[*]}"
  done
  return 0
}


# --- nombre del informe ---
base=$(basename "$MAPA")
informe="informe.$base"

{
  echo "## Informe de análisis de red de transporte"

  if [[ "$MODO" == "hub" ]]; then
    hub
  elif [[ "$MODO" == "camino" ]]; then
    camino
  fi
} > "$informe"

echo "Informe generado en $informe"