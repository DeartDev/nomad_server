#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — respaldos con restic
# ===========================================================================
#  Propósito : instalar y operar el sistema de respaldos: montaje del disco,
#              repositorio cifrado, automatización con systemd y las
#              operaciones del día a día, incluida la prueba de restauración.
#  Uso       : sudo ./scripts/14_restic.sh --help
#  Capítulo  : docs/14_respaldos_restic.md
#
#  Un respaldo que no se ha restaurado nunca no es un respaldo. Por eso este
#  script incluye --probar, y por eso el capítulo no se da por terminado sin
#  haberlo ejecutado.
# ===========================================================================
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

ACCION="instalar"

mostrar_ayuda() {
    cat <<'AYUDA'
Uso: sudo ./scripts/14_restic.sh [acción] [opciones]

Acciones:
  --instalar          Instala y configura todo el sistema de respaldos:
                      montaje por UUID, repositorio, script, servicio y
                      temporizador. Es la acción por omisión.
  --ahora             Ejecuta un respaldo inmediato.
  --listar            Muestra las instantáneas del repositorio.
  --estado            Resumen: temporizador, última copia, tamaño y espacio.
  --verificar         Comprueba la integridad de la estructura (rápido).
  --verificar-datos   Comprueba además una muestra de los datos (lento).
  --probar            PRUEBA DE RESTAURACIÓN: restaura la última instantánea
                      a un directorio temporal y comprueba que coincide.

Opciones:
  -n, --check    Muestra qué cambiaría, sin modificar nada.
  -y, --si       No pide confirmación.
  -h, --help     Muestra esta ayuda.

LO QUE ESTE SCRIPT NO HACE, A PROPÓSITO:
  - Formatear el disco USB. Es destructivo y se hace a mano siguiendo el
    paso 1 del capítulo 14.
  - Escribir la contraseña del repositorio. Debes ponerla tú y guardarla
    también en tu gestor de contraseñas, FUERA del servidor: si solo existe
    aquí, no podrás restaurar cuando este servidor ya no exista.
AYUDA
}

# --- Argumentos --------------------------------------------------------------
ARGS=()
while (( $# > 0 )); do
    case "$1" in
        --instalar)        ACCION="instalar" ;;
        --ahora)           ACCION="ahora" ;;
        --listar)          ACCION="listar" ;;
        --estado)          ACCION="estado" ;;
        --verificar)       ACCION="verificar" ;;
        --verificar-datos) ACCION="verificar-datos" ;;
        --probar)          ACCION="probar" ;;
        *)                 ARGS+=("$1") ;;
    esac
    shift
