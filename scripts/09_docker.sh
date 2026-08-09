#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — motor de contenedores
# ===========================================================================
#  Propósito : instalar Docker CE y Compose v2 desde el repositorio oficial,
#              configurar el demonio (rotación de registros, live-restore,
#              subredes que no colisionan con la LAN) y crear la red
#              compartida por la que hablarán Traefik y los proyectos.
#  Uso       : sudo ./scripts/09_docker.sh --help
#  Capítulo  : docs/09_docker.md
#
#  SALVAGUARDAS: aborta si algo desactiva el reenvío de paquetes, y avisa si
#  daemon.json contiene "iptables": false. Ambas cosas dejarían a todos los
#  contenedores sin red.
# ===========================================================================
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

SIN_PRUEBA=0

mostrar_ayuda() {
    cat <<'AYUDA'
Uso: sudo ./scripts/09_docker.sh [opciones]

Instala y configura Docker:

  1. Comprueba espacio en /var y que nadie desactiva ip_forward
  2. Añade el repositorio oficial de Docker (formato deb822)
  3. Instala docker-ce, containerd y los plugins buildx y compose
  4. Escribe /etc/docker/daemon.json
  5. Añade el usuario administrador al grupo docker
  6. Crea la red compartida y el directorio de proyectos
  7. Prueba de humo: red y DNS dentro de un contenedor

Opciones:
  --sin-prueba   Omite el paso 7.
  -n, --check    Muestra qué cambiaría, sin modificar nada.
  -y, --si       No pide confirmación.
  -h, --help     Muestra esta ayuda.

REGLA CENTRAL DE ESTE SERVIDOR: ningún contenedor publica puertos en el host.
Los contenedores se comunican por la red interna y el único tráfico entrante
llega por el túnel saliente de Cloudflare. Ver docs/09_docker.md § 3.2.

Tras ejecutarlo tendrás que cerrar la sesión y volver a entrar para que el
grupo 'docker' tenga efecto.
AYUDA
}

# --- Argumentos --------------------------------------------------------------
ARGS=()
while (( $# > 0 )); do
    case "$1" in
        --sin-prueba) SIN_PRUEBA=1 ;;
        *)            ARGS+=("$1") ;;
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
requerir_variables ADMIN_USUARIO DEBIAN_SUITE DOCKER_RED_PROXY \
                   DOCKER_RED_PROXY_SUBRED DOCKER_LOG_MAX_SIZE \
                   DOCKER_LOG_MAX_FILE DATOS_RAIZ LAN_CIDR
requerir_internet "download.docker.com"

# ===========================================================================
#  1. CONDICIONES QUE DEJARÍAN A LOS CONTENEDORES SIN RED
# ===========================================================================
log_paso "1/7 · Condiciones previas críticas"

LIBRE_VAR="$(df -BG --output=avail /var | tail -1 | tr -dc '0-9')"
if (( LIBRE_VAR < 20 )); then
    log_aviso "Solo hay ${LIBRE_VAR} GB libres en /var. Las imágenes de Docker viven ahí."
    confirmar "¿Continuar de todos modos?" || die "Cancelado."
else
    log_ok "Espacio libre en /var: ${LIBRE_VAR} GB."
fi

CULPABLES="$(grep -rlE '^\s*net\.ipv4\.ip_forward\s*=\s*0' \
             /etc/sysctl.conf /etc/sysctl.d/ 2>/dev/null || true)"
if [[ -n "${CULPABLES}" ]]; then
    log_error "Estos archivos desactivan el reenvío de paquetes:"
    printf '%s\n' "${CULPABLES}" | sed 's/^/          /' >&2
    log_error "Con ip_forward a 0, NINGÚN contenedor tendrá red."
    die "Elimina esas líneas y ejecuta 'sudo sysctl --system' antes de continuar."
fi
log_ok "Nadie desactiva el reenvío de paquetes."

