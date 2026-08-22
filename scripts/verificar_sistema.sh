#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — verificación del servidor
# ===========================================================================
#  Propósito : recorrer las comprobaciones de los capítulos 04 a 14 y dar un
#              veredicto único sobre el estado del servidor.
#  Uso       : ./scripts/verificar_sistema.sh --help
#  Capítulo  : docs/15_mantenimiento_y_actualizaciones.md § 6
#
#  Este script NO modifica nada: solo lee. Se puede ejecutar siempre.
#  Algunas comprobaciones necesitan sudo; sin él se omiten con un aviso.
# ===========================================================================
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

SECCION="todo"
RAPIDO=0

mostrar_ayuda() {
    cat <<'AYUDA'
Uso: ./scripts/verificar_sistema.sh [opciones]

Comprueba el estado del servidor recorriendo lo que dejaron los capítulos
04 a 14. No modifica nada.

Opciones:
  --rapido            Solo lo esencial: contenedores, disco y respaldos.
                      Es la rutina semanal (unos 30 segundos).
  --seccion <nombre>  Ejecuta solo un bloque:
                        sistema | seguridad | red | docker |
                        publicacion | respaldos
  -h, --help          Muestra esta ayuda.

Código de salida:
  0  todo correcto
  1  hay comprobaciones fallidas

Algunas comprobaciones necesitan privilegios. Para el informe completo:
    sudo ./scripts/verificar_sistema.sh
AYUDA
}

# --- Argumentos --------------------------------------------------------------
while (( $# > 0 )); do
    case "$1" in
        --rapido)  RAPIDO=1 ;;
        --seccion) SECCION="${2:-}"; shift ;;
        -h|--help) mostrar_ayuda; exit 0 ;;
        *)         die "Opción desconocida: $1 (usa --help)" ;;
    esac
    shift
done

cargar_entorno

FALLOS=0
AVISOS=0
fallo()  { log_error "$*"; FALLOS=$((FALLOS + 1)); }
aviso()  { log_aviso "$*"; AVISOS=$((AVISOS + 1)); }

# Ejecuta un comando con sudo si somos root o si sudo no pide contraseña.
# Devuelve 1 si no se puede comprobar, para poder omitir con aviso.
puede_sudo() { (( EUID == 0 )) || sudo -n true 2>/dev/null; }

# ===========================================================================
#  SISTEMA
# ===========================================================================
verificar_sistema() {
    log_paso "Sistema"

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        if [[ "${VERSION_CODENAME:-}" == "${DEBIAN_SUITE:-trixie}" ]]; then
            log_ok "Debian ${VERSION_ID:-?} (${VERSION_CODENAME})"
        else
            aviso "Versión ${VERSION_CODENAME:-?}, esperada ${DEBIAN_SUITE:-trixie}"
        fi
    fi

    if [[ -f /var/run/reboot-required ]]; then
        aviso "Hay un reinicio pendiente: $(cat /var/run/reboot-required.pkgs 2>/dev/null | tr '\n' ' ')"
    else
        log_ok "Sin reinicios pendientes."
    fi

    local pendientes
    pendientes="$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst' || true)"
    if (( pendientes == 0 )); then
        log_ok "Sistema al día."
    else
        aviso "${pendientes} paquetes actualizables. Ejecuta la rutina mensual."
    fi

    if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then
        log_ok "Reloj sincronizado ($(timedatectl show -p Timezone --value))."
    else
        fallo "El reloj NO está sincronizado. Afecta a TLS, registros y Tailscale."
    fi

    local dormidos=0 objetivo
    for objetivo in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
        [[ "$(systemctl is-enabled "${objetivo}" 2>/dev/null || true)" == "masked" ]] || dormidos=1
    done
    if (( dormidos == 0 )); then
        log_ok "Suspensión desactivada."
    else
        fallo "Algún objetivo de suspensión no está enmascarado: el servidor podría dormirse."
    fi

    local uso
    while read -r punto uso; do
        uso="${uso%\%}"
        if (( uso > 90 )); then
            fallo "${punto} al ${uso}% de ocupación."
        elif (( uso > 80 )); then
            aviso "${punto} al ${uso}% de ocupación."
        else
            log_ok "${punto} al ${uso}%."
        fi
    done < <(df --output=target,pcent / /var /srv 2>/dev/null | tail -n +2 | awk '{print $1, $2}')
}

