#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — inventario y validación del hardware
# ===========================================================================
#  Propósito : recoger en un único documento el inventario completo del equipo
#              candidato a servidor (CPU, memoria, discos, red, firmware) y el
#              estado de salud de sus discos, para poder decidir con datos y
#              para tener una referencia el día que algo falle.
#  Uso       : sudo ./scripts/02_inventario_equipo.sh --help
#  Capítulo  : docs/02_validacion_equipo.md
#
#  Se ejecuta EN EL EQUIPO candidato, desde su sistema actual o desde un live.
#  No modifica nada: solo lee. No requiere Debian.
# ===========================================================================
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

SALIDA=""
FECHA="$(date +%Y-%m-%d_%H%M)"

mostrar_ayuda() {
    cat <<'AYUDA'
Uso: sudo ./scripts/02_inventario_equipo.sh [opciones]

Recoge el inventario del hardware y el estado de salud de los discos, y lo
guarda como un documento Markdown con fecha.

Opciones:
  --salida <ruta>   Archivo de destino.
                    Por omisión: inventario/<hostname>-<fecha>.md
  -n, --check       Muestra el inventario por pantalla sin escribir el archivo.
  -h, --help        Muestra esta ayuda.

Conviene ejecutarlo con sudo: sin privilegios no se puede leer la información
de DMI (fabricante, modelo, módulos de memoria) ni consultar SMART.

Lo que este script NO hace, y hay que hacer a mano (ver el capítulo 02):
  - La comprobación de memoria con memtest86+ (paso 4)
  - El rescate de los datos existentes (paso 5)
  - La configuración de la UEFI (paso 7)
AYUDA
}

# --- Argumentos --------------------------------------------------------------
ARGS=()
while (( $# > 0 )); do
    case "$1" in
        --salida) SALIDA="${2:-}"; shift ;;
        *)        ARGS+=("$1") ;;
    esac
    shift
