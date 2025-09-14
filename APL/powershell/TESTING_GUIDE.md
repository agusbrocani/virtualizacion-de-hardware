# 🧪 Guía de Pruebas - Demonio de Seguridad Git

Esta guía te mostrará cómo probar el sistema de monitoreo de seguridad paso a paso.

## 📋 Requisitos Previos

- PowerShell 7+ instalado
- Repositorio Git válido
- Archivo de configuración `resources/patrones.conf`

## 🚀 Paso 1: Verificar el Sistema

### Verificar que el script funciona
```powershell
Get-Help .\ejercicio4.ps1 -Examples
```

### Verificar el archivo de patrones
```powershell
Get-Content .\resources\patrones.conf
```

## 🔧 Paso 2: Iniciar el Demonio

### Comando para iniciar el monitoreo
```powershell
.\ejercicio4.ps1 -repo "C:\Users\Juan\Desktop\stats\virtualizacion-de-hardware" -configuracion ".\resources\patrones.conf" -log ".\security.log"
```

**Resultado esperado:**
```
Iniciando Git Security Monitor en segundo plano para repositorio: C:\Users\Juan\Desktop\stats\virtualizacion-de-hardware
Git Security Monitor iniciado con PID: 12345
Archivo PID: C:\Users\Juan\AppData\Local\Temp\git-security-daemon-c_users_juan_desktop_stats_virtualizacion-de-hardware.pid
Use -kill para detener el demonio.
Proceso confirmado activo después de 2 segundos
```

## ⚠️ Paso 3: Crear Contenido Sospechoso para Pruebas

### 3.1 Crear archivo con credenciales simples
```powershell
# Crear archivo de prueba con password
@"
# Configuración de la aplicación
database_host = localhost
database_user = admin
password = mi_password_secreto_123
api_key = sk_test_123456789
"@ | Out-File -FilePath "test_secrets.txt" -Encoding UTF8
```

### 3.2 Crear archivo con patrones regex
```powershell
# Crear archivo con token JWT simulado
@"
# Variables de entorno
export JWT_TOKEN="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.ejemplo"
export AWS_ACCESS_KEY="AKIAIOSFODNN7EXAMPLE"
secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
"@ | Out-File -FilePath "config_tokens.env" -Encoding UTF8
```

### 3.3 Agregar al repositorio y hacer commit
```powershell
# Agregar archivos al staging
git add test_secrets.txt config_tokens.env

# Hacer commit (esto debería activar el demonio)
git commit -m "test: Agregando archivos con credenciales para prueba"
```

## 🚨 Paso 4: Observar las Alertas

### 4.1 Verificar el archivo de log
```powershell
# Ver las alertas generadas
Get-Content .\security.log
```

**Ejemplo de salida esperada:**
```
[2025-09-14 15:30:45] Alerta: patrón 'password' encontrado en el archivo 'test_secrets.txt' (línea 3) [Tipo: Simple]
[2025-09-14 15:30:45] Alerta: patrón 'api_key' encontrado en el archivo 'test_secrets.txt' (línea 4) [Tipo: Simple]
[2025-09-14 15:30:45] Alerta: patrón 'secret_key' encontrado en el archivo 'config_tokens.env' (línea 3) [Tipo: Simple]
```

### 4.2 Monitorear en tiempo real
```powershell
# Ver log en tiempo real (requiere demonio activo)
Get-Content .\security.log -Wait
```

## 🔍 Paso 5: Verificar el Estado del Demonio

### 5.1 Verificar que el demonio está corriendo
```powershell
# Buscar archivos PID
Get-ChildItem $env:TEMP | Where-Object {$_.Name -like "*git-security-daemon*"}
```

### 5.2 Ver procesos de PowerShell activos
```powershell
Get-Process | Where-Object {$_.ProcessName -eq "pwsh"} | Format-Table Id, ProcessName, StartTime
```

## 🛑 Paso 6: Detener el Demonio

### Comando para detener
```powershell
.\ejercicio4.ps1 -repo "C:\Users\Juan\Desktop\stats\virtualizacion-de-hardware" -kill
```

**Resultado esperado:**
```
Demonio detenido para repositorio: C:\Users\Juan\Desktop\stats\virtualizacion-de-hardware
```

## 🧹 Paso 7: Limpiar Archivos de Prueba

```powershell
# Eliminar archivos de prueba
Remove-Item test_secrets.txt, config_tokens.env -Force

# Hacer commit de limpieza
git add -A
git commit -m "cleanup: Eliminando archivos de prueba de seguridad"

# Opcional: eliminar archivo de log
Remove-Item .\security.log -Force
```

## 🎯 Casos de Prueba Avanzados

### Test 1: Archivo con múltiples patrones
```powershell
@"
#!/bin/bash
# Script de configuración
export DATABASE_PASSWORD="super_secret_pass"
export API_TOKEN="sk_live_abcdef123456"
export PRIVATE_KEY="-----BEGIN RSA PRIVATE KEY-----"
export AUTH_SECRET="mysecretauthkey2023"
"@ | Out-File -FilePath "advanced_test.sh" -Encoding UTF8

git add advanced_test.sh
git commit -m "test: Script con múltiples credenciales"
```

### Test 2: Archivo que NO debería generar alertas
```powershell
@"
# Documentación del proyecto
Este proyecto usa autenticación basada en tokens.
Para configurar:
1. Generar un token de API
2. Configurar las variables de entorno
3. Reiniciar el servicio

# Nota: No incluir passwords reales en el código
"@ | Out-File -FilePath "documentation.md" -Encoding UTF8

git add documentation.md
git commit -m "docs: Agregando documentación"
```

## 🚨 Qué Esperar del Sistema

### ✅ El sistema detectará y alertará sobre:
- Palabras clave: `password`, `secret`, `token`, `api_key`, etc.
- Patrones regex: tokens JWT, claves AWS, etc.
- Cualquier patrón configurado en `resources/patrones.conf`

### ✅ Comportamiento normal:
- **Detección inmediata**: Alertas aparecen segundos después del commit
- **Log persistente**: Todas las alertas se guardan con timestamp
- **Sin falsos positivos**: Solo archivos de texto son escaneados
- **Background execution**: Terminal libre después de iniciar

### ❌ El sistema NO alertará sobre:
- Archivos binarios (`.exe`, `.dll`, `.jpg`, etc.)
- Comentarios que mencionan conceptos de seguridad sin valores reales
- Archivos que no han sido modificados

## 🔧 Resolución de Problemas

### Si no ves alertas:
1. Verificar que el demonio está corriendo
2. Confirmar que el commit se realizó correctamente
3. Revisar que el archivo contiene patrones del archivo de configuración
4. Verificar permisos de escritura en el directorio del log

### Si el demonio no inicia:
1. Verificar que la ruta del repositorio es correcta
2. Confirmar que el archivo de patrones existe
3. Verificar que el directorio padre del log existe
4. Ejecutar con `-Verbose` para más información

### Comando de debugging:
```powershell
# Ejecutar con información detallada
.\ejercicio4.ps1 -repo "ruta_del_repo" -configuracion ".\resources\patrones.conf" -log ".\security.log" -Verbose
```

## 📝 Notas Importantes

- **Un solo demonio por repositorio**: El sistema previene múltiples instancias
- **Persistencia**: El demonio continúa corriendo hasta ser detenido explícitamente
- **Post-commit**: Solo detecta archivos YA committeados, no cambios en staging
- **Real-time**: Usa FileSystemWatcher para detección inmediata de cambios