done
procesar_argumentos_comunes "${ARGS[@]+"${ARGS[@]}"}"
(( ${#NOMAD_ARGS_RESTANTES[@]} == 0 )) \
    || die "Opción desconocida: ${NOMAD_ARGS_RESTANTES[*]} (usa --help)"

# --- Comprobaciones previas --------------------------------------------------
log_paso "Comprobaciones previas"
requerir_root "$@"
cargar_entorno
requerir_variables RESTIC_USB_MOUNT RESTIC_REPO_LOCAL RESTIC_PASSWORD_FILE \
                   RESTIC_RETENCION_DIARIOS RESTIC_RETENCION_SEMANALES \
                   RESTIC_RETENCION_MENSUALES RESTIC_HORA DATOS_RAIZ \
                   ADMIN_USUARIO SERVIDOR_HOSTNAME

# Atajos para no repetir los dos parámetros en cada llamada.
r() { restic --repo "${RESTIC_REPO_LOCAL}" --password-file "${RESTIC_PASSWORD_FILE}" "$@"; }

comprobar_repositorio() {
    command -v restic >/dev/null 2>&1 || die "restic no está instalado. Ejecuta: sudo $0 --instalar"
    mountpoint -q "${RESTIC_USB_MOUNT}" \
        || die "El disco de respaldo no está montado en ${RESTIC_USB_MOUNT}. ¿Está conectado?"
    [[ -r "${RESTIC_PASSWORD_FILE}" ]] \
        || die "No se puede leer ${RESTIC_PASSWORD_FILE}"
    r cat config >/dev/null 2>&1 \
        || die "No se puede abrir el repositorio ${RESTIC_REPO_LOCAL}"
}

# ===========================================================================
#  ACCIONES DE OPERACIÓN
# ===========================================================================
case "${ACCION}" in

    listar)
        comprobar_repositorio
        log_paso "Instantáneas de ${RESTIC_REPO_LOCAL}"
        r snapshots
        exit 0
        ;;

    ahora)
        [[ -x /usr/local/bin/nomad-respaldo.sh ]] \
            || die "Falta /usr/local/bin/nomad-respaldo.sh. Ejecuta: sudo $0 --instalar"
        log_paso "Respaldo inmediato"
        /usr/local/bin/nomad-respaldo.sh
        exit 0
        ;;

    verificar)
        comprobar_repositorio
        log_paso "Comprobación de integridad (estructura)"
        if r check; then
            log_ok "El repositorio es coherente."
        else
            log_error "El repositorio tiene errores de integridad."
            log_error "Comprueba la salud del disco: sudo smartctl -H <disco>"
            exit 1
        fi
        exit 0
        ;;

    verificar-datos)
        comprobar_repositorio
        log_paso "Comprobación de integridad (leyendo el 5% de los datos)"
        log_info "Esto tarda: se descifra y verifica una muestra real."
        if r check --read-data-subset=5%; then
            log_ok "Los datos verificados son correctos."
        else
            log_error "Se han detectado datos corruptos."
            log_error "El disco de respaldo puede estar degradándose. Sustitúyelo."
            exit 1
        fi
        exit 0
        ;;

    estado)
        log_paso "Estado del sistema de respaldos"

        if mountpoint -q "${RESTIC_USB_MOUNT}"; then
            log_ok "Disco montado en ${RESTIC_USB_MOUNT}"
            df -h "${RESTIC_USB_MOUNT}" | tail -1 | sed 's/^/          /'
        else
            log_error "El disco NO está montado. Los respaldos están fallando."
        fi

        if systemctl is-enabled --quiet nomad-respaldo.timer 2>/dev/null; then
            log_ok "Temporizador habilitado."
            systemctl list-timers nomad-respaldo --no-pager 2>/dev/null \
                | sed -n '2p' | sed 's/^/          /'
        else
            log_error "El temporizador NO está habilitado: no hay respaldos automáticos."
        fi

        RESULTADO="$(systemctl show nomad-respaldo.service -p Result --value 2>/dev/null || echo '?')"
        log_info "Resultado de la última ejecución: ${RESULTADO}"

        if command -v restic >/dev/null 2>&1 && mountpoint -q "${RESTIC_USB_MOUNT}"; then
            log_info "Últimas instantáneas:"
            r snapshots --compact 2>/dev/null | tail -6 | sed 's/^/          /' || true
            log_info "Tamaño del repositorio: $(du -sh "${RESTIC_REPO_LOCAL}" 2>/dev/null | cut -f1)"

            ULTIMA="$(r snapshots --json 2>/dev/null | jq -r '.[-1].time // empty' 2>/dev/null || true)"
            if [[ -n "${ULTIMA}" ]]; then
                HORAS=$(( ( $(date +%s) - $(date -d "${ULTIMA}" +%s) ) / 3600 ))
                if (( HORAS > 30 )); then
                    log_error "La última copia tiene ${HORAS} horas. Debería ser diaria."
                else
                    log_ok "Última copia hace ${HORAS} horas."
                fi
            fi
        fi
        exit 0
        ;;

    probar)
        comprobar_repositorio
        log_paso "PRUEBA DE RESTAURACIÓN"
        log_info "Un respaldo que no se ha restaurado nunca no es un respaldo."

        DESTINO="$(mktemp -d /tmp/nomad-prueba-restauracion.XXXXXX)"
        # shellcheck disable=SC2064  # se quiere expandir DESTINO ahora
        trap "rm -rf '${DESTINO}'" EXIT

        log_info "Restaurando la última instantánea de ${DATOS_RAIZ}…"
        r restore latest --target "${DESTINO}" --include "${DATOS_RAIZ}" >/dev/null

        FALLOS=0

        # 1. ¿Coincide el contenido?
        if diff -r --brief "${DATOS_RAIZ}" "${DESTINO}${DATOS_RAIZ}" >/tmp/nomad-diff.txt 2>&1; then
            log_ok "El contenido restaurado es idéntico al original."
        else
            DIFERENCIAS="$(wc -l </tmp/nomad-diff.txt)"
            log_aviso "Hay ${DIFERENCIAS} diferencias. Algunas son normales (bases de datos"
            log_aviso "en uso, registros). Revísalas:"
            head -10 /tmp/nomad-diff.txt | sed 's/^/          /'
        fi

        # 2. ¿Están los secretos, y con sus permisos?
        ENV_ORIG="$(find "${DATOS_RAIZ}" -name '.env' 2>/dev/null | wc -l)"
        ENV_REST="$(find "${DESTINO}${DATOS_RAIZ}" -name '.env' 2>/dev/null | wc -l)"
        if (( ENV_ORIG == ENV_REST )); then
            log_ok "Se han restaurado los ${ENV_REST} archivos .env."
        else
            log_error "Faltan archivos .env: ${ENV_REST} restaurados de ${ENV_ORIG}."
            log_error "Sin ellos, los proyectos no arrancarán tras una restauración real."
            FALLOS=$((FALLOS + 1))
        fi

        MAL_PERMISO="$(find "${DESTINO}${DATOS_RAIZ}" -name '.env' ! -perm 600 2>/dev/null | wc -l)"
        if (( MAL_PERMISO == 0 )); then
            log_ok "Los archivos .env conservan sus permisos 600."
        else
            log_error "${MAL_PERMISO} archivos .env han perdido sus permisos."
            FALLOS=$((FALLOS + 1))
        fi

        # 3. ¿Están las credenciales del túnel?
        if r ls latest 2>/dev/null | grep -q 'cloudflared'; then
            log_ok "Las credenciales del túnel están en el respaldo."
        else
            log_error "Las credenciales del túnel NO están en el respaldo."
            log_error "Sin ellas habría que rehacer el túnel y todos los registros DNS."
            FALLOS=$((FALLOS + 1))
        fi

        # 4. ¿Está el manifiesto del sistema?
        if r ls latest 2>/dev/null | grep -q 'paquetes.txt'; then
            log_ok "El manifiesto del sistema está en el respaldo."
        else
            log_aviso "Falta el manifiesto del sistema. Ejecuta un respaldo nuevo."
        fi

        echo
        if (( FALLOS == 0 )); then
            log_ok "PRUEBA SUPERADA: el respaldo sirve para reconstruir el servidor."
        else
            log_error "PRUEBA FALLIDA: ${FALLOS} problemas. Corrígelos AHORA,"
            log_error "no el día que necesites restaurar de verdad."
            exit 1
        fi
        exit 0
        ;;