# ===========================================================================
#  SEGURIDAD
# ===========================================================================
verificar_seguridad() {
    log_paso "Seguridad"

    if systemctl is-active --quiet ssh.service; then
        log_ok "ssh.service activo."
    else
        fallo "ssh.service NO está activo."
    fi

    if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
        aviso "ssh.socket está habilitado: 'systemctl reload ssh' fallará (capítulo 05 § 3.2)."
    else
        log_ok "ssh.socket desactivado."
    fi

    if puede_sudo; then
        local config
        config="$(sudo sshd -T 2>/dev/null || true)"
        grep -q '^passwordauthentication no' <<<"${config}" \
            && log_ok "Autenticación por contraseña desactivada." \
            || fallo "La autenticación por CONTRASEÑA sigue activa en SSH."
        grep -q '^permitrootlogin no' <<<"${config}" \
            && log_ok "Acceso de root por SSH denegado." \
            || fallo "root PUEDE entrar por SSH."

        if sudo passwd -S root 2>/dev/null | awk '{print $2}' | contiene -x L; then
            log_ok "Cuenta de root bloqueada."
        else
            aviso "La cuenta de root no está bloqueada."
        fi
    else
        aviso "Sin sudo: se omiten las comprobaciones de sshd y de la cuenta root."
    fi

    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        log_ok "fail2ban activo."
        if puede_sudo; then
            sudo fail2ban-client status sshd 2>/dev/null | contiene 'Journal matches' \
                && log_ok "fail2ban lee el journal (backend correcto)." \
                || aviso "fail2ban podría no estar leyendo nada: revisa 'backend = systemd'."
        fi
    else
        aviso "fail2ban no está activo."
    fi

    if systemctl is-active --quiet apparmor 2>/dev/null; then
        log_ok "AppArmor activo."
    else
        aviso "AppArmor no está activo."
    fi

    if systemctl is-enabled --quiet apt-daily-upgrade.timer 2>/dev/null; then
        log_ok "Actualizaciones automáticas habilitadas."
    else
        fallo "Las actualizaciones automáticas NO están habilitadas."
    fi

    # Nada debe escuchar en 0.0.0.0 salvo SSH.
    local escuchando
    escuchando="$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -E '^(0\.0\.0\.0|\*|\[::\]):' || true)"
    local inesperados
    inesperados="$(grep -vc ":${SSH_PUERTO:-22}\$" <<<"${escuchando}" 2>/dev/null || true)"
    if [[ -z "${escuchando}" ]] || (( inesperados == 0 )); then
        log_ok "Solo SSH escucha en todas las interfaces."
    else
        fallo "Hay servicios escuchando en 0.0.0.0 además de SSH:"
        grep -v ":${SSH_PUERTO:-22}\$" <<<"${escuchando}" | sed 's/^/          /' >&2
    fi
}

