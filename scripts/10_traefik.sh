#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — proxy inverso Traefik
# ===========================================================================
#  Propósito : desplegar Traefik con descubrimiento automático de contenedores
#              a través de un intermediario de solo lectura del socket de
#              Docker, sin publicar el tráfico público en el host.
#  Uso       : ./scripts/10_traefik.sh --help
#  Capítulo  : docs/10_traefik.md
#
#  No requiere root: opera con el grupo 'docker' sobre ${DATOS_RAIZ}.
# ===========================================================================
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

SIN_PRUEBA=0

mostrar_ayuda() {
    cat <<'AYUDA'
Uso: ./scripts/10_traefik.sh [opciones]

Despliega Traefik y su intermediario del socket de Docker:

  1. Comprueba la red compartida y la dirección de publicación
  2. Escribe la configuración estática, los middlewares y el compose
  3. Levanta los contenedores
  4. Comprueba que no se ha expuesto nada en 0.0.0.0
  5. Prueba de enrutado de extremo a extremo

Opciones:
  --sin-prueba   Omite el paso 5.
  -n, --check    Muestra qué cambiaría y valida el compose, sin levantar nada.
  -y, --si       No pide confirmación.
  -h, --help     Muestra esta ayuda.

No uses sudo: el script debe ejecutarse con tu usuario, que pertenece al
grupo 'docker' y es el dueño de ${DATOS_RAIZ}.

TRAEFIK_BIND_INTERNA nunca debe ser 0.0.0.0. Usa 127.0.0.1 (con túnel SSH) o
la IP de Tailscale del servidor.
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
requerir_no_root
cargar_entorno
requerir_variables DATOS_RAIZ DOCKER_RED_PROXY DOCKER_RED_PROXY_SUBRED \
                   DOCKER_RED_SOCKET TRAEFIK_BIND_INTERNA \
                   TRAEFIK_PUERTO_INTERNA TRAEFIK_DASHBOARD_HOST \
                   TRAEFIK_ACCESO_TAILNET LAN_CIDR TS_CIDR \
                   SERVIDOR_HOSTNAME
requerir_comandos docker

docker ps >/dev/null 2>&1 \
    || die "No se puede hablar con Docker. ¿Estás en el grupo 'docker'? Cierra la sesión y vuelve a entrar."

DIR_TRAEFIK="${DATOS_RAIZ}/traefik"

# ===========================================================================
#  1. CONDICIONES PREVIAS
# ===========================================================================
log_paso "1/5 · Condiciones previas"

for red in "${DOCKER_RED_PROXY}" "${DOCKER_RED_SOCKET}"; do
    docker network inspect "${red}" >/dev/null 2>&1 \
        || die "La red '${red}' no existe. Ejecuta antes: sudo ./scripts/09_docker.sh"
    log_ok "La red '${red}' existe."
done

if [[ "$(docker network inspect "${DOCKER_RED_SOCKET}" --format '{{.Internal}}')" == "true" ]]; then
    log_ok "La red '${DOCKER_RED_SOCKET}' es interna (sin salida a internet)."
else
    log_aviso "La red '${DOCKER_RED_SOCKET}' NO es interna: el intermediario del socket"
    log_aviso "podría hablar con el exterior. Recréala con --internal."
fi

# La dirección de publicación nunca debe ser pública.
case "${TRAEFIK_BIND_INTERNA}" in
    0.0.0.0|"")
        log_error "TRAEFIK_BIND_INTERNA es '${TRAEFIK_BIND_INTERNA}'."
        log_error "Eso publicaría el panel de Traefik en TODA la red."
        die "Usa 127.0.0.1 o la IP de Tailscale (tailscale ip -4)."
        ;;
    127.0.0.1)
        log_ok "El punto de entrada interno se atará a 127.0.0.1 (túnel SSH)."
        ;;
    *)
        if ip -br -4 addr | contiene -w "${TRAEFIK_BIND_INTERNA}"; then
            log_ok "La dirección ${TRAEFIK_BIND_INTERNA} existe en este host."
        else
            log_error "La dirección ${TRAEFIK_BIND_INTERNA} no existe en este host."
            log_error "Docker se negará a arrancar el contenedor."
            log_error "Direcciones disponibles:"
            ip -br -4 addr | sed 's/^/          /' >&2
            die "Corrige TRAEFIK_BIND_INTERNA en config/servidor.env."
        fi
        ;;
esac

# ===========================================================================
#  2. CONFIGURACIÓN
# ===========================================================================
log_paso "2/5 · Configuración"

if [[ -d "${DIR_TRAEFIK}/config/dinamica" ]]; then
    log_sinca "${DIR_TRAEFIK}/config/dinamica ya existe."
