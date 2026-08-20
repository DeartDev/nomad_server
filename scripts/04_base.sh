#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — configuración base del sistema
# ===========================================================================
#  Propósito : dejar un Debian recién instalado en un estado conocido:
#              repositorios en formato deb822, sistema actualizado, nombre y
#              hora correctos, utilidades de diagnóstico y suspensión
#              desactivada de forma permanente.
#  Uso       : sudo ./scripts/04_base.sh --help
#  Capítulo  : docs/04_primer_arranque_y_base.md
#
#  Se ejecuta EN EL SERVIDOR. Idempotente: ejecutarlo dos veces no cambia nada
#  la segunda vez.
# ===========================================================================
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

SIN_ACTUALIZAR=0

mostrar_ayuda() {
    cat <<'AYUDA'
Uso: sudo ./scripts/04_base.sh [opciones]

Configura la base del sistema tras la instalación de Debian:

  1. Repositorios en formato deb822 (estable + updates + security)
  2. Actualización completa del sistema
  3. Nombre de la máquina y /etc/hosts
  4. Zona horaria y sincronización NTP
  5. Configuración regional
  6. Paquetes base de diagnóstico
  7. Suspensión e hibernación desactivadas

Opciones:
  --sin-actualizar   Omite el paso 2 (apt full-upgrade). Útil para volver a
                     ejecutar el script sin esperar a la descarga.
  -n, --check        Muestra qué cambiaría, sin modificar nada.
  -y, --si           No pide confirmación.
  -h, --help         Muestra esta ayuda.

Lo que este script NO hace:
  - Clonar el repositorio ni copiar config/servidor.env (paso 2 del capítulo,
    que ocurre antes de que el script exista en el servidor).
  - Reiniciar. Si hace falta, lo avisa al terminar.
AYUDA
}

# --- Argumentos --------------------------------------------------------------
ARGS=()
while (( $# > 0 )); do
    case "$1" in
        --sin-actualizar) SIN_ACTUALIZAR=1 ;;
        *)                ARGS+=("$1") ;;
    esac
    shift
