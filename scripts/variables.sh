#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — estado y edición de config/servidor.env
# ===========================================================================
#  Propósito : responder, en cualquier momento del montaje, a las tres
#              preguntas que más se repiten al retomar el trabajo tras una
#              pausa o un reinicio:
#                 · ¿qué variables tengo ya rellenas?
#                 · ¿cuáles faltan y en qué capítulo se averigua su valor?
#                 · ¿cómo escribo un valor que acabo de descubrir?
#  Uso       : scripts/variables.sh [--estado|--faltan|--fijar VAR=valor|…]
#  Capítulo  : docs/98_variables_y_entorno.md
#
#  No necesita root ni servidor: opera solo sobre config/servidor.env.
# ===========================================================================
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

mostrar_ayuda() {
    cat <<'AYUDA'
Uso: scripts/variables.sh [opción]

Inspecciona y edita config/servidor.env sin abrir un editor.

Todo lo que informa este script se refiere al CONTENIDO DEL ARCHIVO, no a las
variables de tu sesión. Es la diferencia que importa: los scripts se ejecutan
con sudo, que limpia el entorno, así que solo ven el archivo. Una variable
exportada a mano funciona en tus comandos y no existe para ellos.

Opciones:
  --estado            Tabla completa: valor en el archivo y estado de cada
                      variable. Es lo que se muestra si no indicas nada.
                      Señala como ENMASCARADA la que tiene valor en tu sesión
                      pero no en el archivo.
  --faltan            Solo lo que queda por rellenar, con el capítulo y el
                      comando que averigua cada valor.
  --fijar VAR=valor   Escribe (o sustituye) una variable en config/servidor.env
                      conservando comentarios, orden y permisos. Si la clave no
                      existía, se inserta en la posición que ocupa en la
                      plantilla: añadirla al final rompería cualquier variable
                      anterior que la referencie.
  --reordenar         Reescribe el archivo siguiendo la estructura de la
                      plantilla, conservando tus valores tal cual (una variable
                      derivada sigue siendo derivada). Muestra las diferencias
                      y pide confirmación. Admite --check y --si.
  --ver VAR           Imprime el valor que la variable tiene EN EL ARCHIVO.
                      Si está vacía ahí pero sí la tienes en la sesión, lo
                      dice: es el caso ENMASCARADA.
  --exportar          Emite líneas 'export VAR="valor"'. Pensado para:
                          eval "$(scripts/variables.sh --exportar)"
                      La vía recomendada, sin embargo, es:
                          source scripts/lib/entorno.sh
  -n, --check         Con --reordenar: muestra las diferencias sin aplicarlas.
  -y, --si            No pide confirmación.
  -h, --help          Muestra esta ayuda.

Etiquetas de la plantilla config/servidor.env.example:
  [OBLIGATORIA]       hay que decidirla; no trae un valor útil por omisión
  [REQUERIDA]         un script la exige; trae valor por omisión que funciona,
                      pero no puede quedarse vacía
  [SE-DESCUBRE: cmd]  se averigua durante el montaje, con ese comando

Código de salida:
  0  todo correcto
  1  faltan variables, hay alguna enmascarada, o error

Ejemplos:
  scripts/variables.sh --faltan
  scripts/variables.sh --fijar CF_TUNEL_ID=8a1b2c3d-4e5f-6789-abcd-ef0123456789
  scripts/variables.sh --fijar 'LAN_DNS=192.168.1.1 1.1.1.1'
  scripts/variables.sh --ver DATOS_RAIZ
AYUDA
}

