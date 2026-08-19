#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — endurecimiento del sistema base
# ===========================================================================
#  Propósito : actualizaciones de seguridad automáticas, límites al registro,
#              parámetros del kernel, verificación de AppArmor y auditoría de
#              referencia con Lynis.
#  Uso       : sudo ./scripts/07_hardening.sh --help
#  Capítulo  : docs/07_endurecimiento_del_sistema.md
#
#  Este script NUNCA fija net.ipv4.ip_forward, y avisa si otro archivo lo pone
#  a 0: eso dejaría a todos los contenedores sin red (capítulo 07 § 3.3).
# ===========================================================================
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

SIN_AUDITORIA=0

mostrar_ayuda() {
    cat <<'AYUDA'
Uso: sudo ./scripts/07_hardening.sh [opciones]

Endurece el sistema base:

  1. Actualizaciones automáticas de seguridad (con reinicio a las 04:00)
  2. Límites del registro de systemd (500 MB, un mes)
  3. Parámetros del kernel (red, memoria, superficie del kernel)
  4. Verificación de AppArmor
  5. Revisión de qué está escuchando en la red
  6. Auditoría de referencia con Lynis

Opciones:
  --sin-auditoria   Omite el paso 6, que es el que más tarda.
  -n, --check       Muestra qué cambiaría, sin modificar nada.
  -y, --si          No pide confirmación.
  -h, --help        Muestra esta ayuda.

El script no modifica net.ipv4.ip_forward: Docker lo necesita a 1 y lo activa
por su cuenta. Si detecta que otro archivo lo pone a 0, avisa.
AYUDA
}

# --- Argumentos --------------------------------------------------------------
ARGS=()
while (( $# > 0 )); do
    case "$1" in
        --sin-auditoria) SIN_AUDITORIA=1 ;;
        *)               ARGS+=("$1") ;;
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
requerir_variables SSH_PUERTO ADMIN_USUARIO
requerir_internet

# ===========================================================================
#  1. ACTUALIZACIONES AUTOMÁTICAS
# ===========================================================================
log_paso "1/6 · Actualizaciones automáticas"

instalar_paquetes unattended-upgrades apt-listchanges

instalar_plantilla etc/unattended-upgrades.conf \
    /etc/apt/apt.conf.d/52-nomad-unattended 644 root:root
instalar_plantilla etc/apt-periodic.conf \
    /etc/apt/apt.conf.d/20auto-upgrades 644 root:root

if (( MODO_CHECK == 0 )); then
    log_info "Comprobando la configuración con una ejecución en seco…"
    if unattended-upgrade --dry-run 2>&1 | contiene "${DEBIAN_SUITE}-security"; then
        log_ok "Los parches de seguridad de ${DEBIAN_SUITE} están cubiertos."
    else
        log_error "unattended-upgrades NO cubre ${DEBIAN_SUITE}-security."
        log_error "El servidor no recibiría parches. Revisa Origins-Pattern."
        log_error "Diagnostica con: sudo unattended-upgrade --dry-run --debug"
    fi

    for temporizador in apt-daily.timer apt-daily-upgrade.timer; do
        habilitar_servicio "${temporizador}"
    done
fi

# ===========================================================================
#  2. LÍMITES DEL REGISTRO
# ===========================================================================
log_paso "2/6 · Límites del registro"

CAMBIOS_ANTES_JOURNALD="${NOMAD_CAMBIOS}"
instalar_plantilla etc/journald-nomad.conf \
    /etc/systemd/journald.conf.d/50-nomad.conf 644 root:root

if (( MODO_CHECK == 0 )); then
    if (( NOMAD_CAMBIOS > CAMBIOS_ANTES_JOURNALD )); then
        ejecutar systemctl restart systemd-journald
    else
        log_sinca "La configuración del registro no ha cambiado: no se reinicia journald."
    fi

    USO_ACTUAL="$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMG]' | head -1)"
    log_info "Espacio usado por el registro: ${USO_ACTUAL:-desconocido}"

    # Recortar de golpe lo que ya hubiera acumulado.
    journalctl --vacuum-size=500M >/dev/null 2>&1 || true
    log_ok "Registro limitado a 500 MB y un mes de retención."
fi

# ===========================================================================
#  3. PARÁMETROS DEL KERNEL
# ===========================================================================
log_paso "3/6 · Parámetros del kernel"

# Antes de tocar nada: comprobar que nadie está desactivando el reenvío.
CULPABLES="$(grep -rlE '^\s*net\.ipv4\.ip_forward\s*=\s*0' \
             /etc/sysctl.conf /etc/sysctl.d/ 2>/dev/null || true)"
if [[ -n "${CULPABLES}" ]]; then
    log_error "Hay archivos que ponen net.ipv4.ip_forward a 0:"
    printf '%s\n' "${CULPABLES}" | sed 's/^/          /' >&2
    log_error "Eso dejaría a TODOS los contenedores sin red (capítulo 07 § 3.3)."
    log_error "Elimina esas líneas antes de instalar Docker."
