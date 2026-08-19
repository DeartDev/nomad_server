#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — validación del repositorio
# ===========================================================================
#  Propósito : comprobar la coherencia interna del repositorio SIN necesidad de
#              un servidor: sintaxis de los scripts, estructura de la
#              documentación, variables declaradas y ausencia de secretos.
#  Uso       : make check     |     scripts/verificar_repositorio.sh [--solo X]
#  Capítulo  : transversal (ver docs/00_planificacion.md § Criterios de "hecho")
#
#  Este script NO modifica nada. Se puede ejecutar siempre, sin privilegios.
# ===========================================================================
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

mostrar_ayuda() {
    cat <<'AYUDA'
Uso: scripts/verificar_repositorio.sh [opciones]

Valida el repositorio de documentación. No modifica nada ni necesita servidor.

Opciones:
  --solo <grupo>   Ejecuta solo un grupo de comprobaciones.
                   Grupos: scripts | docs | secretos | estructura
  -h, --help       Muestra esta ayuda.

Código de salida:
  0  todas las comprobaciones pasaron
  1  al menos una comprobación falló
AYUDA
}

# --- Argumentos --------------------------------------------------------------
SOLO="todo"
while (( $# > 0 )); do
    case "$1" in
        --solo) SOLO="${2:-}"; shift ;;
        -h|--help) mostrar_ayuda; exit 0 ;;
        *) die "Opción desconocida: $1 (usa --help)" ;;
    esac
    shift
done

cd "${NOMAD_RAIZ}"

FALLOS=0
fallo() { log_error "$*"; FALLOS=$((FALLOS + 1)); }

# Secciones obligatorias de todo capítulo (ver docs/00_planificacion.md).
SECCIONES_OBLIGATORIAS=(
    "Objetivo"
    "Requisitos previos"
    "Decisiones y por qué"
    "Variables usadas"
    "Procedimiento"
    "Script asociado"
    "Validación"
    "Reversión"
    "Errores frecuentes"
    "Referencias"
)

# Variables de entorno ajenas a config/servidor.env que pueden aparecer
# legítimamente en los ejemplos de la documentación: variables del sistema,
# nombres genéricos que la propia documentación usa como marcador de posición
# al explicar una regla (VAR, VALOR, LLAVES…), y variables temporales que los
# capítulos declaran en el paso donde hacen falta.
VARIABLES_PERMITIDAS=(
    HOME PATH USER SHELL EDITOR PWD UID EUID HOSTNAME TERM LANG PS1
    BASH_SOURCE FUNCNAME PIPESTATUS RANDOM
    UUID DEVICE INTERFAZ ARCHIVO DISCO PROYECTO DOMINIO SUBDOMINIO
    VERSION ARCH CODENAME FECHA NOMBRE PUERTO IP RUTA
    VARIABLE VARIABLES VAR VALOR LLAVES
    # Variables que pertenecen a OTROS programas o a las propias plantillas, y
    # que la documentación cita precisamente para explicar que NO se sustituyen
    # (ver docs/98_variables_y_entorno.md § 4.4).
    RESTIC_REPOSITORY VERSION_CODENAME POSTGRES_USER POSTGRES_DB
)

# Imprime un archivo Markdown sin el contenido de los bloques de código, para
# que los comentarios de shell (# …) no se confundan con títulos.
sin_bloques_de_codigo() {
    awk '/^```/ { dentro = !dentro; next } !dentro' "$1"
}

# ===========================================================================
#  1. ESTRUCTURA
# ===========================================================================
comprobar_estructura() {
    log_paso "Estructura del repositorio"

    local obligatorios=(
        README.md LICENSE .gitignore Makefile
        config/servidor.env.example
        scripts/lib/common.sh
        scripts/lib/entorno.sh
        scripts/lib/leer_config.sh
    )
    local ruta
    for ruta in "${obligatorios[@]}"; do
        if [[ -e "${ruta}" ]]; then
            log_ok "existe ${ruta}"
        else
            fallo "falta ${ruta}"
        fi
    done

    local dir
    for dir in docs scripts templates checklists config; do
        [[ -d "${dir}" ]] || fallo "falta el directorio ${dir}/"
    done

    # Todo capítulo debe estar enlazado desde el README y viceversa.
    local doc base
    for doc in docs/[0-9]*.md; do
        [[ -e "${doc}" ]] || continue
        base="$(basename "${doc}")"
        if grep -q "${base}" README.md; then
            log_ok "${base} enlazado desde README.md"
        else
            fallo "${base} no aparece en README.md"
        fi
    done

    local enlace
    while read -r enlace; do
        [[ -n "${enlace}" ]] || continue
        if [[ ! -e "${enlace}" ]]; then
            fallo "README.md enlaza a '${enlace}', que no existe"
        fi
    done < <(grep -oE '\]\((docs|scripts|templates|checklists|config)/[^)#]+\)' README.md \
             | sed -E 's/^\]\(//; s/\)$//' | sort -u)
}

