#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — carga del entorno en una sesión interactiva
# ===========================================================================
#  Propósito : dejar disponibles en TU shell las variables de
#              config/servidor.env, para que los comandos de la documentación
#              que usan ${VARIABLE} funcionen al copiarlos y pegarlos.
#
#  Uso       : source ~/nomad_server/scripts/lib/entorno.sh
#              (también vale:  . ~/nomad_server/scripts/lib/entorno.sh)
#
#  Capítulo  : docs/98_variables_y_entorno.md
#
#  POR QUÉ EXISTE ESTE ARCHIVO
#  ---------------------------
#  Los scripts de scripts/ cargan config/servidor.env por su cuenta, así que
#  no necesitan nada de esto. Pero cuando ejecutas los pasos A MANO, tu shell
#  no sabe nada de ese archivo: un comando como
#
#      sudo hostnamectl set-hostname ${SERVIDOR_HOSTNAME}
#
#  se expandiría a una cadena vacía y fallaría, o —peor— haría algo distinto
#  de lo previsto sin avisar. Este archivo evita ese problema.
#
#  Y HAY QUE VOLVER A EJECUTARLO...
#  --------------------------------
#  ...cada vez que empiezas una sesión nueva: al reconectar por SSH, tras un
#  reinicio del servidor, al abrir otra terminal, al abrir una ventana nueva
#  de tmux o al entrar por consola física. Las variables de entorno viven en
#  el proceso del shell y mueren con él. No hay ningún estado persistente.
#
#  DIFERENCIAS CON lib/common.sh
#  -----------------------------
#  common.sh está pensado para scripts: usa 'exit' para abortar y asume
#  'set -euo pipefail'. Si se importara en una sesión interactiva, un fallo
#  cerraría tu terminal (y con ella tu sesión SSH). Este archivo es
#  deliberadamente independiente: nunca llama a 'exit' ni activa 'set -e'.
#
#  Este archivo NO se ejecuta directamente: solo se importa con 'source'.
# ===========================================================================

# --- Guarda: impedir la ejecución directa -----------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: entorno.sh no se ejecuta, se importa." >&2
    echo "       Usa:  source $0" >&2
    exit 1
fi

# ===========================================================================
#  Rutas
# ===========================================================================
NOMAD_ENTORNO_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOMAD_RAIZ="$(cd "${NOMAD_ENTORNO_LIB}/../.." && pwd)"
NOMAD_CONFIG="${NOMAD_RAIZ}/config/servidor.env"
NOMAD_CONFIG_EJEMPLO="${NOMAD_RAIZ}/config/servidor.env.example"
NOMAD_TEMPLATES="${NOMAD_RAIZ}/templates"
export NOMAD_RAIZ NOMAD_CONFIG NOMAD_CONFIG_EJEMPLO NOMAD_TEMPLATES

# ===========================================================================
#  Colores (solo si la salida es un terminal de verdad)
# ===========================================================================
if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
    _e_rojo=$'\033[0;31m'; _e_verde=$'\033[0;32m'; _e_amar=$'\033[0;33m'
    _e_azul=$'\033[0;34m'; _e_gris=$'\033[0;90m'; _e_fin=$'\033[0m'
else
    _e_rojo=""; _e_verde=""; _e_amar=""; _e_azul=""; _e_gris=""; _e_fin=""
fi

_e_ok()    { printf '%s[OK]%s    %s\n'  "${_e_verde}" "${_e_fin}" "$*"; }
_e_info()  { printf '%s[INFO]%s  %s\n'  "${_e_azul}"  "${_e_fin}" "$*"; }
_e_aviso() { printf '%s[AVISO]%s %s\n'  "${_e_amar}"  "${_e_fin}" "$*" >&2; }
_e_error() { printf '%s[ERROR]%s %s\n'  "${_e_rojo}"  "${_e_fin}" "$*" >&2; }

