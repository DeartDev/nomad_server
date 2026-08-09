#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — acceso remoto con Tailscale
# ===========================================================================
#  Propósito : instalar el cliente de Tailscale desde su repositorio oficial y
#              conectar el servidor a la tailnet, sin abrir ningún puerto en el
#              router.
#  Uso       : sudo ./scripts/08_tailscale.sh --help
#  Capítulo  : docs/08_tailscale.md
#
#  SALVAGUARDA: comprueba que el cortafuegos permite la interfaz de Tailscale
#  ANTES de levantar la VPN. Sin esa regla, la VPN se levantaría hacia un
#  servidor inalcanzable.
# ===========================================================================
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

AUTHKEY=""
ETIQUETA=""

mostrar_ayuda() {
    cat <<'AYUDA'
Uso: sudo ./scripts/08_tailscale.sh [opciones]

Instala y conecta Tailscale:

  1. Comprueba que el cortafuegos permite la interfaz de la VPN
  2. Añade el repositorio oficial de Tailscale (formato deb822)
  3. Instala el cliente
  4. Conecta el nodo a la tailnet
  5. Activa las actualizaciones automáticas del cliente
  6. Muestra un diagnóstico de conectividad

Opciones:
  --authkey <clave>  Registra el nodo sin navegador, con una clave de
                     autenticación de https://login.tailscale.com/admin/settings/keys
                     Usa siempre claves de un solo uso y de caducidad corta.
                     La clave no se guarda en ningún archivo ni en el registro.
  --etiqueta <tag>   Registra el nodo con una etiqueta (p. ej. tag:servidor).
                     Los nodos etiquetados NO caducan nunca.
  -n, --check        Muestra qué cambiaría, sin modificar nada.
  -y, --si           No pide confirmación.
  -h, --help         Muestra esta ayuda.

PASOS QUE NO PUEDE HACER ESTE SCRIPT (requieren la consola web):
  - Desactivar la caducidad de la clave del nodo  ← el más importante
  - Activar MagicDNS
  - Definir las ACL de la tailnet

Sin desactivar la caducidad, el acceso remoto dejará de funcionar a los 180
días sin previo aviso. Ver docs/08_tailscale.md § 3.4.
AYUDA
}

# --- Argumentos --------------------------------------------------------------
ARGS=()
while (( $# > 0 )); do
    case "$1" in
        --authkey)  AUTHKEY="${2:-}"; shift ;;
        --etiqueta) ETIQUETA="${2:-}"; shift ;;
        *)          ARGS+=("$1") ;;
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
requerir_variables TS_HOSTNAME TS_INTERFAZ TS_CIDR DEBIAN_SUITE
requerir_internet "pkgs.tailscale.com"

# ===========================================================================
#  1. SALVAGUARDA: el cortafuegos debe permitir la VPN
# ===========================================================================
log_paso "1/6 · Cortafuegos"

if ! command -v nft >/dev/null 2>&1; then
    log_aviso "nftables no está instalado. ¿Se completó el capítulo 06?"
elif ! nft list chain inet nomad_filter entrada >/dev/null 2>&1; then
    log_aviso "No existe la cadena 'entrada' de nomad_filter."
    log_aviso "Ejecuta antes: sudo ./scripts/06_firewall.sh"
    confirmar "¿Continuar de todos modos?" || die "Cancelado."
else
    if nft list chain inet nomad_filter entrada | grep -q "${TS_INTERFAZ}"; then
        log_ok "El cortafuegos permite la interfaz ${TS_INTERFAZ}."
    else
        log_error "El cortafuegos NO permite ${TS_INTERFAZ}."
        log_error "Levantar la VPN ahora te daría un túnel hacia un puerto cerrado."
        die "Ejecuta antes: sudo ./scripts/06_firewall.sh"
    fi

    if nft list chain inet nomad_filter entrada | grep -q '41641'; then
        log_ok "El cortafuegos permite las conexiones directas (UDP 41641)."
    else
        log_aviso "Falta la regla 'udp dport 41641': la VPN funcionará, pero por relé."
    fi
fi

# ===========================================================================
#  2. REPOSITORIO
# ===========================================================================
log_paso "2/6 · Repositorio de Tailscale"

LLAVERO="/usr/share/keyrings/tailscale-archive-keyring.gpg"
URL_LLAVE="https://pkgs.tailscale.com/stable/debian/${DEBIAN_SUITE}.noarmor.gpg"

if [[ -s "${LLAVERO}" ]]; then
    log_sinca "La clave de Tailscale ya está instalada."
else
    if (( MODO_CHECK == 1 )); then
        log_check "descargaría la clave de ${URL_LLAVE}"
    else
        # Se usa el archivo .noarmor.gpg (binario). El .asc daría error de firma.
        curl -fsSL "${URL_LLAVE}" -o "${LLAVERO}" \
            || die "No se ha podido descargar la clave de Tailscale."
        chmod 644 "${LLAVERO}"
        marcar_cambio
        log_ok "Clave instalada en ${LLAVERO}"
    fi
fi

