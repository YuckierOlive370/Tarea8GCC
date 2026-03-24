#!/bin/bash

# ============================================================
# VARIABLES GLOBALES
# ============================================================
DC_IP="192.168.32.3"
DOMINIO="dominio.local"
REALM="DOMINIO.LOCAL"
ADMIN_PASS="Admin@12345!"

# ---------------------------------------- Funciones ----------------------------------------
VerificarRoot() {
    if [ "$EUID" -ne 0 ]; then
        echo "Este script debe ejecutarse como root"
        exit 1
    fi
}

configurar_dns() {
    echo "[+] Configurando DNS hacia el DC ($DC_IP)..."
    cat > /etc/resolv.conf << EOF
nameserver $DC_IP
search $DOMINIO
domain $DOMINIO
EOF
    chattr +i /etc/resolv.conf
    if host "$DOMINIO" &>/dev/null; then
        echo "    DNS OK: $DOMINIO resuelto correctamente"
    else
        echo "    ERROR: No se puede resolver $DOMINIO"; return 1
    fi
}

instalar_paquetes() {
    echo "[+] Instalando paquetes..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y \
        realmd sssd sssd-tools adcli \
        samba-common samba-common-bin \
        krb5-user libpam-sss libnss-sss libsss-sudo \
        oddjob oddjob-mkhomedir packagekit
    echo "    Paquetes instalados"
}

configurar_kerberos() {
    echo "[+] Configurando Kerberos..."
    cat > /etc/krb5.conf << EOF
[libdefaults]
    default_realm = $REALM
    dns_lookup_realm = false
    dns_lookup_kdc = true

[realms]
    $REALM = {
        kdc = $DC_IP
        admin_server = $DC_IP
        default_domain = $DOMINIO
    }

[domain_realm]
    .$DOMINIO = $REALM
    $DOMINIO  = $REALM
EOF
    echo "    Kerberos configurado (realm: $REALM)"
}

unir_dominio() {
    echo "[+] Uniendo al dominio $DOMINIO..."
    echo "$ADMIN_PASS" | /usr/sbin/realm join --user=Administrator "$DOMINIO" -v
    if /usr/sbin/realm list | grep -q "$DOMINIO"; then
        echo "    Union completada"
    else
        echo "    ERROR: No se pudo unir al dominio"; return 1
    fi
}

configurar_sssd() {
    echo "[+] Configurando SSSD..."
    cat > /etc/sssd/sssd.conf << EOF
[sssd]
domains = $DOMINIO
config_file_version = 2
services = nss, pam, sudo

[domain/$DOMINIO]
id_provider = ad
auth_provider = ad
access_provider = ad
ad_domain = $DOMINIO
krb5_realm = $REALM
fallback_homedir = /home/%u@%d
default_shell = /bin/bash
cache_credentials = true
ldap_id_mapping = true
ldap_referrals = false
use_fully_qualified_names = false
EOF
    chmod 600 /etc/sssd/sssd.conf
    echo "    sssd.conf configurado"
}

configurar_sudoers() {
    echo "[+] Configurando sudoers..."
    cat > /etc/sudoers.d/ad-admins << EOF
%domain\ admins@$DOMINIO ALL=(ALL:ALL) ALL
EOF
    chmod 440 /etc/sudoers.d/ad-admins
    echo "    /etc/sudoers.d/ad-admins listo"
}

configurar_pam_mkhomedir() {
    echo "[+] Configurando PAM mkhomedir..."
    if ! grep -q "pam_mkhomedir" /etc/pam.d/common-session; then
        echo "session required pam_mkhomedir.so skel=/etc/skel/ umask=0077" \
            >> /etc/pam.d/common-session
        echo "    PAM mkhomedir agregado"
    else
        echo "    PAM mkhomedir ya estaba configurado"
    fi
}

reiniciar_sssd() {
    echo "[+] Reiniciando sssd..."
    systemctl enable sssd
    systemctl restart sssd
    sleep 2
    if systemctl is-active --quiet sssd; then
        echo "    sssd: ACTIVO"
    else
        echo "    ERROR: sssd no activo"; systemctl status sssd --no-pager; return 1
    fi
}

mostrar_evidencia() {
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
    echo "--- 5. SUDOERS AD ---"
    cat /etc/sudoers.d/ad-admins
    echo ""
    echo "--- 6. fallback_homedir ---"
    grep fallback_homedir /etc/sssd/sssd.conf
    echo ""
    echo "--- 7. PROBAR LOGIN ---"
    echo "Ejecuta: su - cramirez"
    echo "========================================"
}

instalar_todo() {
    configurar_dns       || exit 1
    instalar_paquetes    || exit 1
    configurar_kerberos
    unir_dominio         || exit 1
    configurar_sssd
    configurar_sudoers
    configurar_pam_mkhomedir
    reiniciar_sssd       || exit 1
    mostrar_evidencia
}
