#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — herramientas de operación
# ===========================================================================
#  Propósito : desplegar Dozzle (registros de contenedores en web) y Uptime
#              Kuma (vigilancia y avisos), accesibles solo desde la red
#              privada.
#  Uso       : ./scripts/13_observabilidad.sh --help
#  Capítulo  : docs/13_observabilidad.md
#
#  No requiere root.
# ===========================================================================
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

mostrar_ayuda() {
    cat <<'AYUDA'
Uso: ./scripts/13_observabilidad.sh [opciones]

Despliega las herramientas de operación:

  1. Comprueba Traefik y las redes necesarias
  2. Escribe el fichero compose
  3. Levanta Dozzle y Uptime Kuma
  4. Verifica que Dozzle alcanza el intermediario del socket
  5. Comprueba que nada ha quedado publicado en internet

Opciones:
  -n, --check    Muestra qué cambiaría, sin levantar nada.
  -y, --si       No pide confirmación.
  -h, --help     Muestra esta ayuda.

PASOS QUE NO PUEDE HACER ESTE SCRIPT (son de interfaz web):
  - Crear la cuenta de administrador de Uptime Kuma
  - Configurar los monitores
  - Configurar el canal de avisos y PROBARLO

Un sistema de avisos sin probar no es un sistema de avisos.
AYUDA
}

