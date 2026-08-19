#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — endurecimiento del acceso SSH
# ===========================================================================
#  Propósito : dejar el acceso remoto solo con llave criptográfica: desactivar
#              la autenticación por contraseña, impedir el acceso de root,
#              limitar los usuarios autorizados y activar fail2ban.
#  Uso       : sudo ./scripts/05_ssh.sh --help
#  Capítulo  : docs/05_usuarios_y_acceso_ssh.md
#
#  SALVAGUARDA: el script se niega a desactivar la contraseña si no encuentra
#  ninguna llave pública instalada. Nunca te deja sin vía de entrada.
#
#  Aun así, NO cierres tu sesión actual hasta comprobar desde otra terminal
#  que puedes entrar con la llave.
# ===========================================================================
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

SIN_FAIL2BAN=0

mostrar_ayuda() {
    cat <<'AYUDA'
Uso: sudo ./scripts/05_ssh.sh [opciones]

Endurece el acceso SSH del servidor:

  1. Comprueba que hay al menos una llave pública instalada (salvaguarda)
  2. Cambia de ssh.socket a ssh.service (necesario en Debian 13)
  3. Escribe /etc/ssh/sshd_config.d/50-nomad.conf
  4. Valida la configuración con 'sshd -t' ANTES de aplicarla
  5. Reinicia el servicio sin cortar las sesiones abiertas
  6. Instala y configura fail2ban (backend systemd, acción nftables)

Opciones:
  --sin-fail2ban   Omite el paso 6.
  -n, --check      Muestra qué cambiaría, sin modificar nada.
  -y, --si         No pide confirmación.
  -h, --help       Muestra esta ayuda.

ANTES de ejecutarlo debes haber completado los pasos 1 a 4 del capítulo 05:
generar la llave en TU EQUIPO y copiarla al servidor con ssh-copy-id.

DESPUÉS de ejecutarlo, y antes de cerrar tu sesión, comprueba desde otra
terminal que puedes entrar:  ssh nomad
AYUDA
}

# --- Argumentos --------------------------------------------------------------
ARGS=()
while (( $# > 0 )); do
    case "$1" in
        --sin-fail2ban) SIN_FAIL2BAN=1 ;;
        *)              ARGS+=("$1") ;;
    esac
    shift
