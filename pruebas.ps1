#Requires -RunAsAdministrator

# ============================================================
# VARIABLES GLOBALES
# ============================================================
$Global:ServidorIP = "192.168.32.3"
$Global:HomesShare = "Homes"

# ============================================================
# FUNCION: Mount-UnidadHomes
# Monta la unidad H: apuntando al home del usuario dado
# ============================================================
function Mount-UnidadHomes {
    param(
        [Parameter(Mandatory)][string]$Usuario
    )

    $ruta = "\\$Global:ServidorIP\$Global:HomesShare\$Usuario"
    Write-Host "[+] Montando H: -> $ruta" -ForegroundColor Cyan

    net use H: $ruta /persistent:yes 2>&1 | Out-Null

    $drive = Get-PSDrive H -ErrorAction SilentlyContinue
    if ($drive) {
        Write-Host "    H: montado correctamente en $ruta" -ForegroundColor Green
    } else {
        Write-Host "    ERROR: No se pudo montar H:" -ForegroundColor Red
        return $false
    }
    return $true
}

# ============================================================
# FUNCION: Dismount-UnidadHomes
# Desmonta la unidad H: si esta montada
# ============================================================
function Dismount-UnidadHomes {
    Write-Host "[+] Desmontando H:..." -ForegroundColor Cyan
    net use H: /delete /yes 2>&1 | Out-Null
    Write-Host "    H: desmontada" -ForegroundColor Green
}

