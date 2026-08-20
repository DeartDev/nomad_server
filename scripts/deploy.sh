#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — despliegue de un proyecto
# ===========================================================================
#  Propósito : desplegar o actualizar un proyecto de ${DATOS_RAIZ} de forma
#              segura: valida antes de tocar nada, espera a que los servicios
#              estén sanos y revierte al estado anterior si no lo consiguen.
#  Uso       : ./scripts/deploy.sh --help
#  Capítulo  : docs/12_despliegue_de_proyectos.md
#
#  Este es el script que se usará a diario, mucho después de terminar el
#  montaje. No requiere root.
# ===========================================================================
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

PROYECTO=""
SIN_PULL=0
CONSTRUIR=0
LISTAR=0
ESPERA=120

mostrar_ayuda() {
    cat <<'AYUDA'
Uso: ./scripts/deploy.sh <proyecto> [opciones]
     ./scripts/deploy.sh --listar

Despliega o actualiza un proyecto de ${DATOS_RAIZ}:

  1. Comprueba el proyecto, su .env y la validez del compose
  2. Guarda el estado actual (commit de git e imágenes en marcha)
  3. Actualiza el código con git pull
  4. Descarga o construye las imágenes
  5. Levanta los servicios
  6. Espera a que estén sanos
  7. Si alguno no lo consigue, REVIERTE al estado anterior

Opciones:
  --listar         Muestra el estado de todos los proyectos y termina.
  --sin-pull       No actualiza el código con git pull.
  --construir      Fuerza la reconstrucción de las imágenes (--no-cache).
  --espera <seg>   Segundos de espera a que los servicios estén sanos (120).
  -n, --check      Valida y muestra qué haría, sin desplegar.
  -y, --si         No pide confirmación.
  -h, --help       Muestra esta ayuda.

Ejemplos:
  ./scripts/deploy.sh mi-blog
  ./scripts/deploy.sh mi-blog --construir
  ./scripts/deploy.sh --listar

AVISO SOBRE LA REVERSIÓN
La reversión automática devuelve el CÓDIGO y la CONFIGURACIÓN al commit
anterior. NO revierte migraciones de base de datos: si el despliegue migró el
esquema y luego falló, quedarás con código antiguo y datos nuevos.
Antes de un despliegue con migraciones, respalda:
    sudo ./scripts/14_restic.sh --ahora
AYUDA
}

# --- Argumentos --------------------------------------------------------------
ARGS=()
while (( $# > 0 )); do
    case "$1" in
        --listar)    LISTAR=1 ;;
        --sin-pull)  SIN_PULL=1 ;;
        --construir) CONSTRUIR=1 ;;
        --espera)    ESPERA="${2:-120}"; shift ;;
        -*)          ARGS+=("$1") ;;
        *)           PROYECTO="$1" ;;
    esac
    shift