# ===========================================================================
#  1. El archivo de configuración debe existir
# ===========================================================================
if [[ ! -r "${NOMAD_CONFIG}" ]]; then
    _e_error "No se encuentra (o no se puede leer) ${NOMAD_CONFIG}"
    echo
    echo "  Créalo a partir de la plantilla:"
    echo
    echo "      cp ${NOMAD_CONFIG_EJEMPLO} \\"
    echo "         ${NOMAD_CONFIG}"
    echo "      chmod 600 ${NOMAD_CONFIG}"
    echo "      \${EDITOR:-vim} ${NOMAD_CONFIG}"
    echo
    echo "  Si ya lo tienes relleno en tu equipo cliente, cópialo con scp:"
    echo
    echo "      scp config/servidor.env <usuario>@<servidor>:~/nomad_server/config/"
    echo
    echo "  Más detalle en docs/98_variables_y_entorno.md § 3"
    return 1 2>/dev/null || exit 1
fi

# ===========================================================================
#  2. Permisos
# ===========================================================================
# El archivo contiene el dominio, la topología de red y rutas de credenciales.
# No es un secreto de primer nivel, pero tampoco es información pública.
_e_permisos="$(stat -c '%a' "${NOMAD_CONFIG}" 2>/dev/null || echo '???')"
if [[ "${_e_permisos}" != "600" ]]; then
    _e_aviso "${NOMAD_CONFIG} tiene permisos ${_e_permisos}; deberían ser 600."
    _e_aviso "Corrígelo con:  chmod 600 ${NOMAD_CONFIG}"
fi
unset _e_permisos

# ===========================================================================
#  3. Cargar las variables en ESTA sesión
# ===========================================================================
# 'set -a' hace que toda variable que se defina a continuación se exporte
# automáticamente. Exportarlas importa: sin 'export' una variable existe en tu
# shell pero NO la heredan los programas que lanzas (envsubst, docker
# compose…), y el fallo es silencioso.
set -a
# shellcheck disable=SC1090  # ruta calculada en tiempo de ejecución
. "${NOMAD_CONFIG}"
set +a

_e_ok "Entorno cargado desde ${NOMAD_CONFIG}"

# ===========================================================================
#  4. Comprobar las variables obligatorias
# ===========================================================================
# La lista de obligatorias se deduce de la plantilla: son las que llevan el
# marcador [OBLIGATORIA] en sus comentarios. Así no hay dos listas que
# mantener sincronizadas.
_e_obligatorias() {
    awk '
        /^#.*\[OBLIGATORIA\]/ { marcada = 1; next }
        /^[A-Z][A-Z0-9_]*=/   { if (marcada) { sub(/=.*/, ""); print } ; marcada = 0; next }
        /^[[:space:]]*$/      { marcada = 0 }
    ' "${NOMAD_CONFIG_EJEMPLO}"
}

_e_faltan=()
_e_placeholder=()
while read -r _e_nombre; do
    [[ -n "${_e_nombre}" ]] || continue
    if [[ -z "${!_e_nombre:-}" ]]; then
        _e_faltan+=("${_e_nombre}")
    elif [[ "${!_e_nombre}" == *CAMBIAME* ]]; then
        _e_placeholder+=("${_e_nombre}")
    fi
done < <(_e_obligatorias)