# ============================================================
# FUNCION: Test-CuotaFSRM
# Intenta escribir un archivo del tamano dado en H:
# Segun la cuota del usuario deberia bloquearse si supera el limite
# smendez: limite 5MB -> probar con 6MB
# cramirez: limite 10MB -> probar con 11MB
# ============================================================
function Test-CuotaFSRM {
    param(
        [Parameter(Mandatory)][string]$Usuario,
        [Parameter(Mandatory)][int]   $TamanoMB
    )

    $archivo = "H:\prueba_${TamanoMB}mb.dat"
    Write-Host "[+] Probando cuota FSRM: $TamanoMB MB en H: (usuario: $Usuario)" -ForegroundColor Cyan

    try {
        $buf = New-Object byte[] ($TamanoMB * 1024 * 1024)
        [System.IO.File]::WriteAllBytes($archivo, $buf)
        Write-Host "    RESULTADO: Archivo escrito (cuota NO bloqueo - revisar configuracion)" -ForegroundColor Yellow
    } catch {
        Write-Host "    RESULTADO: BLOQUEADO por cuota FSRM (correcto)" -ForegroundColor Green
        Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}

# ============================================================
# FUNCION: Test-FileScreening
# Intenta copiar un archivo con extension prohibida a H:
# Extensiones bloqueadas: *.mp3 *.mp4 *.exe *.msi
# ============================================================
function Test-FileScreening {
    param(
        [Parameter(Mandatory)][string]$ExtensionProhibida
    )

    # Usamos notepad.exe como archivo fuente de prueba
    $origen  = "C:\Windows\System32\notepad.exe"
    $destino = "H:\prueba_filescreen.$ExtensionProhibida"

    Write-Host "[+] Probando File Screening: copiando archivo como .$ExtensionProhibida" -ForegroundColor Cyan

    try {
        Copy-Item $origen $destino -ErrorAction Stop
        Write-Host "    RESULTADO: Archivo copiado (file screening NO bloqueo - revisar configuracion)" -ForegroundColor Yellow
    } catch {
        Write-Host "    RESULTADO: BLOQUEADO por File Screening FSRM (correcto)" -ForegroundColor Green
        Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}

# ============================================================
# FUNCION: Test-AppLocker
# Intenta abrir notepad y reporta si fue bloqueado o no
# NoCuates: debe bloquearse | Cuates: debe abrirse
# ============================================================
function Test-AppLocker {
    param(
        [Parameter(Mandatory)][string]$Usuario
    )

    $notepad = "$env:SystemRoot\System32\notepad.exe"
    Write-Host "[+] Probando AppLocker con usuario: $Usuario" -ForegroundColor Cyan
    Write-Host "    Intentando abrir notepad..." -ForegroundColor Gray

    try {
        $proc = Start-Process $notepad -PassThru -ErrorAction Stop
        Start-Sleep -Seconds 2
        if (-not $proc.HasExited) {
            Write-Host "    RESULTADO: notepad ABIERTO (esperado para GrupoCuates)" -ForegroundColor Green
            $proc.Kill()
        } else {
            Write-Host "    RESULTADO: notepad BLOQUEADO (proceso termino de inmediato)" -ForegroundColor Red
        }
    } catch {
        Write-Host "    RESULTADO: BLOQUEADO por AppLocker (correcto para GrupoNoCuates)" -ForegroundColor Green
        Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}

# ============================================================
# FUNCION: Show-EstadoUnidadH
# Muestra informacion de la unidad H: si esta montada
# ============================================================
function Show-EstadoUnidadH {
    Write-Host "[+] Estado de la unidad H:" -ForegroundColor Cyan
    $drive = Get-PSDrive H -ErrorAction SilentlyContinue
    if ($drive) {
        Write-Host "    Montada: $($drive.Root)" -ForegroundColor Green
        Get-PSDrive H | Select-Object Name, Root, Used, Free | Format-Table -AutoSize
    } else {
        Write-Host "    H: no esta montada" -ForegroundColor Yellow
    }
}

# ============================================================
# FUNCION: Invoke-PruebaCompleta
# Orquesta todas las pruebas para un usuario dado
# ============================================================
function Invoke-PruebaCompleta {
    param(
        [Parameter(Mandatory)][string]$Usuario,
        [Parameter(Mandatory)][int]   $TamanoMB
    )

    Write-Host "`n===== PRUEBA COMPLETA: $Usuario =====" -ForegroundColor Magenta

    if (-not (Mount-UnidadHomes -Usuario $Usuario)) { return }
    Show-EstadoUnidadH
    Test-CuotaFSRM      -Usuario $Usuario -TamanoMB $TamanoMB
    Test-FileScreening  -ExtensionProhibida "mp3"
    Dismount-UnidadHomes

    Write-Host "`nPrueba completa para $Usuario terminada." -ForegroundColor Cyan
}

# ============================================================
# MENU INTERACTIVO
# ============================================================
function Show-Menu {
    Clear-Host
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "   TAREA 08 - PRUEBAS - MENU PRINCIPAL" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1]  Prueba completa: smendez  (cuota 5MB, FileScreen, AppLocker)" -ForegroundColor White
    Write-Host "  [2]  Prueba completa: cramirez (cuota 10MB, FileScreen, AppLocker)" -ForegroundColor White
    Write-Host "  -----------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  [3]  Solo: Montar H: (pide usuario)" -ForegroundColor Gray
    Write-Host "  [4]  Solo: Desmontar H:" -ForegroundColor Gray
    Write-Host "  [5]  Solo: Ver estado de H:" -ForegroundColor Gray
    Write-Host "  [6]  Solo: Probar cuota FSRM (pide usuario y MB)" -ForegroundColor Gray
    Write-Host "  [7]  Solo: Probar File Screening .mp3" -ForegroundColor Gray
    Write-Host "  [8]  Solo: Probar File Screening .mp4" -ForegroundColor Gray
    Write-Host "  [9]  Solo: Probar AppLocker (pide usuario)" -ForegroundColor Gray
    Write-Host "  -----------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  [0]  Salir" -ForegroundColor Red
    Write-Host ""
}

do {
    Show-Menu
    $opcion = Read-Host "  Selecciona una opcion"

    switch ($opcion) {
        "1" {
            Write-Host "`n>> Prueba completa smendez (limite: 5MB)..." -ForegroundColor Cyan
            Invoke-PruebaCompleta -Usuario "smendez" -TamanoMB 6
        }
        "2" {
            Write-Host "`n>> Prueba completa cramirez (limite: 10MB)..." -ForegroundColor Cyan
            Invoke-PruebaCompleta -Usuario "cramirez" -TamanoMB 11
        }
        "3" {
            $usr = Read-Host "   Ingresa el nombre de usuario"
            Mount-UnidadHomes -Usuario $usr
        }
        "4" {
            Dismount-UnidadHomes
        }
        "5" {
            Show-EstadoUnidadH
        }
        "6" {
            $usr = Read-Host "   Ingresa el nombre de usuario"
            $mb  = [int](Read-Host "   Tamano en MB a escribir")
            Test-CuotaFSRM -Usuario $usr -TamanoMB $mb
        }
        "7" {
            Test-FileScreening -ExtensionProhibida "mp3"
        }
        "8" {
            Test-FileScreening -ExtensionProhibida "mp4"
        }
        "9" {
            $usr = Read-Host "   Ingresa el nombre de usuario logueado actualmente"
            Test-AppLocker -Usuario $usr
        }
        "0" {
            Write-Host "`nSaliendo..." -ForegroundColor Red
            break
        }
        default {
            Write-Host "`nOpcion no valida." -ForegroundColor Red
        }
    }

    if ($opcion -ne "0") {
        Write-Host "`nPresiona ENTER para volver al menu..." -ForegroundColor DarkGray
        Read-Host | Out-Null
    }

} while ($opcion -ne "0")
