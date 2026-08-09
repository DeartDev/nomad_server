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

# --- Valores sustituidos al instalar ---------------------------------------
# Estas dos las lee restic directamente del entorno.
RESTIC_REPOSITORY="${RESTIC_REPO_LOCAL}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE}"
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

punto_montaje="${RESTIC_USB_MOUNT}"
datos_raiz="${DATOS_RAIZ}"
admin_usuario="${ADMIN_USUARIO}"
servidor="${SERVIDOR_HOSTNAME}"
repo_remoto="${RESTIC_REPO_REMOTO}"
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
# ===========================================================================
registrar "=== Respaldo de ${servidor} ==="

[[ -r "${RESTIC_PASSWORD_FILE}" ]] \
    || fallar "No se puede leer el archivo de contraseña ${RESTIC_PASSWORD_FILE}"

mountpoint -q "${punto_montaje}" \
    || fallar "El disco de respaldo no está montado en ${punto_montaje}. ¿Está conectado?"

libre_gb="$(df -BG --output=avail "${punto_montaje}" | tail -1 | tr -dc '0-9')"
registrar "Espacio libre en el disco de respaldo: ${libre_gb} GB"
(( libre_gb < 5 )) && fallar "Quedan menos de 5 GB en el disco de respaldo."

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
if [[ -n "${repo_remoto}" ]]; then
    registrar "Copiando al repositorio remoto…"
    # 'copy' replica las instantáneas ya cifradas en lugar de volver a leer y
    # cifrar todo el sistema de archivos.
    restic copy \
        --from-repo "${RESTIC_REPOSITORY}" \
        --from-password-file "${RESTIC_PASSWORD_FILE}" \
        --repo "${repo_remoto}" \
        --password-file "${RESTIC_PASSWORD_FILE}" \
        2>&1 || registrar "AVISO: la copia remota ha fallado; la local sí se hizo."
fi

# ===========================================================================
#  6. Resumen y aviso
# ===========================================================================
registrar "Instantáneas en el repositorio:"
restic snapshots --compact 2>/dev/null | tail -8

tamano="$(du -sh "${RESTIC_REPOSITORY}" 2>/dev/null | cut -f1)"
registrar "Tamaño del repositorio: ${tamano:-desconocido}"

if [[ -n "${push_url}" ]]; then
    if curl -fsS -m 10 "${push_url}?status=up&msg=respaldo+correcto+${tamano:-}" >/dev/null 2>&1; then
        registrar "Aviso enviado al monitor."
    else
        registrar "AVISO: no se ha podido avisar al monitor."
    fi
fi

registrar "=== Respaldo terminado correctamente ==="
