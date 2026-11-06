#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — preparar_fedora: deja el portátil listo para emitir la pantalla
# ===========================================================================
#  Propósito : preparar el portátil Fedora (KDE) que emite la pantalla extendida
#              al HP: instalar Sunshine y el controlador de vídeo, escribir la
#              configuración de Sunshine, cerrar al exterior el puerto del
#              monitor virtual y enlazar 'pantalla-hp' en el PATH. Después
#              comprueba que la GPU codifica HEVC por hardware.
#  Uso       : scripts/emisor/preparar_fedora.sh [--check]
#  Capítulo  : docs/18_pantalla_extendida.md
#
#  Corre con tu usuario, en el portátil: cada paso que lo necesita llama a sudo.
#  Es idempotente. Con --check no llama a sudo ni cambia nada.
#
#  Requiere PANTALLA_EMISOR_IP en config/servidor.env (la IP de Tailscale del
#  portátil). Sunshine solo escucha en ella.
#
#  Sunshine se instala desde el COPR lizardbyte/stable. No se añade el usuario
#  al grupo 'input': la captura y la entrada van por KWin, y ese grupo daría
#  acceso a todos los dispositivos de entrada.
# ===========================================================================
set -euo pipefail

SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
source "$(dirname "${SCRIPT}")/../lib/common.sh"

mostrar_ayuda() {
    cat <<'AYUDA'
Uso: preparar_fedora.sh [opciones]

Prepara este portátil Fedora (KDE) para emitir la pantalla extendida:
  - Sunshine (COPR lizardbyte/stable) e intel-media-driver.
  - ~/.config/sunshine/sunshine.conf (se respalda si ya existía y difiere).
  - Regla permanente de firewalld que rechaza el puerto 15905/tcp en la zona
    por defecto (el del monitor virtual no debe verse desde fuera).
  - Enlace ~/.local/bin/pantalla-hp.
  - Comprobación de que vainfo ofrece HEVC por hardware.

Necesita PANTALLA_EMISOR_IP en config/servidor.env.

Opciones:
  -n, --check    Muestra lo que haría, sin tocar nada ni llamar a sudo.
  -h, --help     Muestra esta ayuda.
AYUDA
}

PUERTO_MONITOR=15905
REGLA_PUERTO="rule port port=\"${PUERTO_MONITOR}\" protocol=\"tcp\" reject"
ENLACE="${HOME}/.local/bin/pantalla-hp"
DESTINO_ENLACE="${NOMAD_RAIZ}/scripts/emisor/pantalla-hp.sh"
CONF_SUNSHINE="${HOME}/.config/sunshine/sunshine.conf"

# --- Comprobaciones previas --------------------------------------------------

comprobar_sistema() {
    [[ -r /etc/os-release ]] || die "No se encuentra /etc/os-release."
    local ID
    # shellcheck disable=SC1091  # archivo del sistema, no del repositorio
    ID="$(. /etc/os-release; printf '%s' "${ID:-}")"
    [[ "${ID}" == "fedora" ]] || die "Esto es para Fedora (detectado: ${ID:-desconocido})."
    [[ "${XDG_CURRENT_DESKTOP:-}" == *KDE* ]] \
        || die "Hace falta una sesión de KDE Plasma (XDG_CURRENT_DESKTOP='${XDG_CURRENT_DESKTOP:-}')."
}

# --- Paquetes ----------------------------------------------------------------

paquete_instalado() { rpm -q "$1" >/dev/null 2>&1; }

copr_activo() { dnf copr list 2>/dev/null | contiene -x 'copr.fedorainfracloud.org/lizardbyte/stable'; }

