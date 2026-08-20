#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — túnel de Cloudflare
# ===========================================================================
#  Propósito : desplegar el túnel que conecta internet con Traefik, sin abrir
#              ningún puerto en el router, y crear los registros DNS de los
#              subdominios publicados.
#  Uso       : ./scripts/11_cloudflared.sh --help
#  Capítulo  : docs/11_cloudflared_y_dominio.md
#
#  No requiere root. El archivo de credenciales del túnel es un secreto: el
#  script comprueba sus permisos y nunca lo muestra ni lo copia a git.
# ===========================================================================
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

IMAGEN_CF="cloudflare/cloudflared:2026.7.3"
RUTA_NUEVA=""

mostrar_ayuda() {
    cat <<'AYUDA'
Uso: ./scripts/11_cloudflared.sh [opciones]

Despliega el túnel de Cloudflare que entrega el tráfico a Traefik:

  1. Comprueba el túnel, las credenciales y sus permisos
  2. Escribe config.yml y el fichero compose
  3. Comprueba que Traefik está en marcha
  4. Levanta el túnel y espera a que registre conexiones
  5. Comprueba que no se ha publicado ningún puerto

Opciones:
  --ruta <subdominio>  Crea el registro DNS de un subdominio y termina.
                       Se indica solo la parte izquierda: --ruta blog
                       creará blog.${DOMINIO_PUBLICO}
  -n, --check          Muestra qué cambiaría, sin levantar nada.
  -y, --si             No pide confirmación.
  -h, --help           Muestra esta ayuda.

ANTES de ejecutarlo hay que crear el túnel a mano (necesita navegador):

    docker run --rm -it -v ~/.cloudflared:/home/nonroot/.cloudflared \
        cloudflare/cloudflared:2026.7.3 tunnel login

    docker run --rm -it -v ~/.cloudflared:/home/nonroot/.cloudflared \
        cloudflare/cloudflared:2026.7.3 tunnel create <nombre>

Y anotar el UUID resultante en CF_TUNEL_ID, dentro de config/servidor.env.
AYUDA
}

# --- Argumentos --------------------------------------------------------------
ARGS=()
while (( $# > 0 )); do
    case "$1" in
        --ruta) RUTA_NUEVA="${2:-}"; shift ;;
        *)      ARGS+=("$1") ;;
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
requerir_variables DOMINIO_PUBLICO CF_TUNEL_NOMBRE CF_CONFIG_DIR DOCKER_RED_PROXY
requerir_comandos docker

docker ps >/dev/null 2>&1 \
    || die "No se puede hablar con Docker. ¿Estás en el grupo 'docker'?"

# ===========================================================================
#  MODO --ruta: crear un registro DNS y salir
# ===========================================================================
if [[ -n "${RUTA_NUEVA}" ]]; then
    log_paso "Registro DNS para ${RUTA_NUEVA}.${DOMINIO_PUBLICO}"

    [[ -f "${HOME}/.cloudflared/cert.pem" ]] \
        || die "Falta ~/.cloudflared/cert.pem. Ejecuta primero 'tunnel login' (ver --help)."

    if (( MODO_CHECK == 1 )); then
        log_check "crearía el CNAME ${RUTA_NUEVA}.${DOMINIO_PUBLICO} → ${CF_TUNEL_NOMBRE}"
        exit 0
    fi

    docker run --rm \
        -v "${HOME}/.cloudflared:/home/nonroot/.cloudflared" \
        "${IMAGEN_CF}" tunnel route dns \
        "${CF_TUNEL_NOMBRE}" "${RUTA_NUEVA}.${DOMINIO_PUBLICO}"

    log_ok "Registro creado. Compruébalo con:"
    log_ok "    dig ${RUTA_NUEVA}.${DOMINIO_PUBLICO} +short"
    exit 0
fi

# ===========================================================================
#  1. TÚNEL Y CREDENCIALES
# ===========================================================================
log_paso "1/5 · Túnel y credenciales"

if [[ -z "${CF_TUNEL_ID:-}" ]]; then
    log_error "CF_TUNEL_ID está vacío en config/servidor.env."
    log_error ""
    log_error "Crea el túnel primero (necesita navegador para autorizar):"
    log_error ""
    log_error "  docker run --rm -it -v ~/.cloudflared:/home/nonroot/.cloudflared \\"
    log_error "      ${IMAGEN_CF} tunnel login"
    log_error ""
    log_error "  docker run --rm -it -v ~/.cloudflared:/home/nonroot/.cloudflared \\"
    log_error "      ${IMAGEN_CF} tunnel create ${CF_TUNEL_NOMBRE}"
    log_error ""
    log_error "Y anota el UUID que devuelve en CF_TUNEL_ID."
    exit 1
fi
log_ok "Túnel: ${CF_TUNEL_NOMBRE} (${CF_TUNEL_ID})"

CREDENCIALES="${CF_CONFIG_DIR}/${CF_TUNEL_ID}.json"
ORIGEN_CRED="${HOME}/.cloudflared/${CF_TUNEL_ID}.json"

if (( MODO_CHECK == 0 )); then
    mkdir -p "${CF_CONFIG_DIR}"
fi

if [[ -f "${CREDENCIALES}" ]]; then
    log_sinca "Las credenciales ya están en ${CF_CONFIG_DIR}"
