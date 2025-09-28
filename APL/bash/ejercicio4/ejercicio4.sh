#!/bin/bash

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

set -euo pipefail

# Variables globales
tmp="$(basename "$0")"
readonly SCRIPT_NAME="$tmp"
readonly TEMP_DIR="${TMPDIR:-/tmp}"
readonly DAEMON_PREFIX="git-security-daemon"
readonly CONFIG_PREFIX="git-security-config"
readonly PROCESSED_PREFIX="git-security-processed"

# Colores para output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly GRAY='\033[0;37m'
readonly NC='\033[0m' # No Color

# Función para mostrar ayuda
show_help() {
    cat << EOF
SINOPSIS
    Demonio de monitoreo para detectar credenciales y datos sensibles en repositorios Git.

DESCRIPCIÓN
    Este script implementa un demonio que monitorea un repositorio Git en tiempo real para detectar
    credenciales o datos sensibles que se hayan subido por error. Utiliza inotify para detectar
    cambios en la rama principal y escanea archivos modificados usando patrones configurables.

PARÁMETROS
    -repo PATH               Ruta del repositorio Git a monitorear
    -configuracion PATH      Archivo de configuración con patrones de seguridad  
    -log PATH                Archivo de logs donde registrar alertas
    -kill                    Detener el demonio en ejecución
    -help                    Mostrar esta ayuda

EJEMPLOS
    # Iniciar el demonio
    $SCRIPT_NAME -repo /path/to/repo -configuracion patterns.conf -log security.log
    
    # Detener el demonio
    $SCRIPT_NAME -repo /path/to/repo -kill

ARCHIVOS
    El demonio crea archivos temporales en $TEMP_DIR para:
    - Control de procesos (PID files)
    - Configuración temporal
    - Control de commits procesados (debounce)

NOTAS
    - Solo puede ejecutarse un demonio por repositorio
    - Requiere inotify-tools para monitoreo en tiempo real
    - Los patrones soportan texto simple y expresiones regulares (prefijo 'regex:')

EOF
}

# Función para logging con colores
log_info() {
    echo -e "${GREEN}[INFO]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_debug() {
    if [[ "${VERBOSE:-0}" -eq 1 ]]; then
        echo -e "${GRAY}[DEBUG]${NC} $*" >&2
    fi
}

# Función para detener el demonio
stop_daemon() {
    local pid_file
    pid_file=$(get_pid_file)

    if [[ ! -f "$pid_file" ]]; then
        log_error "No se encontró un demonio activo para el repositorio '$REPO_PATH'"
        exit 1
    fi

    local pid
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        log_warn "PID inválido o proceso inexistente. Limpio archivos y salgo."
        rm -f "$pid_file"
        cleanup_temp_files
        return 0
    fi

    log_info "Deteniendo demonio con PID $pid..."

    # Escapar el REPO_PATH para regex de pkill -f
    local repo_re
    repo_re="$(printf '%s' "$REPO_PATH" | sed 's/[.[\*^$()+?{}|]/\\&/g')"

    # 1) Enviar SIGTERM al GRUPO de procesos del daemon (si tiene su propio PGID)
    #    (kill -<pgid> envía la señal a todo el grupo)
    log_debug "Enviando SIGTERM al grupo -$pid y al PID $pid"
    kill -TERM -"$pid" 2>/dev/null || true
    kill -TERM  "$pid" 2>/dev/null || true

    # 2) Terminar hijos por PPID (por si la shell creó pipeline subshells)
    pkill -TERM -P "$pid" 2>/dev/null || true

    # 3) Terminar inotifywait asociado a ESTE repo (no todos)
    pkill -TERM -f "inotifywait.*${repo_re}(/\.git)?/" 2>/dev/null || true
    pkill -TERM -f "inotifywait.*${repo_re}.*\.git"    2>/dev/null || true

    sleep 1

    # 4) Forzar KILL si queda algo vivo
    pkill -KILL -P "$pid" 2>/dev/null || true
    kill -KILL -"$pid" 2>/dev/null || true
    pkill -KILL -f "inotifywait.*${repo_re}(/\.git)?/" 2>/dev/null || true
    pkill -KILL -f "inotifywait.*${repo_re}.*\.git"    2>/dev/null || true

    # 5) Verificación (solo debug)
    local remain
    remain="$(pgrep -a -P "$pid" 2>/dev/null || true)"
    if [[ -n "$remain" ]]; then
        log_warn "Aún hay hijos colgando:\n$remain"
    fi
    local remain_inw
    remain_inw="$(pgrep -a -f "inotifywait.*${repo_re}" 2>/dev/null || true)"
    if [[ -n "$remain_inw" ]]; then
        log_warn "inotifywait restante:\n$remain_inw"
    fi

    # 6) Limpieza
    sleep 1
    log_info "Ejecutando limpieza de archivos temporales..."
    cleanup_temp_files
    rm -f "$pid_file"

    log_info "Demonio detenido para repositorio: $REPO_PATH"
}

