#!/bin/bash
# TAREA 08 - Cliente Debian FINAL
# Ejecutar como root: sudo bash Cliente_Debian_FINAL.sh

# ============================================================
# PASO 1 - Configurar DNS apuntando al DC
# ============================================================
cat > /etc/resolv.conf << EOF
nameserver 192.168.32.3
search dominio.local
domain dominio.local
EOF

# Evitar que se sobreescriba automaticamente
chattr +i /etc/resolv.conf

# Verificar resolucion
host dominio.local && echo "DNS OK" || echo "ERROR: No resuelve dominio.local"

# ============================================================
# PASO 2 - Instalar paquetes necesarios
# ============================================================
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y realmd sssd sssd-tools adcli samba-common samba-common-bin \
    krb5-user libpam-sss libnss-sss libsss-sudo oddjob oddjob-mkhomedir packagekit

# ============================================================
# PASO 3 - Configurar Kerberos
# ============================================================
cat > /etc/krb5.conf << EOF
[libdefaults]
    default_realm = DOMINIO.LOCAL
    dns_lookup_realm = false
    dns_lookup_kdc = true

[realms]
    DOMINIO.LOCAL = {
        kdc = 192.168.32.3
        admin_server = 192.168.32.3
        default_domain = dominio.local
    }

[domain_realm]
    .dominio.local = DOMINIO.LOCAL
    dominio.local = DOMINIO.LOCAL
EOF
echo "Kerberos configurado"

# ============================================================
# PASO 4 - Unirse al dominio con realm
# ============================================================
echo "Admin@12345!" | /usr/sbin/realm join --user=Administrator dominio.local -v
echo "Union al dominio completada"

# ============================================================
# PASO 5 - Configurar /etc/sssd/sssd.conf
# fallback_homedir = /home/%u@%d (requerido por la rubrica)
# ============================================================
cat > /etc/sssd/sssd.conf << EOF
[sssd]
domains = dominio.local
config_file_version = 2
services = nss, pam, sudo

[domain/dominio.local]
id_provider = ad
auth_provider = ad
access_provider = ad
ad_domain = dominio.local
krb5_realm = DOMINIO.LOCAL
fallback_homedir = /home/%u@%d
default_shell = /bin/bash
cache_credentials = true
ldap_id_mapping = true
ldap_referrals = false
use_fully_qualified_names = false
EOF

chmod 600 /etc/sssd/sssd.conf
echo "sssd.conf configurado con fallback_homedir = /home/%u@%d"

# ============================================================
# PASO 6 - Configurar sudoers para Domain Admins
# Requerido por la rubrica: /etc/sudoers.d/ad-admins
# ============================================================
cat > /etc/sudoers.d/ad-admins << EOF
%domain\ admins@dominio.local ALL=(ALL:ALL) ALL
EOF
chmod 440 /etc/sudoers.d/ad-admins
echo "sudoers configurado"

# ============================================================
# PASO 7 - Configurar PAM para creacion automatica de home
# NOTA: pam-auth-update no existe en Debian Trixie
# Se edita directamente /etc/pam.d/common-session
# ============================================================
if ! grep -q "pam_mkhomedir" /etc/pam.d/common-session; then
    echo "session required pam_mkhomedir.so skel=/etc/skel/ umask=0077" >> /etc/pam.d/common-session
    echo "PAM mkhomedir agregado"
else
    echo "PAM mkhomedir ya estaba configurado"
fi

# ============================================================
# PASO 8 - Reiniciar sssd
# ============================================================
systemctl enable sssd
systemctl restart sssd
sleep 2
systemctl is-active sssd && echo "sssd ACTIVO" || echo "ERROR: sssd no activo"

# ============================================================
# PASO 9 - Evidencia para la rubrica
# ============================================================
echo ""
echo "========================================"
echo "EVIDENCIA TAREA 08 - Cliente Debian"
echo "Fecha: $(date)"
echo "========================================"

echo ""
echo "--- 1. UNION AL DOMINIO ---"
/usr/sbin/realm list

echo ""
echo "--- 2. USUARIOS AD RESUELTOS ---"
id cramirez
id smendez

echo ""
echo "--- 3. GRUPOS AD ---"
getent group grupocuates
getent group gruponocuates

echo ""
echo "--- 4. SSSD ACTIVO ---"
systemctl is-active sssd

echo ""
echo "--- 5. SUDOERS AD (requerido por rubrica) ---"
cat /etc/sudoers.d/ad-admins

echo ""
echo "--- 6. fallback_homedir (requerido por rubrica) ---"
grep fallback_homedir /etc/sssd/sssd.conf

echo ""
echo "--- 7. PROBAR LOGIN ---"
echo "Ejecuta: su - cramirez"
echo "El home /home/cramirez@dominio.local se crea automaticamente"
echo "========================================"