else
    log_ok "Nadie está desactivando net.ipv4.ip_forward."
fi

CAMBIOS_ANTES_SYSCTL="${NOMAD_CAMBIOS}"
instalar_plantilla etc/sysctl-nomad.conf \
    /etc/sysctl.d/60-nomad-endurecimiento.conf 644 root:root

if (( MODO_CHECK == 0 )); then
    if (( NOMAD_CAMBIOS > CAMBIOS_ANTES_SYSCTL )); then
        ejecutar sysctl --system >/dev/null
    else
        log_sinca "Los parámetros del kernel no han cambiado: no se recargan."
    fi

    log_info "Valores aplicados:"
    for parametro in kernel.kptr_restrict kernel.dmesg_restrict \
                     net.ipv4.tcp_syncookies vm.swappiness vm.max_map_count; do
        printf '          %-32s %s\n' "${parametro}" "$(sysctl -n "${parametro}" 2>/dev/null || echo '?')"
    done
fi

# ===========================================================================
#  4. APPARMOR
# ===========================================================================
log_paso "4/6 · AppArmor"

if [[ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null || echo N)" != "Y" ]]; then
    log_aviso "El kernel no tiene AppArmor habilitado."
    log_aviso "Revisa que /etc/default/grub no contenga 'apparmor=0'."
    instalar_paquetes apparmor apparmor-utils
elif command -v aa-status >/dev/null 2>&1; then
    PERFILES="$(aa-status --enforced 2>/dev/null || echo 0)"
    if (( PERFILES > 0 )); then
        log_ok "AppArmor activo con ${PERFILES} perfiles en modo enforce."
    else
        log_aviso "AppArmor está cargado pero sin perfiles en modo enforce."
    fi
    habilitar_servicio apparmor
else
    instalar_paquetes apparmor apparmor-utils
    habilitar_servicio apparmor
fi

# ===========================================================================
#  5. QUÉ ESTÁ ESCUCHANDO
# ===========================================================================
log_paso "5/6 · Servicios en escucha"

if (( MODO_CHECK == 0 )) || true; then
    log_info "Puertos en escucha:"
    ss -tulpn 2>/dev/null | grep LISTEN | sed 's/^/          /' || true

    INESPERADOS="$(ss -tulpn 2>/dev/null | grep LISTEN | grep -vc ":${SSH_PUERTO}\b" || true)"
    if (( INESPERADOS == 0 )); then
        log_ok "Solo SSH está escuchando. Es lo esperado."
    else
        log_aviso "Hay ${INESPERADOS} servicios escuchando además de SSH."
        log_aviso "Revisa cada uno: en este montaje solo SSH debería estar en red."
    fi
fi

# ===========================================================================
#  6. AUDITORÍA DE REFERENCIA
# ===========================================================================
log_paso "6/6 · Auditoría de referencia (Lynis)"

if (( SIN_AUDITORIA == 1 )); then
    log_sinca "Omitida por --sin-auditoria."
elif (( MODO_CHECK == 1 )); then
    log_check "ejecutaría: lynis audit system --quick"
else
    instalar_paquetes lynis

    DIR_INVENTARIO="${NOMAD_RAIZ}/inventario"
    mkdir -p "${DIR_INVENTARIO}"
    INFORME="${DIR_INVENTARIO}/lynis-$(date +%F).dat"

    log_info "Ejecutando la auditoría (unos minutos)…"
    lynis audit system --quick --quiet --report-file "${INFORME}" >/dev/null 2>&1 || true

    if [[ -f "${INFORME}" ]]; then
        INDICE="$(grep -m1 '^hardening_index=' "${INFORME}" | cut -d= -f2 || echo '?')"
        log_ok "Índice de endurecimiento: ${INDICE}"
        log_info "Informe guardado en: ${INFORME}"
        log_info "Ese número no es una nota: es una referencia con fecha."
        log_info "Vuelve a ejecutarlo dentro de unos meses y compara."
        log_info "Sugerencias: sudo lynis show suggestions"

        [[ -n "${SUDO_USER:-}" ]] && chown -R "${SUDO_USER}" "${DIR_INVENTARIO}" 2>/dev/null || true
    else
        log_aviso "La auditoría no ha generado informe. Ejecútala a mano: sudo lynis audit system"
    fi
fi

# ===========================================================================
#  RESUMEN
# ===========================================================================
resumen_final "07_hardening"

if [[ -f /var/run/reboot-required ]]; then
    echo
    log_aviso "Hay un reinicio pendiente. Ejecuta: sudo reboot"
fi

log_info "Valida el capítulo con la sección 7 de docs/07_endurecimiento_del_sistema.md"
log_info "Siguiente paso: docs/08_tailscale.md"