# ===========================================================================
#  RED
# ===========================================================================
verificar_red() {
    log_paso "Red y cortafuegos"

    if puede_sudo; then
        if sudo nft list chain inet nomad_filter entrada 2>/dev/null | contiene 'policy drop'; then
            log_ok "Cortafuegos con política 'drop' en entrada."
        else
            fallo "El cortafuegos NO tiene política 'drop' en entrada."
        fi

        # 'flush ruleset' borraría las reglas de Docker al recargar.
        if grep -q '^\s*flush ruleset' /etc/nftables.conf 2>/dev/null; then
            fallo "/etc/nftables.conf tiene 'flush ruleset': al recargar dejaría a Docker sin red."
        else
            log_ok "El cortafuegos no borra las reglas de Docker al recargarse."
        fi
    else
        aviso "Sin sudo: se omiten las comprobaciones del cortafuegos."
    fi

    if systemctl is-enabled --quiet nftables 2>/dev/null; then
        log_ok "nftables se carga al arrancar."
    else
        fallo "nftables NO está habilitado: tras un reinicio no habría cortafuegos."
    fi

    local ip_actual
    ip_actual="$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -v '^100\.' | head -1)"
    if [[ "${ip_actual}" == "${LAN_IP:-}" ]]; then
        log_ok "Dirección local correcta: ${ip_actual}"
    else
        aviso "La dirección local es ${ip_actual:-ninguna}, esperada ${LAN_IP:-?}"
    fi

    if getent hosts deb.debian.org >/dev/null 2>&1; then
        log_ok "Resolución de nombres correcta."
    else
        fallo "El servidor NO resuelve nombres. Revisa /etc/resolv.conf."
    fi

    if command -v tailscale >/dev/null 2>&1; then
        if tailscale status >/dev/null 2>&1 && ! tailscale status 2>&1 | contiene 'Logged out'; then
            log_ok "Tailscale conectado ($(tailscale ip -4 2>/dev/null | head -1))."
            local caducidad
            caducidad="$(tailscale status --json 2>/dev/null | jq -r '.Self.KeyExpiry // "null"' 2>/dev/null || echo null)"
            if [[ "${caducidad}" == "null" ]]; then
                log_ok "La clave del nodo no caduca."
            else
                fallo "La clave del nodo CADUCA el ${caducidad}: ese día perderás el acceso remoto."
            fi
        else
            fallo "Tailscale no está conectado."
        fi
    else
        aviso "Tailscale no está instalado."
    fi
}

# ===========================================================================
#  DOCKER
# ===========================================================================
verificar_docker() {
    log_paso "Docker"

    if ! command -v docker >/dev/null 2>&1; then
        aviso "Docker no está instalado."
        return
    fi

    if ! docker ps >/dev/null 2>&1; then
        fallo "No se puede hablar con Docker. ¿Está el demonio activo? ¿Estás en el grupo docker?"
        return
    fi
    log_ok "Docker responde."

    systemctl is-enabled --quiet docker 2>/dev/null \
        && log_ok "Docker arranca al iniciar el sistema." \
        || fallo "Docker NO está habilitado: tras un reinicio no arrancaría nada."

    local red
    for red in "${DOCKER_RED_PROXY:-proxy}" "${DOCKER_RED_SOCKET:-socket}"; do
        docker network inspect "${red}" >/dev/null 2>&1 \
            && log_ok "Red '${red}' presente." \
            || fallo "Falta la red '${red}'."
    done

    # La regla central del servidor.
    local publicados
    publicados="$(docker ps --format '{{.Names}} {{.Ports}}' | grep '0\.0\.0\.0' || true)"
    if [[ -z "${publicados}" ]]; then
        log_ok "Ningún contenedor publica en 0.0.0.0."
    else
        fallo "Contenedores publicando en 0.0.0.0 (saltan el cortafuegos):"
        sed 's/^/          /' <<<"${publicados}" >&2
    fi

    # Contenedores caídos o enfermos.
    local total sanos enfermos
    total="$(docker ps -q | wc -l)"
    enfermos="$(docker ps --filter health=unhealthy -q | wc -l)"
    sanos="$(docker ps --filter health=healthy -q | wc -l)"
    log_info "Contenedores en marcha: ${total} (sanos: ${sanos})"
    if (( enfermos > 0 )); then
        fallo "${enfermos} contenedores en estado 'unhealthy':"
        docker ps --filter health=unhealthy --format '          {{.Names}}\t{{.Status}}' >&2
    fi

    local parados
    parados="$(docker ps -a --filter status=exited --format '{{.Names}}' | head -5 || true)"
    [[ -n "${parados}" ]] && aviso "Contenedores parados: $(tr '\n' ' ' <<<"${parados}")"
}