# Función para limpiar archivos temporales
cleanup_temp_files() {
    log_info "Iniciando limpieza de archivos temporales del demonio..."
    
    local config_files processed_files pid_files
    local total_files=0 cleaned_files=0
    
    # Buscar archivos temporales
    config_files=$(find "$TEMP_DIR" -name "${CONFIG_PREFIX}-*.json" 2>/dev/null || true)
    processed_files=$(find "$TEMP_DIR" -name "${PROCESSED_PREFIX}-*.json" 2>/dev/null || true)
    pid_files=$(find "$TEMP_DIR" -name "${DAEMON_PREFIX}-*.pid" 2>/dev/null || true)
    
    # Contar archivos
    [[ -n "$config_files" ]] && total_files=$((total_files + $(echo "$config_files" | wc -l)))
    [[ -n "$processed_files" ]] && total_files=$((total_files + $(echo "$processed_files" | wc -l)))
    [[ -n "$pid_files" ]] && total_files=$((total_files + $(echo "$pid_files" | wc -l)))
    
    log_info "Archivos temporales encontrados:"
    echo -e " ${CYAN}-${NC} Configuración: $(printf "%s\n" "$config_files" | grep -c .)"
    echo -e " ${CYAN}-${NC} Commits procesados: $(printf "%s\n" "$processed_files" | grep -c .)"
    echo -e " ${CYAN}-${NC} Archivos PID: $(printf "%s\n" "$pid_files" | grep -c .)"
    
    if [[ $total_files -eq 0 ]]; then
        log_info "No se encontraron archivos temporales para limpiar."
        return
    fi
    
    # Obtener PIDs activos
    local -a active_pids=()
    if [[ -n "$pid_files" ]]; then
        while IFS= read -r pid_file; do
            [[ -z "$pid_file" ]] && continue
            local pid
            pid=$(cat "$pid_file" 2>/dev/null || echo "")
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                active_pids+=("$pid")
                log_warn " PID $pid está activo - archivos relacionados serán preservados"
            fi
        done <<< "$pid_files"
    fi
    
    # Limpiar archivos de configuración
    if [[ -n "$config_files" ]]; then
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            local pid_from_file
            pid_from_file=$(basename "$file" .json | cut -d'-' -f3)
            
            if [[ ! " ${active_pids[*]} " =~ [[:space:]]${pid_from_file}[[:space:]] ]]; then
                rm -f "$file"
                echo -e "  ${GREEN}✓${NC} Eliminado: $(basename "$file")"
                ((cleaned_files++))
            else
                echo -e "  ${YELLOW}→${NC} Preservado: $(basename "$file") (demonio activo)"
            fi
        done <<< "$config_files"
    fi
    
    # Limpiar archivos de commits procesados
    if [[ -n "$processed_files" ]]; then
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            local pid_from_file
            pid_from_file=$(basename "$file" .json | cut -d'-' -f3)
            
            if [[ ! " ${active_pids[*]} " =~ [[:space:]]${pid_from_file}[[:space:]] ]]; then
                rm -f "$file"
                echo -e "  ${GREEN}✓${NC} Eliminado: $(basename "$file")"
                ((cleaned_files++))
            else
                echo -e "  ${YELLOW}→${NC} Preservado: $(basename "$file") (demonio activo)"
            fi
        done <<< "$processed_files"
    fi
    
    # Limpiar archivos PID huérfanos
    if [[ -n "$pid_files" ]]; then
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            local pid
            pid=$(cat "$file" 2>/dev/null || echo "")
            
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                echo -e "  ${YELLOW}→${NC} Preservado: $(basename "$file") (proceso activo PID $pid)"
            else
                rm -f "$file"
                echo -e "  ${GREEN}✓${NC} Eliminado: $(basename "$file") (proceso no existe)"
                ((cleaned_files++))
            fi
        done <<< "$pid_files"
    fi
    
    log_info "Limpieza completada: $cleaned_files archivos eliminados de $total_files encontrados."
}