procesar_argumentos_comunes "$@"
(( ${#NOMAD_ARGS_RESTANTES[@]} == 0 )) \
    || die "Opción desconocida: ${NOMAD_ARGS_RESTANTES[*]} (usa --help)"

# --- Comprobaciones previas --------------------------------------------------
log_paso "Comprobaciones previas"
requerir_no_root
cargar_entorno
requerir_variables DATOS_RAIZ DOCKER_RED_PROXY DOCKER_RED_SOCKET \
                   DOZZLE_HOST UPTIME_KUMA_HOST TRAEFIK_PUERTO_INTERNA \
                   TRAEFIK_BIND_INTERNA SERVIDOR_HOSTNAME
requerir_comandos docker

docker ps >/dev/null 2>&1 \
    || die "No se puede hablar con Docker. ¿Estás en el grupo 'docker'?"

DIR_OBS="${DATOS_RAIZ}/observabilidad"

# ===========================================================================
#  1. CONDICIONES PREVIAS
# ===========================================================================
log_paso "1/5 · Condiciones previas"

docker ps --format '{{.Names}}' | contiene -x traefik \
    || die "Traefik no está en marcha. Ejecuta antes: ./scripts/10_traefik.sh"
log_ok "Traefik está en marcha."

docker ps --format '{{.Names}}' | contiene -x socket-proxy \
    || die "El intermediario del socket no está en marcha. Ejecuta antes: ./scripts/10_traefik.sh"
log_ok "El intermediario del socket está en marcha."

for red in "${DOCKER_RED_PROXY}" "${DOCKER_RED_SOCKET}"; do
    docker network inspect "${red}" >/dev/null 2>&1 \
        || die "La red '${red}' no existe. Ejecuta antes: sudo ./scripts/09_docker.sh"
done
log_ok "Las redes necesarias existen."

# ===========================================================================
#  2. CONFIGURACIÓN
# ===========================================================================
log_paso "2/5 · Configuración"

if (( MODO_CHECK == 0 )); then
    mkdir -p "${DIR_OBS}/datos-kuma"
else
    log_check "crearía ${DIR_OBS}/datos-kuma"
fi

PROPIETARIO="$(id -un):$(id -gn)"
# Se anota el contador para saber después si la configuración ha cambiado: es
# lo que decide si hay que volver a levantar los contenedores.
CAMBIOS_ANTES_COMPOSE="$(cambios)"

instalar_plantilla compose/observabilidad/docker-compose.yml \
    "${DIR_OBS}/docker-compose.yml" 644 "${PROPIETARIO}"

if (( MODO_CHECK == 0 )); then
    if docker compose -f "${DIR_OBS}/docker-compose.yml" config >/dev/null 2>&1; then
        log_ok "El fichero compose es válido."
    else
        log_error "El fichero compose no es válido:"
        docker compose -f "${DIR_OBS}/docker-compose.yml" config 2>&1 | tail -10 >&2
        exit 1
    fi
fi

# ===========================================================================
#  3. DESPLIEGUE
# ===========================================================================
log_paso "3/5 · Despliegue"

if (( MODO_CHECK == 1 )); then
    compose_arriba "${DIR_OBS}" "${CAMBIOS_ANTES_COMPOSE}"
else
    compose_arriba "${DIR_OBS}"

    log_info "Esperando a que los servicios estén sanos…"
    for _ in $(seq 1 40); do
        SANOS=0
        for c in dozzle uptime-kuma; do
            [[ "$(docker inspect "$c" --format '{{.State.Health.Status}}' 2>/dev/null)" == "healthy" ]] \
                && SANOS=$((SANOS + 1))
        done
        (( SANOS == 2 )) && break
        sleep 3
    done

    if (( SANOS == 2 )); then
        log_ok "Dozzle y Uptime Kuma están sanos."
    else
        log_aviso "Solo ${SANOS}/2 servicios están sanos. Uptime Kuma tarda en arrancar la primera vez."
        docker compose -f "${DIR_OBS}/docker-compose.yml" ps | sed 's/^/          /'
    fi
fi

# ===========================================================================
#  4. DOZZLE ALCANZA EL SOCKET
# ===========================================================================
log_paso "4/5 · Acceso de Dozzle a la API de Docker"

if (( MODO_CHECK == 1 )); then
    log_check "comprobaría que Dozzle alcanza el intermediario del socket"
else
    # Es el fallo más probable y el más confuso: Dozzle carga bien pero sale
    # vacío, sin ningún mensaje de error visible en la interfaz.
    # Se captura la respuesta en una variable en lugar de encadenar tuberías.
    # 'head -c' cerraría la tubería en cuanto tuviera sus bytes, wget recibiría
    # SIGPIPE y, con 'set -o pipefail', la comprobación fallaría aunque la
    # respuesta fuera correcta. Es el mismo motivo por el que aquí no se usa
    # 'grep -q' (ver contiene() en lib/common.sh).
    # La ruta no lleva prefijo de versión: fijar '/v1.24/' hace que el demonio
    # responda 400 en cuanto su versión mínima admitida sea mayor, y la
    # comprobación acusaría a Dozzle de un fallo que no es suyo.
    RESPUESTA_SOCKET="$(docker exec dozzle wget -qO- --timeout=5 \
        http://socket-proxy:2375/containers/json 2>/dev/null || true)"
    if [[ "${RESPUESTA_SOCKET:0:1}" == "[" ]]; then
        log_ok "Dozzle alcanza el intermediario del socket."
    else
        log_error "Dozzle NO alcanza el intermediario del socket."
        log_error "La interfaz cargará, pero aparecerá vacía y sin explicar por qué."
        log_error "Comprueba:"
        log_error "  · que dozzle está en la red ${DOCKER_RED_SOCKET}"
        log_error "  · que DOZZLE_REMOTE_HOST es tcp://socket-proxy:2375"
        log_error "Registro:"
        docker logs --tail 15 dozzle 2>&1 | sed 's/^/          /' >&2
    fi
fi

# ===========================================================================
#  5. NADA EXPUESTO
# ===========================================================================
log_paso "5/5 · Comprobación de exposición"

if (( MODO_CHECK == 0 )); then
    ERRORES=0
    for contenedor in dozzle uptime-kuma; do
        ETIQUETAS="$(docker inspect "${contenedor}" --format '{{json .Config.Labels}}' 2>/dev/null || echo '{}')"
        if grep -q '"traefik.http.routers[^"]*entrypoints":"[^"]*web' <<<"${ETIQUETAS}"; then
            log_error "${contenedor} está publicado en el punto de entrada PÚBLICO."
            log_error "Sus registros y su panel serían accesibles desde internet."
            ERRORES=$((ERRORES + 1))
        fi
    done
    (( ERRORES == 0 )) && log_ok "Ambas herramientas están solo en el punto de entrada interno."

    EXPUESTOS="$(docker ps --format '{{.Ports}}' | grep -c '0\.0\.0\.0' || true)"
    if (( EXPUESTOS == 0 )); then
        log_ok "Ningún contenedor publica en 0.0.0.0."
    else
        log_aviso "Hay ${EXPUESTOS} contenedores publicando en 0.0.0.0. Revísalos."
    fi
fi

# ===========================================================================
#  RESUMEN
# ===========================================================================
resumen_final "13_observabilidad"

echo
# Cómo se llega depende de dónde escuche el punto de entrada interno, y darlo
# por supuesto manda al lector a crear registros DNS hacia una dirección en la
# que no hay nada escuchando.
case "${TRAEFIK_BIND_INTERNA}" in
    127.0.0.1|localhost|::1)
        log_info "El punto de entrada interno solo escucha en la loopback del servidor."
        log_info "Se llega por un túnel SSH desde tu equipo:"
        log_info "    ssh -L ${TRAEFIK_PUERTO_INTERNA}:127.0.0.1:${TRAEFIK_PUERTO_INTERNA} ${SERVIDOR_HOSTNAME}"
        log_info "y con estos nombres apuntando a 127.0.0.1 en el /etc/hosts de tu equipo:"
        ;;
    *)
        log_info "El punto de entrada interno escucha en ${TRAEFIK_BIND_INTERNA}."
        log_info "Accede desde cualquier dispositivo que alcance esa dirección:"
        ;;
esac
log_info "    Registros:  http://${DOZZLE_HOST}:${TRAEFIK_PUERTO_INTERNA}"
log_info "    Monitor:    http://${UPTIME_KUMA_HOST}:${TRAEFIK_PUERTO_INTERNA}"
log_info ""
log_info "Si esos nombres no resuelven, revisa el paso 4 del capítulo 13."
log_info ""
log_info "Queda por hacer, en la interfaz de Uptime Kuma:"
log_info "  1. Crear la cuenta de administrador"
log_info "  2. Añadir los monitores"
log_info "  3. Configurar el canal de avisos Y ENVIAR UNA PRUEBA"
log_info "  4. Parar un contenedor a propósito y comprobar que el aviso llega"
log_info ""
log_info "Siguiente paso: docs/14_respaldos_restic.md"