# ===========================================================================
#  PUBLICACIÓN
# ===========================================================================
verificar_publicacion() {
    log_paso "Publicación"

    command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1 || {
        aviso "Sin acceso a Docker: se omite."
        return
    }

    if docker ps --format '{{.Names}}' | contiene -x traefik; then
        log_ok "Traefik en marcha."
        docker exec traefik traefik healthcheck --ping >/dev/null 2>&1 \
            && log_ok "Traefik responde a su comprobación de salud." \
            || fallo "Traefik no responde a su comprobación de salud."
    else
        fallo "Traefik NO está en marcha: ningún proyecto es accesible."
    fi

    if docker ps --format '{{.Names}}' | contiene -x socket-proxy; then
        log_ok "Intermediario del socket en marcha."
    else
        fallo "El intermediario del socket no está en marcha: Traefik no verá los contenedores."
    fi

    if docker ps --format '{{.Names}}' | contiene -x cloudflared; then
        local conexiones
        conexiones="$(docker logs cloudflared 2>&1 | grep -c 'Registered tunnel connection' || true)"
        if (( conexiones >= 2 )); then
            log_ok "Túnel conectado (${conexiones} conexiones registradas)."
        else
            fallo "El túnel tiene ${conexiones} conexiones registradas: los proyectos no son accesibles."
        fi
    else
        aviso "cloudflared no está en marcha."
    fi

    # Comprobación de extremo a extremo, si hay dominio configurado.
    if [[ -n "${DOMINIO_PUBLICO:-}" && "${DOMINIO_PUBLICO}" != "ejemplo.com" ]]; then
        local codigo
        codigo="$(curl -s -o /dev/null -w '%{http_code}' -m 10 \
                  "https://prueba.${DOMINIO_PUBLICO}" 2>/dev/null || echo 000)"
        case "${codigo}" in
            200|301|302|404) log_ok "El dominio responde desde internet (HTTP ${codigo})." ;;
            000)             aviso "No se ha podido comprobar el dominio (¿sin salida a internet?)." ;;
            502|503)         fallo "El dominio responde ${codigo}: el túnel llega pero el origen no." ;;
            *)               aviso "El dominio responde HTTP ${codigo}." ;;
        esac
    fi
}