# Función para obtener archivos modificados en el último commit
get_modified_files() {
    local repo_path="$1"
    local commit_hash="${2:-HEAD}"
    local original_dir="$PWD"
    
    if [[ ! -d "$repo_path" ]]; then
        log_error "El directorio del repositorio no existe: $repo_path"
        return 1
    fi
    
    if ! cd "$repo_path"; then
        log_error "No se pudo acceder al directorio: $repo_path"
        return 1
    fi
    
    # Obtener archivos modificados en el commit
    local modified_files
    modified_files=$(git diff-tree --no-commit-id --name-only -r "$commit_hash" 2>/dev/null || true)
    
    # Regresar al directorio original
    cd "$original_dir"
    
    if [[ -z "$modified_files" ]]; then
        log_debug "No se encontraron archivos modificados en commit $commit_hash"
        return
    fi
    
    # Filtrar solo archivos de texto relevantes
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        
        local full_path="$repo_path/$file"
        if [[ -f "$full_path" ]] && [[ ! "$file" =~ \.(exe|dll|bin|png|jpg|gif|pdf)$ ]]; then
            echo "$file"
        fi
    done <<< "$modified_files"
}

# Función para escanear archivo en busca de secretos
scan_file_patterns() {
    local file_path="$1"
    local config_file="$2"
    local -a alerts=()

    # Debug: entrada a la función
    echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') - Escaneando archivo: $file_path" >> "debug_scan.log"

    if [[ ! -f "$file_path" ]]; then
        log_warn "Archivo no encontrado: $file_path"
        echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') - ARCHIVO NO ENCONTRADO: $file_path" >> "debug_scan.log"
        return
    fi

    # (Opcional) Saltar binarios
    if ! LC_ALL=C grep -Iq . -- "$file_path"; then
        log_debug "Archivo binario omitido: $file_path"
        echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') - BINARIO OMITIDO: $file_path" >> "debug_scan.log"
        return
    fi

    # Leer configuración
    local simple_patterns regex_patterns
    simple_patterns=$(jq -r '.simple_patterns[]' "$config_file" 2>/dev/null || true)
    regex_patterns=$(jq -r '.regex_patterns[]' "$config_file" 2>/dev/null || true)

    echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') - Patrones cargados: $(echo "$simple_patterns" | grep -c . || true) simples, $(echo "$regex_patterns" | grep -c . || true) regex" >> "debug_scan.log"

    log_debug "Escaneando archivo: $file_path"

    # ---------- ESCANEO: PATRONES SIMPLES ----------
    if [[ -n "$simple_patterns" ]]; then
        while IFS= read -r pattern; do
            [[ -z "$pattern" ]] && continue

            # Lector de líneas: normaliza CRLF y no pierde la última línea sin \n
            local line_num=1
            while IFS= read -r line || [[ -n "$line" ]]; do
                # Trazas de lectura para prueba.txt
                if [[ "$line" =~ $pattern ]]; then
                    alerts+=("$(echo "$file_path|$pattern|$line_num|${line:0:100}|Simple" | jq -R .)")
                    log_debug "Patrón simple encontrado: '$pattern' en línea $line_num"
                    echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') - MATCH SIMPLE: '$pattern' en línea $line_num del archivo $file_path" >> "debug_scan.log"
                fi
                ((line_num++))
            done < <(sed -e 's/\r$//' -- "$file_path")
        done <<< "$simple_patterns"
    fi

    # ---------- ESCANEO: PATRONES REGEX ----------
    if [[ -n "$regex_patterns" ]]; then
        while IFS= read -r pattern; do
            [[ -z "$pattern" ]] && continue

            local line_num=1
            while IFS= read -r line || [[ -n "$line" ]]; do
                if [[ "$line" =~ $pattern ]]; then
                    alerts+=("$(echo "$file_path|$pattern|$line_num|${line:0:100}|Regex" | jq -R .)")
                    log_debug "Patrón regex encontrado: '$pattern' en línea $line_num"
                    echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') - MATCH REGEX: '$pattern' en línea $line_num del archivo $file_path" >> "debug_scan.log"
                fi
                ((line_num++))
            done < <(sed -e 's/\r$//' -- "$file_path")
        done <<< "$regex_patterns"
    fi

    # ---------- EMITIR ALERTAS ----------
    local log_path
    log_path=$(jq -r '.log_path' "$config_file")

    for alert in "${alerts[@]}"; do
        IFS='|' read -r file pattern line_num _ pattern_type <<< "$(echo "$alert" | jq -r .)"

        local timestamp filename
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        filename=$(basename "$file")

        local log_entry="[$timestamp] Alerta: patrón '$pattern' encontrado en el archivo '$filename' (línea $line_num) [Tipo: $pattern_type]"
        echo "$log_entry" >> "$log_path"
        echo -e "${RED}$log_entry${NC}"
    done
}