# La subred de la red compartida no puede solapar con la red local.
red_base() { echo "${1%%/*}" | cut -d. -f1,2; }
if [[ "$(red_base "${DOCKER_RED_PROXY_SUBRED}")" == "$(red_base "${LAN_CIDR}")" ]]; then
    log_error "DOCKER_RED_PROXY_SUBRED (${DOCKER_RED_PROXY_SUBRED}) solapa con"
    log_error "LAN_CIDR (${LAN_CIDR}). El servidor perdería la ruta a tu red local."
    die "Cambia DOCKER_RED_PROXY_SUBRED en config/servidor.env (p. ej. 172.20.0.0/16)."
fi
log_ok "La subred de contenedores no solapa con la LAN."

# ===========================================================================
#  2. REPOSITORIO
# ===========================================================================
log_paso "2/7 · Repositorio de Docker"

LLAVE="/etc/apt/keyrings/docker.asc"
if [[ -s "${LLAVE}" ]]; then
    log_sinca "La clave de Docker ya está instalada."
else
    if (( MODO_CHECK == 1 )); then
        log_check "descargaría la clave de Docker en ${LLAVE}"
    else
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg -o "${LLAVE}" \
            || die "No se ha podido descargar la clave de Docker."
        chmod a+r "${LLAVE}"
        marcar_cambio
        log_ok "Clave instalada en ${LLAVE}"
    fi
fi

instalar_plantilla etc/docker.sources /etc/apt/sources.list.d/docker.sources 644 root:root

if [[ -f /etc/apt/sources.list.d/docker.list ]]; then
    log_aviso "Existe también docker.list (formato antiguo): se desactiva."
    ejecutar mv /etc/apt/sources.list.d/docker.list \
                /etc/apt/sources.list.d/docker.list.desactivado
fi

ejecutar apt-get update

# ===========================================================================
#  3. INSTALACIÓN
# ===========================================================================
log_paso "3/7 · Docker CE y Compose v2"

# El paquete docker.io de Debian entraría en conflicto con docker-ce.
if dpkg-query -W -f='${Status}' docker.io 2>/dev/null | grep -q "ok installed"; then
    log_aviso "El paquete 'docker.io' de Debian está instalado y entra en conflicto."
    confirmar "¿Eliminarlo antes de instalar docker-ce?" \
        && ejecutar apt-get purge -y docker.io \
        || die "No se puede continuar con docker.io instalado."
fi

instalar_paquetes docker-ce docker-ce-cli containerd.io \
                  docker-buildx-plugin docker-compose-plugin

# ===========================================================================
#  4. CONFIGURACIÓN DEL DEMONIO
# ===========================================================================
log_paso "4/7 · Configuración del demonio"

if [[ -f /etc/docker/daemon.json ]] && grep -q '"iptables"[[:space:]]*:[[:space:]]*false' /etc/docker/daemon.json; then
    log_aviso "daemon.json contiene \"iptables\": false."
    log_aviso "Esa opción rompe por completo la red de los contenedores."
    log_aviso "Se va a sobrescribir con la configuración de este proyecto."
fi

instalar_plantilla etc/docker-daemon.json /etc/docker/daemon.json 644 root:root

if (( MODO_CHECK == 0 )); then
    # Validar el JSON antes de reiniciar: un error deja Docker sin arrancar.
    if jq empty /etc/docker/daemon.json 2>/dev/null; then
        log_ok "daemon.json es JSON válido."
    else
        die "daemon.json no es JSON válido. Docker no arrancaría."
    fi
    ejecutar systemctl restart docker
    habilitar_servicio docker
fi

# ===========================================================================
#  5. GRUPO DOCKER
# ===========================================================================
log_paso "5/7 · Grupo docker"

if id -nG "${ADMIN_USUARIO}" | tr ' ' '\n' | grep -qx docker; then
    log_sinca "'${ADMIN_USUARIO}' ya pertenece al grupo docker."
else
    log_aviso "Pertenecer al grupo 'docker' equivale a ser root sin contraseña:"
    log_aviso "quien habla con el socket puede montar / del host en un contenedor."
    if confirmar "¿Añadir '${ADMIN_USUARIO}' al grupo docker?"; then
        ejecutar usermod -aG docker "${ADMIN_USUARIO}"
        log_aviso "Cierra la sesión y vuelve a entrar para que tenga efecto."
    else
        log_info "No añadido. Tendrás que usar 'sudo docker' en todos los comandos."
    fi
