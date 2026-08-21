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

    # Hace falta '--debug'. Sin él, 'unattended-upgrade --dry-run' no imprime la
    # línea 'Allowed origins are:', que es la única que dice qué orígenes acepta
    # de verdad —con ${distro_codename} ya expandido—. Buscar el nombre de la
    # versión en la salida sin '--debug' no encuentra nada NUNCA, esté el
    # servidor bien o mal configurado: la comprobación acusaba a todo el mundo
    # de no recibir parches de seguridad.
    ORIGENES_PERMITIDOS="$(unattended-upgrade --dry-run --debug 2>&1 \
        | grep '^Allowed origins are:' || true)"

    # Que unattended-upgrades ACEPTE un origen y que APT lo TENGA son dos cosas
    # distintas: sin el repositorio en las fuentes, el patrón no casa con nada y
    # no hay ningún aviso al respecto.
    if apt-cache policy | contiene "n=${DEBIAN_SUITE}-security"; then
        log_ok "APT conoce el repositorio ${DEBIAN_SUITE}-security."
    else
        log_error "APT no conoce ${DEBIAN_SUITE}-security: falta en las fuentes."
        log_error "Revisa /etc/apt/sources.list.d/debian.sources (capítulo 04)."
    fi

    if [[ -z "${ORIGENES_PERMITIDOS}" ]]; then
        log_error "No se ha podido leer los orígenes permitidos por unattended-upgrades."
        log_error "Diagnostica con: sudo unattended-upgrade --dry-run --debug"
    elif printf '%s\n' "${ORIGENES_PERMITIDOS}" \
            | contiene "codename=${DEBIAN_SUITE}-security"; then
        log_ok "Los parches de seguridad de ${DEBIAN_SUITE} están cubiertos."
    else
        log_error "unattended-upgrades NO cubre ${DEBIAN_SUITE}-security."
        log_error "El servidor no recibiría parches. Revisa Origins-Pattern."
        log_error "Orígenes que sí acepta:"
        printf '%s\n' "${ORIGENES_PERMITIDOS}" | sed 's/^/          /' >&2
    fi

    for temporizador in apt-daily.timer apt-daily-upgrade.timer; do
        habilitar_servicio "${temporizador}"
    done
fi

# ===========================================================================
#  2. LÍMITES DEL REGISTRO
# ===========================================================================
log_paso "2/6 · Límites del registro"

CAMBIOS_ANTES_JOURNALD="$(cambios)"
instalar_plantilla etc/journald-nomad.conf \
    /etc/systemd/journald.conf.d/50-nomad.conf 644 root:root

if (( MODO_CHECK == 0 )); then
    if hubo_cambios_desde "${CAMBIOS_ANTES_JOURNALD}"; then
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

CAMBIOS_ANTES_SYSCTL="$(cambios)"
instalar_plantilla etc/sysctl-nomad.conf \
    /etc/sysctl.d/60-nomad-endurecimiento.conf 644 root:root

if (( MODO_CHECK == 0 )); then
    if hubo_cambios_desde "${CAMBIOS_ANTES_SYSCTL}"; then
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

# Esta comprobación solo lee, así que se ejecuta también en modo simulación.
log_info "Puertos en escucha:"
ss -tulpn 2>/dev/null | grep -E 'LISTEN|UNCONN' | sed 's/^/          /' || true

# QUÉ SIGNIFICA "EXPUESTO", QUE NO ES LO QUE PARECE
#
# El criterio no es dónde escucha un proceso, sino qué deja pasar el
# cortafuegos. Un servicio atado a 0.0.0.0 cuyo puerto nftables no acepta no es
# alcanzable por nadie; y al revés, lo que el cortafuegos abre sí lo es. Medir
# solo la dirección de enlace da falsos positivos permanentes: tailscaled
# escucha en 0.0.0.0:41641 a propósito —lo necesita para las conexiones
# directas, y el capítulo 06 le abre ese puerto—, así que el aviso saltaba en
# cada ejecución. Un aviso que salta siempre enseña a ignorar los avisos.
#
# Además, 'ss' imprime '0.0.0.0:*' en la columna del PAR REMOTO de todo socket
# en escucha, así que hay que mirar la quinta columna, la dirección local, y no
# filtrar la línea entera.
log_info "Puertos en escucha:"
ss -tulpn 2>/dev/null | grep -E 'LISTEN|UNCONN' | sed 's/^/          /' || true