# Función para cargar patrones de seguridad
load_security_patterns() {
    local patterns_file="$1"
    local -a simple_patterns=()
    local -a regex_patterns=()
    
    #Si lo ponés vacío (IFS=), evitás que se "rompan" las líneas en espacios o tabs
    while IFS= read -r line; do
        # Omitir líneas vacías y comentarios
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Limpiar espacios y caracteres de retorno de carro
        line=$(echo "$line" | sed 's/\r$//' | xargs)
        [[ -z "$line" ]] && continue
        
        if [[ "$line" =~ ^regex: ]]; then
            regex_patterns+=("${line#regex:}")
        else
            simple_patterns+=("$line")
        fi
    done < "$patterns_file"
    
    log_debug "Cargados ${#simple_patterns[@]} patrones simples y ${#regex_patterns[@]} patrones regex"
    
    # Crear archivo de configuración temporal
    local config_file="$TEMP_DIR/${CONFIG_PREFIX}-$$.json"
    jq -n \
        --argjson simple "$(printf '%s\n' "${simple_patterns[@]}" | jq -R . | jq -s .)" \
        --argjson regex "$(printf '%s\n' "${regex_patterns[@]}" | jq -R . | jq -s .)" \
        '{
            repository_path: $REPO_PATH,
            log_path: $LOG_PATH,
            simple_patterns: $simple,
            regex_patterns: $regex
        }' \
        --arg REPO_PATH "$REPO_PATH" \
        --arg LOG_PATH "$LOG_PATH" \
        > "$config_file"
    
    echo "$config_file"

    for p in "${simple_patterns[@]}"; do
        log_debug "Simple: $p"
    done
    for r in "${regex_patterns[@]}"; do
        log_debug "Regex: $r"
    done
}

