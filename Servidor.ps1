#Requires -RunAsAdministrator
<#
TAREA 08 - Script Servidor FINAL
Dominio: dominio.local | Homes: C:\Users\Homes

INSTRUCCIONES:
- FASE 1: Ejecutar primero (crea CSV y verifica estado)
- FASE 2: Instala AD DS y promueve a DC (REINICIA el servidor)
- FASE 3: Ejecutar despues del reinicio como DOMINIO\Administrator
#>

# ============================================================
# FASE 1 - Preparacion (ejecutar primero, sin reinicio)
# ============================================================

New-Item -ItemType Directory -Path "C:\Scripts" -Force | Out-Null

@"
Nombre,Apellido,Usuario,Password,Departamento,Email
Carlos,Ramirez,cramirez,P@ssw0rd123,Cuates,cramirez@dominio.local
Maria,Lopez,mlopez,P@ssw0rd123,Cuates,mlopez@dominio.local
Juan,Perez,jperez,P@ssw0rd123,Cuates,jperez@dominio.local
Ana,Torres,atorres,P@ssw0rd123,Cuates,atorres@dominio.local
Luis,Gomez,lgomez,P@ssw0rd123,Cuates,lgomez@dominio.local
Sofia,Mendez,smendez,P@ssw0rd123,NoCuates,smendez@dominio.local
Diego,Vargas,dvargas,P@ssw0rd123,NoCuates,dvargas@dominio.local
Elena,Castro,ecastro,P@ssw0rd123,NoCuates,ecastro@dominio.local
Pablo,Ruiz,pruiz,P@ssw0rd123,NoCuates,pruiz@dominio.local
Laura,Soto,lsoto,P@ssw0rd123,NoCuates,lsoto@dominio.local
"@ | Out-File -FilePath "C:\Scripts\usuarios.csv" -Encoding UTF8 -Force

Write-Host "CSV creado OK" -ForegroundColor Green
Import-Csv "C:\Scripts\usuarios.csv" | Format-Table

$rol = (Get-WmiObject Win32_ComputerSystem).DomainRole
Write-Host "DomainRole actual: $rol (5=DC listo)" -ForegroundColor Cyan

# ============================================================
# FASE 2 - Instalacion AD DS (EL SERVIDOR SE REINICIARA)
# Comentar esta seccion si DomainRole ya es 5
# ============================================================

net user Administrator "Admin@12345!"

Install-WindowsFeature `
    -Name AD-Domain-Services, GPMC, RSAT-AD-PowerShell, FS-Resource-Manager `
    -IncludeManagementTools
Write-Host "Features instalados" -ForegroundColor Green

Import-Module ADDSDeployment
Install-ADDSForest `
    -DomainName "dominio.local" `
    -DomainNetbiosName "DOMINIO" `
    -ForestMode "WinThreshold" `
    -DomainMode "WinThreshold" `
    -InstallDns:$true `
    -SafeModeAdministratorPassword (ConvertTo-SecureString "Admin@12345!" -AsPlainText -Force) `
    -NoRebootOnCompletion:$false `
    -Force:$true

# ============================================================
# FASE 3 - Ejecutar despues del reinicio como DOMINIO\Administrator
# ============================================================

Import-Module ActiveDirectory
Import-Module GroupPolicy
Import-Module FileServerResourceManager

$DominioDN = "DC=dominio,DC=local"
$Dominio   = "dominio.local"
$HomesBase = "C:\Users\Homes"
$usuarios  = Import-Csv "C:\Scripts\usuarios.csv"

# --- OUs y Grupos ---
foreach ($ou in @("Cuates","NoCuates")) {
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$ou'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $ou -Path $DominioDN -ProtectedFromAccidentalDeletion $false
        Write-Host "OU creada: $ou" -ForegroundColor Green
    }
}
New-ADGroup -Name "GrupoCuates"   -GroupScope Global -GroupCategory Security -Path "OU=Cuates,$DominioDN"   -Description "Grupo 1 - Cuates 8AM-3PM"   -ErrorAction SilentlyContinue
New-ADGroup -Name "GrupoNoCuates" -GroupScope Global -GroupCategory Security -Path "OU=NoCuates,$DominioDN" -Description "Grupo 2 - NoCuates 3PM-2AM" -ErrorAction SilentlyContinue
Write-Host "OUs y grupos listos" -ForegroundColor Green