instalar_sunshine() {
    log_paso "Sunshine e intel-media-driver"
    if copr_activo; then
        log_sinca "COPR lizardbyte/stable ya activo."
    else
        ejecutar sudo dnf -y copr enable lizardbyte/stable
    fi

    local pendientes=() p
    for p in Sunshine intel-media-driver; do
        paquete_instalado "${p}" || pendientes+=("${p}")
    done
    if (( ${#pendientes[@]} == 0 )); then
        log_sinca "Paquetes ya instalados: Sunshine intel-media-driver"
    else
        ejecutar sudo dnf -y install "${pendientes[@]}"
    fi
}

# --- Configuración de Sunshine -----------------------------------------------

# Este proyecto es el dueño del archivo: se escribe exactamente lo de abajo, y
# si el actual difiere, instalar_archivo guarda antes una copia al lado.
escribir_conf_sunshine() {
    log_paso "Configuración de Sunshine"
    printf '%s\n' \
        "capture = kwin" \
        "encoder = vaapi" \
        "output_name = Virtual-hp-pantalla" \
        "bind_address = ${PANTALLA_EMISOR_IP}" \
        "upnp = disabled" \
        "vaapi_rc = vbr" \
        "vaapi_strict_rc_buffer = disabled" \
        | instalar_archivo "${CONF_SUNSHINE}" 644 "$(id -un):$(id -gn)"
}

# --- Cortafuegos -------------------------------------------------------------

# krfb-virtualmonitor escucha en todas las interfaces: el puerto se rechaza en
# la zona por defecto. Solo el propio portátil lo usa, por la interfaz local.
regla_cortafuegos() {
    log_paso "Cortafuegos"
    command -v firewall-cmd >/dev/null 2>&1 || die "No hay firewall-cmd: ¿firewalld está instalado?"
    local zona
    zona="$(firewall-cmd --get-default-zone)" || die "firewalld no responde."
    if firewall-cmd --zone="${zona}" --permanent --query-rich-rule="${REGLA_PUERTO}" >/dev/null 2>&1; then
        log_sinca "Regla ya presente en la zona ${zona}: ${REGLA_PUERTO}"
        # Permanente no implica activa: se comprueba también la de ahora.
        if ! firewall-cmd --zone="${zona}" --query-rich-rule="${REGLA_PUERTO}" >/dev/null 2>&1; then
            ejecutar sudo firewall-cmd --zone="${zona}" --add-rich-rule="${REGLA_PUERTO}"
        fi
    else
        ejecutar sudo firewall-cmd --zone="${zona}" --permanent --add-rich-rule="${REGLA_PUERTO}"
        ejecutar sudo firewall-cmd --zone="${zona}" --add-rich-rule="${REGLA_PUERTO}"
    fi
}

# --- Enlace ------------------------------------------------------------------

enlazar_pantalla_hp() {
    log_paso "Enlace pantalla-hp"
    if [[ -L "${ENLACE}" && "$(readlink "${ENLACE}")" == "${DESTINO_ENLACE}" ]]; then
        log_sinca "${ENLACE} ya apunta a ${DESTINO_ENLACE}"
        return 0
    fi
    if [[ -e "${ENLACE}" && ! -L "${ENLACE}" ]]; then
        die "${ENLACE} existe y no es un enlace: muévelo a mano y repite."
    fi
    if [[ ! -d "$(dirname "${ENLACE}")" ]]; then ejecutar mkdir -p "$(dirname "${ENLACE}")"; fi
    ejecutar ln -sfn "${DESTINO_ENLACE}" "${ENLACE}"
}

# --- Codificación por hardware ------------------------------------------------

# Sin HEVC por hardware Sunshine codifica por CPU y el portátil se arrastra.
comprobar_vainfo() {
    log_paso "Codificación HEVC por hardware"
    if ! command -v vainfo >/dev/null 2>&1; then
        if (( MODO_CHECK == 1 )); then
            log_aviso "vainfo no está instalado (paquete libva-utils): no se puede comprobar HEVC."
            return 0
        fi
        ejecutar sudo dnf -y install libva-utils
    fi
    local salida
    salida="$(vainfo 2>&1 || true)"
    if ! contiene -E 'VAProfileHEVCMain[[:space:]]*:[[:space:]]*VAEntrypointEncSlice' <<<"${salida}"; then
        die "vainfo no ofrece VAProfileHEVCMain con VAEntrypointEncSlice: se codificaría por CPU. Revisa intel-media-driver."
    fi
    log_ok "HEVC por hardware disponible (VAProfileHEVCMain / VAEntrypointEncSlice)."
}

# --- Principal -----------------------------------------------------------------

procesar_argumentos_comunes "$@"
(( ${#NOMAD_ARGS_RESTANTES[@]} == 0 )) || die "Argumento desconocido: ${NOMAD_ARGS_RESTANTES[0]} (usa --help)"
requerir_no_root

cargar_entorno
requerir_variables PANTALLA_EMISOR_IP
comprobar_sistema

instalar_sunshine
escribir_conf_sunshine
regla_cortafuegos
enlazar_pantalla_hp
comprobar_vainfo

resumen_final "preparar_fedora"
