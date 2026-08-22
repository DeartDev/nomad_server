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

# CUÁL ES EL REPOSITORIO PRINCIPAL
#
# Con disco USB, el principal es el local y el remoto recibe una copia de las
# instantáneas ya cifradas. Sin disco USB, el principal es el remoto: es una
# configuración legítima, y desde luego mejor que no tener respaldos, pero cada
# respaldo viaja por la red y una restauración completa depende de tu bajada.
ARCHIVO_CRED_REMOTO="/etc/nomad/restic-remoto.env"

if [[ -n "${RESTIC_USB_UUID:-}" ]]; then
    MODO_RESPALDO="local"
    REPO_PRINCIPAL="${RESTIC_REPO_LOCAL}"
else
    MODO_RESPALDO="remoto"
    REPO_PRINCIPAL="${RESTIC_REPO_REMOTO:-}"
fi

# Credenciales del remoto (B2_ACCOUNT_ID, AWS_ACCESS_KEY_ID…). Se cargan aquí
# para que este script pueda hablar con el remoto; la unidad de systemd las
# carga por su cuenta con EnvironmentFile.
if [[ -r "${ARCHIVO_CRED_REMOTO}" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "${ARCHIVO_CRED_REMOTO}"
    set +a
fi

# Atajos para no repetir los dos parámetros en cada llamada.
r() { restic --repo "${REPO_PRINCIPAL}" --password-file "${RESTIC_PASSWORD_FILE}" "$@"; }

comprobar_repositorio() {
    command -v restic >/dev/null 2>&1 || die "restic no está instalado. Ejecuta: sudo $0 --instalar"
    [[ -n "${REPO_PRINCIPAL}" ]] \
        || die "No hay repositorio configurado: ni RESTIC_USB_UUID ni RESTIC_REPO_REMOTO."
    if [[ "${MODO_RESPALDO}" == "local" ]]; then
        mountpoint -q "${RESTIC_USB_MOUNT}" \
            || die "El disco de respaldo no está montado en ${RESTIC_USB_MOUNT}. ¿Está conectado?"
    fi
    [[ -r "${RESTIC_PASSWORD_FILE}" ]] \
        || die "No se puede leer ${RESTIC_PASSWORD_FILE}"
    r cat config >/dev/null 2>&1 \
        || die "No se puede abrir el repositorio ${REPO_PRINCIPAL}"
}

# ===========================================================================
#  ACCIONES DE OPERACIÓN
# ===========================================================================
case "${ACCION}" in

    listar)
        comprobar_repositorio
        log_paso "Instantáneas de ${REPO_PRINCIPAL}"
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

        REPO_ACCESIBLE=0
        if command -v restic >/dev/null 2>&1; then
            if [[ "${MODO_RESPALDO}" == "local" ]]; then
                mountpoint -q "${RESTIC_USB_MOUNT}" && REPO_ACCESIBLE=1
            else
                REPO_ACCESIBLE=1
            fi
        fi

        if (( REPO_ACCESIBLE == 1 )); then
            log_info "Últimas instantáneas:"
            r snapshots --compact 2>/dev/null | tail -6 | sed 's/^/          /' || true
            if [[ "${MODO_RESPALDO}" == "local" ]]; then
                log_info "Tamaño del repositorio: $(du -sh "${RESTIC_REPO_LOCAL}" 2>/dev/null | cut -f1)"
            else
                log_info "Tamaño del repositorio: $(r stats --mode raw-data 2>/dev/null | grep -i 'total size' | cut -d: -f2 | tr -d ' ')"
            fi

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
        # Se encadena 'nomad_limpiar_contador' porque un 'trap ... EXIT' sustituye
        # al anterior, y common.sh había instalado ahí el borrado del contador.
        # shellcheck disable=SC2064  # se quiere expandir DESTINO ahora
        trap "rm -rf '${DESTINO}'; nomad_limpiar_contador" EXIT

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
        if r ls latest 2>/dev/null | contiene 'cloudflared'; then
            log_ok "Las credenciales del túnel están en el respaldo."
        else
            log_error "Las credenciales del túnel NO están en el respaldo."
            log_error "Sin ellas habría que rehacer el túnel y todos los registros DNS."
            FALLOS=$((FALLOS + 1))
        fi

        # 4. ¿Está el manifiesto del sistema?
        if r ls latest 2>/dev/null | contiene 'paquetes.txt'; then
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

# Sin disco USB se respalda directamente contra el remoto. Es una configuración
# admitida, pero renuncia a la copia local: exige que el remoto esté bien
# configurado, porque será el único sitio donde vivan tus respaldos.
if [[ "${MODO_RESPALDO}" == "remoto" ]]; then
    log_sinca "Sin disco USB (RESTIC_USB_UUID vacío): se respalda solo al remoto."

    [[ -n "${REPO_PRINCIPAL}" ]] || {
        log_error "Sin disco USB y sin RESTIC_REPO_REMOTO no hay dónde respaldar."
        log_error "Rellena una de las dos en config/servidor.env:"
        log_error "  · RESTIC_USB_UUID   — disco conectado al servidor"
        log_error "  · RESTIC_REPO_REMOTO — destino remoto (b2:, s3:, sftp:, rclone:)"
        log_error ""
        log_error "Discos disponibles, por si prefieres el USB:"
        lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,UUID,MOUNTPOINTS | sed 's/^/          /' >&2
        exit 1
    }

    log_ok "Repositorio remoto: ${REPO_PRINCIPAL}"

    # Los destinos que no llevan credenciales en la propia URL las necesitan en
    # el archivo de entorno. 'sftp:' con clave SSH es la excepción.
    if [[ "${REPO_PRINCIPAL}" != sftp:* ]] && [[ ! -r "${ARCHIVO_CRED_REMOTO}" ]]; then
        log_error "Falta ${ARCHIVO_CRED_REMOTO} con las credenciales del remoto."
        log_error "Créalo con permisos 600. Para Backblaze B2, por ejemplo:"
        log_error "    B2_ACCOUNT_ID=…"
        log_error "    B2_ACCOUNT_KEY=…"
        log_error "Ver docs/14_respaldos_restic.md § 5 paso 12."
        exit 1
    fi

    if [[ -r "${ARCHIVO_CRED_REMOTO}" ]]; then
        PERM_CRED="$(stat -c '%a' "${ARCHIVO_CRED_REMOTO}")"
        if [[ "${PERM_CRED}" == "600" ]]; then
            log_ok "Credenciales del remoto con permisos correctos (600)."
        else
            log_aviso "${ARCHIVO_CRED_REMOTO} tiene permisos ${PERM_CRED}; deben ser 600."
            ejecutar chmod 600 "${ARCHIVO_CRED_REMOTO}"
        fi
    fi
fi

if [[ "${MODO_RESPALDO}" == "local" ]]; then

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
    if ! grep "${RESTIC_USB_UUID}" /etc/fstab | contiene nofail; then
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
fi   # fin del bloque del disco USB

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
    log_check "inicializaría el repositorio en ${REPO_PRINCIPAL} si no existiera"
elif r cat config >/dev/null 2>&1; then
    log_sinca "El repositorio ya existe en ${REPO_PRINCIPAL}."
else
    # 'mkdir' solo tiene sentido para un repositorio en disco: los remotos los
    # crea restic contra el servicio.
    [[ "${MODO_RESPALDO}" == "local" ]] && mkdir -p "${REPO_PRINCIPAL}"
    r init || die "No se ha podido inicializar el repositorio ${REPO_PRINCIPAL}."
    marcar_cambio
    log_ok "Repositorio creado en ${REPO_PRINCIPAL}."
    log_aviso "APUNTA LA CONTRASEÑA EN TU GESTOR AHORA, fuera de este servidor."
    log_aviso "Sin ella este repositorio es ruido cifrado y no hay forma de abrirlo."
fi

# ---------------------------------------------------------------------------
#  4. Exclusiones y script
# ---------------------------------------------------------------------------
log_paso "4/6 · Exclusiones y script de respaldo"

if (( MODO_CHECK == 0 )); then
    # 'pre-respaldo.d' guarda los volcados de bases de datos que deben hacerse
    # ANTES del respaldo. Se crea vacío: cada proyecto pone el suyo.
    mkdir -p /etc/nomad /etc/nomad/pre-respaldo.d /var/backups/nomad
    chmod 700 /etc/nomad/pre-respaldo.d
fi

# Aviso si hay bases de datos en marcha y ningún gancho que las vuelque: el
# respaldo saldría en verde con un directorio de datos copiado en caliente, que
# no sirve para restaurar.
if (( MODO_CHECK == 0 )) && command -v docker >/dev/null 2>&1; then
    BASES_EN_MARCHA="$(docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null \
        | grep -iE 'postgres|mysql|mariadb|mongo' | cut -f1 || true)"
    GANCHOS="$(find /etc/nomad/pre-respaldo.d -maxdepth 1 -type f -perm -u+x 2>/dev/null | wc -l)"
    if [[ -n "${BASES_EN_MARCHA}" ]] && (( GANCHOS == 0 )); then
        log_aviso "Hay bases de datos en marcha y ningún gancho que las vuelque:"
        printf '          %s\n' ${BASES_EN_MARCHA} >&2
        log_aviso "Copiar su directorio de datos en caliente NO produce un respaldo"
        log_aviso "restaurable, y la prueba de restauración no lo detecta porque"
        log_aviso "compara archivos. Ver docs/14_respaldos_restic.md § 3.4."
    fi
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

# 'RequiresMountsFor' va en un añadido y no en la unidad: con disco es lo
# correcto, y sin disco dejaría el respaldo esperando para siempre un montaje
# que nadie va a hacer.
DIR_ANADIDO="/etc/systemd/system/nomad-respaldo.service.d"
ANADIDO_USB="${DIR_ANADIDO}/10-disco-usb.conf"

if [[ "${MODO_RESPALDO}" == "local" ]]; then
    (( MODO_CHECK == 0 )) && mkdir -p "${DIR_ANADIDO}"
    instalar_plantilla systemd/nomad-respaldo-disco-usb.conf \
        "${ANADIDO_USB}" 644 root:root
elif [[ -f "${ANADIDO_USB}" ]]; then
    if (( MODO_CHECK == 1 )); then
        log_check "retiraría ${ANADIDO_USB} (ya no hay disco USB)"
        marcar_cambio
    else
        respaldar_archivo "${ANADIDO_USB}"
        rm -f "${ANADIDO_USB}"
        marcar_cambio
        log_ok "Retirado ${ANADIDO_USB}: ya no se espera ningún disco."
    fi
else
    log_sinca "Sin dependencia de disco en el servicio: se respalda al remoto."
fi

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
    log_info "Se lanza A TRAVÉS DE SYSTEMD, no llamando al script directamente."
    log_info "Es deliberado: el aislamiento del servicio (ProtectSystem, rutas"
    log_info "escribibles, variables de entorno) solo se ejerce por esa vía, y un"
    log_info "respaldo que funciona a mano puede fallar cada noche sin que se note."

    if confirmar "¿Ejecutar el primer respaldo ahora?"; then
        if systemctl start nomad-respaldo.service; then
            marcar_cambio
            log_ok "Primer respaldo completado a través de systemd."
        else
            log_error "El respaldo ha fallado al ejecutarse como servicio."
            log_error "Registro:"
            journalctl -u nomad-respaldo -n 25 --no-pager | sed 's/^/          /' >&2
            die "Revisa el registro de arriba."
        fi
        journalctl -u nomad-respaldo -n 12 --no-pager | sed 's/^/          /'
    else
        log_aviso "Sin ejecutarlo al menos una vez COMO SERVICIO no sabes si el"
        log_aviso "temporizador funcionará. Lánzalo cuando puedas:"
        log_aviso "    sudo systemctl start nomad-respaldo.service"
        log_aviso "    sudo journalctl -u nomad-respaldo -n 20"
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
