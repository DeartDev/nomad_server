#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — biblioteca común de los scripts
# ===========================================================================
#  Propósito : funciones compartidas por todos los scripts del repositorio:
#              registro con colores, validaciones previas, idempotencia,
#              copias de seguridad y modo simulación (--check).
#  Uso       : source "$(dirname "$0")/lib/common.sh"
#  Capítulo  : transversal (ver docs/00_planificacion.md § Convenciones)
#
#  Este archivo NO se ejecuta directamente: solo se importa con `source`.
# ===========================================================================

# --- Guarda: impedir la ejecución directa -----------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: common.sh es una biblioteca. Impórtala con 'source', no la ejecutes." >&2
    exit 1
fi

# --- Rutas del repositorio ---------------------------------------------------
# shellcheck disable=SC2034  # las consumen los scripts que importan esta lib
NOMAD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOMAD_SCRIPTS_DIR="$(cd "${NOMAD_LIB_DIR}/.." && pwd)"
NOMAD_RAIZ="$(cd "${NOMAD_SCRIPTS_DIR}/.." && pwd)"
NOMAD_CONFIG="${NOMAD_RAIZ}/config/servidor.env"
NOMAD_CONFIG_EJEMPLO="${NOMAD_RAIZ}/config/servidor.env.example"
NOMAD_TEMPLATES="${NOMAD_RAIZ}/templates"

# Lectura del archivo de configuración aislada del entorno actual. Ver la
# cabecera de leer_config.sh: es lo que permite distinguir «lo que dice el
# archivo» de «lo que hay en mi shell».
# shellcheck source=leer_config.sh
. "${NOMAD_LIB_DIR}/leer_config.sh"

# --- Estado global -----------------------------------------------------------
# MODO_CHECK=1  → simular: se muestra lo que se haría, no se modifica nada.
: "${MODO_CHECK:=0}"
# MODO_SI=1     → responder "sí" automáticamente a las confirmaciones.
: "${MODO_SI:=0}"
# Contador de cambios efectivamente aplicados (para el resumen final).
NOMAD_CAMBIOS=0

# --- Colores (solo si la salida es un terminal) ------------------------------
if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
    C_ROJO=$'\033[0;31m'
    C_VERDE=$'\033[0;32m'
    C_AMARILLO=$'\033[0;33m'
    C_AZUL=$'\033[0;34m'
    C_GRIS=$'\033[0;90m'
    C_NEGRITA=$'\033[1m'
    C_FIN=$'\033[0m'
else
    C_ROJO="" C_VERDE="" C_AMARILLO="" C_AZUL="" C_GRIS="" C_NEGRITA="" C_FIN=""
fi

# ===========================================================================
#  REGISTRO
# ===========================================================================

log_paso()  { printf '\n%s==> %s%s\n' "${C_NEGRITA}${C_AZUL}" "$*" "${C_FIN}"; }
log_info()  { printf '%s[INFO]%s  %s\n'  "${C_AZUL}"     "${C_FIN}" "$*"; }
log_ok()    { printf '%s[OK]%s    %s\n'  "${C_VERDE}"    "${C_FIN}" "$*"; }
log_aviso() { printf '%s[AVISO]%s %s\n'  "${C_AMARILLO}" "${C_FIN}" "$*" >&2; }
log_error() { printf '%s[ERROR]%s %s\n'  "${C_ROJO}"     "${C_FIN}" "$*" >&2; }
log_sinca() { printf '%s[=]%s     %s\n'  "${C_GRIS}"     "${C_FIN}" "$*"; }
log_check() { printf '%s[CHECK]%s %s\n'  "${C_AMARILLO}" "${C_FIN}" "$*"; }

# Aborta con mensaje y código de salida.
#   die "mensaje"        → sale con 1
#   die 3 "mensaje"      → sale con 3
die() {
    local codigo=1
    if [[ "$1" =~ ^[0-9]+$ ]]; then codigo="$1"; shift; fi
    log_error "$*"
    exit "${codigo}"
}

# Marca que se ha aplicado un cambio real en el sistema.
marcar_cambio() { NOMAD_CAMBIOS=$((NOMAD_CAMBIOS + 1)); }

# Resumen final para el cierre de cada script.
resumen_final() {
    local nombre="${1:-script}"
    echo
    if (( MODO_CHECK == 1 )); then
        log_check "Simulación de '${nombre}' terminada. No se ha modificado nada."
        log_check "Cambios que se aplicarían: ${NOMAD_CAMBIOS}"
    elif (( NOMAD_CAMBIOS == 0 )); then
        log_ok "'${nombre}' completado. El sistema ya estaba en el estado deseado."
    else
        log_ok "'${nombre}' completado. Cambios aplicados: ${NOMAD_CAMBIOS}"
    fi
}