# Función principal del demonio
start_daemon() {
    local config_file
    config_file=$(load_security_patterns "$CONFIG_PATH")
    
    local pid_file
    pid_file=$(get_pid_file)
    
    # Crear archivo PID
    echo $$ > "$pid_file"
    
    log_info "Demonio de seguridad iniciado para repositorio: $REPO_PATH"
    log_info "PID del demonio: $$"
    log_info "Archivo PID: $pid_file"
    log_info "Archivo de log: $LOG_PATH"
    
    # Configurar limpieza al recibir señales
    trap 'cleanup_and_exit' TERM INT
    
    # Archivo para control de commits procesados (debounce)
    local processed_file="$TEMP_DIR/${PROCESSED_PREFIX}-$$.json"
    echo '{}' > "$processed_file"
    
    log_info "Demonio iniciado correctamente. Use --kill para detenerlo."
    log_info "El demonio se ejecuta en segundo plano de forma continua."
    
    # Monitorear cambios en .git usando inotify
    local git_path="$REPO_PATH/.git"
    
    inotifywait -m -r -e modify,create,move "$git_path" --format '%w%f %e' 2>/dev/null | \
    while read -r file event; do
        local filename
        filename=$(basename "$file")
        
        log_debug "Evento detectado: $event en $filename"
        
        # Filtrar eventos relevantes
        if [[ "$filename" == "HEAD" || "$filename" == "COMMIT_EDITMSG" || "$file" =~ refs/heads/ || "$filename" == "packed-refs" ]]; then
            log_debug "Cambio detectado en: $file"
            
            # Pequeño delay para que Git complete operaciones
            sleep 0.5
            
            # Obtener hash del commit actual
            local current_commit
            if [[ -d "$REPO_PATH" ]]; then
                current_commit=$(cd "$REPO_PATH" && git rev-parse HEAD 2>/dev/null || echo "")
            else
                log_error "El directorio del repositorio no existe: $REPO_PATH"
                continue
            fi
            
            if [[ -z "$current_commit" ]]; then
                log_debug "No se pudo obtener hash del commit actual"
                continue
            fi
            
            # Verificar si ya procesamos este commit (debounce)
            if jq -e --arg commit "$current_commit" 'has($commit)' "$processed_file" &>/dev/null; then
                log_debug "DEBOUNCE: Commit ${current_commit:0:7} ya fue procesado"
                continue
            fi
            
            log_debug "PROCESANDO: Nuevo commit ${current_commit:0:7} detectado"
            echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') - NUEVO COMMIT: $current_commit" >> "debug_main.log"
            
            # Obtener archivos modificados
            local modified_files
            modified_files=$(get_modified_files "$REPO_PATH" "$current_commit")
            
            echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') - Archivos obtenidos: '$modified_files'" >> "debug_main.log"
            
            if [[ -z "$modified_files" ]]; then
                log_debug "No se encontraron archivos modificados en el commit"
                echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') - NO HAY ARCHIVOS MODIFICADOS" >> "debug_main.log"
                continue
            fi
            
            log_debug "Archivos modificados: $(echo "$modified_files" | wc -l)"
            echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') - Cantidad de archivos: $(echo "$modified_files" | wc -l)" >> "debug_main.log"
            
            # Escanear cada archivo modificado
            # Escanear cada archivo modificado
            while IFS= read -r file; do
                [[ -z "$file" ]] && continue
                local full_path="$REPO_PATH/$file"
                log_debug "Escaneando archivo: $file"

                # DEBUG especial para prueba.txt
                if [[ "$(basename "$full_path")" == "prueba.txt" ]]; then
                    local line_no=1
                    while IFS= read -r line || [[ -n "$line" ]]; do
                        echo "[TRACE] prueba.txt:$line_no: ${line@Q}" >> debug_scan.log
                        ((line_no++))
                    done < <(sed -e 's/\r$//' -- "$full_path")
                fi

                scan_file_patterns "$full_path" "$config_file"
            done <<< "$modified_files"

            # ✅ Marcar commit como procesado SOLO después de escanear todo
            local timestamp
            timestamp=$(date '+%Y-%m-%d %H:%M:%S')
            jq --arg commit "$current_commit" --arg time "$timestamp" \
               '. + {($commit): $time}' "$processed_file" > "${processed_file}.tmp"
            mv "${processed_file}.tmp" "$processed_file"
        fi
    done
}