# --- Homes ---
New-Item -ItemType Directory -Path $HomesBase -Force | Out-Null
if (-not (Get-SmbShare -Name "Homes" -ErrorAction SilentlyContinue)) {
    New-SmbShare -Name "Homes" -Path $HomesBase -FullAccess "DOMINIO\Domain Admins" -ChangeAccess "DOMINIO\Domain Users"
    Write-Host "Share Homes creado" -ForegroundColor Green
}

# --- Usuarios desde CSV ---
foreach ($u in $usuarios) {
    $ouPath  = if ($u.Departamento -eq "Cuates") {"OU=Cuates,$DominioDN"} else {"OU=NoCuates,$DominioDN"}
    $grupo   = if ($u.Departamento -eq "Cuates") {"GrupoCuates"} else {"GrupoNoCuates"}
    $homeDir = "$HomesBase\$($u.Usuario)"
    if (-not (Test-Path $homeDir)) { New-Item -ItemType Directory -Path $homeDir | Out-Null }
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$($u.Usuario)'" -ErrorAction SilentlyContinue)) {
        New-ADUser `
            -Name "$($u.Nombre) $($u.Apellido)" -GivenName $u.Nombre -Surname $u.Apellido `
            -SamAccountName $u.Usuario -UserPrincipalName "$($u.Usuario)@$Dominio" `
            -AccountPassword (ConvertTo-SecureString $u.Password -AsPlainText -Force) `
            -Enabled $true -Path $ouPath -HomeDirectory $homeDir -HomeDrive "H:" `
            -Department $u.Departamento
        Write-Host "Usuario creado: $($u.Usuario)" -ForegroundColor Green
    }
    Add-ADGroupMember -Identity $grupo -Members $u.Usuario -ErrorAction SilentlyContinue

    # Permisos NTFS en carpeta home
    $acl  = Get-Acl $homeDir
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "DOMINIO\$($u.Usuario)", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    $acl.AddAccessRule($rule)
    Set-Acl -Path $homeDir -AclObject $acl
}
Write-Host "Usuarios y permisos listos" -ForegroundColor Green

# --- Logon Hours via ldifde ---
# UTC-6: Cuates 8AM-3PM local = 14-20 UTC
# UTC-6: NoCuates 3PM-2AM local = 21-23 y 0-7 UTC
function Get-LogonBytes ([int[]]$horas) {
    $bytes = New-Object byte[] 21
    for ($d = 0; $d -lt 7; $d++) {
        $bits = 0
        foreach ($h in $horas) { $bits = $bits -bor (1 -shl $h) }
        $bytes[$d*3]   = $bits -band 0xFF
        $bytes[$d*3+1] = ($bits -shr 8)  -band 0xFF
        $bytes[$d*3+2] = ($bits -shr 16) -band 0xFF
    }
    return $bytes
}
$bytesCuates   = Get-LogonBytes @(14,15,16,17,18,19,20)
$bytesNoCuates = Get-LogonBytes @(21,22,23,0,1,2,3,4,5,6,7)

foreach ($u in $usuarios) {
    $bytes = if ($u.Departamento -eq "Cuates") {$bytesCuates} else {$bytesNoCuates}
    $dn    = (Get-ADUser $u.Usuario).DistinguishedName
    $ldif  = "dn: $dn`nchangetype: modify`nreplace: logonHours`nlogonHours:: $([Convert]::ToBase64String($bytes))`n-"
    $ldif | Out-File "C:\Scripts\temp_logon.ldf" -Encoding ASCII -Force
    & ldifde -i -f "C:\Scripts\temp_logon.ldf" -j "C:\Scripts" 2>&1 | Out-Null
    Write-Host "Horario OK: $($u.Usuario) ($($u.Departamento))" -ForegroundColor Green
}

# --- GPO: Forzar cierre de sesion al expirar horario ---
if (-not (Get-GPO -Name "GPO-CierreHorario" -ErrorAction SilentlyContinue)) {
    New-GPO -Name "GPO-CierreHorario" | Out-Null
    New-GPLink -Name "GPO-CierreHorario" -Target $DominioDN -LinkEnabled Yes | Out-Null
}
Set-GPRegistryValue -Name "GPO-CierreHorario" `
    -Key "HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" `
    -ValueName "EnableForcedLogOff" -Type DWord -Value 1
Write-Host "GPO-CierreHorario lista" -ForegroundColor Green

# --- FSRM Cuotas HARD ---
foreach ($t in @(
    @{Nombre="Cuota-5MB-NoCuates"; Tam=5MB},
    @{Nombre="Cuota-10MB-Cuates";  Tam=10MB}
)) {
    Remove-FsrmQuotaTemplate -Name $t.Nombre -Confirm:$false -ErrorAction SilentlyContinue
    New-FsrmQuotaTemplate -Name $t.Nombre -Size $t.Tam -SoftLimit:$false
    Write-Host "Plantilla: $($t.Nombre) $([int]($t.Tam/1MB))MB HARD" -ForegroundColor Green
}
foreach ($u in $usuarios) {
    $homeDir  = "$HomesBase\$($u.Usuario)"
    $template = if ($u.Departamento -eq "Cuates") {"Cuota-10MB-Cuates"} else {"Cuota-5MB-NoCuates"}
    $tam      = if ($u.Departamento -eq "Cuates") {10MB} else {5MB}
    Remove-FsrmQuota -Path $homeDir -Confirm:$false -ErrorAction SilentlyContinue
    New-FsrmQuota -Path $homeDir -Template $template -Size $tam -SoftLimit:$false
    Write-Host "Cuota $([int]($tam/1MB))MB: $($u.Usuario)" -ForegroundColor Green
}

# --- FSRM File Screening Activo ---
$fgName = "Archivos-Prohibidos-Tarea08"
$stName = "Screen-Multimedia-Ejecutables"
Remove-FsrmFileGroup -Name $fgName -Confirm:$false -ErrorAction SilentlyContinue
New-FsrmFileGroup -Name $fgName -IncludePattern @("*.mp3","*.mp4","*.exe","*.msi")
Remove-FsrmFileScreenTemplate -Name $stName -Confirm:$false -ErrorAction SilentlyContinue
New-FsrmFileScreenTemplate -Name $stName -Active:$true -IncludeGroup @($fgName)
foreach ($u in $usuarios) {
    $homeDir = "$HomesBase\$($u.Usuario)"
    Remove-FsrmFileScreen -Path $homeDir -Confirm:$false -ErrorAction SilentlyContinue
    New-FsrmFileScreen -Path $homeDir -Template $stName -Active:$true
    Write-Host "FileScreen: $($u.Usuario)" -ForegroundColor Green
}
Write-Host "File Screening listo" -ForegroundColor Green

# --- AppIDSvc en servidor ---
Set-Service AppIDSvc -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service AppIDSvc -ErrorAction SilentlyContinue
Write-Host "AppIDSvc iniciado" -ForegroundColor Green

# --- Verificacion final ---
Write-Host "`n===== VERIFICACION FINAL =====" -ForegroundColor Magenta

Write-Host "`nUsuarios en AD:" -ForegroundColor Yellow
Get-ADUser -Filter * -SearchBase $DominioDN -Properties Department |
    Where-Object {$_.Department -in @("Cuates","NoCuates")} |
    Select-Object SamAccountName, Department, Enabled | Format-Table -AutoSize

Write-Host "Logon Hours:" -ForegroundColor Yellow
foreach ($u in $usuarios) {
    $adU    = Get-ADUser $u.Usuario -Properties logonHours
    $estado = if ($adU.logonHours.Count -eq 21) {"OK"} else {"FALTA"}
    Write-Host "  $($u.Usuario) ($($u.Departamento)): $estado - $($adU.logonHours.Count) bytes"
}

Write-Host "`nCuotas FSRM:" -ForegroundColor Yellow
Get-FsrmQuota | Select-Object Path, @{N="MB";E={[int]($_.Size/1MB)}}, @{N="Tipo";E={if($_.SoftLimit){"SOFT"}else{"HARD"}}} | Format-Table -AutoSize

Write-Host "File Screens:" -ForegroundColor Yellow
Get-FsrmFileScreen | Select-Object Path, Active | Format-Table -AutoSize

Write-Host "GPOs activas:" -ForegroundColor Yellow
(Get-GPInheritance -Target $DominioDN).GpoLinks | Select-Object DisplayName, Enabled | Format-Table

Write-Host "`nServidor listo. Ejecuta ahora los scripts de cliente." -ForegroundColor Green
