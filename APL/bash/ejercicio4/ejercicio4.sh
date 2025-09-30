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

# audit.sh - Monitoreo de repos Git (solo main/master) y escaneo de patrones sensibles
# Flags permitidos: -r/--repo  -c/--configuracion  -l/--log  -k/--kill
set -euo pipefail

# --- UI ---
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
log_error(){ echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_info(){  echo -e "${GREEN}[INFO] ${NC}$*"; }
log_warn(){  echo -e "${YELLOW}[WARN] ${NC}$*"; }
timestamp(){ date +"%Y-%m-%d %H:%M:%S"; }

# --- Helpers ---
to_abs_path() {
  local p="${1:-}"; [[ -z "$p" ]] && { echo ""; return 0; }
  if [[ "$p" = /* ]]; then echo "$p"; else
    local dir base; dir="$(dirname -- "$p")"; base="$(basename -- "$p")"
    (cd -- "$dir" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$base") || printf '%s\n' "$p"
  fi
}
hash_repo_path(){ echo -n "$1" | md5sum | awk '{print $1}'; }

# --- Dependencias ---
check_dependencies() {
  local -a missing=()
  for cmd in git inotifywait jq; do command -v "$cmd" &>/dev/null || missing+=("$cmd"); done
  if ((${#missing[@]})); then
    log_error "Dependencias faltantes: ${missing[*]}"
    log_error "En Ubuntu/Debian: sudo apt install -y inotify-tools jq git"
    log_error "En CentOS/RHEL:   sudo yum install -y inotify-tools jq git"
    exit 1
  fi
  # flock es opcional (para atomizar el log); si no está, seguimos con append normal
  if ! command -v flock >/dev/null 2>&1; then
    log_warn "flock no encontrado: el log podría intercalar líneas bajo alta concurrencia."
  fi
}

# Función para mostrar ayuda
show_help() {
  cat <<EOF
Uso: $SCRIPT_NAME [opciones]

Opciones:
  -r, --repo <ruta>            Ruta absoluta al repositorio Git a monitorear
  -c, --configuracion <archivo> Ruta absoluta al archivo de patrones
  -l, --log <archivo>          Ruta absoluta al archivo de log (por defecto: .git/audit.log)
  -k, --kill                   Detiene el demonio asociado al repositorio

Notas:
  * Solo se permite usar -r con -k para detener un demonio.
  * El demonio monitorea únicamente las ramas 'main' o 'master'.
  * Los patrones deben estar en el archivo de configuración, uno por línea.
    Para regex, usar el prefijo "regex:" (ejemplo: regex:^.*API_KEY=.*$).
EOF
}

# --- Git helpers ---
branch_exists(){ (cd "$REPO" && git show-ref --verify --quiet "refs/heads/$1"); }
get_head_commit(){ (cd "$REPO" && git rev-parse HEAD); }
get_changed_files_since(){ local since="$1"; (cd "$REPO" && git diff --name-only "${since}..HEAD" --); }

# --- Patrones (1 por línea; soporta 'regex:...') ---
declare -a PATTERNS_FIXED=() PATTERNS_REGEX=()

_trim_ws_and_cr() { # elimina CRLF y espacios/tabs a ambos lados
  local s="$1"
  s="${s%$'\r'}"                          # CR final (Windows)
  # trim left
  s="${s#"${s%%[!$' \t']*}"}"
  # trim right
  s="${s%"${s##*[!$' \t']}"}"
  printf '%s' "$s"
}

load_patterns() {
  local cfg="$1"; [[ -f "$cfg" ]] || { log_error "Archivo de configuración no existe: $cfg"; exit 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"               # comentario simple al final
    line="$(_trim_ws_and_cr "$line")"
    [[ -z "$line" ]] && continue
    if [[ "$line" == regex:* ]]; then
      PATTERNS_REGEX+=("$(_trim_ws_and_cr "${line#regex:}")")
    else
      PATTERNS_FIXED+=("$line")
    fi
  done < "$cfg"
  # De-duplicar preservando orden
  mapfile -t PATTERNS_FIXED < <(printf "%s\n" "${PATTERNS_FIXED[@]}" | awk '!seen[$0]++')
  mapfile -t PATTERNS_REGEX < <(printf "%s\n" "${PATTERNS_REGEX[@]}"  | awk '!seen[$0]++')
}

# --- Logging con lock (si hay flock) ---
LOG_LOCKFILE=""
log_line() {
  local line="$1"
  if command -v flock >/dev/null 2>&1; then
    flock -x "$LOG_LOCKFILE" bash -c "printf '%s\n' \"\$1\" >> \"\$2\"" _ "$line" "$LOGFILE"
  else
    printf "%s\n" "$line" >> "$LOGFILE"
  fi
}

# Formato exacto 1 línea/hallazgo
# [YYYY-MM-DD HH:MM:SS] Alerta: patrón '<pat>' encontrado en el archivo '<file>' (línea N) [Tipo: Simple|Regex]
log_alert(){ # $1=patrón $2=archivo_rel $3=línea $4=Tipo
  log_line "$(printf "[%s] Alerta: patrón '%s' encontrado en el archivo '%s' (línea %s) [Tipo: %s]" \
    "$(timestamp)" "$1" "$2" "$3" "$4")"
}

# --- Escaneo ---
extract_lineno() { # acepta "ruta:lin:..." o "lin:..."
  local hit="$1"
  # Si empieza con DIGITOS:
  if [[ "$hit" =~ ^([0-9]+): ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi
  # Si empieza con ruta:, quedate con la primera parte numérica
  local tmp="${hit#*:}"; echo "${tmp%%:*}"
}

scan_files_for_patterns() {
  local files=("$@")
  for f in "${files[@]}"; do
    [[ -z "$f" ]] && continue
    [[ ! -f "$REPO/$f" ]] && continue
    [[ "$f" == .git/* ]] && continue

    # Simples
    for pat in "${PATTERNS_FIXED[@]}"; do
      local pat_clean
      pat_clean="$(_trim_ws_and_cr "$pat")"
      [[ -z "$pat_clean" ]] && continue
      while IFS= read -r hit; do
        [[ -z "$hit" ]] && continue
        local ln; ln="$(extract_lineno "$hit")"
        [[ -n "$ln" ]] && log_alert "$pat_clean" "$f" "$ln" "Simple"
      done < <(grep -I -n -F -i -e "$pat_clean" -- "$REPO/$f" 2>/dev/null || true)
    done

    # Regex
    for rx in "${PATTERNS_REGEX[@]}"; do
      local rx_clean
      rx_clean="$(_trim_ws_and_cr "$rx")"
      [[ -z "$rx_clean" ]] && continue
      while IFS= read -r hit; do
        [[ -z "$hit" ]] && continue
        local ln; ln="$(extract_lineno "$hit")"
        [[ -n "$ln" ]] && log_alert "$rx_clean" "$f" "$ln" "Regex"
      done < <(grep -I -n -E -e "$rx_clean" -- "$REPO/$f" 2>/dev/null || true)
    done
  done
}

# --- Limpieza ---
cleanup() {
  local code=$?
  log_info "Limpiando recursos (PID $$, código $code)..."
  [[ -f "$PIDFILE" ]] && rm -f "$PIDFILE"
  [[ -f "$STATEFILE" ]] && rm -f "$STATEFILE"
  [[ -n "${LOG_LOCKFILE:-}" && -f "$LOG_LOCKFILE" ]] && rm -f "$LOG_LOCKFILE"
  exit $code
}
trap cleanup EXIT INT TERM ERR

# --- Daemon ---
INTERVAL=5  # fijo
daemon_loop() {
  echo $$ > "$PIDFILE"

  local branch=""
  if branch_exists main; then branch="main"
  elif branch_exists master; then branch="master"
  else log_error "El repo no tiene ramas 'main' ni 'master'."; exit 1; fi

  local head_file="$REPO/.git/refs/heads/$branch"
  local packed_refs="$REPO/.git/packed-refs"
  local last_commit
  last_commit="$(get_head_commit)"; echo "$last_commit" > "$STATEFILE"

  log_info "Monitoreando $REPO (rama $branch) | log: $LOGFILE | PID: $$"
  while :; do
    inotifywait -q -e modify,attrib,close_write,move,create,delete --timeout "$INTERVAL" "$head_file" "$packed_refs" 2>/dev/null \
      || sleep "$INTERVAL"
    local current_commit
    current_commit="$(get_head_commit)"
    if [[ "$current_commit" != "$last_commit" ]]; then
      mapfile -t changed < <(get_changed_files_since "$last_commit" || true)
      if ((${#changed[@]} > 0)); then
        log_line "$(printf "[%s] Detectados %d archivos modificados en %s..%s" \
          "$(timestamp)" "${#changed[@]}" "${last_commit:0:7}" "${current_commit:0:7}")"
        scan_files_for_patterns "${changed[@]}"
      fi
      last_commit="$current_commit"; echo "$last_commit" > "$STATEFILE"
    fi
  done
}

# --- CLI ---
REPO=""; CONFIG=""; LOGFILE=""; KILL_MODE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--repo)          REPO="$(to_abs_path "${2:-}")"; shift 2;;
    -c|--configuracion) CONFIG="$(to_abs_path "${2:-}")"; shift 2;;
    -l|--log)           LOGFILE="$(to_abs_path "${2:-}")"; shift 2;;
    -k|--kill)          KILL_MODE=1; shift;;
    -repo|--branch|--interval|-b|-i|--config|-config|--alerta|-a|*)
      log_error "Flag no permitido o desconocido: $1"; exit 1;;
  esac
done

[[ -z "$REPO" ]] && { log_error "Debe indicar -r/--repo <ruta ABSOLUTA al repo>"; exit 1; }
[[ -d "$REPO/.git" ]] || { log_error "No parece un repo Git: $REPO"; exit 1; }

# Derivados
repo_hash="$(hash_repo_path "$REPO")"
PIDFILE="/tmp/audit-${repo_hash}.pid"
STATEFILE="/tmp/audit-${repo_hash}.state"
LOG_LOCKFILE="/tmp/audit-${repo_hash}.lock"
[[ -z "${LOGFILE:-}" ]] && LOGFILE="$REPO/.git/audit.log"

# --- Kill mode (solo -r + -k) ---
if (( KILL_MODE )); then
  if [[ -n "${CONFIG:-}" || ( -n "${LOGFILE:-}" && "$LOGFILE" != "$REPO/.git/audit.log" ) ]]; then
    log_error "Con -k/--kill solo se permite -r/--repo. No use -c/--configuracion ni -l/--log."
    exit 1
  fi
  if [[ -f "$PIDFILE" ]]; then
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      log_info "Deteniendo daemon (PID $pid)..."
      kill -TERM "$pid" 2>/dev/null || true
    else
      log_warn "PID inválido u offline."
    fi
  else
    log_warn "No hay daemon corriendo para este repo."
  fi
  exit 0
fi

# --- Start ---
check_dependencies
[[ -n "${CONFIG:-}" ]] || { log_error "Debe indicar -c/--configuracion <archivo>"; exit 1; }
[[ -f "$CONFIG" ]] || { log_error "Archivo de configuración no existe: $CONFIG"; exit 1; }
load_patterns "$CONFIG"

# Evitar múltiples instancias
if [[ -f "$PIDFILE" ]]; then
  oldpid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [[ -n "$oldpid" ]] && kill -0 "$oldpid" 2>/dev/null; then
    log_error "Ya hay un daemon para este repo (PID $oldpid)."; exit 1
  fi
fi

mkdir -p -- "$(dirname "$LOGFILE")"; touch -- "$LOGFILE"
: > "$LOG_LOCKFILE"  # asegurar que exista para flock

# Daemonizar
if [[ "${DAEMON_MODE:-0}" != "1" ]]; then
  nohup env DAEMON_MODE=1 "$0" -r "$REPO" -c "$CONFIG" -l "$LOGFILE" >/dev/null 2>&1 &
  echo $! > "$PIDFILE"
  log_info "Daemon iniciado en segundo plano (PID $(cat "$PIDFILE"))"
  exit 0
else
  daemon_loop
fi