instalar_plantilla etc/tailscale.sources \
    /etc/apt/sources.list.d/tailscale.sources 644 root:root

# El .list oficial y nuestro .sources definirían el mismo repositorio dos veces.
if [[ -f /etc/apt/sources.list.d/tailscale.list ]]; then
    log_aviso "Existe también tailscale.list (formato antiguo): se desactiva."
    ejecutar mv /etc/apt/sources.list.d/tailscale.list \
                /etc/apt/sources.list.d/tailscale.list.desactivado
fi

ejecutar apt-get update

# ===========================================================================
#  3. INSTALACIÓN
# ===========================================================================
log_paso "3/6 · Cliente de Tailscale"

instalar_paquetes tailscale
habilitar_servicio tailscaled

# ===========================================================================
#  4. CONEXIÓN
# ===========================================================================
log_paso "4/6 · Conexión a la tailnet"

if (( MODO_CHECK == 1 )); then
    log_check "ejecutaría: tailscale up --hostname=${TS_HOSTNAME}"
elif tailscale status >/dev/null 2>&1 && ! tailscale status 2>&1 | grep -q 'Logged out'; then
    log_sinca "El nodo ya está conectado a la tailnet."
    tailscale status | head -5 | sed 's/^/          /'
else
    OPCIONES=(--hostname="${TS_HOSTNAME}")
    [[ -n "${ETIQUETA}" ]] && OPCIONES+=(--advertise-tags="${ETIQUETA}")

    if [[ -n "${AUTHKEY}" ]]; then
        log_info "Registrando el nodo con clave de autenticación…"
        # La clave no se registra: se pasa directamente al comando.
        tailscale up "${OPCIONES[@]}" --authkey="${AUTHKEY}" \
            || die "El registro con clave de autenticación ha fallado."
        log_ok "Nodo registrado."
    else
        echo
        log_info "Se abrirá una URL de autorización. Ábrela en tu navegador,"
        log_info "inicia sesión y autoriza este dispositivo."
        echo
        tailscale up "${OPCIONES[@]}" \
            || die "La conexión ha fallado."
    fi
    marcar_cambio
fi

# ===========================================================================
#  5. ACTUALIZACIONES AUTOMÁTICAS DEL CLIENTE
# ===========================================================================
log_paso "5/6 · Actualizaciones automáticas del cliente"

if (( MODO_CHECK == 1 )); then
    log_check "ejecutaría: tailscale set --auto-update"
else
    tailscale set --auto-update 2>/dev/null \
        && log_ok "Actualizaciones automáticas activadas." \
        || log_aviso "No se han podido activar las actualizaciones automáticas."
fi

# ===========================================================================
#  6. DIAGNÓSTICO
# ===========================================================================
log_paso "6/6 · Diagnóstico"

if (( MODO_CHECK == 0 )); then
    IP_TS="$(tailscale ip -4 2>/dev/null | head -1 || true)"
    if [[ -n "${IP_TS}" ]]; then
        log_ok "Dirección en la tailnet: ${IP_TS}"
    else
        log_aviso "El nodo no tiene dirección de Tailscale todavía."
    fi

    log_info "Conectividad:"
    tailscale netcheck 2>/dev/null | grep -E 'UDP|IPv4|DERP' | sed 's/^/          /' || true

    if tailscale netcheck 2>/dev/null | grep -q 'UDP: true'; then
        log_ok "Hay conectividad UDP directa."
    else
        log_aviso "Sin conectividad UDP directa: el tráfico irá por relé y será más lento."
        log_aviso "Comprueba la regla 'udp dport 41641' del capítulo 06."
    fi

    # Caducidad de la clave: el fallo a seis meses vista.
    CADUCIDAD="$(tailscale status --json 2>/dev/null | jq -r '.Self.KeyExpiry // "null"' || echo 'null')"
    if [[ "${CADUCIDAD}" == "null" ]]; then
        log_ok "La clave del nodo no caduca."
    else
        echo
        log_aviso "════════════════════════════════════════════════════════════════"
        log_aviso "  LA CLAVE DE ESTE NODO CADUCA EL: ${CADUCIDAD}"
        log_aviso ""
        log_aviso "  Ese día perderás el acceso remoto sin previo aviso."
        log_aviso ""
        log_aviso "  Desactívalo ahora en:"
        log_aviso "      https://login.tailscale.com/admin/machines"
        log_aviso "  Busca '${TS_HOSTNAME}' → menú ⋯ → Disable key expiry"
        log_aviso "════════════════════════════════════════════════════════════════"
    fi
fi

# ===========================================================================
#  RESUMEN
# ===========================================================================
resumen_final "08_tailscale"

echo
log_info "Pasos que quedan por hacer en la consola web:"
log_info "  1. Desactivar la caducidad de clave  → https://login.tailscale.com/admin/machines"
log_info "  2. Activar MagicDNS                  → https://login.tailscale.com/admin/dns"
log_info "  3. Definir las ACL                   → https://login.tailscale.com/admin/acls"
log_info ""
log_info "Y la prueba real: conéctate desde datos móviles, fuera de tu red."
log_info "Siguiente paso: docs/09_docker.md"
