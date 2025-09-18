# Git Security Monitor - Implementación Bash

## Descripción

Demonio de monitoreo en tiempo real para detectar credenciales y datos sensibles en repositorios Git. Esta versión en Bash utiliza `inotify` y herramientas Unix nativas para proporcionar un monitoreo eficiente y ligero.

## Características

- 🔍 **Monitoreo en tiempo real** usando `inotifywait`
- 🔒 **Detección de patrones** configurables (texto simple + regex)
- 🚫 **Sistema debounce** basado en hash de commits
- 🧹 **Limpieza automática** de archivos temporales
- 📊 **Logging estructurado** con timestamps precisos
- ⚡ **Ejecución en background** con control de PIDs
- 🛑 **Comando kill** para detener demonios activos

## Dependencias

El script requiere las siguientes herramientas:

```bash
# Ubuntu/Debian
sudo apt install inotify-tools jq git

# CentOS/RHEL
sudo yum install inotify-tools jq git

# macOS (con Homebrew)
brew install fswatch jq git
```

## Instalación

1. **Clonar el repositorio**:
   ```bash
   git clone <repo-url>
   cd virtualizacion-de-hardware/APL/bash
   ```

2. **Hacer el script ejecutable**:
   ```bash
   chmod +x ejercicio4.sh
   ```

3. **Verificar dependencias**:
   ```bash
   ./ejercicio4.sh --help
   ```

## Uso

### Sintaxis Básica

```bash
./ejercicio4.sh -repo <REPO_PATH> -configuracion <CONFIG_PATH> -log <LOG_PATH>
```

### Parámetros

- `-repo PATH`: Ruta del repositorio Git a monitorear
- `-configuracion PATH`: Archivo de configuración con patrones
- `-log PATH`: Archivo de logs para alertas
- `-kill`: Detener el demonio en ejecución
- `-verbose`: Activar modo debug detallado
- `-help`: Mostrar ayuda completa

### Ejemplos de Uso

**Iniciar el demonio**:
```bash
./ejercicio4.sh -repo "/path/to/repo" -configuracion "patrones.conf" -log "security.log"
```

**Detener el demonio**:
```bash
./ejercicio4.sh -repo "/path/to/repo" -kill
```

**Modo verbose para debugging**:
```bash
./ejercicio4.sh -repo "/path/to/repo" -configuracion "patrones.conf" -log "security.log" -verbose
```

## Archivo de Configuración

El archivo `patrones.conf` define los patrones a detectar:

```conf
# Patrones de texto simple
password
secret
api_key
private_key

# Patrones regex (prefijo 'regex:')
regex:sk_[a-zA-Z0-9]{24}
regex:[A-Za-z0-9+/]{20,}={0,2}
regex:xox[baprs]-[0-9]+-[0-9]+-[0-9]+-[a-z0-9]+
```

## Arquitectura Interna

### Monitoreo de Archivos
- Utiliza `inotifywait` para detectar cambios en `.git/`
- Filtra eventos relevantes (HEAD, refs, COMMIT_EDITMSG)
- Procesa solo archivos de texto modificados

### Sistema Debounce
- Utiliza hash de commit como clave única
- Evita procesar el mismo commit múltiples veces
- Almacena estado en archivos JSON temporales

### Gestión de Procesos
- Archivos PID para control de instancias
- Señales TERM/INT para terminación limpia
- Ejecución en background con `nohup`

## Archivos Temporales

El demonio crea archivos en `/tmp`:

- **PID Files**: `git-security-daemon-<hash>.pid`
- **Config Temp**: `git-security-config-<pid>.json`
- **Processed**: `git-security-processed-<pid>.json`

### Limpieza Automática

```bash
# El comando kill ejecuta limpieza automática
./ejercicio4.sh -repo "/path/to/repo" -kill

# Salida ejemplo:
[INFO] Ejecutando limpieza de archivos temporales...
[INFO] Archivos temporales encontrados:
  • Configuración: 1
  • Commits procesados: 1
  • Archivos PID: 1
  ✓ Eliminado: git-security-config-12345.json
  ✓ Eliminado: git-security-processed-12345.json
  ✓ Eliminado: git-security-daemon-repo_path.pid
[INFO] Limpieza completada: 3 archivos eliminados de 3 encontrados.
```

## Formato de Logs

```
[2025-09-17 22:15:30] Alerta: patrón 'password' encontrado en el archivo 'config.txt' (línea 15) [Tipo: Simple]
[2025-09-17 22:15:30] Alerta: patrón 'sk_[a-zA-Z0-9]{24}' encontrado en el archivo 'secrets.env' (línea 8) [Tipo: Regex]
```

## Solución de Problemas

### Error: Dependencias faltantes
```bash
[ERROR] Dependencias faltantes: inotifywait jq
[ERROR] En Ubuntu/Debian: sudo apt install inotify-tools jq
```
**Solución**: Instalar las dependencias indicadas.

### Error: No es un repositorio Git
```bash
[ERROR] El directorio '/path' no es un repositorio Git válido
```
**Solución**: Verificar que el directorio contenga `.git/`.

### Error: Demonio ya activo
```bash
[ERROR] Ya existe un demonio activo para el repositorio '/path'
[ERROR] Use -kill para detenerlo primero
```
**Solución**: Detener el demonio existente antes de iniciar uno nuevo.

## Diferencias con PowerShell

| Aspecto | Bash | PowerShell |
|---------|------|------------|
| Monitoreo | `inotifywait` | `FileSystemWatcher` |
| JSON | `jq` | Nativo |
| Background | `nohup` | `Start-Process -WindowStyle Hidden` |
| Plataforma | Linux/Unix/macOS | Windows |

## Limitaciones

- **Linux/Unix solamente**: Requiere `inotify` (no disponible en Windows nativo)
- **Dependencias externas**: Necesita `inotify-tools` y `jq`
- **Permisos de directorio**: Requiere acceso de lectura a `/tmp`

## Rendimiento

- **CPU**: Muy bajo (herramientas nativas optimizadas)
- **Memoria**: Mínima (~5-10MB por demonio)
- **I/O**: Eficiente (inotify a nivel kernel)

## Contribuir

1. Fork del repositorio
2. Crear rama de feature: `git checkout -b feature/nueva-funcionalidad`
3. Commit cambios: `git commit -am 'Agregar nueva funcionalidad'`
4. Push a la rama: `git push origin feature/nueva-funcionalidad`
5. Crear Pull Request

## Licencia

Ver archivo LICENSE en el directorio raíz del proyecto.