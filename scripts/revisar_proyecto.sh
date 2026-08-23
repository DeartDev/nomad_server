#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — revisión de un proyecto antes de desplegarlo
#
#  Propósito : contrastar el docker-compose.yml de un proyecto contra las
#              reglas del capítulo 12, y decir qué hay que cambiar ANTES de
#              desplegarlo, no después.
#
#  No modifica nada. Se puede ejecutar sobre un proyecto recién clonado que
#  todavía no cumple ninguna regla: para eso está.
#
#  POR QUÉ PREGUNTA A COMPOSE Y NO LEE EL YAML
#
#  'docker compose config --format json' devuelve la configuración RESUELTA:
#  con las variables sustituidas, los ficheros de superposición fusionados y
#  la sintaxis corta expandida a la larga. Auditar el YAML a mano se equivoca
#  en todos esos casos, y son justo los que se prestan a error.
# ===========================================================================
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

mostrar_ayuda() {
    cat <<'AYUDA'
Uso: ./scripts/revisar_proyecto.sh <nombre-o-ruta>

Revisa un proyecto contra las reglas del capítulo 12 y dice qué falta.

  ./scripts/revisar_proyecto.sh mi-proyecto     # bajo ${DATOS_RAIZ}
  ./scripts/revisar_proyecto.sh /ruta/completa  # en cualquier sitio

Comprueba:
  · que no publica puertos                      (§ 3.2)
  · que no usa volúmenes con nombre             (§ 3.3)
  · que no monta el socket de Docker            (capítulo 10 § 3.2)
  · que el .env existe, es 600 y no versionado  (§ 3.4)
  · que todas las imágenes tienen versión fija  (§ 3.5)
  · que todos los servicios tienen healthcheck  (§ 3.6)
  · que lo no publicado está en red interna     (§ 3.7)
  · que las etiquetas de Traefik son coherentes (capítulo 10)
  · que el nombre de host publicado resuelve    (capítulo 11)
  · que los nombres de router no chocan con otro proyecto

Opciones:
  -h, --help   Muestra esta ayuda.

Código de salida:
  0  el proyecto cumple
  1  hay algo que corregir antes de desplegar
AYUDA
}

DESTINO=""
while (( $# > 0 )); do
    case "$1" in
        -h|--help) mostrar_ayuda; exit 0 ;;
        -*)        die "Opción desconocida: $1 (usa --help)" ;;
        *)         DESTINO="$1" ;;
    esac
    shift
done
[[ -n "${DESTINO}" ]] || { mostrar_ayuda; exit 1; }

cargar_entorno
requerir_variables DATOS_RAIZ DOCKER_RED_PROXY DOMINIO_PUBLICO
requerir_comandos docker jq

# Admite nombre corto o ruta.
if [[ -d "${DESTINO}" ]]; then
    DIR="$(cd "${DESTINO}" && pwd)"
else
    DIR="${DATOS_RAIZ}/${DESTINO}"
fi
PROYECTO="$(basename "${DIR}")"

FALLOS=0
falla() { log_error "$*"; FALLOS=$((FALLOS + 1)); }

log_paso "Revisión de '${PROYECTO}'"
log_info "Directorio: ${DIR}"

[[ -d "${DIR}" ]] || die "No existe ${DIR}"
COMPOSE="${DIR}/docker-compose.yml"
[[ -f "${COMPOSE}" ]] || COMPOSE="${DIR}/compose.yml"
[[ -f "${COMPOSE}" ]] || die "No hay docker-compose.yml ni compose.yml en ${DIR}"

# La configuración resuelta. Si esto falla, no hay nada más que revisar.
CONF="$(cd "${DIR}" && docker compose config --format json 2>/dev/null)" || {
    log_error "El fichero compose no es válido. Docker dice:"
    ( cd "${DIR}" && docker compose config 2>&1 | tail -15 | sed 's/^/          /' >&2 )
    die "Corrige eso antes de seguir."
}
log_ok "El fichero compose es válido."