fi

# ===========================================================================
#  6. RED COMPARTIDA Y DIRECTORIO DE PROYECTOS
# ===========================================================================
log_paso "6/7 · Red compartida y directorio de proyectos"

if (( MODO_CHECK == 1 )); then
    log_check "crearía la red ${DOCKER_RED_PROXY} (${DOCKER_RED_PROXY_SUBRED})"
    log_check "crearía el directorio ${DATOS_RAIZ}"
elif docker network inspect "${DOCKER_RED_PROXY}" >/dev/null 2>&1; then
    SUBRED_ACTUAL="$(docker network inspect "${DOCKER_RED_PROXY}" \
        --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}')"
    log_sinca "La red '${DOCKER_RED_PROXY}' ya existe (${SUBRED_ACTUAL})."
    if [[ "${SUBRED_ACTUAL}" != "${DOCKER_RED_PROXY_SUBRED}" ]]; then
        log_aviso "Su subred no coincide con DOCKER_RED_PROXY_SUBRED."
        log_aviso "Para cambiarla habría que parar los contenedores conectados,"
        log_aviso "borrar la red y volver a crearla."
    fi
else
    docker network create --driver bridge \
        --subnet "${DOCKER_RED_PROXY_SUBRED}" "${DOCKER_RED_PROXY}"
    marcar_cambio
    log_ok "Red '${DOCKER_RED_PROXY}' creada."
fi

if [[ -d "${DATOS_RAIZ}" ]]; then
    log_sinca "${DATOS_RAIZ} ya existe."
else
    ejecutar mkdir -p "${DATOS_RAIZ}"
fi
ejecutar chown "${ADMIN_USUARIO}:${ADMIN_USUARIO}" "${DATOS_RAIZ}"

# ===========================================================================
#  7. PRUEBA DE HUMO
# ===========================================================================
log_paso "7/7 · Prueba de humo"

if (( SIN_PRUEBA == 1 )); then
    log_sinca "Omitida por --sin-prueba."
elif (( MODO_CHECK == 1 )); then
    log_check "ejecutaría un contenedor de prueba para validar red y DNS"
else
    log_info "Comprobando red y resolución de nombres dentro de un contenedor…"
    if docker run --rm --network "${DOCKER_RED_PROXY}" alpine:latest \
           sh -c 'ping -c2 -W2 1.1.1.1 >/dev/null && nslookup deb.debian.org >/dev/null' 2>/dev/null; then
        log_ok "Los contenedores tienen red y resuelven nombres."
    else
        log_error "La prueba ha fallado. Diagnóstico:"
        log_error "  · ¿Ping sin resolución? → DNS del host (capítulo 06 § 3.3)"
        log_error "  · ¿Nada funciona?       → ip_forward (capítulo 07 § 3.3)"
        log_error "Reproduce con:"
        log_error "  docker run --rm --network ${DOCKER_RED_PROXY} alpine sh -c 'ping -c2 1.1.1.1'"
        exit 1
    fi

    # La regla central del servidor: nadie publica puertos.
    PUBLICADOS="$(docker ps --format '{{.Ports}}' | grep -c '0.0.0.0' || true)"
    if (( PUBLICADOS == 0 )); then
        log_ok "Ningún contenedor publica puertos en el host."
    else
        log_aviso "Hay ${PUBLICADOS} contenedores publicando puertos."
        log_aviso "Eso contradice el diseño de este servidor (capítulo 09 § 3.2)."
        docker ps --format 'table {{.Names}}\t{{.Ports}}' | sed 's/^/          /'
    fi
fi

# ===========================================================================
#  RESUMEN
# ===========================================================================
resumen_final "09_docker"

if (( MODO_CHECK == 0 )) && ! id -nG "${ADMIN_USUARIO}" | tr ' ' '\n' | grep -qx docker; then
    :
else
    echo
    log_info "Si acabas de añadirte al grupo 'docker', cierra la sesión y vuelve a entrar."
fi

log_info "Valida el capítulo con la sección 7 de docs/09_docker.md"
log_info "Siguiente paso: docs/10_traefik.md"
