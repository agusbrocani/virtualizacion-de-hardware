#!/usr/bin/env bash
#-------------------------------------------------------#
#               Virtualizacion de Hardware              #
#                                                       #
#   APL1                                                #
#   Nro ejercicio: 4                                    #
#                                                       #
#   Integrantes:                                        #
#        BIANCHI, JUAN              30474902            #
#        BROCANI, AGUSTIN           40931870            #
#        PASCUAL, PABLO             39208705            #
#        SANZ, ELISEO               44690195            #
#        VARALDO, RODRIGO           42772765            #
#-------------------------------------------------------#

# ejercicio4.sh - Monitorea un repo Git (solo main/master) y escanea archivos modificados.
# Flags PERMITIDOS: -r/--repo  -c/--configuracion  -l/--log  -k/--kill  -h/--help
set -euo pipefail

# ---------- UI ----------
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
log_error(){ echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_info(){  echo -e "${GREEN}[INFO] ${NC}$*"; }
log_warn(){  echo -e "${YELLOW}[WARN] ${NC}$*"; }
timestamp(){ date +"%Y-%m-%d %H:%M:%S"; }

# ---------- Help ----------
show_help() {
  cat <<'EOF'
Uso:
  Iniciar daemon (OBLIGATORIOS: -r -c -l):
    ./ejercicio4.sh -r <ruta_repo> -c <patrones.conf> -l <archivo_log|directorio>

  Detener daemon (SOLO -r):
    ./ejercicio4.sh -r <ruta_repo> -k

Flags:
  -r, --repo            Ruta de la RAÍZ del repositorio (DEBE existir <ruta>/.git). NO asciende.
  -c, --configuracion   Archivo de patrones (líneas simples o 'regex:<PCRE>').
  -l, --log             Ruta de log. Si es directorio/termina en '/', se usa .audit-<repo>.log dentro.
  -k, --kill            Detiene el daemon del repo indicado (SOLO con --repo).
  -h, --help            Muestra esta ayuda.

Notas:
  • Monitorea SOLO 'main' o 'master' (si no hay HEAD, espera primer commit).
  • Un solo daemon por repo (identificado por token --repo-abs <ruta_canónica>).
  • Se ignoran binarios. Regex requiere grep con -P (PCRE).
  • Si no hay 'inotifywait', cae a modo polling (Linux/WSL/Git Bash).
EOF
}

# ---------- Helpers ----------
to_abs_path() {
  local p="${1:-}"; [[ -z "$p" ]] && { echo ""; return 0; }
  if [[ "$p" = /* ]]; then echo "$p"; else
    local dir base; dir="$(dirname -- "$p")"; base="$(basename -- "$p")"
    (cd -- "$dir" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$base") || printf '%s\n' "$p"
  fi
}

# NO asciende al toplevel; solo absolutiza. La validación .git se hace luego.
canon_repo(){ to_abs_path "$1"; }

hash_repo_path(){ echo -n "$1" | md5sum | awk '{print $1}'; }

# Busca PIDs del script para el repo canónico (para -k). Robusta y evita falsos positivos.
find_daemon_pids_by_repo() {
  local script self n nslash
  script="$(basename "$0")"; self="$$"
  n="${REPO%/}"; nslash="$n/"
  ps -eo pid=,args= | awk -v s="$script" -v n="$n" -v nslash="$nslash" -v self="$self" '
    { pid=$1; $1=""; cmd=$0
      if (index(cmd,s)==0) next
      if (pid==self) next
      if (index(cmd," -k ") || index(cmd," --kill ")) next
      if (index(cmd,"--repo-abs " n) || index(cmd,"--repo-abs " nslash)) { print pid; next }
      if (index(cmd,"-r " n " ") || index(cmd,"--repo " n " ") ||
          index(cmd,"-r " nslash) || index(cmd,"--repo " nslash)) { print pid; next }
    }'
}

# SOLO para prevenir duplicados ANTES de lanzar: cuenta SOLO daemons reales (con --repo-abs)
find_running_daemons_strict() {
  local script n
  script="$(basename "$0")"; n="${REPO%/}"
  ps -eo pid=,args= | awk -v s="$script" -v n="$n" '
    { pid=$1; $1=""; cmd=$0
      if (index(cmd,s)==0) next
      if (index(cmd,"--repo-abs " n) || index(cmd,"--repo-abs " n "/")) print pid
    }'
}

# ---------- Dependencias ----------
check_dependencies() {
  local -a missing=()
  # Usar ggrep si está disponible (macOS con brew), sino grep
  if command -v ggrep >/dev/null 2>&1; then
    GREP_CMD="ggrep"
  else
    GREP_CMD="grep"
  fi

  for cmd in git jq "$GREP_CMD"; do command -v "$cmd" &>/dev/null || missing+=("$cmd"); done
  if ((${#missing[@]})); then log_error "Dependencias faltantes: ${missing[*]}"; exit 1; fi
  if ! "$GREP_CMD" -P "" <<<"" >/dev/null 2>&1; then
    log_error "Tu '$GREP_CMD' no soporta -P (PCRE). Es obligatorio para regex del config."; exit 1
  fi
  command -v inotifywait >/dev/null 2>&1 || log_warn "inotifywait no encontrado: se usará polling."
  command -v flock >/dev/null 2>&1 || log_warn "flock no encontrado: el log podría intercalar líneas bajo concurrencia."
}

# ---------- Git ----------
branch_exists(){ (cd "$REPO" && git show-ref --verify --quiet "refs/heads/$1"); }
get_head_commit(){ (cd "$REPO" && git rev-parse --verify -q HEAD 2>/dev/null) || echo ""; }
get_changed_files_since(){ local since="$1"; (cd "$REPO" && git diff --name-only "${since}..HEAD" --); }
is_hash(){ [[ "$1" =~ ^[0-9a-f]{7,40}$ ]]; }

# ---------- Patrones ----------
declare -a PATTERNS_FIXED=() PATTERNS_REGEX=()
_trim_ws_and_cr() { local s="$1"; s="${s%$'\r'}"; s="${s#"${s%%[!$' \t']*}"}"; s="${s%"${s##*[!$' \t']}"}"; printf '%s' "$s"; }

load_patterns() {
  local cfg="$1"; [[ -f "$cfg" ]] || { log_error "Archivo de configuración no existe: $cfg"; exit 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(_trim_ws_and_cr "$line")"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" == regex:* ]]; then
      line="${line#regex:}"; line="$(_trim_ws_and_cr "$line")"; [[ -n "$line" ]] && PATTERNS_REGEX+=("$line")
    else
      PATTERNS_FIXED+=("$line")
    fi
  done < "$cfg"
  # Remover duplicados usando awk y read (compatible con bash antiguo)
  PATTERNS_FIXED=($(printf "%s\n" "${PATTERNS_FIXED[@]}" | awk '!seen[$0]++'))
  PATTERNS_REGEX=($(printf "%s\n" "${PATTERNS_REGEX[@]}"  | awk '!seen[$0]++'))
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
log_alert(){
  log_line "$(printf "[%s] Alerta: patrón '%s' encontrado en el archivo '%s' (línea %s) [Tipo: %s]" \
    "$(timestamp)" "$1" "$2" "$3" "$4")"
}

# ---------- Regex grep ----------
_grep_regex() {
  local pattern="$1" file="$2"
  LC_ALL=C sed 's/\r$//' "$file" | "$GREP_CMD" -n -i -P --no-filename -- "$pattern" 2>/dev/null || true
}
extract_lineno() {
  local hit="$1"
  if [[ "$hit" =~ ^([0-9]+): ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; return 0; fi
  local before="${hit%:*}"; local ln="${before##*:}"
  [[ "$ln" =~ ^[0-9]+$ ]] || ln="$("$GREP_CMD" -oE '(^|:)[0-9]+(:|$)' <<<"$hit" | head -n1 | tr -d ':')"
  printf '%s\n' "$ln"
}

# ---------- Escaneo ----------
scan_file_patterns() {
  local rel_path="$1"
  [[ -z "$rel_path" || "$rel_path" == .git/* ]] && return 0
  local abs_path="$REPO/$rel_path"; [[ -f "$abs_path" ]] || { log_warn "Archivo no encontrado: $rel_path"; return 0; }
  if ! LC_ALL=C "$GREP_CMD" -Iq . -- "$abs_path"; then return 0; fi  # Omitir binarios

  # Simples
  local pat pat_clean
  for pat in "${PATTERNS_FIXED[@]}"; do
    pat_clean="$(_trim_ws_and_cr "$pat")"; [[ -n "$pat_clean" ]] || continue
    while IFS= read -r hit; do
      [[ -z "$hit" ]] && continue
      local ln; ln="$(extract_lineno "$hit")"
      [[ -n "$ln" ]] && log_alert "$pat_clean" "$rel_path" "$ln" "Simple"
    done < <(LC_ALL=C sed 's/\r$//' "$abs_path" | "$GREP_CMD" -n -F -i --no-filename -- "$pat_clean" 2>/dev/null || true)
  done

  # Regex
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
cleanup(){ local code=$?; [[ -n "${LOG_LOCKFILE:-}" && -f "$LOG_LOCKFILE" ]] && rm -f "$LOG_LOCKFILE"; exit $code; }
trap cleanup EXIT INT TERM ERR

# ---------- Daemon ----------
INTERVAL=5
daemon_loop() {
  local branch=""
  branch="$(cd "$REPO" && git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [[ "$branch" != "main" && "$branch" != "master" ]]; then
    if branch_exists main; then branch="main"
    elif branch_exists master; then branch="master"
    else branch="main"; fi
  fi

  # Vigilar SIEMPRE .git (robusto; si no hay inotify, usamos polling)
  local -a watch_targets=("$REPO/.git")
  local use_inotify=0
  if command -v inotifywait >/dev/null 2>&1; then use_inotify=1; fi

  local last_commit current_commit
  local last_git_mtime=""

  last_commit="$(get_head_commit)"
  if [[ -n "$last_commit" ]]; then
    log_line "$(printf "[%s] Patrones cargados: %d simples, %d regex" \
      "$(timestamp)" "${#PATTERNS_FIXED[@]}" "${#PATTERNS_REGEX[@]}")"
    log_info "Monitoreando $REPO (rama $branch) | log: $LOGFILE"
  else
    log_warn "Repo válido pero sin commits (HEAD inexistente). Esperando el primer commit en $branch..."
  fi

  if (( ! use_inotify )); then
    last_git_mtime="$(LC_ALL=C stat -c %Y "$REPO/.git" 2>/dev/null || echo "")"
  fi

  while :; do
    if (( use_inotify )); then
      inotifywait -q -e modify,attrib,close_write,move,create,delete --timeout "$INTERVAL" "${watch_targets[@]}" 2>/dev/null || sleep "$INTERVAL"
    else
      sleep "$INTERVAL"
      local mtime_now
      mtime_now="$(LC_ALL=C stat -c %Y "$REPO/.git" 2>/dev/null || echo "")"
      [[ "$mtime_now" == "$last_git_mtime" ]] || last_git_mtime="$mtime_now"
    fi

    current_commit="$(get_head_commit)"

    # Primer commit: escanear y luego monitoreo normal
    if [[ -z "$last_commit" ]]; then
      if [[ -n "$current_commit" ]]; then
        first_files=($(cd "$REPO" && git ls-tree -r --name-only "$current_commit"))
        if ((${#first_files[@]} > 0)); then
          log_line "$(printf "[%s] Detectados %d archivos iniciales en %s (primer commit)" \
            "$(timestamp)" "${#first_files[@]}" "${current_commit:0:7}")"
          for f in "${first_files[@]}"; do scan_file_patterns "$f"; done
        fi
        log_line "$(printf "[%s] Patrones cargados: %d simples, %d regex" \
          "$(timestamp)" "${#PATTERNS_FIXED[@]}" "${#PATTERNS_REGEX[@]}")"
        log_info "Monitoreando $REPO (rama $branch) | log: $LOGFILE"
        last_commit="$current_commit"
      fi
      continue
    fi

    # Commit nuevo
    if [[ -n "$current_commit" && "$current_commit" != "$last_commit" ]]; then
      # Si last_commit no es hash (p.ej. "HEAD"), tratar como primer commit
      if ! is_hash "$last_commit"; then
        first_files2=($(cd "$REPO" && git ls-tree -r --name-only "$current_commit"))
        if ((${#first_files2[@]} > 0)); then
          log_line "$(printf "[%s] Detectados %d archivos iniciales en %s (primer commit)" \
            "$(timestamp)" "${#first_files2[@]}" "${current_commit:0:7}")"
          for f in "${first_files2[@]}"; do scan_file_patterns "$f"; done
        fi
        last_commit="$current_commit"
        continue
      fi

      # Camino normal: diff entre hashes
      changed=($(get_changed_files_since "$last_commit" || true))
      # Fallback: si el diff vino vacío, listar archivos del commit nuevo
      if ((${#changed[@]} == 0)); then
        changed=($(cd "$REPO" && git diff-tree --no-commit-id --name-only -r "$current_commit" 2>/dev/null || true))
      fi

      if ((${#changed[@]} > 0)); then
        log_line "$(printf "[%s] Detectados %d archivos modificados en %s..%s" \
          "$(timestamp)" "${#changed[@]}" "${last_commit:0:7}" "${current_commit:0:7}")"
        for f in "${changed[@]}"; do scan_file_patterns "$f"; done
      else
        log_line "$(printf "[%s] Commit %s..%s sin cambios detectables en archivos (diff vacío)" \
          "$(timestamp)" "${last_commit:0:7}" "${current_commit:0:7}")"
      fi
      last_commit="$current_commit"
    fi
  done
}

# ---------- CLI ----------
REPO=""; CONFIG=""; LOGFILE=""; KILL_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-abs)          shift 2;;   # token del hijo (para identificación); no se usa en el padre
    -r|--repo)           REPO="$(canon_repo "${2:-}")"; shift 2;;
    -c|--configuracion)  CONFIG="$(to_abs_path "${2:-}")"; shift 2;;
    -l|--log)            LOGFILE="$(to_abs_path "${2:-}")"; shift 2;;
    -k|--kill)           KILL_MODE=1; shift;;
    -h|--help)           show_help; exit 0;;
    --)                  shift; break;;
    -*)                  log_error "Flag no permitido o desconocido: $1"; exit 1;;
    *)                   log_error "Argumento no reconocido: $1"; exit 1;;
  esac
done

# Validación por modo
if (( KILL_MODE )); then
  [[ -z "$REPO" ]] && { log_error "Con -k/--kill debe indicar -r/--repo"; exit 1; }
  [[ -n "${CONFIG:-}" || -n "${LOGFILE:-}" ]] && { log_error "Con -k/--kill solo se permite -r/--repo (sin -c ni -l)."; exit 1; }
else
  [[ -z "$REPO" ]]        && { log_error "Falta -r/--repo"; exit 1; }
  [[ -z "${CONFIG:-}" ]]  && { log_error "Falta -c/--configuracion"; exit 1; }
  [[ -z "${LOGFILE:-}" ]] && { log_error "Falta -l/--log"; exit 1; }
fi

# Canonicalizar y validar ESTRICTO: debe existir .git EN ESA RUTA (no subir hacia arriba)
REPO="$(canon_repo "$REPO")"
if [[ ! -d "$REPO/.git" ]]; then
  log_error "La ruta en -r debe ser la RAÍZ del repo: se espera '$REPO/.git'. No se sube hacia arriba."
  exit 1
fi

# Nombre base del repo (para componer log si -l es directorio)
repo_base="$(basename "$REPO")"

# Derivados comunes (lock)
repo_hash="$(hash_repo_path "$REPO")"
LOG_LOCKFILE="/tmp/audit-${repo_hash}.lock"
: > "$LOG_LOCKFILE"

# ----- Kill mode -----
if (( KILL_MODE )); then
  pids=($(find_daemon_pids_by_repo))
  if ((${#pids[@]} == 0)); then
    log_warn "No hay daemon corriendo para este repo."
  else
    # Marcar parada intencional (para que el watchdog externo no avise)
    for p in "${pids[@]}"; do : > "/tmp/audit-stop.${p}"; done
    log_info "Deteniendo por cmdline: ${pids[*]}"
    for p in "${pids[@]}"; do kill -TERM "$p" 2>/dev/null || true; done
    sleep 1
    for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null || true; done
  fi
  rm -f "$LOG_LOCKFILE" 2>/dev/null || true
  exit 0
fi

# Validar configuración
[[ -f "$CONFIG" ]] || { log_error "Archivo de configuración no existe: $CONFIG"; exit 1; }

# Normalizar/validar LOGFILE (si es directorio o termina en /, crear nombre por defecto dentro)
if [[ -d "$LOGFILE" || "$LOGFILE" == */ ]]; then
  LOGFILE="${LOGFILE%/}/audit-${repo_base}.log"
fi
mkdir -p -- "$(dirname -- "$LOGFILE")" 2>/dev/null || true
: > "$LOGFILE" 2>/dev/null || { log_error "No puedo escribir en '$LOGFILE' (¿es un directorio o falta permiso?)."; exit 1; }

check_dependencies
load_patterns "$CONFIG"

# ÚNICO DAEMON por repo (chequeo estricto SOLO de daemons reales con --repo-abs)
if [[ "${DAEMON_MODE:-0}" != "1" ]]; then
  running=($(find_running_daemons_strict))
  if ((${#running[@]} > 0)); then
    log_error "Ya hay un daemon para este repo (PIDs: ${running[*]})."; exit 1
  fi

  # Lanzar hijo (daemon) con token --repo-abs
  nohup env DAEMON_MODE=1 "$0" --repo-abs "$REPO" -r "$REPO" -c "$CONFIG" -l "$LOGFILE" >/dev/null 2>&1 &
  child_pid=$!

  # Watchdog externo, desacoplado del proceso padre (avisa SOLO por consola si el daemon cae)
  quit_marker="/tmp/audit-stop.${child_pid}"
  nohup bash -c "
    pid=\"\$1\"; repo=\"\$2\"; marker=\"\$3\"
    ts(){ date +\"%Y-%m-%d %H:%M:%S\"; }
    while kill -0 \"\$pid\" 2>/dev/null; do sleep 5; done
    if [ -f \"\$marker\" ]; then rm -f \"\$marker\" 2>/dev/null || true; exit 0; fi
    echo \"[\$(ts)] ERROR: daemon detenido para \$repo (pid \$pid). Revísalo y reinícialo.\" >&2
  " _ "$child_pid" "$REPO" "$quit_marker" >/dev/null 2>&1 & disown

  log_info "Daemon iniciado en segundo plano (pid $child_pid)."
  exit 0
else
  daemon_loop
fi
