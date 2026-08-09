#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — creación del USB de instalación de Debian
# ===========================================================================
#  Propósito : descargar la imagen netinst de Debian, verificar su suma y su
#              firma OpenPGP, escribirla en una memoria USB y comprobar que lo
#              escrito coincide byte a byte con el original.
#  Uso       : ./scripts/01_crear_usb.sh --help
#  Capítulo  : docs/01_unidad_usb_booteable.md
#
#  Se ejecuta en TU EQUIPO CLIENTE, no en el servidor. No requiere Debian.
# ===========================================================================
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

BASE_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"
USB_DEV=""
FORZAR=0
DIR_TRABAJO=""

mostrar_ayuda() {
    cat <<'AYUDA'
Uso: ./scripts/01_crear_usb.sh [opciones]

Descarga la imagen netinst de Debian (amd64), verifica su integridad y su
autenticidad, y la escribe en una memoria USB.

Opciones:
  --usb <dispositivo>  Dispositivo de bloques destino, p. ej. /dev/sdb.
                       Debe ser el DISPOSITIVO COMPLETO, nunca una partición
                       (/dev/sdb, no /dev/sdb1).
  --dir <ruta>         Directorio de descarga (por omisión: ~/debian-iso).
  --forzar             Permite escribir en un dispositivo que no se detecta
                       como extraíble. Úsalo solo si estás completamente
                       seguro: destruye todos los datos del dispositivo.
  -n, --check          Descarga y verifica, pero NO escribe en el USB.
  -y, --si             No pide confirmación antes de escribir.
  -h, --help           Muestra esta ayuda.

Ejemplos:
  ./scripts/01_crear_usb.sh --check
  sudo ./scripts/01_crear_usb.sh --usb /dev/sdb

Para escribir en el USB hacen falta privilegios de root (sudo).
El modo --check no los necesita.

ATENCIÓN: escribir en el dispositivo equivocado destruye sus datos de forma
irrecuperable. El script comprueba que el destino sea extraíble y que no
contenga particiones del sistema, pero la responsabilidad última es tuya.
AYUDA
}

# --- Argumentos --------------------------------------------------------------
ARGS=()
while (( $# > 0 )); do
    case "$1" in
        --usb)     USB_DEV="${2:-}"; shift ;;
        --dir)     DIR_TRABAJO="${2:-}"; shift ;;
        --forzar)  FORZAR=1 ;;
        *)         ARGS+=("$1") ;;
    esac
    shift