# ===========================================================================
#  EJECUCIÓN CON SOPORTE DE SIMULACIÓN
# ===========================================================================

# Ejecuta un comando que MODIFICA el sistema.
# En modo --check solo lo imprime. Cuenta como cambio.
ejecutar() {
    if (( MODO_CHECK == 1 )); then
        log_check "ejecutaría: $*"
        marcar_cambio
        return 0
    fi
    log_info "ejecutando: $*"
    "$@" || return $?
    marcar_cambio
}

# Ejecuta un comando de SOLO LECTURA (consultas, comprobaciones).
# Se ejecuta también en modo --check porque no altera nada.
consultar() { "$@"; }

# ===========================================================================
#  VALIDACIONES PREVIAS
# ===========================================================================

# El script debe ejecutarse como root (o con sudo).
requerir_root() {
    if (( EUID != 0 )); then
        die "Este script necesita privilegios de root. Ejecútalo con: sudo $0 $*"
    fi
}

# El script NO debe ejecutarse como root (p. ej. generación de claves SSH).
requerir_no_root() {
    if (( EUID == 0 )); then
        die "Este script NO debe ejecutarse como root. Ejecútalo con tu usuario normal."
    fi
}

# Comprueba que existen los comandos indicados.
requerir_comandos() {
    local faltan=()
    local cmd
    for cmd in "$@"; do
        command -v "${cmd}" >/dev/null 2>&1 || faltan+=("${cmd}")
    done
    if (( ${#faltan[@]} > 0 )); then
        die "Faltan comandos necesarios: ${faltan[*]}. Instálalos antes de continuar."
    fi
}

# Comprueba que estamos en Debian y, opcionalmente, en la versión esperada.
#   requerir_debian            → solo comprueba que es Debian
#   requerir_debian trixie     → además avisa si el nombre en clave no coincide
requerir_debian() {
    local suite_esperada="${1:-}"
    [[ -r /etc/os-release ]] || die "No se encuentra /etc/os-release: ¿esto es Debian?"

    local ID VERSION_CODENAME
    # shellcheck disable=SC1091  # archivo del sistema, no del repositorio
    . /etc/os-release

    [[ "${ID:-}" == "debian" ]] || die "Este script está diseñado para Debian (detectado: ${ID:-desconocido})."

    if [[ -n "${suite_esperada}" && "${VERSION_CODENAME:-}" != "${suite_esperada}" ]]; then
        log_aviso "Versión esperada '${suite_esperada}', detectada '${VERSION_CODENAME:-desconocida}'."
        log_aviso "La documentación está escrita para ${suite_esperada}; revisa las diferencias."
    fi
}

# Comprueba conectividad a internet (resolución DNS + salida HTTPS).
requerir_internet() {
    local destino="${1:-deb.debian.org}"
    if ! getent hosts "${destino}" >/dev/null 2>&1; then
        die "No se resuelve '${destino}'. Revisa la configuración de red y DNS (docs/06_red_y_firewall.md)."
    fi
    log_ok "Conectividad verificada con ${destino}."
}

# ===========================================================================
#  CONFIGURACIÓN
# ===========================================================================

# Carga config/servidor.env. Aborta con instrucciones claras si no existe.
cargar_entorno() {
    if [[ ! -r "${NOMAD_CONFIG}" ]]; then
        log_error "No se encuentra ${NOMAD_CONFIG}"
        log_error "Créalo a partir de la plantilla:"
        log_error "    cp ${NOMAD_CONFIG_EJEMPLO} ${NOMAD_CONFIG}"
        log_error "    chmod 600 ${NOMAD_CONFIG}"
        log_error "    \$EDITOR ${NOMAD_CONFIG}"
        exit 1
    fi

    local permisos
    permisos="$(stat -c '%a' "${NOMAD_CONFIG}")"
    if [[ "${permisos}" != "600" ]]; then
        log_aviso "${NOMAD_CONFIG} tiene permisos ${permisos}; deberían ser 600."
        log_aviso "Corrígelo con: chmod 600 ${NOMAD_CONFIG}"
    fi

    set -a
    # shellcheck disable=SC1090  # ruta calculada en tiempo de ejecución
    . "${NOMAD_CONFIG}"
    set +a
    log_ok "Configuración cargada desde ${NOMAD_CONFIG}"
}

# Verifica que las variables indicadas existen y no están vacías.
#   requerir_variables SERVIDOR_HOSTNAME LAN_CIDR
#
# Comprueba el valor EFECTIVO (el que usará el script) y, cuando falta alguna,
# vuelve a mirar el archivo por separado para poder explicar el caso confuso:
# una variable que existe en tu shell pero no en config/servidor.env. Ahí el
# comando manual funciona y el script falla, y sin esta distinción el mensaje
# resultaría incomprensible.
requerir_variables() {
    local faltan=()
    local nombre
    for nombre in "$@"; do
        if [[ -z "${!nombre:-}" ]]; then faltan+=("${nombre}"); fi
    done
    if (( ${#faltan[@]} > 0 )); then
        log_error "Variables sin definir en ${NOMAD_CONFIG}: ${faltan[*]}"
        log_error "Consulta ${NOMAD_CONFIG_EJEMPLO} para saber qué valor corresponde."
        log_error "O ejecuta: ${NOMAD_SCRIPTS_DIR}/variables.sh --faltan"
        exit 1
    fi

    # Aviso preventivo: variables que este script NO exige ahora mismo pero que
    # están enmascaradas por el entorno. Hoy funcionan; mañana, bajo sudo o en
    # una sesión nueva, no.
    local enmascaradas=() linea valor_archivo
    while IFS= read -r linea; do
        nombre="${linea%%=*}"
        valor_archivo="${linea#*=}"
        [[ -z "${valor_archivo}" && -n "${!nombre:-}" ]] && enmascaradas+=("${nombre}")
    done < <(nomad_leer_config "${NOMAD_CONFIG}" "$@" 2>/dev/null || true)

    if (( ${#enmascaradas[@]} > 0 )); then
        log_aviso "Estas variables tienen valor en el entorno pero NO en ${NOMAD_CONFIG}:"
        log_aviso "    ${enmascaradas[*]}"
        log_aviso "Escríbelas en el archivo o se perderán en la próxima sesión:"
        log_aviso "    ${NOMAD_SCRIPTS_DIR}/variables.sh --fijar NOMBRE=valor"
    fi
}

# ===========================================================================
#  INTERACCIÓN
# ===========================================================================

# Pregunta sí/no. Devuelve 0 si la respuesta es afirmativa.
#   confirmar "¿Continuar?" && hacer_algo
# En modo --check o con MODO_SI=1 responde que sí sin preguntar.
confirmar() {
    local pregunta="$1"
    if (( MODO_SI == 1 || MODO_CHECK == 1 )); then
        log_info "${pregunta} → sí (automático)"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        die "Se requiere confirmación para '${pregunta}' pero no hay terminal interactivo. Usa --si."
    fi
    local respuesta
    read -r -p "${C_AMARILLO}${pregunta}${C_FIN} [s/N] " respuesta
    [[ "${respuesta}" =~ ^[sSyY]$ ]]
}

# ===========================================================================
#  IDEMPOTENCIA Y ARCHIVOS
# ===========================================================================

# Copia de seguridad de un archivo antes de modificarlo.
#
# El sufijo lleva fecha y hora al segundo. Eso basta para el uso normal, pero
# no para varias escrituras seguidas: 'variables.sh --fijar' llamado siete
# veces en un bucle cae en el mismo segundo y cada copia pisaría a la anterior,
# dejando una sola que ya no refleja el estado original. Por eso, si el nombre
# está ocupado, se añade un contador.
respaldar_archivo() {
    local archivo="$1"
    [[ -e "${archivo}" ]] || return 0
    local base destino n=0
    base="${archivo}.bak-$(date +%Y%m%d-%H%M%S)"
    destino="${base}"
    while [[ -e "${destino}" ]]; do
        n=$((n + 1))
        destino="${base}.${n}"
    done
    if (( MODO_CHECK == 1 )); then
        log_check "respaldaría ${archivo} → ${destino}"
        return 0
    fi
    cp -a "${archivo}" "${destino}"
    log_info "Copia de seguridad: ${destino}"
}

# Escribe contenido en un archivo SOLO si difiere del actual (idempotencia).
# El contenido se pasa por la entrada estándar.
#   printf '%s\n' "hola" | instalar_archivo /etc/ejemplo.conf 644 root:root
instalar_archivo() {
    local destino="$1"
    local modo="${2:-644}"
    local propietario="${3:-root:root}"

    local tmp
    tmp="$(mktemp)"
    cat > "${tmp}"

    if [[ -f "${destino}" ]] && cmp -s "${tmp}" "${destino}"; then
        local modo_actual
        modo_actual="$(stat -c '%a' "${destino}")"
        if [[ "${modo_actual}" == "${modo}" ]]; then
            rm -f "${tmp}"
            log_sinca "${destino} ya está actualizado."
            return 0
        fi
    fi

    if (( MODO_CHECK == 1 )); then
        log_check "escribiría ${destino} (modo ${modo}, dueño ${propietario})"
        if [[ -f "${destino}" ]]; then
            log_check "diferencias:"
            diff -u "${destino}" "${tmp}" | sed 's/^/          /' || true
        fi
        rm -f "${tmp}"
        marcar_cambio
        return 0
    fi

    respaldar_archivo "${destino}"
    install -D -m "${modo}" -o "${propietario%%:*}" -g "${propietario##*:}" "${tmp}" "${destino}"
    rm -f "${tmp}"
    log_ok "Escrito ${destino}"
    marcar_cambio
}

# Lista de variables sustituibles, en el formato que espera envsubst.
# Se deriva de config/servidor.env.example para que envsubst NO toque otros
# símbolos con '$' que aparecen legítimamente en las plantillas: las variables
# propias de nftables ($lan_cidr), la sintaxis de partman ($primary{ }) o las
# referencias de Traefik.
formato_envsubst() {
    grep -oE '^[A-Z][A-Z0-9_]*=' "${NOMAD_CONFIG_EJEMPLO}" \
        | tr -d '=' \
        | sed 's/^/${/; s/$/}/' \
        | tr '\n' ' '
}

# Instala una plantilla de templates/ sustituyendo las ${VARIABLES} conocidas.
#   instalar_plantilla etc/nftables.conf /etc/nftables.conf 640 root:root
instalar_plantilla() {
    local origen="${NOMAD_TEMPLATES}/$1"
    local destino="$2"
    local modo="${3:-644}"
    local propietario="${4:-root:root}"

    [[ -r "${origen}" ]] || die "No se encuentra la plantilla ${origen}"
    envsubst "$(formato_envsubst)" < "${origen}" \
        | instalar_archivo "${destino}" "${modo}" "${propietario}"
}

# Instala paquetes APT solo si faltan.
instalar_paquetes() {
    local pendientes=()
    local paquete
    for paquete in "$@"; do
        if ! dpkg-query -W -f='${Status}' "${paquete}" 2>/dev/null | grep -q "ok installed"; then
            pendientes+=("${paquete}")
        fi
    done
    if (( ${#pendientes[@]} == 0 )); then
        log_sinca "Paquetes ya instalados: $*"
        return 0
    fi
    log_info "Paquetes por instalar: ${pendientes[*]}"
    ejecutar env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pendientes[@]}"
}

# Activa y arranca un servicio systemd si no lo está ya.
habilitar_servicio() {
    local servicio="$1"
    if systemctl is-enabled --quiet "${servicio}" 2>/dev/null \
       && systemctl is-active --quiet "${servicio}" 2>/dev/null; then
        log_sinca "Servicio ${servicio} ya activo y habilitado."
        return 0
    fi
    ejecutar systemctl enable --now "${servicio}"
}

# Recarga un servicio solo si está activo.
recargar_servicio() {
    local servicio="$1"
    if systemctl is-active --quiet "${servicio}" 2>/dev/null; then
        ejecutar systemctl reload-or-restart "${servicio}"
    else
        log_sinca "Servicio ${servicio} no está activo; no se recarga."
    fi
}

# ===========================================================================
#  UTILIDADES DE RED
# ===========================================================================

# Detecta la interfaz de red cableada con ruta por defecto.
detectar_interfaz_lan() {
    ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}'
}

# Devuelve la interfaz LAN: la de config si está definida, o la detectada.
interfaz_lan() {
    if [[ -n "${LAN_INTERFAZ:-}" ]]; then
        echo "${LAN_INTERFAZ}"
        return 0
    fi
    local detectada
    detectada="$(detectar_interfaz_lan)"
    [[ -n "${detectada}" ]] || die "No se ha podido detectar la interfaz de red. Defínela en LAN_INTERFAZ."
    echo "${detectada}"
}

# ===========================================================================
#  ARGUMENTOS COMUNES
# ===========================================================================

# Procesa --check / --si / --help. Los scripts la llaman al principio:
#   procesar_argumentos_comunes "$@"
# Devuelve en NOMAD_ARGS_RESTANTES los argumentos no reconocidos.
NOMAD_ARGS_RESTANTES=()
procesar_argumentos_comunes() {
    NOMAD_ARGS_RESTANTES=()
    while (( $# > 0 )); do
        case "$1" in
            --check|--dry-run|-n) MODO_CHECK=1 ;;
            --si|--yes|-y)        MODO_SI=1 ;;
            --help|-h)            mostrar_ayuda; exit 0 ;;
            *)                    NOMAD_ARGS_RESTANTES+=("$1") ;;
        esac
        shift
    done
    if (( MODO_CHECK == 1 )); then
        log_check "MODO SIMULACIÓN: no se modificará nada en el sistema."
    fi
}

# Cada script define su propia mostrar_ayuda(). Esta es la de reserva.
if ! declare -F mostrar_ayuda >/dev/null; then
    mostrar_ayuda() {
        cat <<AYUDA
Uso: $(basename "$0") [opciones]

Opciones comunes:
  -n, --check     Simula la ejecución: muestra lo que haría sin modificar nada.
  -y, --si        Responde afirmativamente a todas las confirmaciones.
  -h, --help      Muestra esta ayuda.
AYUDA
    }
fi