elif (( MODO_CHECK == 1 )); then
    log_check "crearía ${DIR_TRAEFIK}/config/dinamica"
    marcar_cambio
else
    mkdir -p "${DIR_TRAEFIK}/config/dinamica"
    marcar_cambio
    log_ok "Creado ${DIR_TRAEFIK}/config/dinamica"
fi

# Estos archivos pertenecen al usuario, no a root: el script no usa sudo.
PROPIETARIO="$(id -un):$(id -gn)"

# Se anota el contador para saber después si alguno de los tres archivos ha
# cambiado: es lo que decide si hay que volver a levantar los contenedores.
CAMBIOS_ANTES_COMPOSE="$(cambios)"

instalar_plantilla compose/traefik/traefik.yml \
    "${DIR_TRAEFIK}/config/traefik.yml" 644 "${PROPIETARIO}"
instalar_plantilla compose/traefik/dinamica/middlewares.yml \
    "${DIR_TRAEFIK}/config/dinamica/middlewares.yml" 644 "${PROPIETARIO}"
instalar_plantilla compose/traefik/docker-compose.yml \
    "${DIR_TRAEFIK}/docker-compose.yml" 644 "${PROPIETARIO}"

# --- Acceso adicional desde la tailnet -------------------------------------
# Una entrada de 'ports' publica en UNA dirección, así que escuchar a la vez en
# la loopback y en la tailnet exige dos. La segunda vive en un
# docker-compose.override.yml, que Docker Compose carga solo por estar ahí:
# activar o desactivar este acceso es crear o borrar ese archivo.
OVERRIDE_TAILNET="${DIR_TRAEFIK}/docker-compose.override.yml"

case "${TRAEFIK_ACCESO_TAILNET,,}" in
    si|sí|s|1|true|yes)
        [[ -n "${TS_IP:-}" ]] \
            || die "TRAEFIK_ACCESO_TAILNET=si exige TS_IP. Termina el capítulo 08 y fíjala."
        [[ "${TS_IP}" != "0.0.0.0" ]] \
            || die "TS_IP no puede ser 0.0.0.0: eso publicaría el panel en toda la red."
        [[ "${TS_IP}" != "${TRAEFIK_BIND_INTERNA}" ]] \
            || die "TS_IP y TRAEFIK_BIND_INTERNA son la misma dirección (${TS_IP}). Docker no puede publicar dos veces el mismo puerto en ella: pon TRAEFIK_ACCESO_TAILNET=no."
        instalar_plantilla compose/traefik/docker-compose.override.yml \
            "${OVERRIDE_TAILNET}" 644 "${PROPIETARIO}"
        log_info "El punto de entrada interno escuchará también en ${TS_IP}."
        ;;
    *)
        if [[ -f "${OVERRIDE_TAILNET}" ]]; then
            if (( MODO_CHECK == 1 )); then
                log_check "retiraría ${OVERRIDE_TAILNET} (TRAEFIK_ACCESO_TAILNET=${TRAEFIK_ACCESO_TAILNET})"
                marcar_cambio
            else
                respaldar_archivo "${OVERRIDE_TAILNET}"
                rm -f "${OVERRIDE_TAILNET}"
                marcar_cambio
                log_ok "Retirado ${OVERRIDE_TAILNET}: el acceso desde la tailnet queda desactivado."
            fi
        else
            log_sinca "Sin acceso desde la tailnet (TRAEFIK_ACCESO_TAILNET=${TRAEFIK_ACCESO_TAILNET})."
        fi
        ;;
esac

if (( MODO_CHECK == 0 )); then
    if docker compose -f "${DIR_TRAEFIK}/docker-compose.yml" config >/dev/null 2>&1; then
        log_ok "El fichero compose es válido."
    else
        log_error "El fichero compose no es válido:"
        docker compose -f "${DIR_TRAEFIK}/docker-compose.yml" config 2>&1 | tail -10 >&2
        exit 1
    fi
fi

# ===========================================================================
#  3. DESPLIEGUE
# ===========================================================================
log_paso "3/5 · Despliegue"

if (( MODO_CHECK == 1 )); then
    compose_arriba "${DIR_TRAEFIK}" "${CAMBIOS_ANTES_COMPOSE}"
else
    compose_arriba "${DIR_TRAEFIK}"

    log_info "Esperando a que los contenedores estén sanos…"
    for _ in $(seq 1 30); do
        ESTADO="$(docker inspect -f '{{.State.Health.Status}}' traefik 2>/dev/null || echo 'sin-datos')"
        [[ "${ESTADO}" == "healthy" ]] && break
        sleep 2
    done

    if [[ "${ESTADO}" == "healthy" ]]; then
        log_ok "Traefik está sano."
    else
        log_aviso "Traefik no reporta estado 'healthy' (actual: ${ESTADO})."
        log_aviso "Registro reciente:"
        docker logs --tail 20 traefik 2>&1 | sed 's/^/          /'
    fi