# ===========================================================================
#  Metadatos: se leen de la propia plantilla
# ===========================================================================
#  La plantilla config/servidor.env.example marca cada variable con etiquetas
#  en sus comentarios:
#      [OBLIGATORIA]              → hay que decidirla; no trae valor útil
#      [REQUERIDA]                → un script la exige; trae valor por omisión
#                                   que funciona, pero no puede quedarse vacía
#      [SE-DESCUBRE: texto]       → su valor se averigua durante el montaje
#      [CAPITULO: nn]             → dónde se usa o se averigua
#
#  Así no hay dos listas que mantener sincronizadas: la plantilla es la única
#  fuente de verdad, igual que para los valores. Y 'make check' comprueba que
#  toda variable exigida por algún script lleve una de las tres primeras
#  etiquetas, de modo que la promesa no se puede desincronizar en silencio.
# ===========================================================================
metadatos() {
    awk '
        /^[[:space:]]*$/ { clase = ""; desc = ""; cap = ""; next }
        /^#/ {
            linea = $0
            if (linea ~ /\[OBLIGATORIA\]/) clase = "OBLIGATORIA"
            if (linea ~ /\[REQUERIDA\]/ && clase == "") clase = "REQUERIDA"
            if (linea ~ /\[SE-DESCUBRE:/) {
                desc = linea
                sub(/.*\[SE-DESCUBRE:[[:space:]]*/, "", desc)
                sub(/\].*/, "", desc)
            }
            if (linea ~ /\[CAPITULO:/) {
                cap = linea
                sub(/.*\[CAPITULO:[[:space:]]*/, "", cap)
                sub(/\].*/, "", cap)
            }
            next
        }
        /^[A-Z][A-Z0-9_]*=/ {
            nombre = $0
            sub(/=.*/, "", nombre)
            efectiva = (desc != "" ? "DESCUBRE" : (clase != "" ? clase : "OPCIONAL"))
            printf "%s\t%s\t%s\t%s\n", nombre, efectiva, (desc == "" ? "-" : desc), (cap == "" ? "-" : cap)
            clase = ""; desc = ""; cap = ""
            next
        }
    ' "${NOMAD_CONFIG_EJEMPLO}"
}

# Nombres declarados en la plantilla, en orden.
nombres_declarados() { metadatos | cut -f1; }

# ===========================================================================
#  Valores: los del ARCHIVO, no los del entorno
# ===========================================================================
#  Esta es la corrección más importante de este script. Antes se leía el
#  archivo dentro de un subshell, que hereda el entorno del shell padre: una
#  variable exportada a mano —cosa habitual durante un montaje manual— se
#  contaba como si estuviera en el archivo. El resultado era que este script
#  daba por buena una configuración incompleta, y luego 'sudo ./scripts/…'
#  fallaba con una lista de variables que aquí aparecían rellenas.
#
#  nomad_leer_config lee el archivo en un entorno vacío, así que informa de lo
#  mismo que verá un script ejecutado con sudo.
# ===========================================================================
declare -A VALOR_ARCHIVO=()
declare -A VALOR_ENTORNO=()

cargar_valores() {
    local nombres=() linea nombre
    mapfile -t nombres < <(nombres_declarados)
    (( ${#nombres[@]} > 0 )) || return 0

    while IFS= read -r linea; do
        nombre="${linea%%=*}"
        VALOR_ARCHIVO["${nombre}"]="${linea#*=}"
    done < <(nomad_leer_config "${NOMAD_CONFIG}" "${nombres[@]}")

    # Y el valor que tiene ahora mismo tu sesión, para poder señalar las
    # discrepancias en lugar de esconderlas.
    for nombre in "${nombres[@]}"; do
        VALOR_ENTORNO["${nombre}"]="${!nombre:-}"
    done
}

# Estado de una variable: ok | FALTA | pendiente | opcional | ENMASCARADA
estado_de() {
    local nombre="$1" clase="$2"
    local archivo="${VALOR_ARCHIVO[${nombre}]:-}"
    local entorno="${VALOR_ENTORNO[${nombre}]:-}"

    if [[ -n "${archivo}" ]]; then
        [[ "${archivo}" == *CAMBIAME* ]] && { echo "SIN CAMBIAR"; return; }
        echo "ok"; return
    fi
    # Vacía en el archivo. ¿La está tapando el entorno?
    if [[ -n "${entorno}" ]]; then echo "ENMASCARADA"; return; fi
    case "${clase}" in
        OBLIGATORIA|REQUERIDA) echo "FALTA" ;;
        DESCUBRE)              echo "pendiente" ;;
        *)                     echo "opcional" ;;
    esac
}

exigir_configuracion() {
    if [[ ! -r "${NOMAD_CONFIG}" ]]; then
        log_error "No existe ${NOMAD_CONFIG}"
        log_error "Créalo con:  make init      (o: cp ${NOMAD_CONFIG_EJEMPLO} ${NOMAD_CONFIG} && chmod 600 …)"
        exit 1
    fi
}

# ===========================================================================
#  --estado
# ===========================================================================
accion_estado() {
    exigir_configuracion
    cargar_valores
    log_paso "Estado de ${NOMAD_CONFIG}"
    log_info "Se muestra el valor que tiene el ARCHIVO, que es el que verán los"
    log_info "scripts al ejecutarse con sudo. Tu entorno actual no cuenta."

    printf '\n  %-30s %-28s %s\n' "VARIABLE" "VALOR EN EL ARCHIVO" "ESTADO"
    printf '  %-30s %-28s %s\n' "------------------------------" \
           "----------------------------" "------"

    local rotas=0 enmascaradas=0 sin_cambiar=0 nombre clase descubre capitulo valor estado color recorte
    while IFS=$'\t' read -r nombre clase descubre capitulo; do
        [[ -n "${nombre}" ]] || continue
        valor="${VALOR_ARCHIVO[${nombre}]:-}"
        estado="$(estado_de "${nombre}" "${clase}")"

        case "${estado}" in
            ok)           color="${C_VERDE}" ;;
            pendiente)    color="${C_AMARILLO}" ;;
            opcional)     color="${C_GRIS}"; estado="vacía (opcional)" ;;
            ENMASCARADA)  color="${C_ROJO}"; enmascaradas=$((enmascaradas + 1)) ;;
            "SIN CAMBIAR") color="${C_ROJO}"; sin_cambiar=$((sin_cambiar + 1)) ;;
            *)            color="${C_ROJO}"; rotas=$((rotas + 1)) ;;
        esac

        recorte="${valor}"
        (( ${#recorte} > 27 )) && recorte="${recorte:0:24}..."
        printf '  %-30s %-28s %b\n' "${nombre}" "${recorte:-(sin valor)}" "${color}${estado}${C_FIN}"
        : "${descubre}" "${capitulo}"
    done < <(metadatos)

    echo
    if (( enmascaradas > 0 )); then
        log_error "Variables ENMASCARADAS: ${enmascaradas}"
        log_error "Tienen valor en tu sesión pero NO en el archivo. Los comandos que"
        log_error "escribas ahora funcionarán; los scripts con sudo, no. Y al cerrar"
        log_error "la terminal se pierden. Escríbelas con --fijar."
    fi
    if (( rotas > 0 )); then
        log_aviso "Variables vacías que algún script exige: ${rotas}"
    fi
    if (( sin_cambiar > 0 )); then
        log_aviso "Variables que conservan el valor de ejemplo: ${sin_cambiar}"
    fi
    if (( rotas == 0 && enmascaradas == 0 && sin_cambiar == 0 )); then
        log_ok "El archivo está completo para todo lo hecho hasta ahora."
        return 0
    fi
    log_aviso "Detalle y cómo obtenerlas:  scripts/variables.sh --faltan"
    return 1
}

# ===========================================================================
#  --faltan
# ===========================================================================
accion_faltan() {
    exigir_configuracion
    cargar_valores
    log_paso "Variables pendientes"

    local hay=0 nombre clase descubre capitulo estado
    while IFS=$'\t' read -r nombre clase descubre capitulo; do
        [[ -n "${nombre}" ]] || continue
        estado="$(estado_de "${nombre}" "${clase}")"
        case "${estado}" in
            ok|opcional) continue ;;
        esac

        hay=1
        echo
        printf '  %s%s%s' "${C_NEGRITA}" "${nombre}" "${C_FIN}"
        case "${estado}" in
            ENMASCARADA)  printf '  %s← tiene valor en tu sesión, pero NO en el archivo%s\n' "${C_ROJO}" "${C_FIN}" ;;
            "SIN CAMBIAR") printf '  %s← conserva el valor de ejemplo%s\n' "${C_ROJO}" "${C_FIN}" ;;
            *)            printf '\n' ;;
        esac

        [[ "${capitulo}" != "-" ]] && printf '    capítulo : %s\n' "${capitulo}"
        if [[ "${estado}" == "ENMASCARADA" ]]; then
            printf '    valor en tu sesión: %s\n' "${VALOR_ENTORNO[${nombre}]:-}"
            printf '    se fija con   : scripts/variables.sh --fijar %s="%s"\n' \
                   "${nombre}" "${VALOR_ENTORNO[${nombre}]:-}"
            continue
        fi
        if [[ "${descubre}" != "-" ]]; then
            printf '    se obtiene con: %s\n' "${descubre}"
        elif [[ "${clase}" == "REQUERIDA" ]]; then
            printf '    trae valor por omisión en la plantilla: cópialo de\n'
            printf '                    %s\n' "${NOMAD_CONFIG_EJEMPLO}"
        else
            printf '    se decide en la planificación (capítulo 00)\n'
        fi
        printf '    se fija con   : scripts/variables.sh --fijar %s=<valor>\n' "${nombre}"
    done < <(metadatos)

    echo
    if (( hay == 0 )); then
        log_ok "No falta ninguna variable."
        return 0
    fi
    log_aviso "Rellena lo anterior antes de seguir con el capítulo correspondiente."
    return 1
}