esac

# ===========================================================================
#  INSTALACIÓN
# ===========================================================================

# ---------------------------------------------------------------------------
#  1. Disco
# ---------------------------------------------------------------------------
log_paso "1/6 · Disco de respaldo"

if [[ -z "${RESTIC_USB_UUID:-}" ]]; then
    log_error "RESTIC_USB_UUID está vacío en config/servidor.env."
    log_error ""
    log_error "Conecta el disco, identifícalo y formatéalo siguiendo el paso 1"
    log_error "del capítulo 14. Después obtén su UUID con:"
    log_error "    sudo blkid /dev/sdX1"
    log_error ""
    log_error "Discos disponibles:"
    lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,UUID,MOUNTPOINTS | sed 's/^/          /' >&2
    exit 1
fi

if [[ -e "/dev/disk/by-uuid/${RESTIC_USB_UUID}" ]]; then
    log_ok "El disco con UUID ${RESTIC_USB_UUID} está presente."
else
    log_error "No se encuentra ningún dispositivo con UUID ${RESTIC_USB_UUID}."
    log_error "¿Está conectado el disco? ¿Es correcto el UUID?"
    lsblk -o NAME,SIZE,FSTYPE,UUID | sed 's/^/          /' >&2
    exit 1
fi

if (( MODO_CHECK == 0 )); then
    mkdir -p "${RESTIC_USB_MOUNT}"
