#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — ejecución del respaldo
#  Destino  : /usr/local/bin/nomad-respaldo.sh
#  Generado por scripts/14_restic.sh
#  Capítulo : docs/14_respaldos_restic.md
#
#  Propósito : ejecutar el respaldo nocturno con restic y aplicar la política
#              de retención.
#
#  Este script se instala FUERA del repositorio a propósito: el respaldo debe
#  funcionar aunque el repositorio nomad_server no esté clonado, se haya
#  movido o esté a medio actualizar (capítulo 14 § 3.5).
#
#  No lo edites aquí: edita config/servidor.env y vuelve a ejecutar
#  scripts/14_restic.sh
#
#  NOTA PARA QUIEN EDITE LA PLANTILLA: las ${VARIABLES_EN_MAYÚSCULA} se
#  sustituyen al generar el archivo. Las variables propias del script van en
#  minúscula precisamente para que la sustitución no las toque.
# ===========================================================================
set -euo pipefail

# --- Credenciales del repositorio remoto -----------------------------------
# B2_ACCOUNT_ID, AWS_ACCESS_KEY_ID y compañía. El archivo puede no existir si
# no hay repositorio remoto, de ahí el '-' de EnvironmentFile en la unidad de
# systemd y el '|| true' de aquí.
if [[ -r /etc/nomad/restic-remoto.env ]]; then
    set -a
    . /etc/nomad/restic-remoto.env
    set +a
fi

# --- Valores sustituidos al instalar ---------------------------------------
repo_local="${RESTIC_REPO_LOCAL}"
repo_remoto="${RESTIC_REPO_REMOTO}"
punto_montaje="${RESTIC_USB_MOUNT}"
usb_uuid="${RESTIC_USB_UUID}"

# CUÁL ES EL REPOSITORIO PRINCIPAL
#
# Con disco USB, el principal es el local: el respaldo lee el sistema de
# archivos una sola vez y después 'restic copy' replica al remoto las
# instantáneas YA cifradas, sin volver a leerlo todo.
#
# Sin disco USB, el principal es el remoto y no hay copia que hacer. Es una
# configuración legítima —y mejor que no tener respaldos— pero conviene saber
# lo que implica: cada respaldo viaja por la red, y una restauración completa
# depende de tu velocidad de bajada.
if [[ -n "${usb_uuid}" ]]; then
    modo="local"
    RESTIC_REPOSITORY="${repo_local}"
else
    modo="remoto"
    RESTIC_REPOSITORY="${repo_remoto}"
fi
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE}"
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
datos_raiz="${DATOS_RAIZ}"
admin_usuario="${ADMIN_USUARIO}"
servidor="${SERVIDOR_HOSTNAME}"
push_url="${RESTIC_PUSH_URL}"
ret_diarios="${RESTIC_RETENCION_DIARIOS}"
ret_semanales="${RESTIC_RETENCION_SEMANALES}"
ret_mensuales="${RESTIC_RETENCION_MENSUALES}"

exclusiones="/etc/nomad/restic-excluir.txt"
manifiesto="/var/backups/nomad"

registrar() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

fallar() {
    registrar "ERROR: $*"
    # No se avisa al monitor en caso de fallo: es la AUSENCIA de aviso lo que
    # lo hace saltar. Si avisáramos del fallo, un servidor apagado o sin red
    # no enviaría nada y el monitor tampoco se enteraría (capítulo 14 § 3.6).
    exit 1
}

# ===========================================================================
#  1. Comprobaciones previas
#
#  CÓMO APLICARLA A MANO (equivalente a lo que hace el script)
#
#      cd ~/nomad_server
#      source scripts/lib/entorno.sh
#      nomad_diff etc/nomad-respaldo.sh /usr/local/bin/nomad-respaldo.sh
#      sudo cp -a /usr/local/bin/nomad-respaldo.sh \
#          /usr/local/bin/nomad-respaldo.sh.bak-$(date +%Y%m%d-%H%M%S) 2>/dev/null || true
#      nomad_plantilla etc/nomad-respaldo.sh \
#          | sudo tee /usr/local/bin/nomad-respaldo.sh >/dev/null
#      sudo chmod 700 /usr/local/bin/nomad-respaldo.sh
#
#  Y después, para que tenga efecto:
#      sudo bash -n /usr/local/bin/nomad-respaldo.sh && echo 'SINTAXIS CORRECTA'
#
#  Detalle: templates/README.md y docs/98_variables_y_entorno.md § 4.3
# ===========================================================================
registrar "=== Respaldo de ${servidor} ==="