elif [[ -f "${ORIGEN_CRED}" ]]; then
    if (( MODO_CHECK == 1 )); then
        log_check "copiaría ${ORIGEN_CRED} → ${CREDENCIALES}"
    else
        cp "${ORIGEN_CRED}" "${CREDENCIALES}"
        marcar_cambio
        log_ok "Credenciales copiadas."
    fi
else
    log_error "No se encuentran las credenciales del túnel:"
    log_error "  ni en ${CREDENCIALES}"
    log_error "  ni en ${ORIGEN_CRED}"
    die "Vuelve a crear el túnel, o restaura el archivo desde tu respaldo."
fi

# El archivo ES el túnel: quien lo tenga puede recibir el tráfico de tus dominios.
if [[ -f "${CREDENCIALES}" ]]; then
    PERMISOS="$(stat -c '%a' "${CREDENCIALES}")"
    if [[ "${PERMISOS}" == "600" ]]; then
        log_ok "Permisos de las credenciales correctos (600)."
    else
        log_aviso "Las credenciales tienen permisos ${PERMISOS}; deben ser 600."
        ejecutar chmod 600 "${CREDENCIALES}"
    fi
fi

# ===========================================================================
#  2. CONFIGURACIÓN
# ===========================================================================
log_paso "2/5 · Configuración"

PROPIETARIO="$(id -un):$(id -gn)"
# Se anota el contador para saber después si la configuración del túnel ha
# cambiado: es lo que decide si hay que volver a levantar el contenedor.
CAMBIOS_ANTES_COMPOSE="$(cambios)"

instalar_plantilla compose/cloudflared/config.yml \
    "${CF_CONFIG_DIR}/config.yml" 644 "${PROPIETARIO}"
instalar_plantilla compose/cloudflared/docker-compose.yml \
    "${CF_CONFIG_DIR}/docker-compose.yml" 644 "${PROPIETARIO}"

if (( MODO_CHECK == 0 )); then
    if docker compose -f "${CF_CONFIG_DIR}/docker-compose.yml" config >/dev/null 2>&1; then
        log_ok "El fichero compose es válido."
    else
        log_error "El fichero compose no es válido:"
        docker compose -f "${CF_CONFIG_DIR}/docker-compose.yml" config 2>&1 | tail -10 >&2
        exit 1
    fi
fi

# ===========================================================================
#  3. TRAEFIK DEBE ESTAR EN MARCHA
# ===========================================================================
log_paso "3/5 · Origen del túnel"

if docker ps --format '{{.Names}}' | contiene -x traefik; then
    log_ok "Traefik está en marcha."
else
    log_error "Traefik no está en marcha: el túnel se conectaría a un origen inexistente."
    log_error "Todo el tráfico devolvería 502."
    die "Ejecuta antes: ./scripts/10_traefik.sh"
fi

# ===========================================================================
#  4. DESPLIEGUE
# ===========================================================================
log_paso "4/5 · Despliegue del túnel"

if (( MODO_CHECK == 1 )); then
    compose_arriba "${CF_CONFIG_DIR}" "${CAMBIOS_ANTES_COMPOSE}"
else
    compose_arriba "${CF_CONFIG_DIR}"

    log_info "Esperando a que el túnel registre conexiones con el borde de Cloudflare…"
    CONEXIONES=0
    for _ in $(seq 1 30); do
        CONEXIONES="$(docker logs cloudflared 2>&1 | grep -c 'Registered tunnel connection' || true)"
        (( CONEXIONES >= 2 )) && break
        sleep 2
    done

    if (( CONEXIONES >= 2 )); then
        log_ok "Túnel conectado (${CONEXIONES} conexiones registradas)."
    else
        log_error "El túnel no ha registrado conexiones suficientes (${CONEXIONES})."
        log_error "Registro reciente:"
        docker logs --tail 25 cloudflared 2>&1 | sed 's/^/          /' >&2
        log_error ""
        log_error "Causas habituales:"
        log_error "  · Credenciales incorrectas o de otro túnel"
        log_error "  · Sin salida a internet (comprueba: ping 1.1.1.1)"
        log_error "  · UDP/QUIC bloqueado: prueba 'protocol: http2' en config.yml"
        exit 1
    fi
fi

# ===========================================================================
#  5. SUPERFICIE EXPUESTA
# ===========================================================================
log_paso "5/5 · Superficie expuesta"

if (( MODO_CHECK == 0 )); then
    PUERTOS_CF="$(docker inspect cloudflared --format '{{json .NetworkSettings.Ports}}' 2>/dev/null || echo '{}')"
    if [[ "${PUERTOS_CF}" == "{}" || "${PUERTOS_CF}" == "null" ]]; then
        log_ok "cloudflared no publica ningún puerto."
    else
        log_aviso "cloudflared publica puertos: ${PUERTOS_CF}"
    fi

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
resumen_final "11_cloudflared"

echo
log_info "Para publicar un subdominio nuevo:"
log_info "    ./scripts/11_cloudflared.sh --ruta <subdominio>"
log_info "y añade las etiquetas de Traefik al compose del proyecto."
log_info ""
log_info "Comprueba en el panel de Cloudflare que el modo SSL/TLS es 'Full'."
log_info "Siguiente paso: docs/12_despliegue_de_proyectos.md"