done
procesar_argumentos_comunes "${ARGS[@]+"${ARGS[@]}"}"
(( ${#NOMAD_ARGS_RESTANTES[@]} == 0 )) \
    || die "Opción desconocida: ${NOMAD_ARGS_RESTANTES[*]} (usa --help)"

# --- Comprobaciones previas --------------------------------------------------
log_paso "Comprobaciones previas"
requerir_root "$@"
requerir_debian "trixie"
cargar_entorno
requerir_variables SERVIDOR_HOSTNAME SERVIDOR_ZONA_HORARIA SERVIDOR_LOCALE \
                   ADMIN_USUARIO DEBIAN_MIRROR DEBIAN_SUITE
requerir_comandos apt-get hostnamectl timedatectl systemctl envsubst

if ! id "${ADMIN_USUARIO}" >/dev/null 2>&1; then
    die "El usuario '${ADMIN_USUARIO}' no existe. Revisa ADMIN_USUARIO en config/servidor.env."
fi
log_ok "Sistema y configuración verificados."

# ===========================================================================
#  1. CUENTAS: root bloqueada y administrador con sudo
# ===========================================================================
log_paso "1/7 · Cuentas"

ESTADO_ROOT="$(passwd -S root | awk '{print $2}')"
if [[ "${ESTADO_ROOT}" == "L" ]]; then
    log_sinca "La cuenta de root ya está bloqueada."
else
    log_aviso "La cuenta de root tiene contraseña (estado: ${ESTADO_ROOT})."
    log_aviso "Toda la administración debe pasar por sudo (capítulo 03 § 3.1)."
    if confirmar "¿Bloquear la cuenta de root?"; then
        ejecutar passwd -l root
    else
        log_aviso "root sigue desbloqueada. Anótalo como desviación consciente."
    fi
fi

if id -nG "${ADMIN_USUARIO}" | tr ' ' '\n' | contiene -x sudo; then
    log_sinca "'${ADMIN_USUARIO}' ya pertenece al grupo sudo."
else
    ejecutar usermod -aG sudo "${ADMIN_USUARIO}"
    log_aviso "Cierra la sesión y vuelve a entrar para que el grupo tenga efecto."
fi

# ===========================================================================
#  2. REPOSITORIOS
# ===========================================================================
log_paso "2/7 · Repositorios APT"

CAMBIOS_ANTES_REPO="$(cambios)"
instalar_plantilla etc/debian.sources /etc/apt/sources.list.d/debian.sources 644 root:root

# El formato antiguo, si sigue presente, duplicaría las definiciones.
if [[ -s /etc/apt/sources.list ]] && grep -qvE '^\s*(#|$)' /etc/apt/sources.list; then
    log_aviso "/etc/apt/sources.list (formato antiguo) tiene entradas activas."
    log_aviso "Se desactiva para evitar definiciones duplicadas."
    ejecutar mv /etc/apt/sources.list /etc/apt/sources.list.desactivado
else
    log_sinca "No hay un sources.list antiguo con entradas activas."
fi

# 'apt-get update' solo tiene sentido si la definición de repositorios ha
# cambiado, o si aún falta por instalar lo que este capítulo necesita. Hacerlo
# siempre convertiría cada pasada en un cambio.
if hubo_cambios_desde "${CAMBIOS_ANTES_REPO}"; then
    ejecutar apt-get update
else
    log_sinca "Los repositorios no han cambiado: no se actualiza el índice."
fi

# ===========================================================================
#  3. ACTUALIZACIÓN DEL SISTEMA
# ===========================================================================
log_paso "3/7 · Actualización del sistema"

if (( SIN_ACTUALIZAR == 1 )); then
    log_sinca "Omitida por --sin-actualizar."
else
    PENDIENTES="$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst' || true)"
    if (( PENDIENTES == 0 )); then
        log_sinca "El sistema ya está al día."
    else
        log_info "Paquetes por actualizar: ${PENDIENTES}"
        ejecutar env DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y
        ejecutar env DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y
    fi
fi

# ===========================================================================
#  4. NOMBRE DE LA MÁQUINA
# ===========================================================================
log_paso "4/7 · Nombre de la máquina"

FQDN="${SERVIDOR_HOSTNAME}"
[[ -n "${SERVIDOR_DOMINIO_LOCAL:-}" ]] && FQDN="${SERVIDOR_HOSTNAME}.${SERVIDOR_DOMINIO_LOCAL}"

if [[ "$(hostnamectl --static)" == "${SERVIDOR_HOSTNAME}" ]]; then
    log_sinca "El nombre ya es '${SERVIDOR_HOSTNAME}'."
else
    ejecutar hostnamectl set-hostname "${SERVIDOR_HOSTNAME}"
fi

# /etc/hosts: se reescribe la línea 127.0.1.1 conservando el resto.
LINEA_HOSTS="127.0.1.1	${FQDN} ${SERVIDOR_HOSTNAME}"
if grep -qxF "${LINEA_HOSTS}" /etc/hosts; then
    log_sinca "/etc/hosts ya tiene la entrada correcta."
else
    {
        grep -v '^127\.0\.1\.1' /etc/hosts | sed '/^127\.0\.0\.1/a '"${LINEA_HOSTS}"
    } | instalar_archivo /etc/hosts 644 root:root
fi

# ===========================================================================
#  5. HORA Y CONFIGURACIÓN REGIONAL
# ===========================================================================
log_paso "5/7 · Hora y configuración regional"

if [[ "$(timedatectl show -p Timezone --value)" == "${SERVIDOR_ZONA_HORARIA}" ]]; then
    log_sinca "Zona horaria ya configurada: ${SERVIDOR_ZONA_HORARIA}"
else
    ejecutar timedatectl set-timezone "${SERVIDOR_ZONA_HORARIA}"
fi

if [[ "$(timedatectl show -p NTP --value)" == "yes" ]]; then
    log_sinca "Sincronización NTP ya activa."
else
    ejecutar timedatectl set-ntp true
fi

if locale -a 2>/dev/null | contiene -iF "${SERVIDOR_LOCALE//-/}"; then
    log_sinca "La configuración regional ${SERVIDOR_LOCALE} ya está generada."
else
    ejecutar sed -i "s/^# *\(${SERVIDOR_LOCALE}\)/\1/" /etc/locale.gen
    ejecutar locale-gen
fi
if grep -q "LANG=${SERVIDOR_LOCALE}" /etc/default/locale 2>/dev/null; then
    log_sinca "LANG ya apunta a ${SERVIDOR_LOCALE}."
else
    ejecutar update-locale "LANG=${SERVIDOR_LOCALE}"
fi

# ===========================================================================
#  6. PAQUETES BASE
# ===========================================================================
log_paso "6/7 · Paquetes base"

# Solo herramientas para entender qué ocurre en el sistema. Nada de servicios:
# todo lo demás va en contenedores (capítulo 04 § 3.6).
instalar_paquetes \
    git curl wget ca-certificates gnupg \
    vim less tmux rsync jq unzip tree \
    btop ncdu \
    smartmontools lm-sensors \
    bind9-dnsutils iproute2 \
    unattended-upgrades

# ===========================================================================
#  7. SUSPENSIÓN DESACTIVADA
# ===========================================================================
log_paso "7/7 · Suspensión e hibernación"

OBJETIVOS=(sleep.target suspend.target hibernate.target hybrid-sleep.target)
POR_ENMASCARAR=()
for objetivo in "${OBJETIVOS[@]}"; do
    if [[ "$(systemctl is-enabled "${objetivo}" 2>/dev/null || true)" == "masked" ]]; then
        continue
    fi
    POR_ENMASCARAR+=("${objetivo}")
done

if (( ${#POR_ENMASCARAR[@]} == 0 )); then
    log_sinca "Los cuatro objetivos de suspensión ya están enmascarados."
else
    ejecutar systemctl mask "${POR_ENMASCARAR[@]}"
fi

# Se recarga logind solo si el archivo ha cambiado. Hacerlo siempre contaría
# como un cambio en cada ejecución y rompería la promesa de la idempotencia:
# que una segunda pasada informe de que no había nada que hacer.
CAMBIOS_ANTES="$(cambios)"
printf '[Login]\nHandlePowerKey=ignore\nHandleLidSwitch=ignore\nHandleSuspendKey=ignore\nHandleHibernateKey=ignore\n' \
    | instalar_archivo /etc/systemd/logind.conf.d/50-nomad-servidor.conf 644 root:root

if hubo_cambios_desde "${CAMBIOS_ANTES}"; then
    recargar_servicio systemd-logind
else
    log_sinca "logind no necesita recargarse."
fi

# ===========================================================================
#  RESUMEN
# ===========================================================================
resumen_final "04_base"

if [[ -f /var/run/reboot-required ]]; then
    echo
    log_aviso "Hay un reinicio pendiente (probablemente por una actualización del kernel)."
    log_aviso "Ejecuta:  sudo reboot"
    log_aviso "Mantén conectados el monitor y el teclado hasta comprobar que vuelve."
fi

log_info "Valida el capítulo con la sección 7 de docs/04_primer_arranque_y_base.md"
log_info "Siguiente paso: docs/05_usuarios_y_acceso_ssh.md"
