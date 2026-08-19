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
                      conservando comentarios, orden y permisos.
  --ver VAR           Imprime el valor que la variable tiene EN EL ARCHIVO.
                      Si está vacía ahí pero sí la tienes en la sesión, lo
                      dice: es el caso ENMASCARADA.
  --exportar          Emite líneas 'export VAR="valor"'. Pensado para:
                          eval "$(scripts/variables.sh --exportar)"
                      La vía recomendada, sin embargo, es:
                          source scripts/lib/entorno.sh
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
        # Añadir al final, con una nota de dónde salió.
        cat "${NOMAD_CONFIG}" > "${tmp}"
        {
            echo
            echo "# Añadida por scripts/variables.sh el $(date +%F)"
            printf '%s="%s"\n' "${nombre}" "${valor}"
        } >> "${tmp}"
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
    case "$1" in
        --estado)    ACCION="estado" ;;
        --faltan)    ACCION="faltan" ;;
        --exportar)  ACCION="exportar" ;;
        --fijar)     ACCION="fijar"; ARGUMENTO="${2:-}"; shift ;;
        --ver)       ACCION="ver";   ARGUMENTO="${2:-}"; shift ;;
        -h|--help)   mostrar_ayuda; exit 0 ;;
        *)           die "Opción desconocida: $1 (usa --help)" ;;
    esac
    shift
done

case "${ACCION}" in
    estado)   accion_estado ;;
    faltan)   accion_faltan ;;
    fijar)    [[ -n "${ARGUMENTO}" ]] || die "--fijar necesita NOMBRE=valor"; accion_fijar "${ARGUMENTO}" ;;
    ver)      [[ -n "${ARGUMENTO}" ]] || die "--ver necesita el nombre de una variable"; accion_ver "${ARGUMENTO}" ;;
    exportar) accion_exportar ;;
esac
