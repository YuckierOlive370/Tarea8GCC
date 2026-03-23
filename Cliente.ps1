#Requires -RunAsAdministrator
<#
TAREA 08 - Cliente Windows 10 FINAL
Ejecutar como Administrador local en el cliente Windows 10

PASOS:
1. Ejecutar SECCION 1 - Union al dominio (reinicia el equipo)
2. Despues del reinicio ejecutar SECCION 2 - AppLocker
#>

# ============================================================
# SECCION 1 - UNION AL DOMINIO (ejecutar primero) despues de estas seccion se reinicia
# ============================================================

Write-Host "Interfaces de red:" -ForegroundColor Cyan
Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.IPAddress -notlike "127.*"} |
    Select-Object IPAddress, InterfaceAlias | Format-Table

# Detectar automaticamente la interfaz en red 192.168.32.x
$iface = Get-NetAdapter | Where-Object {$_.Status -eq "Up"} | ForEach-Object {
    $ip = Get-NetIPAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($ip -and $ip.IPAddress -like "192.168.32.*") { $_ }
} | Select-Object -First 1

if (-not $iface) {
    $iface = Get-NetAdapter | Where-Object {$_.Status -eq "Up"} | Select-Object -First 1
}
Write-Host "Interfaz detectada: $($iface.Name)" -ForegroundColor Green

Set-DnsClientServerAddress -InterfaceIndex $iface.InterfaceIndex -ServerAddresses "192.168.32.3"
Write-Host "DNS -> 192.168.32.3" -ForegroundColor Green

Start-Sleep -Seconds 2
$resolve = Resolve-DnsName -Name "dominio.local" -Server "192.168.32.3" -ErrorAction SilentlyContinue
if ($resolve) {
    Write-Host "Dominio resuelto: OK" -ForegroundColor Green
} else {
    Write-Host "ERROR: No resuelve dominio.local" -ForegroundColor Red
    exit 1
}

$cred = New-Object System.Management.Automation.PSCredential(
    "DOMINIO\Administrator",
    (ConvertTo-SecureString "Admin@12345!" -AsPlainText -Force)
)
Add-Computer -DomainName "dominio.local" -Credential $cred -Force -ErrorAction Stop
Write-Host "Unido al dominio. Reiniciando..." -ForegroundColor Green
Start-Sleep -Seconds 3
Restart-Computer -Force

# ============================================================
# SECCION 2 - APPLOCKER DIFERENCIADO POR GRUPO
# Ejecutar como Administrator DESPUES del reinicio
#
# LOGICA:
# - GrupoCuates   (Grupo 1): PERMITE notepad
# - GrupoNoCuates (Grupo 2): BLOQUEA notepad por HASH
#   Bloquea aunque el usuario renombre el ejecutable
# ============================================================

$dominioActual = (Get-WmiObject Win32_ComputerSystem).Domain
Write-Host "Dominio: $dominioActual" -ForegroundColor Cyan

gpupdate /force
Set-Service AppIDSvc -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service AppIDSvc -ErrorAction SilentlyContinue
Write-Host "AppIDSvc: $((Get-Service AppIDSvc).Status)" -ForegroundColor Cyan

# Hashes de AMBAS versiones de notepad en este cliente
$notepad1 = "$env:SystemRoot\System32\notepad.exe"
$notepad2 = "$env:SystemRoot\SysWOW64\notepad.exe"
$hash1 = (Get-AppLockerFileInformation -Path $notepad1).Hash.HashDataString
$len1  = (Get-Item $notepad1).Length
$hash2 = (Get-AppLockerFileInformation -Path $notepad2).Hash.HashDataString
$len2  = (Get-Item $notepad2).Length
Write-Host "Hash System32:  $hash1" -ForegroundColor Cyan
Write-Host "Hash SysWOW64:  $hash2" -ForegroundColor Cyan

# SID real del grupo NoCuates del dominio
Import-Module ActiveDirectory
$sidNoCuates = "S-1-5-21-2205334512-381440921-4159792505-1604"
$sidAdmins   = "S-1-5-32-544"
Write-Host "SID GrupoNoCuates: $sidNoCuates" -ForegroundColor Cyan

