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

Opciones:
  --estado            Tabla completa: valor actual y estado de cada variable.
                      Es lo que se muestra si no indicas nada.
  --faltan            Solo lo que queda por rellenar, con el capítulo y el
                      comando que averigua cada valor.
  --fijar VAR=valor   Escribe (o sustituye) una variable en config/servidor.env
                      conservando comentarios, orden y permisos.
  --ver VAR           Imprime el valor efectivo de una variable, sin más.
  --exportar          Emite líneas 'export VAR="valor"'. Pensado para:
                          eval "$(scripts/variables.sh --exportar)"
                      La vía recomendada, sin embargo, es:
                          source scripts/lib/entorno.sh
  -h, --help          Muestra esta ayuda.

Código de salida:
  0  todo correcto
  1  faltan variables obligatorias (con --estado o --faltan), o error

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
#      [OBLIGATORIA]              → no puede quedarse vacía
#      [SE-DESCUBRE: texto]       → su valor se averigua durante el montaje
#      [CAPITULO: nn]             → dónde se usa o se averigua
#  Así no hay dos listas que mantener sincronizadas: la plantilla es la única
#  fuente de verdad, igual que para los valores.
# ===========================================================================
metadatos() {
    awk '
        /^[[:space:]]*$/ { com = ""; obl = 0; desc = ""; cap = ""; next }
        /^#/ {
            linea = $0
            if (linea ~ /\[OBLIGATORIA\]/)  obl = 1
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
            printf "%s\t%d\t%s\t%s\n", nombre, obl, (desc == "" ? "-" : desc), (cap == "" ? "-" : cap)
            obl = 0; desc = ""; cap = ""
            next
        }
    ' "${NOMAD_CONFIG_EJEMPLO}"
}

# Valor actual de una variable dentro de config/servidor.env, ya expandido
# (algunos valores se componen a partir de otros, como RESTIC_REPO_LOCAL).
valor_actual() {
    local nombre="$1"
    ( set -a
      # shellcheck disable=SC1090
      . "${NOMAD_CONFIG}" 2>/dev/null || true
      set +a
      printf '%s' "${!nombre:-}" )
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
    log_paso "Estado de ${NOMAD_CONFIG}"

    printf '\n  %-30s %-28s %s\n' "VARIABLE" "VALOR ACTUAL" "ESTADO"
    printf '  %-30s %-28s %s\n' "------------------------------" \
           "----------------------------" "------"

    local pendientes=0 nombre obligatoria descubre capitulo valor estado recorte
    while IFS=$'\t' read -r nombre obligatoria descubre capitulo; do
        [[ -n "${nombre}" ]] || continue
        valor="$(valor_actual "${nombre}")"

        if [[ -z "${valor}" ]]; then
            if (( obligatoria == 1 )); then
                estado="${C_ROJO}FALTA${C_FIN}"
                pendientes=$((pendientes + 1))
            elif [[ "${descubre}" != "-" ]]; then
                estado="${C_AMARILLO}pendiente${C_FIN}"
            else
                estado="${C_GRIS}vacía (opcional)${C_FIN}"
            fi
        elif [[ "${valor}" == *CAMBIAME* ]]; then
            estado="${C_ROJO}SIN CAMBIAR${C_FIN}"
            pendientes=$((pendientes + 1))
        else
            estado="${C_VERDE}ok${C_FIN}"
        fi

        recorte="${valor}"
        (( ${#recorte} > 27 )) && recorte="${recorte:0:24}..."
        printf '  %-30s %-28s %b\n' "${nombre}" "${recorte:-(sin valor)}" "${estado}"
        # 'capitulo' se usa en --faltan; aquí se ignora a propósito.
        : "${capitulo}"
    done < <(metadatos)

    echo
    if (( pendientes == 0 )); then
        log_ok "No queda ninguna variable obligatoria por rellenar."
    else
        log_aviso "Variables obligatorias pendientes: ${pendientes}"
        log_aviso "Detalle y cómo obtenerlas:  scripts/variables.sh --faltan"
        return 1
    fi
}

# ===========================================================================
#  --faltan
# ===========================================================================
accion_faltan() {
    exigir_configuracion
    log_paso "Variables pendientes"

    local hay=0 nombre obligatoria descubre capitulo valor
    while IFS=$'\t' read -r nombre obligatoria descubre capitulo; do
        [[ -n "${nombre}" ]] || continue
        valor="$(valor_actual "${nombre}")"
        [[ -n "${valor}" && "${valor}" != *CAMBIAME* ]] && continue
        # Una variable opcional y vacía no es un pendiente: es una decisión.
        (( obligatoria == 0 )) && [[ "${descubre}" == "-" ]] && continue

        hay=1
        echo
        printf '  %s%s%s\n' "${C_NEGRITA}" "${nombre}" "${C_FIN}"
        [[ "${capitulo}" != "-" ]] && printf '    capítulo : %s\n' "${capitulo}"
        if [[ "${descubre}" != "-" ]]; then
            printf '    se obtiene con: %s\n' "${descubre}"
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
    local nombre="$1"
    local valor
    valor="$(valor_actual "${nombre}")"
    if [[ -z "${valor}" ]]; then
        log_error "${nombre} no tiene valor en ${NOMAD_CONFIG}"
        exit 1
    fi
    printf '%s\n' "${valor}"
}

accion_exportar() {
    exigir_configuracion
    local nombre valor
    while IFS=$'\t' read -r nombre _ _ _; do
        [[ -n "${nombre}" ]] || continue
        valor="$(valor_actual "${nombre}")"
        printf 'export %s="%s"\n' "${nombre}" "${valor}"
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