# ===========================================================================
#  1. Puertos publicados
# ===========================================================================
log_paso "1/8 · Puertos publicados"

PUBLICADOS="$(jq -r '.services | to_entries[]
    | select(.value.ports != null and (.value.ports | length) > 0)
    | "\(.key): \(.value.ports | map(.published // "?" | tostring) | join(", "))"' <<<"${CONF}")"

if [[ -z "${PUBLICADOS}" ]]; then
    log_ok "Ningún servicio publica puertos."
else
    falla "Estos servicios publican puertos en el host:"
    printf '          %s\n' ${PUBLICADOS} >&2
    log_error "En este servidor NADA publica puertos: el acceso público llega por"
    log_error "Traefik a través del túnel, y Docker se salta el cortafuegos."
    log_error "Quita la sección 'ports:' y añade las etiquetas de Traefik."
fi

# ===========================================================================
#  2. Volúmenes y montajes
# ===========================================================================
log_paso "2/8 · Volúmenes y montajes"

CON_NOMBRE="$(jq -r '.volumes // {} | keys[]' <<<"${CONF}" 2>/dev/null || true)"
if [[ -z "${CON_NOMBRE}" ]]; then
    log_ok "No usa volúmenes con nombre."
else
    falla "Usa volúmenes con nombre: $(tr '\n' ' ' <<<"${CON_NOMBRE}")"
    log_error "Los datos van en ./datos dentro del proyecto: así el respaldo del"
    log_error "capítulo 14 los recoge sin configurar nada y se pueden inspeccionar."
fi

