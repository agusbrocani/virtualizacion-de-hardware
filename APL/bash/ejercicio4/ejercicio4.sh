#!/usr/bin/env bash
#-------------------------------------------------------#
#               Virtualizacion de Hardware              #
#                                                       #
#   APL1                                                #
#   Nro ejercicio: 4                                    #
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

# ejercicio4.sh - Monitorea un repo Git (solo main/master) y escanea archivos modificados
# buscando credenciales/datos sensibles (patrones simples + regex).
# Flags PERMITIDOS: -r/--repo  -c/--configuracion  -l/--log  -k/--kill
set -euo pipefail

# ---------- UI ----------
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
log_error(){ echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_info(){  echo -e "${GREEN}[INFO] ${NC}$*"; }
log_warn(){  echo -e "${YELLOW}[WARN] ${NC}$*"; }
timestamp(){ date +"%Y-%m-%d %H:%M:%S"; }

# ---------- Helpers ----------
to_abs_path() {
  local p="${1:-}"; [[ -z "$p" ]] && { echo ""; return 0; }
  if [[ "$p" = /* ]]; then echo "$p"; else
    local dir base; dir="$(dirname -- "$p")"; base="$(basename -- "$p")"
    (cd -- "$dir" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$base") || printf '%s\n' "$p"
  fi
}
canon_repo() { # normaliza a la RAÍZ real del repo
  local p="$(to_abs_path "$1")"
  ( cd "$p" && git rev-parse --show-toplevel 2>/dev/null ) || ( cd "$p" && pwd -P )
}
hash_repo_path(){ echo -n "$1" | md5sum | awk '{print $1}'; }

# Devuelve PIDs de este script cuyo cmdline contiene --repo/-r con la misma ruta (con y sin / final)
find_daemon_pids_by_repo() {
  local n="${REPO%/}"           # sin barra final
  local script="$(basename "$0")"
  ps -eo pid=,args= | awk -v script="$script" -v n="$n" 'index($0, script) && (index($0, "--repo " n) || index($0, "-r " n) || index($0, "--repo " n "/") || index($0, "-r " n "/")) {print $1}'
}

# ---------- Dependencias (EXIGE grep -P para PCRE) ----------
check_dependencies() {
  local -a missing=()
  for cmd in git inotifywait jq grep; do command -v "$cmd" &>/dev/null || missing+=("$cmd"); done
  if ((${#missing[@]})); then
    log_error "Dependencias faltantes: ${missing[*]}"
    log_error "Ubuntu/Debian: sudo apt install -y inotify-tools jq grep git"
    log_error "CentOS/RHEL:   sudo yum install -y inotify-tools jq grep git"
    exit 1
  fi
  if ! grep -P "" <<<"" >/dev/null 2>&1; then
    log_error "Tu 'grep' no soporta -P (PCRE). Es obligatorio para las regex del config."
    log_error "Instalá GNU grep con soporte PCRE. En Ubuntu/Debian: sudo apt install -y grep"
    exit 1
  fi
  command -v flock >/dev/null 2>&1 || log_warn "flock no encontrado: el log podría intercalar líneas bajo concurrencia."
}

# ---------- Git ----------
branch_exists(){ (cd "$REPO" && git show-ref --verify --quiet "refs/heads/$1"); }
get_head_commit(){ (cd "$REPO" && git rev-parse HEAD); }
get_changed_files_since(){ local since="$1"; (cd "$REPO" && git diff --name-only "${since}..HEAD" --); }

# ---------- Patrones ----------
declare -a PATTERNS_FIXED=() PATTERNS_REGEX=()

_trim_ws_and_cr() { local s="$1"; s="${s%$'\r'}"; s="${s#"${s%%[!$' \t']*}"}"; s="${s%"${s##*[!$' \t']}"}"; printf '%s' "$s"; }

load_patterns() {
  local cfg="$1"; [[ -f "$cfg" ]] || { log_error "Archivo de configuración no existe: $cfg"; exit 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(_trim_ws_and_cr "$line")"
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    if [[ "$line" == regex:* ]]; then
      line="${line#regex:}"; line="$(_trim_ws_and_cr "$line")"
      [[ -n "$line" ]] && PATTERNS_REGEX+=("$line")
    else
      PATTERNS_FIXED+=("$line")
    fi
  done < "$cfg"
  mapfile -t PATTERNS_FIXED < <(printf "%s\n" "${PATTERNS_FIXED[@]}" | awk '!seen[$0]++')
  mapfile -t PATTERNS_REGEX < <(printf "%s\n" "${PATTERNS_REGEX[@]}"  | awk '!seen[$0]++')
}

# ---------- Log atómico ----------
LOG_LOCKFILE=""
log_line() {
  local line="$1"
  if command -v flock >/dev/null 2>&1; then
    flock -x "$LOG_LOCKFILE" bash -c "printf '%s\n' \"\$1\" >> \"\$2\"" _ "$line" "$LOGFILE"
  else
    printf "%s\n" "$line" >> "$LOGFILE"
  fi
}
log_alert(){ # $1=patrón $2=archivo_rel $3=nro_linea $4=Tipo
  log_line "$(printf "[%s] Alerta: patrón '%s' encontrado en el archivo '%s' (línea %s) [Tipo: %s]" \
    "$(timestamp)" "$1" "$2" "$3" "$4")"
}

# ---------- Regex (PCRE obligatorio) ----------
_grep_regex() {
  local pattern="$1" file="$2"
  LC_ALL=C sed 's/\r$//' "$file" | grep -n -i -P --no-filename -- "$pattern" 2>/dev/null || true
}

# Extrae el número de línea desde la salida de grep -n (robusto ante "ruta:...:N:...")
extract_lineno() {
  local hit="$1"
  if [[ "$hit" =~ ^([0-9]+): ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; return 0; fi
  local before="${hit%:*}"; local ln="${before##*:}"
  if [[ ! "$ln" =~ ^[0-9]+$ ]]; then ln="$(grep -oE '(^|:)[0-9]+(:|$)' <<<"$hit" | head -n1 | tr -d ':')"; fi
  printf '%s\n' "$ln"
}

# ---------- Escaneo de un archivo ----------
scan_file_patterns() {
  local rel_path="$1"
  [[ -z "$rel_path" ]] && return 0
  [[ "$rel_path" == .git/* ]] && return 0

  local abs_path="$REPO/$rel_path"
  [[ -f "$abs_path" ]] || { log_warn "Archivo no encontrado: $rel_path"; return 0; }

  # Omitir binarios
  if ! LC_ALL=C grep -Iq . -- "$abs_path"; then return 0; fi

  # Simples (literal, case-insensitive) con normalización CRLF
  local pat pat_clean
  for pat in "${PATTERNS_FIXED[@]}"; do
    pat_clean="$(_trim_ws_and_cr "$pat")"; [[ -n "$pat_clean" ]] || continue
    while IFS= read -r hit; do
      [[ -z "$hit" ]] && continue
      local ln; ln="$(extract_lineno "$hit")"
      [[ -n "$ln" ]] && log_alert "$pat_clean" "$rel_path" "$ln" "Simple"
    done < <(LC_ALL=C sed 's/\r$//' "$abs_path" | grep -n -F -i --no-filename -- "$pat_clean" 2>/dev/null || true)
  done

  # Regex (PCRE)
  local rx rx_clean
  for rx in "${PATTERNS_REGEX[@]}"; do
    rx_clean="$(_trim_ws_and_cr "$rx")"; [[ -n "$rx_clean" ]] || continue
    while IFS= read -r hit; do
      [[ -z "$hit" ]] && continue
      local ln; ln="$(extract_lineno "$hit")"
      [[ -n "$ln" ]] && log_alert "$rx_clean" "$rel_path" "$ln" "Regex"
    done < <(_grep_regex "$rx_clean" "$abs_path")
  done
}

# ---------- Limpieza ----------
cleanup() { local code=$?; [[ -n "${LOG_LOCKFILE:-}" && -f "$LOG_LOCKFILE" ]] && rm -f "$LOG_LOCKFILE"; exit $code; }
trap cleanup EXIT INT TERM ERR

# ---------- Daemon ----------
INTERVAL=5
daemon_loop() {
  local branch=""
  if branch_exists main; then branch="main"
  elif branch_exists master; then branch="master"
  else log_error "El repo no tiene ramas 'main' ni 'master'."; exit 1; fi

  local head_file="$REPO/.git/refs/heads/$branch"
  local packed_refs="$REPO/.git/packed-refs"
  local -a watch_targets=()
  [[ -e "$head_file" ]] && watch_targets+=("$head_file")
  [[ -e "$packed_refs" ]] && watch_targets+=("$packed_refs")
  ((${#watch_targets[@]}==0)) && watch_targets+=("$REPO/.git")

  local last_commit="$(get_head_commit)"

  log_line "$(printf "[%s] Patrones cargados: %d simples, %d regex" \
    "$(timestamp)" "${#PATTERNS_FIXED[@]}" "${#PATTERNS_REGEX[@]}")"
  log_info "Monitoreando $REPO (rama $branch) | log: $LOGFILE"

  while :; do
    inotifywait -q -e modify,attrib,close_write,move,create,delete --timeout "$INTERVAL" "${watch_targets[@]}" 2>/dev/null || sleep "$INTERVAL"
    local current_commit="$(get_head_commit)"
    if [[ "$current_commit" != "$last_commit" ]]; then
      mapfile -t changed < <(get_changed_files_since "$last_commit" || true)
      if ((${#changed[@]} > 0)); then
        log_line "$(printf "[%s] Detectados %d archivos modificados en %s..%s" \
          "$(timestamp)" "${#changed[@]}" "${last_commit:0:7}" "${current_commit:0:7}")"
        for f in "${changed[@]}"; do scan_file_patterns "$f"; done
      fi
      last_commit="$current_commit"
    fi
  done
}

# ---------- CLI ----------
REPO=""; CONFIG=""; LOGFILE=""; KILL_MODE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--repo)            REPO="$(canon_repo "${2:-}")"; shift 2;;
    -c|--configuracion)   CONFIG="$(to_abs_path "${2:-}")"; shift 2;;
    -l|--log)             LOGFILE="$(to_abs_path "${2:-}")"; shift 2;;
    -k|--kill)            KILL_MODE=1; shift;;
    -repo|--branch|--interval|-b|-i|--config|-config|--alerta|-a|*)
      log_error "Flag no permitido o desconocido: $1"; exit 1;;
  esac
done

[[ -z "$REPO" ]] && { log_error "Debe indicar -r/--repo <ruta al repo>"; exit 1; }
REPO="$(canon_repo "$REPO")"
[[ -d "$REPO/.git" ]] || { log_error "No parece un repo Git: $REPO"; exit 1; }

# Derivados
repo_hash="$(hash_repo_path "$REPO")"
[[ -z "${LOGFILE:-}" ]] && LOGFILE="$REPO/.git/audit.log"
LOG_LOCKFILE="/tmp/audit-${repo_hash}.lock"
: > "$LOG_LOCKFILE"

# --- Kill mode (solo -r + -k) ---
if (( KILL_MODE )); then
  if [[ -n "${CONFIG:-}" || ( -n "${LOGFILE:-}" && "$LOGFILE" != "$REPO/.git/audit.log" ) ]]; then
    log_error "Con -k/--kill solo se permite -r/--repo. No use -c/--configuracion ni -l/--log."
    exit 1
  fi
  mapfile -t pids < <(find_daemon_pids_by_repo)
  if ((${#pids[@]} == 0)); then
    log_warn "No hay daemon corriendo para este repo."
  else
    log_info "Deteniendo por cmdline: ${pids[*]}"
    for p in "${pids[@]}"; do kill -TERM "$p" 2>/dev/null || true; done
    sleep 1
    for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null || true; done
  fi
  rm -f "$LOG_LOCKFILE" 2>/dev/null || true
  exit 0
fi

check_dependencies
[[ -n "${CONFIG:-}" ]] || { log_error "Debe indicar -c/--configuracion <archivo>"; exit 1; }
[[ -f "$CONFIG" ]] || { log_error "Archivo de configuración no existe: $CONFIG"; exit 1; }
load_patterns "$CONFIG"

# SOLO el PADRE chequea duplicados (antes de daemonizar)
if [[ "${DAEMON_MODE:-0}" != "1" ]]; then
  mapfile -t running < <(find_daemon_pids_by_repo)
  if ((${#running[@]} > 0)); then
    log_error "Ya hay un daemon para este repo (PIDs: ${running[*]})."; exit 1
  fi
  # Daemonizar
  nohup env DAEMON_MODE=1 "$0" -r "$REPO" -c "$CONFIG" -l "$LOGFILE" >/dev/null 2>&1 &
  log_info "Daemon iniciado en segundo plano."
  exit 0
else
  # El HIJO NO se auto-bloquea: entra directo al loop
  daemon_loop
fi