# Los tres casos, y solo uno es un problema:
#
#   · atado a todas las interfaces CON regla en nftables → deliberado. Es el
#     caso de tailscaled en udp 41641, que el capítulo 06 abre a propósito. Se
#     inventaría, no se avisa: un aviso permanente enseña a ignorar los avisos.
#
#   · atado a todas las interfaces SIN regla → no es alcanzable desde fuera.
#     Conviene saber que está, pero no es un fallo.
#
#   · publicado por Docker en todas las interfaces → EXPUESTO, tenga o no
#     regla. Docker inserta sus propias reglas de reenvío y NO pasa por la
#     cadena de entrada, así que el cortafuegos del capítulo 06 no lo protege.
#     Este es el único que es un error, y es el que se le escapa a quien mira
#     solo nftables.
REGLAS_ENTRADA="$(nft list chain inet nomad_filter entrada 2>/dev/null || true)"
DELIBERADOS=()
INALCANZABLES=()
EXPUESTOS=()

while read -r proto local proceso; do
    [[ -z "${proto}" ]] && continue
    puerto="${local##*:}"
    [[ "${puerto}" == "${SSH_PUERTO}" ]] && continue

    # El nombre del proceso viene como users:(("nombre",pid=…,fd=…))
    nombre="${proceso#*\"}"
    nombre="${nombre%%\"*}"
    [[ "${proceso}" == *'users:'* ]] || nombre="(desconocido)"

    if [[ "${nombre}" == docker-proxy ]]; then
        EXPUESTOS+=("${proto} ${local} — ${nombre}")
    # El límite de palabra es imprescindible por partida doble: sin él, el
    # puerto 22 casaría con una regla del 2222, y un '[^0-9]' delante tampoco
    # sirve —el espacio que separa 'dport' del número ya está consumido por el
    # propio literal, así que exigir otro separador hace que no case nunca.
    elif printf '%s\n' "${REGLAS_ENTRADA}" | contiene -E "${proto} dport .*\b${puerto}\b"; then
        DELIBERADOS+=("${proto} ${local} — ${nombre}")
    else
        INALCANZABLES+=("${proto} ${local} — ${nombre}")
    fi
done < <(ss -tulpnH 2>/dev/null | awk '$5 ~ /^(0\.0\.0\.0|\*|\[::\]):/ {print $1, $5, $NF}')

if (( ${#INALCANZABLES[@]} > 0 )); then
    log_sinca "Escuchan en todas las interfaces, pero nada abre su puerto:"
    printf '          %s\n' "${INALCANZABLES[@]}"
fi

if (( ${#DELIBERADOS[@]} > 0 )); then
    log_ok "Alcanzables desde la red por decisión del capítulo 06, además de SSH:"
    printf '          %s\n' "${DELIBERADOS[@]}"
fi

if [[ -z "${REGLAS_ENTRADA}" ]]; then
    log_aviso "No se ha podido leer 'inet nomad_filter entrada': sin cortafuegos que"
    log_aviso "consultar, esta comprobación no puede decidir nada. ¿Falta el capítulo 06?"
elif (( ${#EXPUESTOS[@]} > 0 )); then
    log_error "Hay puertos publicados por Docker en TODAS las interfaces:"
    printf '          %s\n' "${EXPUESTOS[@]}" >&2
    log_error "Docker inserta sus propias reglas y NO pasa por la cadena de entrada:"
    log_error "el cortafuegos del capítulo 06 no protege esto. Ata cada publicación"
    log_error "a una dirección privada (capítulo 09 § 3.2)."
elif (( ${#DELIBERADOS[@]} == 0 )); then
    log_ok "Solo SSH es alcanzable desde la red. Es lo esperado."
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