[[ -r "${RESTIC_PASSWORD_FILE}" ]] \
    || fallar "No se puede leer el archivo de contraseña ${RESTIC_PASSWORD_FILE}"

[[ -n "${RESTIC_REPOSITORY}" ]] \
    || fallar "No hay repositorio configurado: ni disco USB ni destino remoto."

registrar "Repositorio principal (${modo}): ${RESTIC_REPOSITORY}"

if [[ "${modo}" == "local" ]]; then
    mountpoint -q "${punto_montaje}" \
        || fallar "El disco de respaldo no está montado en ${punto_montaje}. ¿Está conectado?"

    libre_gb="$(df -BG --output=avail "${punto_montaje}" | tail -1 | tr -dc '0-9')"
    registrar "Espacio libre en el disco de respaldo: ${libre_gb} GB"
    (( libre_gb < 5 )) && fallar "Quedan menos de 5 GB en el disco de respaldo."
fi

restic cat config >/dev/null 2>&1 \
    || fallar "No se puede abrir el repositorio ${RESTIC_REPOSITORY}"

# ===========================================================================
#  2. Manifiesto del sistema
# ===========================================================================
# Lo que NO está en ningún archivo pero hace falta para reconstruir el
# servidor: qué paquetes había instalados y qué imágenes de contenedor
# estaban en uso (capítulo 14 § 3.2).
registrar "Generando el manifiesto del sistema…"
mkdir -p "${manifiesto}"

dpkg --get-selections    > "${manifiesto}/paquetes.txt"          2>/dev/null || true
apt-mark showmanual      > "${manifiesto}/paquetes-manuales.txt" 2>/dev/null || true
lsblk -f                 > "${manifiesto}/discos.txt"            2>/dev/null || true
docker image ls --format '{{.Repository}}:{{.Tag}}' \
                         > "${manifiesto}/imagenes.txt"          2>/dev/null || true
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' \
                         > "${manifiesto}/contenedores.txt"      2>/dev/null || true
docker network ls --format '{{.Name}}\t{{.Driver}}' \
                         > "${manifiesto}/redes.txt"             2>/dev/null || true
{
    echo "Fecha:    $(date -Is)"
    echo "Servidor: ${servidor}"
    echo "Kernel:   $(uname -r)"
    echo "Debian:   $(. /etc/os-release && echo "${VERSION_CODENAME}")"
} > "${manifiesto}/sistema.txt"

# ===========================================================================
#  2b. Ganchos previos: volcados de bases de datos
#
#  POR QUÉ ESTO NO ES OPCIONAL SI TIENES BASES DE DATOS
#
#  Copiar archivo a archivo el directorio de datos de un PostgreSQL o un MySQL
#  EN MARCHA no produce un respaldo del que se pueda restaurar. PostgreSQL lo
#  documenta explícitamente. A veces la copia arranca, a veces arranca con
#  corrupción, y a veces no arranca: depende de qué estuviera escribiendo el
#  motor en ese instante. Y una prueba de restauración que compara archivos no
#  lo detecta, porque los archivos están ahí.
#
#  La solución es un volcado consistente hecho por el propio motor ANTES del
#  respaldo. Cada proyecto pone aquí un script ejecutable que genere el suyo
#  dentro del directorio del proyecto, donde el respaldo lo recogerá.
#  Ver docs/14_respaldos_restic.md § 3.4.
# ===========================================================================
dir_ganchos="/etc/nomad/pre-respaldo.d"
gancho_fallido=0