SOCKET="$(jq -r '.services | to_entries[]
    | select([.value.volumes // [] | .[]? | .source] | any(. == "/var/run/docker.sock"))
    | .key' <<<"${CONF}")"
if [[ -z "${SOCKET}" ]]; then
    log_ok "No monta el socket de Docker."
else
    falla "Monta /var/run/docker.sock: $(tr '\n' ' ' <<<"${SOCKET}")"
    log_error "Acceso al socket es acceso de root al anfitrión, aunque sea ':ro'."
    log_error "Usa el intermediario del capítulo 10 (socket-proxy)."
fi

FUERA="$(jq -r --arg dir "${DIR}" '.services | to_entries[]
    | .key as $s | (.value.volumes // [])[]?
    | select(.type == "bind")
    | select(.source | startswith($dir) | not)
    | select(.source != "/var/run/docker.sock")
    | "\($s): \(.source)"' <<<"${CONF}")"
if [[ -n "${FUERA}" ]]; then
    log_aviso "Monta rutas de fuera del proyecto:"
    printf '          %s\n' "${FUERA}" >&2
    log_aviso "El respaldo del capítulo 14 NO las recoge si están fuera de ${DATOS_RAIZ}."
fi

# ===========================================================================
#  3. Secretos
# ===========================================================================
log_paso "3/8 · Secretos"

if [[ -f "${DIR}/.env" ]]; then
    PERM="$(stat -c '%a' "${DIR}/.env")"
    if [[ "${PERM}" == "600" ]]; then
        log_ok ".env presente con permisos 600."
    else
        falla ".env tiene permisos ${PERM}; deben ser 600."
    fi
    if grep -q 'CAMBIAME' "${DIR}/.env" 2>/dev/null; then
        falla "El .env todavía tiene valores CAMBIAME sin sustituir."
    fi
    if git -C "${DIR}" rev-parse --git-dir >/dev/null 2>&1; then
        if git -C "${DIR}" check-ignore -q .env 2>/dev/null; then
            log_ok ".env está excluido de git."
        else
            falla ".env NO está en .gitignore: acabará versionado."
        fi
    fi
else
    log_aviso "No hay .env. Si el proyecto no necesita secretos, correcto."
fi

# ===========================================================================
#  4. Versiones de imagen
# ===========================================================================
log_paso "4/8 · Versiones de imagen"

# Se mira el último tramo de la ruta, no la cadena entera: 'registro:5000/app'
# tiene dos puntos en el nombre del registro y no por eso está fijada.
SIN_FIJAR="$(jq -r '.services | to_entries[]
    | select(.value.image != null)
    | select( (.value.image | split("/") | last | test(":") | not)
              or (.value.image | endswith(":latest")) )
    | "\(.key): \(.value.image)"' <<<"${CONF}")"
if [[ -z "${SIN_FIJAR}" ]]; then
    log_ok "Todas las imágenes tienen una versión fija."
else
    falla "Imágenes sin versión fija:"
    printf '          %s\n' "${SIN_FIJAR}" >&2
    log_error "Con 'latest', un despliegue rutinario trae una versión nueva sin"
    log_error "avisar, y el mismo compose produce resultados distintos según el día."
fi

# ===========================================================================
#  5. Healthchecks
# ===========================================================================
log_paso "5/8 · Comprobaciones de salud"

SIN_SALUD="$(jq -r '.services | to_entries[]
    | select(.value.healthcheck == null or .value.healthcheck.disable == true)
    | .key' <<<"${CONF}")"
if [[ -z "${SIN_SALUD}" ]]; then
    log_ok "Todos los servicios declaran healthcheck."
else
    falla "Servicios sin healthcheck: $(tr '\n' ' ' <<<"${SIN_SALUD}")"
    log_error "Un contenedor sin healthcheck siempre parece 'en marcha', aunque su"
    log_error "proceso esté colgado. deploy.sh lo usa para decidir si revertir."
fi

# ===========================================================================
#  6. Redes
# ===========================================================================
log_paso "6/8 · Redes"

PUBLICOS="$(jq -r '.services | to_entries[]
    | select((.value.labels // {}) | to_entries | any(.key == "traefik.enable" and (.value | tostring) == "true"))
    | .key' <<<"${CONF}")"

if [[ -z "${PUBLICOS}" ]]; then
    log_aviso "Ningún servicio tiene 'traefik.enable=true': nada será accesible."
else
    log_ok "Servicios publicados por Traefik: $(tr '\n' ' ' <<<"${PUBLICOS}")"
fi

EN_PROXY="$(jq -r --arg red "${DOCKER_RED_PROXY}" '.services | to_entries[]
    | select((.value.networks // {}) | keys | any(. == "proxy" or . == $red))
    | .key' <<<"${CONF}")"

while read -r servicio; do
    [[ -z "${servicio}" ]] && continue
    if ! grep -qx "${servicio}" <<<"${PUBLICOS}"; then
        log_aviso "'${servicio}' está en la red 'proxy' sin publicarse por Traefik."
        log_aviso "Si no necesita salir, sácalo: lo que no se publica va en red interna."
    fi
done <<<"${EN_PROXY}"

# ===========================================================================
#  7. Etiquetas de Traefik
# ===========================================================================
log_paso "7/8 · Etiquetas de Traefik"

REGLAS="$(jq -r '.services[].labels // {} | to_entries[]
    | select(.key | test("^traefik\\.http\\.routers\\..*\\.rule$"))
    | "\(.key)=\(.value)"' <<<"${CONF}")"

if [[ -z "${REGLAS}" ]]; then
    [[ -n "${PUBLICOS}" ]] && falla "Hay servicios con traefik.enable pero ninguna regla de enrutado."
else
    printf '%s\n' "${REGLAS}" | sed 's/^/          /'

    ROUTERS="$(sed -E 's/^traefik\.http\.routers\.([^.]+)\..*/\1/' <<<"${REGLAS}")"
    # Los nombres de router son globales en todo el servidor: si dos proyectos
    # usan 'web', el segundo pisa al primero sin decir nada.
    if docker ps >/dev/null 2>&1; then
        AJENOS="$(docker ps --format '{{.Labels}}' 2>/dev/null \
            | tr ',' '\n' \
            | sed -nE 's/^traefik\.http\.routers\.([^.]+)\..*/\1/p' \
            | sort -u || true)"
        while read -r r; do
            [[ -z "${r}" ]] && continue
            if grep -qx "${r}" <<<"${AJENOS}" 2>/dev/null; then
                CONTENEDOR="$(docker ps --filter "label=traefik.http.routers.${r}.rule" \
                              --format '{{.Names}}' | head -1)"
                if [[ -n "${CONTENEDOR}" && "${CONTENEDOR}" != "${PROYECTO}"* ]]; then
                    falla "El router '${r}' ya lo usa el contenedor '${CONTENEDOR}'."
                    log_error "Los nombres de router son globales: el segundo pisa al primero."
                    log_error "Usa el nombre del proyecto como prefijo."
                fi
            fi
        done <<<"${ROUTERS}"
    fi

    # ¿Resuelven los nombres de host publicados?
    HOSTS="$(grep -oE 'Host\(`[^`]+`\)' <<<"${REGLAS}" | tr -d '`' | sed 's/^Host(//; s/)$//' || true)"
    while read -r h; do
        [[ -z "${h}" ]] && continue
        if [[ "${h}" == *".${DOMINIO_PUBLICO}" || "${h}" == "${DOMINIO_PUBLICO}" ]]; then
            if [[ -n "$(dig +short "${h}" 2>/dev/null)" ]]; then
                log_ok "${h} resuelve."
            else
                falla "${h} NO resuelve: falta su registro DNS."
                log_error "Créalo con: ./scripts/11_cloudflared.sh --ruta ${h%%.*}"
            fi
        else
            log_sinca "${h} no es del dominio público: se servirá solo por el punto interno."
        fi
    done <<<"${HOSTS}"
fi

# ===========================================================================
#  8. Detalles de robustez
# ===========================================================================
log_paso "8/8 · Robustez"

SIN_REINICIO="$(jq -r '.services | to_entries[]
    | select((.value.restart // "no") == "no")
    | .key' <<<"${CONF}")"
if [[ -z "${SIN_REINICIO}" ]]; then
    log_ok "Todos los servicios tienen política de reinicio."
else
    log_aviso "Sin 'restart': $(tr '\n' ' ' <<<"${SIN_REINICIO}") — no volverán tras un reinicio."
fi

SIN_PRIV="$(jq -r '.services | to_entries[]
    | select(((.value.security_opt // []) | any(. == "no-new-privileges:true")) | not)
    | .key' <<<"${CONF}")"
if [[ -z "${SIN_PRIV}" ]]; then
    log_ok "Todos los servicios llevan no-new-privileges."
else
    log_aviso "Sin 'no-new-privileges:true': $(tr '\n' ' ' <<<"${SIN_PRIV}")"
fi

BASES="$(jq -r '.services | to_entries[]
    | select(.value.image != null)
    | select(.value.image | test("postgres|mysql|mariadb|mongo"; "i"))
    | .key' <<<"${CONF}")"
if [[ -n "${BASES}" ]]; then
    log_aviso "Hay bases de datos: $(tr '\n' ' ' <<<"${BASES}")"
    if compgen -G "/etc/nomad/pre-respaldo.d/*${PROYECTO}*" >/dev/null 2>&1; then
        log_ok "Tiene gancho de volcado para el respaldo."
    else
        falla "No hay gancho de volcado en /etc/nomad/pre-respaldo.d para este proyecto."
        log_error "Sin él se respalda su directorio de datos en caliente, que NO se"
        log_error "puede restaurar. Ver docs/14_respaldos_restic.md § 3.4."
    fi
fi

# ===========================================================================
echo
if (( FALLOS == 0 )); then
    log_ok "'${PROYECTO}' cumple las reglas del capítulo 12."
    log_info "Siguiente paso: ./scripts/deploy.sh ${PROYECTO} --check"
else
    log_error "Hay ${FALLOS} cosas que corregir antes de desplegar."
    log_error "Detalle de cada regla: docs/12_despliegue_de_proyectos.md § 3"
    exit 1
fi