fi

# fstab: 'nofail' no es opcional. Sin él, el servidor no arranca si el disco
# no está conectado, y te quedas en una consola de emergencia sin SSH.
LINEA_FSTAB="UUID=${RESTIC_USB_UUID}  ${RESTIC_USB_MOUNT}  ext4  defaults,nofail,noatime,x-systemd.device-timeout=10  0  2"

if grep -q "${RESTIC_USB_UUID}" /etc/fstab; then
    log_sinca "El disco ya está declarado en /etc/fstab."
    if ! grep "${RESTIC_USB_UUID}" /etc/fstab | grep -q nofail; then
        log_error "Su entrada en fstab NO tiene 'nofail'."
        log_error "Si el disco falla, el servidor no arrancará."
        log_error "Añade 'nofail' a las opciones de esa línea."
    fi
else
    respaldar_archivo /etc/fstab
    if (( MODO_CHECK == 1 )); then
        log_check "añadiría a /etc/fstab:"
        log_check "  ${LINEA_FSTAB}"
    else
        printf '\n# nomad_server — disco de respaldo (docs/14_respaldos_restic.md)\n%s\n' \
            "${LINEA_FSTAB}" >> /etc/fstab
        marcar_cambio
        log_ok "Entrada añadida a /etc/fstab."
        systemctl daemon-reload
    fi
fi

if (( MODO_CHECK == 0 )); then
    if mountpoint -q "${RESTIC_USB_MOUNT}"; then
        log_sinca "Ya está montado en ${RESTIC_USB_MOUNT}."
    else
        mount "${RESTIC_USB_MOUNT}" || die "No se ha podido montar ${RESTIC_USB_MOUNT}"
        marcar_cambio
        log_ok "Disco montado."
    fi
    df -h "${RESTIC_USB_MOUNT}" | tail -1 | sed 's/^/          /'
fi

# ---------------------------------------------------------------------------
#  2. restic y contraseña
# ---------------------------------------------------------------------------
log_paso "2/6 · restic y contraseña"

instalar_paquetes restic

if [[ -s "${RESTIC_PASSWORD_FILE}" ]]; then
    PERM="$(stat -c '%a' "${RESTIC_PASSWORD_FILE}")"
    if [[ "${PERM}" == "600" ]]; then
        log_ok "Archivo de contraseña presente con permisos correctos."
    else
        log_aviso "El archivo de contraseña tiene permisos ${PERM}."
        ejecutar chmod 600 "${RESTIC_PASSWORD_FILE}"
    fi
else
    log_error "Falta el archivo de contraseña ${RESTIC_PASSWORD_FILE}."
    log_error ""
    log_error "Créalo con la contraseña que guardaste en el capítulo 00:"
    log_error "    sudo touch ${RESTIC_PASSWORD_FILE}"
    log_error "    sudo chmod 600 ${RESTIC_PASSWORD_FILE}"
    log_error "    sudo \$EDITOR ${RESTIC_PASSWORD_FILE}"
    log_error ""
    log_error "O genera una nueva:"
    log_error "    openssl rand -base64 48 | sudo tee ${RESTIC_PASSWORD_FILE}"
    log_error "    sudo chmod 600 ${RESTIC_PASSWORD_FILE}"
    log_error ""
    log_error "Y GUÁRDALA TAMBIÉN EN TU GESTOR DE CONTRASEÑAS."
    log_error "Si solo existe en este servidor, no podrás restaurar cuando"
    log_error "este servidor ya no exista, que es para lo que sirve un respaldo."
    exit 1