# Politica AppLocker diferenciada por grupo
$xml = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FileHashRule Id="b2e2d5b5-1a2b-4c3d-8e4f-5a6b7c8d9e0f"
                  Name="BLOQUEAR Notepad System32 - NoCuates"
                  Description="Bloquea notepad.exe System32 por hash para NoCuates aunque sea renombrado"
                  UserOrGroupSid="$sidNoCuates" Action="Deny">
      <Conditions><FileHashCondition>
        <FileHash Type="SHA256" Data="$hash1" SourceFileName="notepad.exe" SourceFileLength="$len1" />
      </FileHashCondition></Conditions>
    </FileHashRule>
    <FileHashRule Id="c5d6e7f8-a9b0-1234-cdef-567890abcdef"
                  Name="BLOQUEAR Notepad SysWOW64 - NoCuates"
                  Description="Bloquea notepad.exe SysWOW64 por hash para NoCuates aunque sea renombrado"
                  UserOrGroupSid="$sidNoCuates" Action="Deny">
      <Conditions><FileHashCondition>
        <FileHash Type="SHA256" Data="$hash2" SourceFileName="notepad.exe" SourceFileLength="$len2" />
      </FileHashCondition></Conditions>
    </FileHashRule>
    <FilePathRule Id="a1b2c3d4-e5f6-7890-abcd-ef1234567890"
                  Name="Permitir Windows"
                  Description="Permite ejecutables de Windows para todos incluido Cuates con notepad"
                  UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%WINDIR%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="b2c3d4e5-f6a7-8901-bcde-f12345678901"
                  Name="Permitir Program Files"
                  Description="Permite ejecutables de Program Files"
                  UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%PROGRAMFILES%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="fd686d83-a829-4351-8ff4-27c7de5755d2"
                  Name="Admins total"
                  Description="Administradores sin restriccion"
                  UserOrGroupSid="$sidAdmins" Action="Allow">
      <Conditions><FilePathCondition Path="*" /></Conditions>
    </FilePathRule>
  </RuleCollection>
  <RuleCollection Type="Script" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Msi" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Dll" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Appx" EnforcementMode="NotConfigured" />
</AppLockerPolicy>
"@

$xml | Out-File "C:\AppLocker_Local.xml" -Encoding UTF8 -Force
Write-Host "XML guardado en C:\AppLocker_Local.xml" -ForegroundColor Green

# Limpiar politicas GPO anteriores que puedan interferir
$basePath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SrpV2"
if (Test-Path $basePath) { Remove-Item -Path $basePath -Recurse -Force }
New-Item -Path $basePath -Force | Out-Null

# Aplicar politica con Set-AppLockerPolicy (herramienta critica de la rubrica)
Set-AppLockerPolicy -XmlPolicy "C:\AppLocker_Local.xml"

Restart-Service AppIDSvc -Force
Start-Sleep -Seconds 3

Write-Host "AppLocker configurado" -ForegroundColor Green
Write-Host "`nPolitica efectiva:" -ForegroundColor Yellow
Get-AppLockerPolicy -Effective -Xml

Write-Host "`n===== RESUMEN APPLOCKER =====" -ForegroundColor Magenta
Write-Host "GrupoCuates   (Grupo 1): notepad PERMITIDO" -ForegroundColor Green
Write-Host "  -> Allow %WINDIR% incluye notepad para Cuates"
Write-Host "GrupoNoCuates (Grupo 2): notepad BLOQUEADO por hash" -ForegroundColor Red
Write-Host "  -> Deny por hash - bloquea aunque renombren el archivo"
Write-Host "  -> SID: $sidNoCuates"

Write-Host "`n===== PRUEBAS PARA LA RUBRICA =====" -ForegroundColor Magenta
Write-Host "AppLocker (30%):" -ForegroundColor Yellow
Write-Host "  smendez (NoCuates): notepad debe BLOQUEARSE"
Write-Host "  cramirez (Cuates):  notepad debe ABRIRSE"
Write-Host "Cuotas FSRM (40%):" -ForegroundColor Yellow
Write-Host "  smendez: archivo >5MB en H: debe BLOQUEARSE"
Write-Host "  cramirez: archivo >10MB en H: debe BLOQUEARSE"
Write-Host "Logon Hours (15%):" -ForegroundColor Yellow
Write-Host "  cramirez fuera de 8AM-3PM: login RECHAZADO"
Write-Host "  smendez fuera de 3PM-2AM:  login RECHAZADO"