if (( ${#_e_faltan[@]} > 0 )); then
    _e_error "Variables OBLIGATORIAS sin valor: ${_e_faltan[*]}"
    _e_error "Rellénalas antes de continuar:  \${EDITOR:-vim} ${NOMAD_CONFIG}"
    _e_error "O consulta qué falta y por qué:  ${NOMAD_RAIZ}/scripts/variables.sh --faltan"
fi
if (( ${#_e_placeholder[@]} > 0 )); then
    _e_aviso "Variables con el valor de ejemplo sin cambiar: ${_e_placeholder[*]}"
fi

# ===========================================================================
#  5. Resumen de lo cargado
# ===========================================================================
# Ver de un vistazo con qué valores estás trabajando evita el error clásico de
# aplicar el capítulo con la configuración de otro servidor.
printf '%s' "${_e_gris}"
cat <<RESUMEN
        servidor   : ${SERVIDOR_HOSTNAME:-<sin definir>}.${SERVIDOR_DOMINIO_LOCAL:-lan}
        usuario    : ${ADMIN_USUARIO:-<sin definir>}
        LAN        : ${LAN_IP:-<sin definir>}/${LAN_PREFIJO:-?} en ${LAN_CIDR:-<sin definir>}
        dominio    : ${DOMINIO_PUBLICO:-<sin definir>}
        proyectos  : ${DATOS_RAIZ:-<sin definir>}
RESUMEN
printf '%s' "${_e_fin}"

unset _e_faltan _e_placeholder _e_nombre

# ===========================================================================
#  6. Ayudantes disponibles en la sesión
# ===========================================================================

# Lista de variables sustituibles en el formato que espera envsubst.
# Se deriva de la plantilla para que envsubst NO toque otros símbolos con '$'
# que aparecen legítimamente en los archivos: las variables propias de
# nftables ($lan_cidr), la sintaxis de partman ($primary{ }), las referencias
# $${VAR} de los ficheros compose o las variables de APT (${distro_codename}).
nomad_lista_envsubst() {
    grep -oE '^[A-Z][A-Z0-9_]*=' "${NOMAD_CONFIG_EJEMPLO}" \
        | tr -d '=' \
        | sed 's/^/${/; s/$/}/' \
        | tr '\n' ' '
}

# Renderiza una plantilla de templates/ con tus valores y la escribe en la
# salida estándar. Es la operación equivalente a lo que hacen los scripts.
#
#   nomad_plantilla etc/nftables.conf                 # ver el resultado
#   nomad_plantilla etc/nftables.conf | sudo tee /etc/nftables.conf
#
nomad_plantilla() {
    local relativa="${1:-}"
    if [[ -z "${relativa}" ]]; then
        echo "Uso: nomad_plantilla <ruta-relativa-dentro-de-templates/>" >&2
        echo "Ejemplo: nomad_plantilla etc/nftables.conf" >&2
        return 2
    fi
    local origen="${NOMAD_TEMPLATES}/${relativa}"
    if [[ ! -r "${origen}" ]]; then
        echo "No se encuentra la plantilla ${origen}" >&2
        echo "Plantillas disponibles:" >&2
        ( cd "${NOMAD_TEMPLATES}" && find . -type f | sed 's|^\./|  |' ) >&2
        return 1
    fi
    envsubst "$(nomad_lista_envsubst)" < "${origen}"
}

# Muestra las diferencias entre lo que la plantilla produciría y lo que hay
# instalado ahora mismo en el sistema. Sirve para revisar antes de aplicar.
#
#   nomad_diff etc/nftables.conf /etc/nftables.conf
#
nomad_diff() {
    local relativa="${1:-}" destino="${2:-}"
    if [[ -z "${relativa}" || -z "${destino}" ]]; then
        echo "Uso: nomad_diff <plantilla> <archivo-del-sistema>" >&2
        return 2
    fi
    if [[ ! -e "${destino}" ]]; then
        echo "(${destino} todavía no existe: se crearía entero)"
        return 0
    fi
    diff -u "${destino}" <(nomad_plantilla "${relativa}") \
        && echo "(sin diferencias: ${destino} ya está al día)"
}

# Escribe un valor descubierto durante el montaje en config/servidor.env y lo
# recarga en la sesión actual. Es la forma correcta de persistir un dato que
# acabas de averiguar (el UUID del túnel, el del disco de respaldo…).
#
#   nomad_fijar CF_TUNEL_ID 8a1b2c3d-4e5f-...
#
nomad_fijar() {
    local nombre="${1:-}" valor="${2:-}"
    if [[ -z "${nombre}" ]]; then
        echo "Uso: nomad_fijar NOMBRE valor" >&2
        return 2
    fi
    "${NOMAD_RAIZ}/scripts/variables.sh" --fijar "${nombre}=${valor}" || return $?
    # Recargar para que el valor nuevo esté disponible de inmediato.
    set -a
    # shellcheck disable=SC1090
    . "${NOMAD_CONFIG}"
    set +a
    _e_ok "${nombre} disponible ya en esta sesión: ${!nombre}"
}

# Recordatorio de lo que queda por rellenar.
nomad_estado() {
    "${NOMAD_RAIZ}/scripts/variables.sh" --estado
}

_e_info "Ayudantes disponibles: nomad_plantilla, nomad_diff, nomad_fijar, nomad_estado"
_e_info "Detalle completo en docs/98_variables_y_entorno.md"