# ===========================================================================
#  RESPALDOS
# ===========================================================================
verificar_respaldos() {
    log_paso "Respaldos"

    if ! command -v restic >/dev/null 2>&1; then
        fallo "restic no está instalado: no hay respaldos."
        return
    fi

    # Con RESTIC_USB_UUID vacía el respaldo va directo al remoto y no hay disco
    # que montar: exigirlo informaba de un fallo inexistente (capítulo 14 § 3.3).
    local repo_principal modo_respaldo
    if [[ -n "${RESTIC_USB_UUID:-}" ]]; then
        modo_respaldo="local"
        repo_principal="${RESTIC_REPO_LOCAL}"
        if mountpoint -q "${RESTIC_USB_MOUNT:-/mnt/respaldo}" 2>/dev/null; then
            log_ok "Disco de respaldo montado."
            local libre
            libre="$(df -BG --output=avail "${RESTIC_USB_MOUNT}" 2>/dev/null | tail -1 | tr -dc '0-9')"
            if (( libre < 10 )); then
                fallo "Solo quedan ${libre} GB en el disco de respaldo."
            else
                log_ok "Espacio libre en el disco de respaldo: ${libre} GB."
            fi
        else
            fallo "El disco de respaldo NO está montado: los respaldos están fallando."
        fi
    else
        modo_respaldo="remoto"
        repo_principal="${RESTIC_REPO_REMOTO:-}"
        if [[ -n "${repo_principal}" ]]; then
            log_ok "Respaldo remoto: ${repo_principal}"
        else
            fallo "Ni disco USB ni destino remoto: NO hay respaldos configurados."
        fi
    fi

    if systemctl is-enabled --quiet nomad-respaldo.timer 2>/dev/null; then
        log_ok "Temporizador de respaldo habilitado."
    else
        fallo "El temporizador de respaldo NO está habilitado."
    fi

    local resultado
    resultado="$(systemctl show nomad-respaldo.service -p Result --value 2>/dev/null || echo '')"
    case "${resultado}" in
        success) log_ok "La última ejecución del respaldo terminó bien." ;;
        "")      aviso "El respaldo aún no se ha ejecutado nunca." ;;
        *)       fallo "La última ejecución del respaldo terminó con: ${resultado}" ;;
    esac

    local repo_accesible=0
    if puede_sudo && [[ -n "${repo_principal}" ]]; then
        if [[ "${modo_respaldo}" == "local" ]]; then
            mountpoint -q "${RESTIC_USB_MOUNT:-/mnt/respaldo}" 2>/dev/null && repo_accesible=1
        else
            repo_accesible=1
        fi
    fi

    if (( repo_accesible == 1 )); then
        local ultima horas
        # '-E' conserva las credenciales del proveedor remoto, que sudo borraría.
        ultima="$(sudo -E bash -c '
                    [[ -r /etc/nomad/restic-remoto.env ]] && { set -a; . /etc/nomad/restic-remoto.env; set +a; }
                    restic snapshots --json --repo "$1" --password-file "$2"' \
                    _ "${repo_principal}" "${RESTIC_PASSWORD_FILE}" 2>/dev/null \
                  | jq -r '.[-1].time // empty' 2>/dev/null || true)"
        if [[ -n "${ultima}" ]]; then
            horas=$(( ( $(date +%s) - $(date -d "${ultima}" +%s) ) / 3600 ))
            if (( horas > 30 )); then
                fallo "La última copia tiene ${horas} horas: el respaldo diario no se está ejecutando."
            else
                log_ok "Última copia hace ${horas} horas."
            fi
        else
            aviso "No se han podido leer las instantáneas del repositorio."
        fi
    else
        aviso "Sin sudo o sin repositorio accesible: se omite la comprobación de instantáneas."
    fi

    # Tener respaldos y saber que sirven son cosas distintas.
    local marca="/var/backups/nomad/ultima-prueba-restauracion"
    if [[ -r "${marca}" ]]; then
        local dias
        dias=$(( ( $(date +%s) - $(date -d "$(cat "${marca}")" +%s) ) / 86400 ))
        if (( dias <= 40 )); then
            log_ok "Prueba de restauración superada hace ${dias} días."
        else
            fallo "La última prueba de restauración tiene ${dias} días."
        fi
    else
        fallo "NUNCA se ha superado una prueba de restauración."
    fi
}

# ===========================================================================
#  EJECUCIÓN
# ===========================================================================
echo
log_paso "Verificación de ${SERVIDOR_HOSTNAME:-este servidor} — $(date '+%F %T')"

if (( RAPIDO == 1 )); then
    verificar_docker
    verificar_respaldos
    log_paso "Espacio en disco"
    df -h / /var /srv 2>/dev/null | sed 's/^/          /'
else
    case "${SECCION}" in
        todo)        verificar_sistema; verificar_seguridad; verificar_red
                     verificar_docker; verificar_publicacion; verificar_respaldos ;;
        sistema)     verificar_sistema ;;
        seguridad)   verificar_seguridad ;;
        red)         verificar_red ;;
        docker)      verificar_docker ;;
        publicacion) verificar_publicacion ;;
        respaldos)   verificar_respaldos ;;
        *) die "Sección desconocida: '${SECCION}'. Usa --help." ;;
    esac
fi

# ===========================================================================
#  VEREDICTO
# ===========================================================================
echo
if (( FALLOS == 0 && AVISOS == 0 )); then
    log_ok "Todas las comprobaciones han pasado."
    exit 0
elif (( FALLOS == 0 )); then
    log_ok "Sin fallos. Avisos que merecen un vistazo: ${AVISOS}"
    exit 0
else
    log_error "Comprobaciones fallidas: ${FALLOS}   ·   Avisos: ${AVISOS}"
    log_error "Consulta la sección 9 (errores frecuentes) del capítulo correspondiente."
    exit 1
fi