fi

# ===========================================================================
#  4. NADA EXPUESTO EN 0.0.0.0
# ===========================================================================
log_paso "4/5 · Superficie expuesta"

if (( MODO_CHECK == 0 )); then
    log_info "Puertos publicados por los contenedores:"
    docker ps --format 'table {{.Names}}\t{{.Ports}}' | sed 's/^/          /'

    EXPUESTOS="$(docker ps --format '{{.Ports}}' | grep -c '0\.0\.0\.0' || true)"
    if (( EXPUESTOS == 0 )); then
        log_ok "Ningún contenedor publica en 0.0.0.0."
    else
        log_error "Hay ${EXPUESTOS} contenedores publicando en 0.0.0.0."
        log_error "Eso contradice el diseño de este servidor (capítulo 09 § 3.2)."
    fi

    if ss -tlnp 2>/dev/null | contiene -E '0\.0\.0\.0:80\b|:::80\b'; then
        log_error "El puerto 80 está escuchando en todas las interfaces."
        log_error "Traefik no debe publicar su punto de entrada público."
    else
        log_ok "El puerto 80 no está publicado en el host."
    fi
fi

# ===========================================================================
#  5. PRUEBA DE ENRUTADO
# ===========================================================================
log_paso "5/5 · Prueba de enrutado"

if (( SIN_PRUEBA == 1 )); then
    log_sinca "Omitida por --sin-prueba."
elif (( MODO_CHECK == 1 )); then
    log_check "levantaría un contenedor de prueba y comprobaría el enrutado"
else
    log_info "Levantando un contenedor de prueba…"
    docker rm -f prueba-traefik >/dev/null 2>&1 || true
    docker run -d --name prueba-traefik \
        --network "${DOCKER_RED_PROXY}" \
        --label traefik.enable=true \
        --label 'traefik.http.routers.pruebanomad.rule=Host(`prueba.local`)' \
        --label traefik.http.routers.pruebanomad.entrypoints=web \
        --label traefik.http.services.pruebanomad.loadbalancer.server.port=80 \
        traefik/whoami:latest >/dev/null

    sleep 4

    # La petición se hace DESDE otro contenedor: el puerto 80 no existe en el host.
    RESPUESTA="$(docker run --rm --network "${DOCKER_RED_PROXY}" curlimages/curl:latest \
        -s -m 10 -H 'Host: prueba.local' http://traefik/ 2>/dev/null || true)"

    if grep -q 'Hostname' <<<"${RESPUESTA}"; then
        log_ok "Traefik enruta correctamente por nombre de host."

        CABECERAS="$(docker run --rm --network "${DOCKER_RED_PROXY}" curlimages/curl:latest \
            -s -m 10 -I -H 'Host: prueba.local' http://traefik/ 2>/dev/null || true)"
        if grep -qi 'x-frame-options' <<<"${CABECERAS}"; then
            log_ok "Las cabeceras de seguridad se están aplicando."
        else
            log_aviso "No se ven las cabeceras de seguridad. Revisa 'seguridad@file'."
        fi
    else
        log_error "La prueba de enrutado ha fallado."
        log_error "Registro de Traefik:"
        docker logs --tail 20 traefik 2>&1 | sed 's/^/          /' >&2
        docker rm -f prueba-traefik >/dev/null 2>&1 || true
        exit 1
    fi

    docker rm -f prueba-traefik >/dev/null 2>&1 || true
    log_info "Contenedor de prueba eliminado."
fi

# ===========================================================================
#  RESUMEN
# ===========================================================================
resumen_final "10_traefik"

echo
if [[ "${TRAEFIK_BIND_INTERNA}" == "127.0.0.1" ]]; then
    log_info "Para abrir el panel, desde tu equipo:"
    log_info "    ssh -L ${TRAEFIK_PUERTO_INTERNA}:127.0.0.1:${TRAEFIK_PUERTO_INTERNA} ${SERVIDOR_HOSTNAME}"
    log_info "    y luego http://localhost:${TRAEFIK_PUERTO_INTERNA}/dashboard/"
else
    log_info "Panel: http://${TRAEFIK_BIND_INTERNA}:${TRAEFIK_PUERTO_INTERNA}/dashboard/"
fi
if [[ -f "${OVERRIDE_TAILNET}" ]]; then
    log_info "Y desde cualquier dispositivo de tu tailnet, sin túnel:"
    log_info "    http://${TS_IP}:${TRAEFIK_PUERTO_INTERNA}/dashboard/"
fi
log_info "(la barra final de /dashboard/ es obligatoria)"
log_info "Siguiente paso: docs/11_cloudflared_y_dominio.md"
