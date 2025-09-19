# Comparación: Git Security Monitor PowerShell vs Bash

## Resumen Ejecutivo

Se han implementado dos versiones del **Git Security Monitor**: una en PowerShell y otra en Bash. Ambas versiones mantienen la funcionalidad core del demonio de monitoreo, pero utilizan diferentes enfoques tecnológicos según las capacidades de cada plataforma.

## Características Comunes

### Funcionalidad Core
- ✅ **Monitoreo en tiempo real** de repositorios Git
- ✅ **Detección de patrones** de credenciales y datos sensibles  
- ✅ **Debounce basado en commit hash** para evitar duplicados
- ✅ **Limpieza comprehensiva** de archivos temporales
- ✅ **Gestión de PIDs** para control de procesos demonio
- ✅ **Logging estructurado** con timestamps y líneas precisas
- ✅ **Comando kill** para detener demonios activos
- ✅ **Interfaz de parámetros idéntica** (-repo, -configuracion, -log, -kill)

### Arquitectura Compartida
- **Patrones configurables**: Soporte para texto simple y regex
- **Archivos temporales JSON**: Configuración y estado del demonio
- **Control de instancias únicas**: Un demonio por repositorio
- **Filtrado inteligente**: Solo archivos de texto relevantes
- **Parámetros consistentes**: Misma sintaxis de comandos

## Diferencias Técnicas

| Aspecto | PowerShell | Bash |
|---------|------------|------|
| **Monitoreo de archivos** | `FileSystemWatcher` (.NET) | `inotifywait` (inotify-tools) |
| **Procesamiento JSON** | `ConvertTo-Json` / `ConvertFrom-Json` | `jq` |
| **Gestión de procesos** | `Start-Process -WindowStyle Hidden` | `nohup` + background jobs |
| **Manejo de colores** | `Write-Host -ForegroundColor` | Códigos ANSI escape |
| **Dependencias** | PowerShell 7+ | bash, git, inotify-tools, jq |

## Implementación PowerShell

### Ventajas
- **Integración nativa con Windows**: FileSystemWatcher es robusto y eficiente
- **Gestión avanzada de procesos**: Control fino sobre ventanas y procesos hijo
- **JSON nativo**: Manejo integrado sin dependencias externas
- **Debugging robusto**: Variables de scope y logging detallado

### Código Destacado
```powershell
# Modo invisible para demonios
Start-Process powershell -ArgumentList $startArgs -WindowStyle Hidden

# Monitoreo nativo de archivos
$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $gitPath
$watcher.IncludeSubdirectories = $true

# Debounce basado en commit
$commitHash = (git rev-parse HEAD 2>$null)
if ($processedCommits.ContainsKey($commitHash)) { return }
```

### Archivos de Salida
- **PID Files**: `$env:TEMP\git-security-daemon-*.pid`
- **Config Temp**: `$env:TEMP\git-security-config-*.json`
- **Processed**: `$env:TEMP\git-security-processed-*.json`

## Implementación Bash

### Ventajas  
- **Portabilidad multiplataforma**: Funciona en Linux, macOS, WSL
- **Herramientas especializadas**: `inotifywait` optimizado para monitoreo
- **Sintaxis simplificada**: Código más legible y mantenible
- **Gestión nativa de procesos Unix**: Señales y control de trabajos

### Código Destacado
```bash
# Monitoreo con inotify
inotifywait -m -r -e modify,create,move "$git_path" --format '%w%f %e' | \
while read -r file event; do
    # Procesamiento de eventos
done

# Debounce con jq
if jq -e --arg commit "$current_commit" 'has($commit)' "$processed_file" &>/dev/null; then
    continue
fi

# Background daemon con nohup
DAEMON_MODE=1 nohup "$0" --repo "$repo_path" --config "$config_path" --log "$log_path" >/dev/null 2>&1 &
```

### Archivos de Salida
- **PID Files**: `/tmp/git-security-daemon-*.pid`
- **Config Temp**: `/tmp/git-security-config-*.json`  
- **Processed**: `/tmp/git-security-processed-*.json`

## Rendimiento y Eficiencia

### PowerShell
- **CPU**: Medio (FileSystemWatcher eficiente, pero .NET overhead)
- **Memoria**: Media-Alta (PowerShell + .NET runtime)
- **I/O**: Muy eficiente (FileSystemWatcher optimizado)

### Bash
- **CPU**: Bajo (herramientas nativas optimizadas)
- **Memoria**: Baja (procesos ligeros)
- **I/O**: Muy eficiente (inotify kernel-level)

## Casos de Uso Recomendados

### PowerShell - Ideal para:
```powershell
# Sintaxis idéntica en ambas versiones
.\ejercicio4.ps1 -repo "C:\mi-proyecto" -configuracion ".\patrones.conf" -log ".\security.log"
.\ejercicio4.ps1 -repo "C:\mi-proyecto" -kill
```

### Bash - Ideal para:
```bash
# Sintaxis idéntica en ambas versiones  
./ejercicio4.sh -repo "/path/to/repo" -configuracion "./patrones.conf" -log "./security.log"
./ejercicio4.sh -repo "/path/to/repo" -kill
```

## Casos de Uso Recomendados

### PowerShell - Ideal para:
- ✅ **Entornos Windows corporativos**
- ✅ **Integración con Azure DevOps/TFS**
- ✅ **Equipos familiarizados con .NET**
- ✅ **Necesidad de interfaz gráfica ocasional**

### Bash - Ideal para:
- ✅ **Servidores Linux/Unix**
- ✅ **Pipelines CI/CD en contenedores**
- ✅ **Entornos embebidos o con recursos limitados**
- ✅ **Equipos DevOps con herramientas Unix**

## Instalación y Dependencias

### PowerShell
```powershell
# Verificar versión
$PSVersionTable.PSVersion  # Requiere 7.0+

# No requiere instalaciones adicionales en Windows
```

### Bash
```bash
# Ubuntu/Debian
sudo apt install inotify-tools jq

# CentOS/RHEL  
sudo yum install inotify-tools jq

# macOS (con Homebrew)
brew install fswatch jq
```

## Conclusiones

Ambas implementaciones son **funcionalmente equivalentes** y mantienen los mismos patrones de detección, algoritmos de debounce, y características de limpieza. La elección entre PowerShell y Bash debe basarse en:

1. **Plataforma objetivo** (Windows vs Linux/Unix)
2. **Recursos disponibles** (memoria, CPU)
3. **Experiencia del equipo** (PowerShell vs Bash)
4. **Infraestructura existente** (Azure vs AWS/GCP)

**Recomendación**: Usar **PowerShell** en entornos Windows corporativos y **Bash** en servidores Linux o pipelines CI/CD containerizados.