# Función de limpieza al salir
cleanup_and_exit() {
    log_info "Señal de terminación recibida. Ejecutando limpieza..."
    
    # Matar procesos inotifywait relacionados antes de limpiar archivos
    local inotify_pids
    inotify_pids=$(pgrep -f "inotifywait.*\.git" 2>/dev/null || true)
    
    if [[ -n "$inotify_pids" ]]; then
        log_info "Matando procesos inotifywait: $inotify_pids"
        echo "$inotify_pids" | xargs -r kill -9 2>/dev/null || true
    fi
    
    # Búsqueda adicional por procesos inotifywait
    local more_inotify_pids
    more_inotify_pids=$(ps aux | grep inotifywait | grep -v grep | awk '{print $2}' 2>/dev/null || true)
    
    if [[ -n "$more_inotify_pids" ]]; then
        log_info "Matando TODOS los procesos inotifywait: $more_inotify_pids"
        echo "$more_inotify_pids" | xargs -r kill -9 2>/dev/null || true
    fi
    
    # Limpiar archivos temporales del proceso actual
    rm -f "$TEMP_DIR/${CONFIG_PREFIX}-$$.json"
    rm -f "$TEMP_DIR/${PROCESSED_PREFIX}-$$.json"
    
    local pid_file
    pid_file=$(get_pid_file)
    rm -f "$pid_file"
    
    log_info "Demonio detenido."
    exit 0
}

# Función para normalizar rutas: siempre devolver absoluta
to_abs_path() {
    local input_path="$1"

    # Si la ruta ya es absoluta, devolver tal cual
    if [[ "$input_path" =~ ^/ ]]; then
        echo "$input_path"
        return
    fi

    # Si es relativa, expandirla a absoluta
    echo "$(cd "$(dirname "$input_path")" && pwd)/$(basename "$input_path")"
}

# Función para verificar dependencias
check_dependencies() {
    local -a missing_deps=()
    
    # Verificar herramientas básicas
    for cmd in git inotifywait jq; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Dependencias faltantes: ${missing_deps[*]}"
        log_error "En Ubuntu/Debian: sudo apt install inotify-tools jq"
        log_error "En CentOS/RHEL: sudo yum install inotify-tools jq"
        exit 1
    fi
}

# Función para validar parámetros
validate_params() {
    # Validar repositorio
    if [[ ! -d "$REPO_PATH" ]]; then
        log_error "El directorio '$REPO_PATH' no existe"
        exit 1
    fi
    
    if [[ ! -d "$REPO_PATH/.git" ]]; then
        log_error "El directorio '$REPO_PATH' no es un repositorio Git válido"
        exit 1
    fi
    
    # Validar archivo de configuración (solo si no es kill)
    if [[ "$ACTION" != "kill" ]]; then
        if [[ ! -f "$CONFIG_PATH" ]]; then
            log_error "El archivo de configuración '$CONFIG_PATH' no existe"
            exit 1
        fi
        
        # Verificar que tenga al menos un patrón válido
        local valid_patterns
        valid_patterns=$(grep -v '^#' "$CONFIG_PATH" | grep -vc '^[[:space:]]*$')
        if [[ $valid_patterns -eq 0 ]]; then
            log_error "El archivo de configuración '$CONFIG_PATH' no contiene patrones válidos"
            exit 1
        fi
        
        # Validar directorio del log
        local log_dir
        log_dir=$(dirname "$LOG_PATH")
        if [[ ! -d "$log_dir" ]]; then
            log_error "El directorio padre del log '$log_dir' no existe"
            exit 1
        fi
    fi
}

# Función para obtener ruta del archivo PID
get_pid_file() {
    local repo_hash
    repo_hash=$(echo "$REPO_PATH" | tr '/' '_' | tr -d ':')
    echo "$TEMP_DIR/${DAEMON_PREFIX}-${repo_hash}.pid"
}