done
procesar_argumentos_comunes "${ARGS[@]+"${ARGS[@]}"}"
(( ${#NOMAD_ARGS_RESTANTES[@]} == 0 )) \
    || die "Opción desconocida: ${NOMAD_ARGS_RESTANTES[*]} (usa --help)"

if (( EUID != 0 )); then
    log_aviso "Sin privilegios de root: faltarán los datos de DMI y de SMART."
    log_aviso "Vuelve a ejecutarlo con: sudo $0 $*"
fi

: "${SALIDA:=${NOMAD_RAIZ}/inventario/$(hostname)-${FECHA}.md}"

# --- Utilidades --------------------------------------------------------------

# Ejecuta un comando y devuelve su salida, o un aviso si la herramienta falta.
intentar() {
    if command -v "$1" >/dev/null 2>&1; then
        "$@" 2>/dev/null || echo "(el comando '$*' ha devuelto un error)"
    else
        echo "(no disponible: falta el comando '$1')"
    fi
}

seccion() { printf '\n## %s\n\n' "$*"; }

# Imprime un bloque de código. Si el contenido viene vacío (por falta de
# privilegios o de la herramienta), lo dice en lugar de dejar un hueco.
bloque() {
    local contenido="$*"
    if [[ -z "${contenido//[[:space:]]/}" ]]; then
        contenido="(sin datos: prueba a ejecutar el script con sudo)"
    fi
    printf '```\n%s\n```\n' "${contenido}"
}

# Discos físicos reales, excluyendo zram, loop, ram y unidades ópticas.
discos_fisicos() {
    lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}' \
        | grep -vE '^(zram|loop|ram|sr)[0-9]*$' || true
}

# ===========================================================================
#  GENERACIÓN DEL INVENTARIO
# ===========================================================================
generar_inventario() {
    cat <<CABECERA
# Inventario de hardware — $(hostname)

**Fecha:** $(date '+%Y-%m-%d %H:%M:%S %Z')
**Generado por:** scripts/02_inventario_equipo.sh
**Capítulo:** docs/02_validacion_equipo.md

> Este documento contiene números de serie del hardware. El directorio
> \`inventario/\` está excluido del control de versiones a propósito.
CABECERA

    seccion "1. Identificación del equipo"
    bloque "$(
        for campo in system-manufacturer system-product-name system-version \
                     baseboard-product-name bios-vendor bios-version bios-release-date; do
            printf '%-24s %s\n' "${campo}:" "$(intentar dmidecode -s "${campo}" | tail -1)"
        done
    )"

    seccion "2. Procesador"
    bloque "$(intentar lscpu | grep -E 'Architecture|Model name|^CPU\(s\)|Thread|Core|Socket|Virtualization|MHz')"

    seccion "3. Memoria"
    bloque "$(intentar free -h)"
    echo
    echo "Módulos instalados y zócalos libres:"
    bloque "$(intentar dmidecode -t memory | grep -E '^\s+(Locator|Size|Type|Speed|Manufacturer|Part Number):' | sed 's/^\s*//')"

    seccion "4. Discos"
    bloque "$(intentar lsblk -o NAME,SIZE,TYPE,FSTYPE,MODEL,SERIAL,ROTA,TRAN,MOUNTPOINTS)"
    echo
    echo "Rutas estables por identificador (usa una de estas para \`DISCO_DESTINO\`):"
    bloque "$(
        for enlace in /dev/disk/by-id/*; do
            [[ -L "${enlace}" ]] || continue
            [[ "${enlace}" == *-part* ]] && continue
            printf '%s -> %s\n' "${enlace}" "$(readlink -f "${enlace}")"
        done
    )"

    seccion "5. Salud de los discos (SMART)"
    local disco
    while read -r disco; do
        [[ -n "${disco}" ]] || continue
        echo
        echo "### /dev/${disco}"
        echo
        bloque "$(intentar smartctl -i "/dev/${disco}" | grep -E 'Model|Serial|Capacity|Rotation|Form Factor|SMART support')"
        echo
        echo "Veredicto global:"
        bloque "$(intentar smartctl -H "/dev/${disco}" | grep -E 'result|assessment' || echo '(sin datos)')"
        echo
        echo "Atributos relevantes:"
        bloque "$(intentar smartctl -A "/dev/${disco}" \
            | grep -E 'Reallocated_Sector|Current_Pending|Offline_Uncorrectable|Power_On_Hours|Wear_Leveling|Percent_Lifetime|Media_Wearout|Total_LBAs_Written|Percentage Used|Data Units Written' \
            || echo '(sin atributos legibles)')"
    done < <(discos_fisicos)

    seccion "6. Red"
    bloque "$(intentar ip -br link)"
    echo
    bloque "$(intentar ip -br -4 addr)"
    echo
    echo "Controladores de red:"
    bloque "$(intentar lspci | grep -iE 'ethernet|network' || echo '(no disponible)')"
    echo
    echo "Ruta por defecto:"
    bloque "$(intentar ip -4 route show default || echo '(sin ruta por defecto)')"

    seccion "7. Modo de arranque"
    if [[ -d /sys/firmware/efi ]]; then
        bloque "UEFI (correcto para este montaje)"
    else
        bloque "BIOS / Legacy — revisa Boot Mode y CSM en la UEFI antes de instalar (capítulo 02, paso 7)"
    fi

    seccion "8. Dispositivos PCI"
    bloque "$(intentar lspci)"

    seccion "9. Dispositivos USB"
    bloque "$(intentar lsusb)"

    seccion "10. Temperaturas (si hay sensores disponibles)"
    bloque "$(intentar sensors || echo '(instala lm-sensors y ejecuta sensors-detect)')"

    cat <<'PIE'

## Comprobaciones manuales pendientes

Marca cada una cuando la completes (ver docs/02_validacion_equipo.md):

- [ ] memtest86+: al menos una pasada completa con 0 errores
- [ ] Datos anteriores respaldados **y verificados** en un disco externo
- [ ] Firmware de la UEFI actualizado
- [ ] UEFI configurada según la tabla del paso 7
- [ ] *Restore on AC Power Loss* = **Power On**, probado desconectando la corriente
- [ ] SATA Mode = **AHCI**
- [ ] Suspensión desactivada
- [ ] Limpieza de polvo y revisión de ventiladores
- [ ] Equipo en su ubicación definitiva, ventilado y conectado por cable
- [ ] `DISCO_DESTINO` y `LAN_INTERFAZ` anotados en config/servidor.env

## Ajustes cambiados en la UEFI

Anota aquí lo que modificaste, para poder reproducirlo si algún día se
restablecen los valores de fábrica:

| Ajuste | Valor anterior | Valor nuevo |
|---|---|---|
|  |  |  |
PIE
}

# ===========================================================================
#  EJECUCIÓN
# ===========================================================================
log_paso "Recogiendo el inventario del equipo"
log_info "Esto puede tardar unos segundos mientras se consultan los discos…"

CONTENIDO="$(generar_inventario)"

if (( MODO_CHECK == 1 )); then
    log_check "No se escribe ningún archivo. Inventario:"
    echo
    printf '%s\n' "${CONTENIDO}"
    resumen_final "02_inventario_equipo"
    exit 0
fi

mkdir -p "$(dirname "${SALIDA}")"
printf '%s\n' "${CONTENIDO}" > "${SALIDA}"
marcar_cambio

# Que el archivo pertenezca al usuario real, no a root.
if [[ -n "${SUDO_USER:-}" ]]; then
    chown "${SUDO_USER}" "${SALIDA}" 2>/dev/null || true
fi

log_ok "Inventario guardado en: ${SALIDA}"
echo

# Resumen en pantalla de lo más importante.
log_paso "Resumen"
grep -E 'system-product-name|Model name|^Mem:' <<<"${CONTENIDO}" | sed 's/^/  /' || true

if grep -qE 'FAILED' <<<"${CONTENIDO}"; then
    log_error "SMART reporta FAILED en algún disco. NO uses ese disco para el servidor."
elif grep -qE 'PASSED' <<<"${CONTENIDO}"; then
    log_ok "SMART: todos los discos consultados dan PASSED."
else
    log_aviso "No se ha podido leer SMART. Ejecuta el script con sudo e instala smartmontools."
fi

if [[ -d /sys/firmware/efi ]]; then
    log_ok "El equipo ha arrancado en modo UEFI."
else
    log_aviso "El equipo ha arrancado en modo BIOS/Legacy. Corrígelo antes de instalar."
fi

resumen_final "02_inventario_equipo"
log_info "Revisa el archivo generado y completa las comprobaciones manuales que incluye."
log_info "Siguiente paso: docs/03_instalacion_debian.md"