done
procesar_argumentos_comunes "${ARGS[@]+"${ARGS[@]}"}"
(( ${#NOMAD_ARGS_RESTANTES[@]} == 0 )) \
    || die "Opción desconocida: ${NOMAD_ARGS_RESTANTES[*]} (usa --help)"

# --- Usuario real (el script puede correr bajo sudo) -------------------------
USUARIO_REAL="${SUDO_USER:-${USER:-$(id -un)}}"
HOME_REAL="$(getent passwd "${USUARIO_REAL}" | cut -d: -f6)"
[[ -n "${HOME_REAL}" ]] || HOME_REAL="${HOME}"
: "${DIR_TRABAJO:=${HOME_REAL}/debian-iso}"

# Ejecuta un comando como el usuario real, no como root.
# gpg debe usar el llavero del usuario, no el de root.
como_usuario() {
    if (( EUID == 0 )) && [[ -n "${SUDO_USER:-}" ]]; then
        sudo -u "${USUARIO_REAL}" -H "$@"
    else
        "$@"
    fi
}

# ===========================================================================
#  1. COMPROBACIONES PREVIAS
# ===========================================================================
log_paso "Comprobaciones previas"

requerir_comandos curl gpg sha256sum stat lsblk dd

if (( MODO_CHECK == 0 )); then
    [[ -n "${USB_DEV}" ]] || die "Falta --usb <dispositivo>. Consulta --help para identificarlo."
    (( EUID == 0 )) || die "Escribir en el USB requiere root. Ejecuta: sudo $0 --usb ${USB_DEV}"
fi

log_ok "Herramientas necesarias disponibles."

# ===========================================================================
#  2. DESCARGA
# ===========================================================================
log_paso "Descarga de la imagen"

if [[ ! -d "${DIR_TRABAJO}" ]]; then
    mkdir -p "${DIR_TRABAJO}"
    (( EUID == 0 )) && chown "${USUARIO_REAL}" "${DIR_TRABAJO}"
fi
cd "${DIR_TRABAJO}"
log_info "Directorio de trabajo: ${DIR_TRABAJO}"

log_info "Consultando la versión actual de Debian…"
curl -fsSL "${BASE_URL}/SHA256SUMS" -o SHA256SUMS \
    || die "No se ha podido descargar SHA256SUMS. ¿Hay conexión a internet?"
curl -fsSL "${BASE_URL}/SHA256SUMS.sign" -o SHA256SUMS.sign \
    || die "No se ha podido descargar SHA256SUMS.sign."

# La primera coincidencia es la netinst estándar (las otras son -edu y -mac).
ISO="$(grep -oE 'debian-[0-9.]+-amd64-netinst\.iso$' SHA256SUMS | head -1)"
[[ -n "${ISO}" ]] || die "No se ha encontrado ninguna imagen netinst en SHA256SUMS."
log_ok "Imagen actual: ${ISO}"

if [[ -f "${ISO}" ]] && sha256sum --ignore-missing -c SHA256SUMS >/dev/null 2>&1; then
    log_sinca "La imagen ya está descargada y su suma es correcta."
else
    log_info "Descargando ${ISO} (unos 700 MB)…"
    curl -fL --progress-bar -C - "${BASE_URL}/${ISO}" -o "${ISO}" \
        || die "La descarga ha fallado."
fi
(( EUID == 0 )) && chown "${USUARIO_REAL}" "${ISO}" SHA256SUMS SHA256SUMS.sign

# ===========================================================================
#  3. VERIFICACIÓN DE INTEGRIDAD
# ===========================================================================
log_paso "Verificación de la suma de comprobación"

if sha256sum --ignore-missing -c SHA256SUMS 2>/dev/null | grep -q "${ISO}"; then
    log_ok "La suma SHA256 de la imagen coincide."
else
    rm -f "${ISO}"
    die "La suma SHA256 NO coincide. Se ha borrado la imagen; vuelve a ejecutar el script."
fi

# ===========================================================================
#  4. VERIFICACIÓN DE AUTENTICIDAD
# ===========================================================================
log_paso "Verificación de la firma OpenPGP"

# Claves de firma de las imágenes de Debian.
# Contrástalas siempre con https://www.debian.org/CD/verify
CLAVES_DEBIAN=(
    "DF9B9C49EAA9298432589D76DA87E80D6294BE9B"
    "F41D30342F3546695F65C66942468F4009EA8AC3"
    "10460DAD76165AD81FBC0CE9988021A964E6EA7D"
)

if ! como_usuario gpg --verify SHA256SUMS.sign SHA256SUMS >/dev/null 2>&1; then
    log_info "Importando las claves de firma de Debian…"
    for servidor in "keyring.debian.org" "hkps://keys.openpgp.org"; do
        if como_usuario gpg --keyserver "${servidor}" \
             --recv-keys "${CLAVES_DEBIAN[@]}" >/dev/null 2>&1; then
            log_ok "Claves importadas desde ${servidor}."
            break
        fi
        log_aviso "No se han podido obtener las claves de ${servidor}; probando otro servidor."
    done
fi

SALIDA_GPG="$(como_usuario gpg --status-fd 1 --verify SHA256SUMS.sign SHA256SUMS 2>/dev/null || true)"

if ! grep -q 'GOODSIG' <<<"${SALIDA_GPG}"; then
    log_error "La firma de SHA256SUMS no se ha podido verificar."
    log_error "No continúes: no hay garantía de que la imagen sea auténtica."
    log_error "Verifica manualmente siguiendo docs/01_unidad_usb_booteable.md § 5, pasos 5 a 7."
    exit 1
fi

# La firma es válida: comprobamos además que provenga de una clave conocida.
HUELLA_FIRMANTE="$(grep -m1 'VALIDSIG' <<<"${SALIDA_GPG}" | awk '{print $3}')"
if printf '%s\n' "${CLAVES_DEBIAN[@]}" | grep -qx "${HUELLA_FIRMANTE}"; then
    log_ok "Firma válida de una clave de Debian conocida:"
    log_ok "  ${HUELLA_FIRMANTE}"
else
    log_aviso "La firma es válida, pero la huella no está en la lista incluida en este script:"
    log_aviso "  ${HUELLA_FIRMANTE}"
    log_aviso "Debian puede haber rotado sus claves. Compruébala en https://www.debian.org/CD/verify"
    confirmar "¿La huella coincide con la publicada por Debian?" \
        || die "Verificación interrumpida por el usuario."
fi

# ===========================================================================
#  5. VALIDACIÓN DEL DISPOSITIVO DESTINO
# ===========================================================================
log_paso "Dispositivo destino"

if [[ -z "${USB_DEV}" ]]; then
    log_check "No se ha indicado --usb: se omite la escritura."
    log_check "Dispositivos extraíbles detectados:"
    lsblk -d -o NAME,SIZE,MODEL,TRAN,RM | awk 'NR==1 || $5==1 || $4=="usb"'
    resumen_final "01_crear_usb"
    exit 0
fi

[[ -b "${USB_DEV}" ]] || die "${USB_DEV} no es un dispositivo de bloques."

if [[ "${USB_DEV}" =~ [0-9]$ && "${USB_DEV}" =~ ^/dev/(sd|vd)[a-z]+[0-9]+$ ]]; then
    die "${USB_DEV} parece una partición. Indica el dispositivo completo (p. ej. /dev/sdb)."
fi

NOMBRE_DEV="$(basename "${USB_DEV}")"

# El dispositivo que contiene la raíz del sistema nunca puede ser el destino.
DEV_RAIZ="$(findmnt -no SOURCE / 2>/dev/null || true)"
DISCO_RAIZ="$(lsblk -no PKNAME "${DEV_RAIZ}" 2>/dev/null | head -1 || true)"
if [[ -n "${DISCO_RAIZ}" && "${DISCO_RAIZ}" == "${NOMBRE_DEV}" ]]; then
    die "${USB_DEV} contiene el sistema de archivos raíz. ABORTADO."
fi

# Ninguna partición del destino puede estar montada en una ruta del sistema.
while read -r punto; do
    [[ -n "${punto}" ]] || continue
    case "${punto}" in
        /|/boot|/boot/*|/home|/var|/usr|/etc)
            die "${USB_DEV} tiene una partición montada en '${punto}'. ABORTADO."
            ;;
    esac
done < <(lsblk -no MOUNTPOINTS "${USB_DEV}" 2>/dev/null || true)

ES_EXTRAIBLE="$(lsblk -dno RM "${USB_DEV}" | tr -d ' ')"
TRANSPORTE="$(lsblk -dno TRAN "${USB_DEV}" | tr -d ' ')"
if [[ "${ES_EXTRAIBLE}" != "1" && "${TRANSPORTE}" != "usb" ]]; then
    log_aviso "${USB_DEV} no se detecta como extraíble ni como USB."
    (( FORZAR == 1 )) || die "Usa --forzar si estás seguro de que es el dispositivo correcto."
    log_aviso "Continuando por --forzar."
fi

echo
lsblk -o NAME,SIZE,MODEL,TRAN,RM,FSTYPE,LABEL,MOUNTPOINTS "${USB_DEV}"
echo
log_aviso "TODO el contenido de ${USB_DEV} se destruirá de forma irrecuperable."
confirmar "¿Escribir ${ISO} en ${USB_DEV}?" || die "Cancelado por el usuario."

# ===========================================================================
#  6. ESCRITURA
# ===========================================================================
log_paso "Escritura de la imagen"

while read -r punto; do
    [[ -n "${punto}" ]] || continue
    log_info "Desmontando ${punto}…"
    ejecutar umount "${punto}"
done < <(lsblk -no MOUNTPOINTS "${USB_DEV}" 2>/dev/null || true)

if (( MODO_CHECK == 1 )); then
    log_check "escribiría: dd if=${ISO} of=${USB_DEV} bs=4M oflag=sync"
    marcar_cambio
else
    log_info "Escribiendo (puede tardar varios minutos)…"
    dd if="${ISO}" of="${USB_DEV}" bs=4M status=progress oflag=sync
    sync
    marcar_cambio
    log_ok "Imagen escrita."
fi

# ===========================================================================
#  7. VERIFICACIÓN DE LO ESCRITO
# ===========================================================================
log_paso "Verificación del USB"

if (( MODO_CHECK == 1 )); then
    log_check "verificaría que los primeros bytes de ${USB_DEV} coinciden con ${ISO}"
else
    BYTES="$(stat -c %s "${ISO}")"
    log_info "Leyendo ${BYTES} bytes de ${USB_DEV} para comprobar…"
    SUMA_USB="$(head -c "${BYTES}" "${USB_DEV}" | sha256sum | cut -d' ' -f1)"
    SUMA_ISO="$(sha256sum "${ISO}" | cut -d' ' -f1)"

    if [[ "${SUMA_USB}" == "${SUMA_ISO}" ]]; then
        log_ok "El contenido del USB coincide con la imagen verificada."
        log_ok "El medio de instalación está listo."
    else
        log_error "El contenido del USB NO coincide con la imagen."
        log_error "  esperado: ${SUMA_ISO}"
        log_error "  leído:    ${SUMA_USB}"
        log_error "Repite la escritura. Si vuelve a fallar, la memoria puede estar defectuosa."
        exit 1
    fi
fi

resumen_final "01_crear_usb"
log_info "Siguiente paso: docs/02_validacion_equipo.md"