if [[ -d "${dir_ganchos}" ]]; then
    for gancho in "${dir_ganchos}"/*; do
        [[ -x "${gancho}" ]] || continue
        registrar "Gancho previo: ${gancho}"
        if "${gancho}" >>"${manifiesto}/ganchos.log" 2>&1; then
            registrar "  correcto"
        else
            # No se aborta: los archivos siguen mereciendo respaldarse. Pero el
            # aviso al monitor irá en rojo, porque un respaldo sin el volcado de
            # la base de datos no sirve para lo que uno cree que sirve.
            registrar "  FALLÓ: revisa ${manifiesto}/ganchos.log"
            gancho_fallido=1
        fi
    done
else
    registrar "Sin ganchos previos en ${dir_ganchos}."
fi

# ===========================================================================
#  3. Respaldo
# ===========================================================================
# Qué se respalda y por qué está en docs/14_respaldos_restic.md § 3.2.
rutas=(
    "${datos_raiz}"          # proyectos: compose, .env y datos
    "/etc"                   # configuración del sistema
    "${manifiesto}"          # manifiesto generado arriba
    "/var/lib/tailscale"     # estado del nodo de la VPN
    "/var/spool/cron"        # tareas programadas
)

# Directorios del administrador que contienen credenciales irreemplazables.
home_admin="$(getent passwd "${admin_usuario}" | cut -d: -f6)"
[[ -d "${home_admin}/.cloudflared" ]]        && rutas+=("${home_admin}/.cloudflared")
[[ -d "${home_admin}/.ssh" ]]                && rutas+=("${home_admin}/.ssh")
[[ -d "${home_admin}/nomad_server/config" ]] && rutas+=("${home_admin}/nomad_server/config")

existentes=()
for ruta in "${rutas[@]}"; do
    [[ -e "${ruta}" ]] && existentes+=("${ruta}")
done

registrar "Respaldando: ${existentes[*]}"

restic backup \
    --verbose \
    --tag automatico \
    --tag "${servidor}" \
    --exclude-file "${exclusiones}" \
    --exclude-caches \
    --one-file-system \
    "${existentes[@]}" \
    || fallar "El respaldo ha fallado."

registrar "Respaldo completado."

# ===========================================================================
#  4. Retención
# ===========================================================================
registrar "Aplicando la política de retención…"
restic forget \
    --keep-daily   "${ret_diarios}" \
    --keep-weekly  "${ret_semanales}" \
    --keep-monthly "${ret_mensuales}" \
    --keep-last 3 \
    --prune \
    || registrar "AVISO: la limpieza ha fallado; el respaldo sí se hizo."

# ===========================================================================
#  5. Copia remota (opcional)
# ===========================================================================
# Solo tiene sentido en modo local: en modo remoto el respaldo YA se hizo
# contra el remoto y no hay nada que copiar.
copia_remota_fallida=0
if [[ "${modo}" == "local" && -n "${repo_remoto}" ]]; then
    registrar "Copiando al repositorio remoto…"
    # 'copy' replica las instantáneas ya cifradas en lugar de volver a leer y
    # cifrar todo el sistema de archivos.
    if restic copy \
        --from-repo "${RESTIC_REPOSITORY}" \
        --from-password-file "${RESTIC_PASSWORD_FILE}" \
        --repo "${repo_remoto}" \
        --password-file "${RESTIC_PASSWORD_FILE}" 2>&1
    then
        registrar "Copia remota completada."
    else
        # No se llama a 'fallar': el respaldo local SÍ se hizo y perderlo por
        # un problema de red sería peor. Pero tampoco se calla: se avisa al
        # monitor en rojo. Un fallo de la copia remota que solo quede en el
        # registro se convierte, en unos meses, en creer que hay copia fuera
        # de casa cuando hace tiempo que no la hay.
        registrar "AVISO: la copia remota ha fallado; la local sí se hizo."
        copia_remota_fallida=1
    fi
fi

# ===========================================================================
#  6. Resumen y aviso
# ===========================================================================
registrar "Instantáneas en el repositorio:"
restic snapshots --compact 2>/dev/null | tail -8

# 'du' solo sirve para un repositorio en disco. Con uno remoto hay que
# preguntárselo a restic, que además informa del tamaño real tras deduplicar.
if [[ "${modo}" == "local" ]]; then
    tamano="$(du -sh "${RESTIC_REPOSITORY}" 2>/dev/null | cut -f1)"
else
    tamano="$(restic stats --mode raw-data 2>/dev/null \
              | grep -i 'total size' | cut -d: -f2 | tr -d ' ')"
fi
registrar "Tamaño del repositorio: ${tamano:-desconocido}"

if (( gancho_fallido == 1 )); then
    estado_aviso="down"
    mensaje_aviso="respaldo+hecho+pero+un+volcado+de+base+de+datos+fallo"
elif (( copia_remota_fallida == 1 )); then
    estado_aviso="down"
    mensaje_aviso="respaldo+local+correcto+pero+la+copia+remota+fallo"
else
    estado_aviso="up"
    mensaje_aviso="respaldo+correcto+${tamano:-}"
fi

if [[ -n "${push_url}" ]]; then
    if curl -fsS -m 10 "${push_url}?status=${estado_aviso}&msg=${mensaje_aviso}" >/dev/null 2>&1; then
        registrar "Aviso enviado al monitor."
    else
        registrar "AVISO: no se ha podido avisar al monitor."
    fi
fi

registrar "=== Respaldo terminado correctamente ==="