fi

# ---------------------------------------------------------------------------
#  3. Repositorio
# ---------------------------------------------------------------------------
log_paso "3/6 · Repositorio"

if (( MODO_CHECK == 1 )); then
    log_check "inicializaría el repositorio en ${RESTIC_REPO_LOCAL} si no existiera"
elif r cat config >/dev/null 2>&1; then
    log_sinca "El repositorio ya existe en ${RESTIC_REPO_LOCAL}."
else
    mkdir -p "${RESTIC_REPO_LOCAL}"
    r init || die "No se ha podido inicializar el repositorio."
    marcar_cambio
    log_ok "Repositorio creado."
fi

# ---------------------------------------------------------------------------
#  4. Exclusiones y script
# ---------------------------------------------------------------------------
log_paso "4/6 · Exclusiones y script de respaldo"

if (( MODO_CHECK == 0 )); then
    mkdir -p /etc/nomad /var/backups/nomad
fi

instalar_plantilla etc/restic-excluir.txt /etc/nomad/restic-excluir.txt 644 root:root

# El script se instala fuera del repositorio a propósito: el respaldo debe
# funcionar aunque nomad_server no esté clonado (capítulo 14 § 3.5).
instalar_plantilla etc/nomad-respaldo.sh /usr/local/bin/nomad-respaldo.sh 700 root:root

if (( MODO_CHECK == 0 )); then
    bash -n /usr/local/bin/nomad-respaldo.sh \
        || die "El script de respaldo generado tiene errores de sintaxis."
    log_ok "El script de respaldo es sintácticamente correcto."
fi

# ---------------------------------------------------------------------------
#  5. Automatización
# ---------------------------------------------------------------------------
log_paso "5/6 · Automatización"

instalar_plantilla systemd/nomad-respaldo.service \
    /etc/systemd/system/nomad-respaldo.service 644 root:root
instalar_plantilla systemd/nomad-respaldo.timer \
    /etc/systemd/system/nomad-respaldo.timer 644 root:root

if (( MODO_CHECK == 0 )); then
    systemctl daemon-reload
    habilitar_servicio nomad-respaldo.timer
    systemctl list-timers nomad-respaldo --no-pager | sed -n '1,2p' | sed 's/^/          /'
fi

# ---------------------------------------------------------------------------
#  6. Primer respaldo
# ---------------------------------------------------------------------------
log_paso "6/6 · Primer respaldo"

if (( MODO_CHECK == 1 )); then
    log_check "ejecutaría el primer respaldo"
else
    log_info "El primero tarda: hay que leer y cifrar todo."
    if confirmar "¿Ejecutar el primer respaldo ahora?"; then
        /usr/local/bin/nomad-respaldo.sh || die "El primer respaldo ha fallado."
        marcar_cambio
        log_ok "Primer respaldo completado."
    else
        log_info "Lo puedes lanzar después con: sudo $0 --ahora"
    fi
fi

# ===========================================================================
#  RESUMEN
# ===========================================================================
resumen_final "14_restic"

if (( MODO_CHECK == 0 )); then
    echo
    log_aviso "════════════════════════════════════════════════════════════════"
    log_aviso "  FALTA EL PASO MÁS IMPORTANTE: LA PRUEBA DE RESTAURACIÓN"
    log_aviso ""
    log_aviso "      sudo $0 --probar"
    log_aviso ""
    log_aviso "  Hasta que no la ejecutes, no sabes si tienes respaldos:"
    log_aviso "  solo sabes que tienes archivos en un disco."
    log_aviso "════════════════════════════════════════════════════════════════"
    echo
    log_info "Y comprueba que la contraseña del repositorio está guardada"
    log_info "en tu gestor de contraseñas, fuera de este servidor."
fi

log_info "Siguiente paso: docs/15_mantenimiento_y_actualizaciones.md"