# ===========================================================================
#  Orden del archivo
# ===========================================================================
#  El orden importa: config/servidor.env lo lee bash de arriba abajo, y varias
#  variables se componen a partir de otras
#
#      TRAEFIK_DASHBOARD_HOST="traefik.${SERVIDOR_HOSTNAME}.${SERVIDOR_DOMINIO_LOCAL}"
#
#  Si una clave nueva se añadiera al final, toda variable anterior que la
#  referencie se evaluaría con ella todavía vacía, y el resultado sería un
#  valor malformado —'traefik.nomad.'— que no da ningún error. Por eso las
#  claves nuevas se insertan en la posición que ocupan en la plantilla.
# ===========================================================================

# Línea del archivo tras la cual debe insertarse una clave nueva, según el
# orden de la plantilla. Devuelve 0 si debe ir antes de la primera variable.
posicion_para() {
    local nombre="$1"
    local orden=() previas=() k n
    mapfile -t orden < <(grep -oE '^[A-Z][A-Z0-9_]*=' "${NOMAD_CONFIG_EJEMPLO}" | tr -d '=')

    for k in "${orden[@]}"; do
        [[ "${k}" == "${nombre}" ]] && break
        previas+=("${k}")
    done

    # De la más cercana a la más lejana: la primera que exista manda.
    local i
    for (( i = ${#previas[@]} - 1; i >= 0; i-- )); do
        n="$(grep -n "^${previas[i]}=" "${NOMAD_CONFIG}" | head -1 | cut -d: -f1)"
        if [[ -n "${n}" ]]; then printf '%s\n' "${n}"; return 0; fi
    done
    printf '0\n'
}

# ===========================================================================
#  --reordenar
# ===========================================================================
#  Reescribe config/servidor.env siguiendo la estructura de la plantilla y
#  conservando TUS valores tal cual están escritos, sin expandirlos: una
#  variable derivada sigue siendo derivada.
#
#  Sirve para dos cosas: recolocar claves que quedaron fuera de sitio, y
#  recuperar los comentarios de la plantilla cuando esta se amplía.
# ===========================================================================
accion_reordenar() {
    exigir_configuracion

    local -A crudo=()
    local linea nombre
    while IFS= read -r linea; do
        [[ "${linea}" =~ ^([A-Z][A-Z0-9_]*)= ]] || continue
        nombre="${BASH_REMATCH[1]}"
        [[ -v "crudo[${nombre}]" ]] || crudo["${nombre}"]="${linea#*=}"
    done < "${NOMAD_CONFIG}"

    local tmp agregadas=() extras=()
    tmp="$(mktemp)"

    local -A vistas=()
    while IFS= read -r linea; do
        if [[ "${linea}" =~ ^([A-Z][A-Z0-9_]*)= ]]; then
            nombre="${BASH_REMATCH[1]}"
            vistas["${nombre}"]=1
            if [[ -v "crudo[${nombre}]" ]]; then
                printf '%s=%s\n' "${nombre}" "${crudo[${nombre}]}" >> "${tmp}"
            else
                printf '%s=""\n' "${nombre}" >> "${tmp}"
                agregadas+=("${nombre}")
            fi
        else
            printf '%s\n' "${linea}" >> "${tmp}"
        fi
    done < "${NOMAD_CONFIG_EJEMPLO}"

    # Claves tuyas que la plantilla no conoce: se conservan al final.
    for nombre in "${!crudo[@]}"; do
        [[ -v "vistas[${nombre}]" ]] && continue
        extras+=("${nombre}")
    done
    if (( ${#extras[@]} > 0 )); then
        {
            echo
            echo "# ---------------------------------------------------------------------------"
            echo "# Variables propias, ajenas a config/servidor.env.example"
            echo "# ---------------------------------------------------------------------------"
            for nombre in $(printf '%s\n' "${extras[@]}" | sort); do
                printf '%s=%s\n' "${nombre}" "${crudo[${nombre}]}"
            done
        } >> "${tmp}"
    fi

    log_paso "Reordenar ${NOMAD_CONFIG} según la plantilla"
    if cmp -s "${NOMAD_CONFIG}" "${tmp}"; then
        rm -f "${tmp}"
        log_ok "El archivo ya sigue el orden y la estructura de la plantilla."
        return 0
    fi

    log_info "Diferencias que se aplicarían (los valores no cambian, solo su sitio):"
    diff -u "${NOMAD_CONFIG}" "${tmp}" | sed 's/^/    /' || true
    (( ${#agregadas[@]} > 0 )) && log_aviso "Se añaden vacías: ${agregadas[*]}"
    (( ${#extras[@]} > 0 ))   && log_info  "Se conservan al final: ${extras[*]}"

    if (( MODO_CHECK == 1 )); then
        rm -f "${tmp}"
        log_check "Simulación: no se ha modificado nada."
        return 0
    fi
    if ! confirmar "¿Reescribir ${NOMAD_CONFIG} con este orden?"; then
        rm -f "${tmp}"
        log_info "No se ha tocado nada."
        return 1
    fi

    respaldar_archivo "${NOMAD_CONFIG}"
    cat "${tmp}" > "${NOMAD_CONFIG}"
    rm -f "${tmp}"
    chmod 600 "${NOMAD_CONFIG}"
    log_ok "Archivo reordenado. Recarga el entorno:"
    log_ok "    source ${NOMAD_RAIZ}/scripts/lib/entorno.sh"
}

# ===========================================================================
#  --fijar
# ===========================================================================
accion_fijar() {
    exigir_configuracion
    local asignacion="$1"

    if [[ "${asignacion}" != *=* ]]; then
        die "Formato incorrecto: '${asignacion}'. Se espera NOMBRE=valor."
    fi

    local nombre="${asignacion%%=*}"
    local valor="${asignacion#*=}"

    if [[ ! "${nombre}" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
        die "Nombre de variable no válido: '${nombre}' (mayúsculas, dígitos y '_')."
    fi

    # Aviso, no error: puede que estés añadiendo una variable propia.
    if ! grep -qE "^${nombre}=" "${NOMAD_CONFIG_EJEMPLO}"; then
        log_aviso "'${nombre}' no aparece en ${NOMAD_CONFIG_EJEMPLO}."
        log_aviso "Se escribirá igualmente, pero comprueba que no es una errata."
    fi

    respaldar_archivo "${NOMAD_CONFIG}"

    local tmp
    tmp="$(mktemp)"
    if grep -qE "^${nombre}=" "${NOMAD_CONFIG}"; then
        # Sustituir en su sitio, conservando el orden y los comentarios.
        awk -v n="${nombre}" -v v="${valor}" '
            $0 ~ "^" n "=" { printf "%s=\"%s\"\n", n, v; hecho = 1; next }
            { print }
            END { if (!hecho) printf "%s=\"%s\"\n", n, v }
        ' "${NOMAD_CONFIG}" > "${tmp}"
    else
        # Insertar en la posición que ocupa en la plantilla. Añadirla al final
        # rompería cualquier variable anterior que la referencie.
        local tras
        tras="$(posicion_para "${nombre}")"
        awk -v n="${nombre}" -v v="${valor}" -v tras="${tras}" -v fecha="$(date +%F)" '
            NR == tras {
                print
                printf "\n# Añadida por scripts/variables.sh el %s\n", fecha
                printf "%s=\"%s\"\n", n, v
                hecho = 1
                next
            }
            tras == 0 && !hecho && /^[A-Z][A-Z0-9_]*=/ {
                printf "# Añadida por scripts/variables.sh el %s\n", fecha
                printf "%s=\"%s\"\n\n", n, v
                hecho = 1
            }
            { print }
            END {
                if (!hecho) {
                    printf "\n# Añadida por scripts/variables.sh el %s\n", fecha
                    printf "%s=\"%s\"\n", n, v
                }
            }
        ' "${NOMAD_CONFIG}" > "${tmp}"
        log_info "Clave nueva: se inserta en el orden de la plantilla, no al final."
    fi

    cat "${tmp}" > "${NOMAD_CONFIG}"
    rm -f "${tmp}"
    chmod 600 "${NOMAD_CONFIG}"

    log_ok "${nombre}=\"${valor}\" escrito en ${NOMAD_CONFIG}"
    log_info "Si tienes una sesión con el entorno cargado, recárgalo:"
    log_info "    source ${NOMAD_RAIZ}/scripts/lib/entorno.sh"
}

# ===========================================================================
#  --ver / --exportar
# ===========================================================================
accion_ver() {
    exigir_configuracion
    local nombre="$1" linea valor
    linea="$(nomad_leer_config "${NOMAD_CONFIG}" "${nombre}")" || {
        log_error "No se puede leer ${NOMAD_CONFIG}"; exit 1; }
    valor="${linea#*=}"
    if [[ -z "${valor}" ]]; then
        log_error "${nombre} no tiene valor en ${NOMAD_CONFIG}"
        if [[ -n "${!nombre:-}" ]]; then
            log_error "Ojo: sí lo tiene en tu sesión ('${!nombre}'), pero eso no cuenta:"
            log_error "los scripts leen el archivo. Escríbelo con --fijar."
        fi
        exit 1
    fi
    printf '%s\n' "${valor}"
}

accion_exportar() {
    exigir_configuracion
    cargar_valores
    local nombre
    while IFS=$'\t' read -r nombre _ _ _; do
        [[ -n "${nombre}" ]] || continue
        printf 'export %s="%s"\n' "${nombre}" "${VALOR_ARCHIVO[${nombre}]:-}"
    done < <(metadatos)
}

# ===========================================================================
#  Argumentos
# ===========================================================================
ACCION="estado"
ARGUMENTO=""

while (( $# > 0 )); do
    # MODO_SI no se lee en este archivo: lo consulta confirmar(), definida en
    # lib/common.sh, cuando --reordenar pide confirmación.
    # shellcheck disable=SC2034
    case "$1" in
        --estado)    ACCION="estado" ;;
        --reordenar) ACCION="reordenar" ;;
        --faltan)    ACCION="faltan" ;;
        --exportar)  ACCION="exportar" ;;
        --fijar)     ACCION="fijar"; ARGUMENTO="${2:-}"; shift ;;
        --ver)       ACCION="ver";   ARGUMENTO="${2:-}"; shift ;;
        -n|--check)  MODO_CHECK=1 ;;
        -y|--si)     MODO_SI=1 ;;
        -h|--help)   mostrar_ayuda; exit 0 ;;
        *)           die "Opción desconocida: $1 (usa --help)" ;;
    esac
    shift
done

case "${ACCION}" in
    estado)    accion_estado ;;
    reordenar) accion_reordenar ;;
    faltan)   accion_faltan ;;
    fijar)    [[ -n "${ARGUMENTO}" ]] || die "--fijar necesita NOMBRE=valor"; accion_fijar "${ARGUMENTO}" ;;
    ver)      [[ -n "${ARGUMENTO}" ]] || die "--ver necesita el nombre de una variable"; accion_ver "${ARGUMENTO}" ;;
    exportar) accion_exportar ;;
esac