done
procesar_argumentos_comunes "${ARGS[@]+"${ARGS[@]}"}"
(( ${#NOMAD_ARGS_RESTANTES[@]} == 0 )) \
    || die "Opción desconocida: ${NOMAD_ARGS_RESTANTES[*]} (usa --help)"

[[ "${ESPERA}" =~ ^[0-9]+$ ]] || die "--espera debe ser un número de segundos."

# --- Comprobaciones previas --------------------------------------------------
requerir_no_root
cargar_entorno
requerir_variables DATOS_RAIZ DOCKER_RED_PROXY
requerir_comandos docker

docker ps >/dev/null 2>&1 \
    || die "No se puede hablar con Docker. ¿Estás en el grupo 'docker'?"

# ===========================================================================
#  MODO --listar
# ===========================================================================
if (( LISTAR == 1 )); then
    log_paso "Proyectos en ${DATOS_RAIZ}"
    printf '  %-24s %-10s %s\n' "PROYECTO" "SERVICIOS" "ESTADO"
    printf '  %-24s %-10s %s\n' "------------------------" "----------" "----------------"
    for dir in "${DATOS_RAIZ}"/*/; do
        [[ -f "${dir}/docker-compose.yml" ]] || continue
        nombre="$(basename "${dir}")"
        total="$(docker compose -f "${dir}/docker-compose.yml" ps --services 2>/dev/null | wc -l)"
        activos="$(docker compose -f "${dir}/docker-compose.yml" ps --services --filter status=running 2>/dev/null | wc -l)"
        if (( total == 0 )); then
            estado="sin desplegar"
        elif (( activos == total )); then
            estado="en marcha"
        else
            estado="PARCIAL (${activos}/${total})"
        fi
        printf '  %-24s %-10s %s\n' "${nombre}" "${activos}/${total}" "${estado}"
    done
    exit 0
fi

[[ -n "${PROYECTO}" ]] || die "Falta el nombre del proyecto. Usa --help o --listar."

DIR="${DATOS_RAIZ}/${PROYECTO}"
COMPOSE="${DIR}/docker-compose.yml"

# ===========================================================================
#  1. COMPROBACIONES DEL PROYECTO
# ===========================================================================
log_paso "1/7 · Comprobaciones de '${PROYECTO}'"

[[ -d "${DIR}" ]]     || die "No existe el proyecto ${DIR}"
[[ -f "${COMPOSE}" ]] || die "No existe ${COMPOSE}"
log_ok "Proyecto encontrado en ${DIR}"

if [[ -f "${DIR}/.env" ]]; then
    PERMISOS="$(stat -c '%a' "${DIR}/.env")"
    if [[ "${PERMISOS}" == "600" ]]; then
        log_ok "Permisos de .env correctos (600)."
    else
        log_aviso ".env tiene permisos ${PERMISOS}; deben ser 600."
        ejecutar chmod 600 "${DIR}/.env"
    fi
elif [[ -f "${DIR}/.env.example" ]]; then
    log_error "Falta ${DIR}/.env pero existe .env.example."
    log_error "Créalo con:  cp ${DIR}/.env.example ${DIR}/.env && chmod 600 ${DIR}/.env"
    exit 1
else
    log_sinca "El proyecto no usa archivo .env."
fi

# Validar el compose ANTES de tocar nada.
if docker compose -f "${COMPOSE}" config >/dev/null 2>&1; then
    log_ok "El fichero compose es válido."
else
    log_error "El fichero compose no es válido:"
    docker compose -f "${COMPOSE}" config 2>&1 | tail -15 >&2
    exit 1
fi

# La regla del servidor: nadie publica puertos.
if docker compose -f "${COMPOSE}" config 2>/dev/null | contiene -E '^\s+published:' ; then
    log_aviso "El compose publica puertos en el host."
    log_aviso "Salvo que estén atados a una dirección privada, eso salta el"
    log_aviso "cortafuegos (capítulo 12 § 3.2). Para depurar usa un túnel SSH:"
    log_aviso "    ssh -L <puerto>:localhost:<puerto> ${SERVIDOR_HOSTNAME:-nomad}"
fi

# ===========================================================================
#  2. ESTADO ACTUAL (para poder revertir)
# ===========================================================================
log_paso "2/7 · Guardando el estado actual"

DIR_CODIGO=""
COMMIT_ANTERIOR=""
for candidato in "${DIR}/codigo" "${DIR}"; do
    if [[ -d "${candidato}/.git" ]]; then
        DIR_CODIGO="${candidato}"
        COMMIT_ANTERIOR="$(git -C "${DIR_CODIGO}" rev-parse HEAD 2>/dev/null || true)"
        break
    fi
done

if [[ -n "${COMMIT_ANTERIOR}" ]]; then
    log_ok "Repositorio en ${DIR_CODIGO}, commit actual: ${COMMIT_ANTERIOR:0:8}"
else
    log_sinca "El proyecto no es un repositorio git: no habrá reversión de código."
fi

IMAGENES_ANTES="$(docker compose -f "${COMPOSE}" images --quiet 2>/dev/null | sort -u || true)"
if [[ -n "${IMAGENES_ANTES}" ]]; then
    log_info "Imágenes en marcha: $(wc -l <<<"${IMAGENES_ANTES}")"
fi

# Función de reversión, llamada solo si el despliegue falla.
revertir() {
    echo
    log_aviso "════════════════════════════════════════════════════════════════"
    log_aviso "  REVIRTIENDO el despliegue"
    log_aviso "════════════════════════════════════════════════════════════════"

    if [[ -n "${COMMIT_ANTERIOR}" ]]; then
        log_info "Volviendo al commit ${COMMIT_ANTERIOR:0:8}…"
        git -C "${DIR_CODIGO}" checkout --quiet "${COMMIT_ANTERIOR}" 2>/dev/null \
            && log_ok "Código revertido." \
            || log_error "No se ha podido revertir el código."
    fi

    log_info "Levantando de nuevo con la configuración anterior…"
    docker compose -f "${COMPOSE}" up -d --force-recreate 2>&1 | tail -5 || true

    echo
    log_aviso "La reversión NO deshace migraciones de base de datos."
    log_aviso "Si este despliegue migró el esquema, restaura desde el respaldo:"
    log_aviso "    docs/16_recuperacion_ante_desastres.md"
}

# ===========================================================================
#  3. ACTUALIZACIÓN DEL CÓDIGO
# ===========================================================================
log_paso "3/7 · Código"

if (( SIN_PULL == 1 )); then
    log_sinca "Omitido por --sin-pull."
elif [[ -z "${DIR_CODIGO}" ]]; then
    log_sinca "No hay repositorio que actualizar."
elif (( MODO_CHECK == 1 )); then
    log_check "ejecutaría: git -C ${DIR_CODIGO} pull"
else
    if [[ -n "$(git -C "${DIR_CODIGO}" status --porcelain)" ]]; then
        log_aviso "Hay cambios locales sin confirmar en ${DIR_CODIGO}:"
        git -C "${DIR_CODIGO}" status --short | sed 's/^/          /'
        confirmar "¿Continuar de todos modos?" || die "Cancelado."
    fi
    git -C "${DIR_CODIGO}" pull --ff-only || die "git pull ha fallado."
    COMMIT_NUEVO="$(git -C "${DIR_CODIGO}" rev-parse HEAD)"
    if [[ "${COMMIT_NUEVO}" == "${COMMIT_ANTERIOR}" ]]; then
        log_sinca "El código ya estaba al día."
    else
        log_ok "Código actualizado: ${COMMIT_ANTERIOR:0:8} → ${COMMIT_NUEVO:0:8}"
        git -C "${DIR_CODIGO}" log --oneline "${COMMIT_ANTERIOR}..${COMMIT_NUEVO}" \
            | sed 's/^/          /' | head -10
    fi
fi

# ===========================================================================
#  4. IMÁGENES
# ===========================================================================
log_paso "4/7 · Imágenes"

if (( MODO_CHECK == 1 )); then
    log_check "descargaría y construiría las imágenes del proyecto"
else
    log_info "Descargando imágenes…"
    docker compose -f "${COMPOSE}" pull --quiet 2>/dev/null || \
        log_aviso "Alguna imagen no se ha podido descargar (¿se construye en local?)."

    if (( CONSTRUIR == 1 )); then
        log_info "Reconstruyendo sin caché…"
        docker compose -f "${COMPOSE}" build --no-cache || { revertir; die "La construcción ha fallado."; }
    elif docker compose -f "${COMPOSE}" config 2>/dev/null | contiene 'build:'; then
        log_info "Construyendo…"
        docker compose -f "${COMPOSE}" build || { revertir; die "La construcción ha fallado."; }
    fi
fi

# ===========================================================================
#  5. DESPLIEGUE
# ===========================================================================
log_paso "5/7 · Despliegue"

if (( MODO_CHECK == 1 )); then
    # 'up -d' no toca nada si el proyecto ya corre con esta configuración, así
    # que solo se cuenta como cambio si falta algún servicio por levantar. Si no,
    # 'Cambios que se aplicarían: 0' significaría aquí algo distinto que en el
    # resto de capítulos, y el número dejaría de servir para nada.
    SERVICIOS="$( ( cd "${DIR}" && docker compose config --services 2>/dev/null ) \
                  | grep -c . || true )"
    VIVOS="$(compose_en_marcha "${DIR}" | grep -c . || true)"

    log_check "ejecutaría: docker compose up -d --remove-orphans"
    log_check "y esperaría hasta ${ESPERA}s a que los servicios estén sanos"
    if (( SERVICIOS > 0 && VIVOS == SERVICIOS )); then
        log_sinca "Los ${SERVICIOS} servicios ya están en marcha."
        log_aviso "Desde la simulación no se puede saber si hay una imagen nueva"
        log_aviso "esperando: eso solo se averigua descargándola."
    else
        log_check "faltan servicios por levantar (${VIVOS}/${SERVICIOS} en marcha)"
        marcar_cambio
    fi

    resumen_final "deploy(${PROYECTO})"
    exit 0
fi

docker compose -f "${COMPOSE}" up -d --remove-orphans \
    || { revertir; die "El despliegue ha fallado."; }
marcar_cambio

# ===========================================================================
#  6. ESPERA A QUE ESTÉN SANOS
# ===========================================================================
log_paso "6/7 · Comprobación de salud"

# Solo se esperan los servicios que declaran healthcheck: los que no lo tienen
# no dan información útil (capítulo 12 § 3.6).
CONTENEDORES="$(docker compose -f "${COMPOSE}" ps -q)"
CON_SALUD=()
for c in ${CONTENEDORES}; do
    if [[ "$(docker inspect "$c" --format '{{if .Config.Healthcheck}}sí{{end}}')" == "sí" ]]; then
        CON_SALUD+=("$c")
    fi
done

if (( ${#CON_SALUD[@]} == 0 )); then
    log_aviso "Ningún servicio declara healthcheck: no se puede verificar el despliegue."
    log_aviso "Añade uno a cada servicio (capítulo 12 § 3.6)."
else
    log_info "Esperando a ${#CON_SALUD[@]} servicios (hasta ${ESPERA}s)…"
    TRANSCURRIDO=0
    SANOS=0
    while (( TRANSCURRIDO < ESPERA )); do
        SANOS=0
        for c in "${CON_SALUD[@]}"; do
            [[ "$(docker inspect "$c" --format '{{.State.Health.Status}}' 2>/dev/null)" == "healthy" ]] \
                && SANOS=$((SANOS + 1))
        done
        (( SANOS == ${#CON_SALUD[@]} )) && break
        sleep 5
        TRANSCURRIDO=$((TRANSCURRIDO + 5))
        printf '\r          %s/%s sanos (%ss)   ' "${SANOS}" "${#CON_SALUD[@]}" "${TRANSCURRIDO}"
    done
    echo

    if (( SANOS == ${#CON_SALUD[@]} )); then
        log_ok "Todos los servicios están sanos."
    else
        log_error "Solo ${SANOS} de ${#CON_SALUD[@]} servicios están sanos tras ${ESPERA}s."
        echo
        log_error "Registro de los servicios que fallan:"
        for c in "${CON_SALUD[@]}"; do
            ESTADO="$(docker inspect "$c" --format '{{.State.Health.Status}}' 2>/dev/null)"
            [[ "${ESTADO}" == "healthy" ]] && continue
            NOMBRE="$(docker inspect "$c" --format '{{.Name}}' | tr -d '/')"
            log_error "  ── ${NOMBRE} (${ESTADO}) ──"
            docker logs --tail 20 "$c" 2>&1 | sed 's/^/          /' >&2
        done
        revertir
        exit 1
    fi
fi

# ===========================================================================
#  7. RESULTADO
# ===========================================================================
log_paso "7/7 · Estado final"

docker compose -f "${COMPOSE}" ps --format 'table {{.Name}}\t{{.State}}\t{{.Status}}' \
    | sed 's/^/          /'

EXPUESTOS="$(docker compose -f "${COMPOSE}" ps --format '{{.Ports}}' 2>/dev/null | grep -c '0\.0\.0\.0' || true)"
if (( EXPUESTOS == 0 )); then
    log_ok "El proyecto no publica ningún puerto en 0.0.0.0."
else
    log_aviso "El proyecto publica ${EXPUESTOS} puertos en 0.0.0.0. Revísalo."
fi

resumen_final "deploy(${PROYECTO})"

if [[ -n "${DOMINIO_PUBLICO:-}" ]]; then
    echo
    log_info "Comprueba desde internet:"
    log_info "    curl -sI https://${PROYECTO}.${DOMINIO_PUBLICO} | head -3"
fi