# Función para verificar si hay un demonio corriendo
is_daemon_running() {
    local pid_file
    pid_file=$(get_pid_file)
    
    if [[ ! -f "$pid_file" ]]; then
        return 1
    fi
    
    local pid
    pid=$(cat "$pid_file" 2>/dev/null || echo "")
    if [[ -z "$pid" ]]; then
        rm -f "$pid_file"
        return 1
    fi
    
    if kill -0 "$pid" 2>/dev/null; then
        return 0
    else
        rm -f "$pid_file"
        return 1
    fi
}

# Función principal
main() {
    local repo_path="" config_path="" log_path="" action="start"
    
    # Parsear argumentos
    while [[ $# -gt 0 ]]; do
        case $1 in
            -repo)
                repo_path="$2"
                shift 2
                ;;
            -configuracion)
                config_path="$2"
                shift 2
                ;;
            -log)
                log_path="$2"
                shift 2
                ;;
            -kill)
                action="kill"
                shift
                ;;
            -verbose)
                VERBOSE=1
                shift
                ;;
            -help)
                show_help
                exit 0
                ;;
            *)
                log_error "Parámetro desconocido: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Verificar parámetros requeridos
    if [[ -z "$repo_path" ]]; then
        log_error "El parámetro -repo es obligatorio"
        show_help
        exit 1
    fi

    if [[ "$action" == "kill" && ( -n "$config_path" || -n "$log_path" ) ]]; then
        log_error "Si usa -kill, solo puede combinarlo con -repo (no con -configuracion ni -log)"
        exit 1
    fi
        
    
  # Normalizar rutas: siempre absolutas
    repo_path=$(to_abs_path "$repo_path")
    if [[ -n "$config_path" ]]; then
        config_path=$(to_abs_path "$config_path")
    fi
    if [[ -n "$log_path" ]]; then
        log_path=$(to_abs_path "$log_path")
    fi
    
    log_debug "Rutas normalizadas:"
    log_debug "  Repositorio: $repo_path"
    log_debug "  Configuración: $config_path"
    log_debug "  Log: $log_path"
    
    # Exportar variables globales
    export REPO_PATH="$repo_path"
    export CONFIG_PATH="$config_path"
    export LOG_PATH="$log_path"
    export ACTION="$action"
    
    # Verificar dependencias
    check_dependencies
    
    # Validar parámetros
    validate_params
    
    case "$action" in
        "kill")
            stop_daemon
            ;;
        "start")
            if [[ -z "$config_path" || -z "$log_path" ]]; then
                log_error "Los parámetros -configuracion y -log son obligatorios para iniciar el demonio"
                show_help
                exit 1
            fi
            
            if is_daemon_running; then
                log_error "Ya existe un demonio activo para el repositorio '$repo_path'"
                log_error "Use --kill o -k para detenerlo primero"
                exit 1
            fi
            
            # Ejecutar demonio en segundo plano
            if [[ "${DAEMON_MODE:-0}" -eq 1 ]]; then
                # Modo demonio directo
                start_daemon
            else
                # Lanzar en background
                log_info "Iniciando Git Security Monitor en segundo plano para repositorio."
                

                #CAMBIARRRRR
                DAEMON_MODE=1 "$0" -repo "$repo_path" -configuracion "$config_path" -log "$log_path" ${VERBOSE:+-verbose} &
                local daemon_pid=$!
                
                # Verificar que se inició correctamente
                sleep 2
                if kill -0 "$daemon_pid" 2>/dev/null; then
                    log_info "Git Security Monitor iniciado con PID: $daemon_pid"
                    log_info "Use -kill para detener el demonio"
                else
                    log_error "Error al iniciar el demonio"
                    exit 1
                fi
            fi
            ;;
    esac
}

# Ejecutar función principal solo si el script se ejecuta directamente
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