# ===========================================================================
#  2. SCRIPTS
# ===========================================================================
comprobar_scripts() {
    log_paso "Scripts"

    # El analizador estático puede estar instalado en el sistema, o ejecutarse
    # en contenedor si ya hay imagen descargada. Nunca se descarga nada.
    local hay_shellcheck=0
    local motor=""
    if command -v shellcheck >/dev/null 2>&1; then
        hay_shellcheck=1
    else
        for motor in podman docker; do
            if command -v "${motor}" >/dev/null 2>&1 \
               && "${motor}" image exists docker.io/koalaman/shellcheck:stable >/dev/null 2>&1; then
                hay_shellcheck=2
                log_info "Usando shellcheck en contenedor (${motor})."
                break
            fi
        done
    fi
    if (( hay_shellcheck == 0 )); then
        log_aviso "shellcheck no está disponible: se omite el análisis estático."
        log_aviso "Instálalo con 'sudo apt install shellcheck' (ver 'make herramientas')."
    fi

    # Ejecuta shellcheck por el medio disponible.
    correr_shellcheck() {
        if (( hay_shellcheck == 1 )); then
            shellcheck -x -S warning "$@"
        else
            "${motor}" run --rm -v "${NOMAD_RAIZ}:/mnt:z" -w /mnt \
                docker.io/koalaman/shellcheck:stable -x -S warning "$@"
        fi
    }

    local script
    while read -r script; do
        [[ -n "${script}" ]] || continue

        # Sintaxis
        if bash -n "${script}" 2>/dev/null; then
            log_ok "sintaxis correcta: ${script}"
        else
            fallo "error de sintaxis en ${script}"
            bash -n "${script}" || true
            continue
        fi

        # Cabecera documental obligatoria
        grep -q 'Propósito' "${script}" || fallo "${script} no tiene cabecera con 'Propósito'"

        # Análisis estático: se aplica también a las bibliotecas
        if (( hay_shellcheck != 0 )); then
            if correr_shellcheck "${script}" >/dev/null 2>&1; then
                log_ok "shellcheck limpio: ${script}"
            else
                fallo "shellcheck reporta hallazgos en ${script}"
                correr_shellcheck "${script}" || true
            fi
        fi

        # Bibliotecas: no necesitan set -euo pipefail ni ser ejecutables
        if [[ "${script}" == scripts/lib/* ]]; then
            continue
        fi

        grep -qE '^set -euo pipefail' "${script}" \
            || fallo "${script} no declara 'set -euo pipefail'"

        [[ -x "${script}" ]] || fallo "${script} no tiene permiso de ejecución (chmod +x)"

        grep -q 'mostrar_ayuda' "${script}" \
            || fallo "${script} no define mostrar_ayuda() (--help es obligatorio)"
    done < <(find scripts -name '*.sh' -type f | sort)
}

# ===========================================================================
#  3. DOCUMENTACIÓN
# ===========================================================================
comprobar_docs() {
    log_paso "Documentación: plantilla de secciones"

    local doc seccion
    for doc in docs/[0-9]*.md; do
        [[ -e "${doc}" ]] || continue

        # Los documentos 9x son anexos transversales (vías de montaje,
        # variables y entorno, glosario), no capítulos de procedimiento: no
        # tienen pasos que ejecutar ni nada que revertir, así que no se les
        # exige la plantilla de 10 secciones.
        if [[ "$(basename "${doc}")" == 9[0-9]_* ]]; then
            log_sinca "$(basename "${doc}") es un anexo: no se le exige la plantilla."
            continue
        fi

        local cuerpo
        cuerpo="$(sin_bloques_de_codigo "${doc}")"

        local faltantes=()
        for seccion in "${SECCIONES_OBLIGATORIAS[@]}"; do
            grep -qE "^## [0-9]+\. ${seccion}" <<<"${cuerpo}" || faltantes+=("${seccion}")
        done

        if (( ${#faltantes[@]} == 0 )); then
            log_ok "$(basename "${doc}") tiene las 10 secciones"
        else
            fallo "$(basename "${doc}") no tiene: ${faltantes[*]}"
        fi

        # Un único título de nivel 1 (ignorando los bloques de código)
        local titulos
        titulos="$(grep -c '^# ' <<<"${cuerpo}" || true)"
        [[ "${titulos}" == "1" ]] \
            || fallo "$(basename "${doc}") tiene ${titulos} títulos de nivel 1 (debe haber exactamente 1)"
    done

    log_paso "Documentación: variables"

    local definidas
    definidas="$(grep -oE '^[A-Z][A-Z0-9_]*=' config/servidor.env.example | tr -d '=' | sort -u)"

    local archivo usadas locales variable
    while read -r archivo; do
        [[ -n "${archivo}" ]] || continue

        # Se descartan primero las secuencias '$${VAR}': en un fichero compose
        # ese doble dólar es el escape que deja la variable para el contenedor,
        # no para envsubst.
        usadas="$(sed -E 's/\$\$\{[A-Z][A-Z0-9_]*\}//g' "${archivo}" 2>/dev/null \
                  | grep -ohE '\$\{[A-Z][A-Z0-9_]*\}' \
                  | sed -E 's/^\$\{//; s/\}$//' | sort -u || true)"

        # Variables asignadas dentro del propio archivo (ejemplos de shell que
        # definen su variable antes de usarla). No tienen que estar en la
        # plantilla de configuración.
        locales="$(grep -ohE '(^|[[:space:](])[A-Z][A-Z0-9_]*=' "${archivo}" 2>/dev/null \
                   | tr -d ' (=' | sort -u || true)"

        for variable in ${usadas}; do
            grep -qx "${variable}" <<<"${definidas}" && continue
            grep -qx "${variable}" <<<"${locales}" && continue
            printf '%s\n' "${VARIABLES_PERMITIDAS[@]}" | grep -qx "${variable}" && continue
            fallo "${archivo}: \${${variable}} no está en config/servidor.env.example ni se define en el propio archivo"
        done
    done < <(find docs templates -type f \( -name '*.md' -o -name '*.cfg' -o -name '*.yml' -o -name '*.conf' \) | sort)

    log_ok "variables usadas en docs/ y templates/ contrastadas con la plantilla"

    log_paso "Documentación: contrato de las variables"

    # Toda variable que un script exige con requerir_variables debe llevar una
    # etiqueta en la plantilla ([OBLIGATORIA], [REQUERIDA] o [SE-DESCUBRE]).
    # Sin esta comprobación, la plantilla puede prometer que 'variables.sh
    # --faltan' avisa de lo que falta y no hacerlo: fue exactamente lo que
    # ocurrió con SERVIDOR_LOCALE, DEBIAN_MIRROR y DEBIAN_SUITE.
    local etiquetadas
    etiquetadas="$(awk '
        /^[[:space:]]*$/ { et = 0; next }
        /^#/ {
            if ($0 ~ /\[OBLIGATORIA\]|\[REQUERIDA\]|\[SE-DESCUBRE:/) et = 1
            next
        }
        /^[A-Z][A-Z0-9_]*=/ {
            if (et) { nombre = $0; sub(/=.*/, "", nombre); print nombre }
            et = 0; next
        }
    ' config/servidor.env.example | sort -u)"

    # Nombres exigidos por los scripts. Se extraen de las llamadas a
    # requerir_variables, incluidas sus continuaciones de línea.
    local exigidas
    exigidas="$(sed -n '/requerir_variables/,/[^\\]$/p' scripts/*.sh \
        | tr ' ' '\n' \
        | grep -oE '^[A-Z][A-Z0-9_]+$' | sort -u)"

    local sin_etiqueta=() variable
    while IFS= read -r variable; do
        [[ -n "${variable}" ]] || continue
        grep -qx "${variable}" <<<"${etiquetadas}" || sin_etiqueta+=("${variable}")
    done <<<"${exigidas}"

    if (( ${#sin_etiqueta[@]} == 0 )); then
        log_ok "toda variable exigida por un script está etiquetada en la plantilla"
    else
        fallo "variables exigidas por algún script y sin etiquetar en config/servidor.env.example:"
        fallo "    ${sin_etiqueta[*]}"
        fallo "    Añádeles [OBLIGATORIA], [REQUERIDA] o [SE-DESCUBRE: …]"
    fi

    log_paso "Documentación: enlaces"

    if command -v lychee >/dev/null 2>&1; then
        if lychee --no-progress --offline docs/ README.md >/dev/null 2>&1; then
            log_ok "enlaces internos correctos"
        else
            fallo "hay enlaces internos rotos (ejecuta: lychee --offline docs/ README.md)"
        fi
    else
        # Verificación mínima sin dependencias: enlaces relativos entre capítulos.
        local origen destino
        while read -r origen destino; do
            [[ -n "${destino}" ]] || continue
            if [[ ! -e "docs/${destino}" && ! -e "${destino}" ]]; then
                fallo "${origen} enlaza a '${destino}', que no existe"
            fi
        done < <(grep -roE '\]\([0-9A-Za-z_./-]+\.md\)' docs/ \
                 | sed -E 's/:\]\(/ /; s/\)$//' || true)
        log_ok "enlaces relativos entre capítulos verificados"
        log_aviso "lychee no está instalado: no se comprueban los enlaces externos."
    fi

    log_paso "Documentación: marcadores pendientes"

    # Se ignoran los bloques de código y el código en línea: ahí un "XXX MB" o
    # un echo "REINICIO PENDIENTE" son contenido legítimo, no una tarea sin
    # terminar.
    local hay_marcadores=0
    for doc in docs/*.md README.md checklists/*.md; do
        [[ -e "${doc}" ]] || continue
        if sin_bloques_de_codigo "${doc}" \
             | sed 's/`[^`]*`//g' \
             | grep -nE '\b(TODO|TBD|FIXME|XXX)\b|\bPENDIENTE:' ; then
            fallo "${doc} contiene marcadores pendientes (arriba)"
            hay_marcadores=1
        fi
    done
    (( hay_marcadores == 0 )) && log_ok "sin marcadores pendientes"
}

# ===========================================================================
#  4. SECRETOS
# ===========================================================================
comprobar_secretos() {
    log_paso "Secretos"

    # config/servidor.env nunca debe estar versionado.
    if git ls-files --error-unmatch config/servidor.env >/dev/null 2>&1; then
        fallo "¡config/servidor.env está versionado en git! Elimínalo del índice."
    else
        log_ok "config/servidor.env no está versionado"
    fi

    # Patrones de material sensible en archivos versionados.
    # Se exige una longitud mínima para que los marcadores de la documentación
    # (tskey-auth-XXXXX, CAMBIAME) no se confundan con credenciales reales.
    local patrones=(
        'BEGIN (RSA|OPENSSH|EC|PGP) PRIVATE KEY'
        'AccountTag'
        'TunnelSecret'
        'tskey-[a-z]+-[A-Za-z0-9]{16,}'
        'ghp_[A-Za-z0-9]{20,}'
        'AKIA[0-9A-Z]{16}'
    )
    local patron encontrado=0
    for patron in "${patrones[@]}"; do
        if git grep -InE "${patron}" -- ':!*.example' ':!scripts/verificar_repositorio.sh' >/dev/null 2>&1; then
            fallo "posible secreto versionado (patrón: ${patron})"
            git grep -InE "${patron}" -- ':!*.example' ':!scripts/verificar_repositorio.sh' || true
            encontrado=1
        fi
    done
    (( encontrado == 0 )) && log_ok "no se han encontrado secretos versionados"

    # Permisos del archivo de configuración local, si existe.
    if [[ -f config/servidor.env ]]; then
        local permisos
        permisos="$(stat -c '%a' config/servidor.env)"
        if [[ "${permisos}" == "600" ]]; then
            log_ok "config/servidor.env tiene permisos 600"
        else
            fallo "config/servidor.env tiene permisos ${permisos}; deben ser 600"
        fi
    fi
}

# ===========================================================================
#  EJECUCIÓN
# ===========================================================================
case "${SOLO}" in
    todo)        comprobar_estructura; comprobar_scripts; comprobar_docs; comprobar_secretos ;;
    estructura)  comprobar_estructura ;;
    scripts)     comprobar_scripts ;;
    docs)        comprobar_docs ;;
    secretos)    comprobar_secretos ;;
    *)           die "Grupo desconocido: '${SOLO}'. Usa: scripts | docs | secretos | estructura" ;;
esac

echo
if (( FALLOS == 0 )); then
    log_ok "Todas las comprobaciones han pasado."
    exit 0
fi
log_error "Comprobaciones fallidas: ${FALLOS}"
exit 1