done
procesar_argumentos_comunes "${ARGS[@]+"${ARGS[@]}"}"
(( ${#NOMAD_ARGS_RESTANTES[@]} == 0 )) \
    || die "Opción desconocida: ${NOMAD_ARGS_RESTANTES[*]} (usa --help)"

# --- Comprobaciones previas --------------------------------------------------
log_paso "Comprobaciones previas"
requerir_root "$@"
requerir_debian "trixie"
cargar_entorno
requerir_variables ADMIN_USUARIO SSH_PUERTO LAN_CIDR TS_CIDR
requerir_comandos sshd systemctl

id "${ADMIN_USUARIO}" >/dev/null 2>&1 \
    || die "El usuario '${ADMIN_USUARIO}' no existe."

# ===========================================================================
#  1. SALVAGUARDA: debe existir al menos una llave pública instalada
# ===========================================================================
log_paso "1/6 · Salvaguarda: llaves autorizadas"

HOME_ADMIN="$(getent passwd "${ADMIN_USUARIO}" | cut -d: -f6)"
AUTORIZADAS="${HOME_ADMIN}/.ssh/authorized_keys"

if [[ ! -s "${AUTORIZADAS}" ]]; then
    log_error "No hay ninguna llave pública en ${AUTORIZADAS}"
    log_error ""
    log_error "Desactivar la autenticación por contraseña ahora te dejaría fuera"
    log_error "del servidor. Primero, DESDE TU EQUIPO CLIENTE:"
    log_error ""
    log_error "    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_nomad"
    log_error "    ssh-copy-id -i ~/.ssh/id_ed25519_nomad.pub ${ADMIN_USUARIO}@<ip>"
    log_error ""
    log_error "Consulta docs/05_usuarios_y_acceso_ssh.md § 5, pasos 1 a 3."
    exit 1
fi

NUM_LLAVES="$(grep -cvE '^\s*(#|$)' "${AUTORIZADAS}")"
log_ok "Llaves autorizadas encontradas: ${NUM_LLAVES}"
ssh-keygen -lf "${AUTORIZADAS}" 2>/dev/null | sed 's/^/          /' || true

# Permisos: OpenSSH ignora las llaves si el directorio o el archivo son laxos.
if [[ "$(stat -c '%a' "${HOME_ADMIN}/.ssh")" != "700" ]]; then
    ejecutar chmod 700 "${HOME_ADMIN}/.ssh"
else
    log_sinca "Permisos de ~/.ssh correctos (700)."
fi
if [[ "$(stat -c '%a' "${AUTORIZADAS}")" != "600" ]]; then
    ejecutar chmod 600 "${AUTORIZADAS}"
else
    log_sinca "Permisos de authorized_keys correctos (600)."
fi
# El propietario también importa: OpenSSH ignora un authorized_keys que no
# pertenezca al usuario. Se corrige solo si hace falta; hacerlo siempre
# contaría como un cambio en cada ejecución.
DUENO_ACTUAL="$(stat -c '%U:%G' "${HOME_ADMIN}/.ssh")"
if [[ "${DUENO_ACTUAL}" != "${ADMIN_USUARIO}:${ADMIN_USUARIO}" ]] \
   || find "${HOME_ADMIN}/.ssh" ! -user "${ADMIN_USUARIO}" -print -quit | grep -q .; then
    ejecutar chown -R "${ADMIN_USUARIO}:${ADMIN_USUARIO}" "${HOME_ADMIN}/.ssh"
else
    log_sinca "Propietario de ~/.ssh correcto (${ADMIN_USUARIO})."
fi

# ===========================================================================
#  2. ssh.socket → ssh.service
# ===========================================================================
log_paso "2/6 · Activación por socket (Debian 13)"

if systemctl is-active --quiet ssh.socket 2>/dev/null \
   || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    log_info "ssh.socket está activo: 'systemctl reload ssh' fallaría (capítulo 05 § 3.2)."
    ejecutar systemctl disable --now ssh.socket
    ejecutar systemctl enable --now ssh.service
else
    log_sinca "ssh.socket ya está desactivado."
    if ! systemctl is-enabled --quiet ssh.service 2>/dev/null; then
        ejecutar systemctl enable --now ssh.service
    else
        log_sinca "ssh.service ya está habilitado."
    fi
fi

# ===========================================================================
#  3. Configuración de sshd
# ===========================================================================
log_paso "3/6 · Configuración de sshd"

DESTINO_SSHD="/etc/ssh/sshd_config.d/50-nomad.conf"
CAMBIOS_ANTES_SSHD="${NOMAD_CAMBIOS}"
instalar_plantilla etc/sshd_50-nomad.conf "${DESTINO_SSHD}" 644 root:root
# Si el archivo no ha cambiado no hay nada que aplicar, y reiniciar el servicio
# por costumbre convertiría cada pasada en un cambio. Reiniciar sshd sin motivo
# es además una operación que conviene no normalizar.
SSHD_CAMBIO=$(( NOMAD_CAMBIOS > CAMBIOS_ANTES_SSHD ? 1 : 0 ))

# ===========================================================================
#  4. Validación antes de aplicar
# ===========================================================================
log_paso "4/6 · Validación de la configuración"

if (( MODO_CHECK == 1 )); then
    log_check "validaría la configuración con: sshd -t"
else
    if sshd -t 2>/tmp/nomad-sshd-test.err; then
        log_ok "La configuración de sshd es válida."
    else
        log_error "La configuración de sshd NO es válida:"
        sed 's/^/          /' /tmp/nomad-sshd-test.err >&2

        # Restaurar la copia más reciente y abortar sin tocar el servicio.
        ULTIMA_COPIA="$(find /etc/ssh/sshd_config.d -name '50-nomad.conf.bak-*' \
                        -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
        if [[ -n "${ULTIMA_COPIA}" ]]; then
            cp -a "${ULTIMA_COPIA}" "${DESTINO_SSHD}"
            log_aviso "Restaurada la configuración anterior desde ${ULTIMA_COPIA}."
        else
            rm -f "${DESTINO_SSHD}"
            log_aviso "Eliminado ${DESTINO_SSHD}: no había configuración previa."
        fi
        log_error "El servicio SSH NO se ha tocado. Tu sesión sigue segura."
        exit 1
    fi

    # Configuración efectiva, ya combinada con /etc/ssh/sshd_config.
    log_info "Configuración efectiva:"
    sshd -T 2>/dev/null \
        | grep -E '^(port|permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|maxauthtries|allowusers)' \
        | sed 's/^/          /'
fi

# ===========================================================================
#  5. Aplicar
# ===========================================================================
log_paso "5/6 · Aplicar la configuración"

# 'restart' no corta las sesiones establecidas: cada una la atiende un proceso
# hijo independiente del demonio que escucha.
if (( SSHD_CAMBIO == 1 )); then
    ejecutar systemctl restart ssh.service
else
    log_sinca "La configuración de sshd no ha cambiado: no se reinicia el servicio."
fi

if (( MODO_CHECK == 0 )); then
    if systemctl is-active --quiet ssh.service; then
        log_ok "ssh.service activo."
    else
        log_error "ssh.service no está activo tras el reinicio."
        log_error "Diagnostica con: journalctl -u ssh -n 50"
        exit 1
    fi
fi

# ===========================================================================
#  6. fail2ban
# ===========================================================================
log_paso "6/6 · fail2ban"

if (( SIN_FAIL2BAN == 1 )); then
    log_sinca "Omitido por --sin-fail2ban."
else
    instalar_paquetes fail2ban
    CAMBIOS_ANTES_F2B="${NOMAD_CAMBIOS}"
    instalar_plantilla etc/fail2ban_nomad.local /etc/fail2ban/jail.d/nomad.local 644 root:root
    habilitar_servicio fail2ban
    if (( NOMAD_CAMBIOS > CAMBIOS_ANTES_F2B )); then
        recargar_servicio fail2ban
    else
        log_sinca "La configuración de fail2ban no ha cambiado: no se recarga."
    fi

    if (( MODO_CHECK == 0 )); then
        sleep 2
        if fail2ban-client status sshd 2>/dev/null | grep -q 'Journal matches'; then
            log_ok "fail2ban lee el journal de systemd (backend correcto)."
        else
            log_aviso "fail2ban no parece estar leyendo el journal."
            log_aviso "Comprueba con: sudo fail2ban-client status sshd"
            log_aviso "Si dice 'File list: /var/log/auth.log', revisa 'backend = systemd'."
        fi
    fi
fi

# ===========================================================================
#  RESUMEN
# ===========================================================================
resumen_final "05_ssh"

if (( MODO_CHECK == 0 )); then
    echo
    log_aviso "════════════════════════════════════════════════════════════════"
    log_aviso "  NO CIERRES ESTA SESIÓN todavía."
    log_aviso ""
    log_aviso "  Abre OTRA terminal en tu equipo y comprueba que entras:"
    log_aviso "      ssh ${ADMIN_USUARIO}@<ip-del-servidor>"
    log_aviso ""
    log_aviso "  Y que la contraseña está rechazada:"
    log_aviso "      ssh -o PubkeyAuthentication=no \\"
    log_aviso "          -o PreferredAuthentications=password ${ADMIN_USUARIO}@<ip>"
    log_aviso "      → debe responder: Permission denied (publickey)"
    log_aviso ""
    log_aviso "  Solo cuando ambas pasen, cierra esta sesión."
    log_aviso "════════════════════════════════════════════════════════════════"
fi

log_info "Siguiente paso: docs/06_red_y_firewall.md"
