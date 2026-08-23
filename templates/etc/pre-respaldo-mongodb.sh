#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — volcado de MongoDB antes del respaldo
#  Destino  : /etc/nomad/pre-respaldo.d/10-<proyecto>-mongodb.sh
#  Capítulo : docs/14_respaldos_restic.md § 3.4
#
#  CÓMO INSTALARLA
#
#      cd ~/nomad_server
#      source scripts/lib/entorno.sh
#      sudo mkdir -p /etc/nomad/pre-respaldo.d
#      nomad_plantilla etc/pre-respaldo-mongodb.sh \
#          | sudo tee /etc/nomad/pre-respaldo.d/10-miproyecto-mongodb.sh >/dev/null
#      sudo chmod 700 /etc/nomad/pre-respaldo.d/10-miproyecto-mongodb.sh
#      sudo vim /etc/nomad/pre-respaldo.d/10-miproyecto-mongodb.sh
#
#  Y pruébala a mano ANTES de fiarte de ella:
#      sudo /etc/nomad/pre-respaldo.d/10-miproyecto-mongodb.sh && echo CORRECTO
# ===========================================================================
set -euo pipefail

# --- CAMBIAR: los datos del proyecto ---------------------------------------
contenedor="miproyecto-db"
nombre_bd="miproyecto"
proyecto="miproyecto"
variable_usuario="MONGO_INITDB_ROOT_USERNAME"
variable_clave="MONGO_INITDB_ROOT_PASSWORD"

# ---------------------------------------------------------------------------
destino="/var/backups/nomad/volcados/${proyecto}"
mkdir -p "${destino}"
chmod 750 "${destino}"
archivo="${destino}/${nombre_bd}.archive.gz"

# 'mongodump --archive' produce un único archivo en lugar de un árbol de
# directorios: más fácil de mover, y restic lo deduplica igual de bien.
docker exec "${contenedor}" sh -c \
    "mongodump --archive --gzip --db=${nombre_bd} \
        --username=\"\${${variable_usuario}}\" \
        --password=\"\${${variable_clave}}\" \
        --authenticationDatabase=admin" \
    > "${archivo}.parcial"

mv "${archivo}.parcial" "${archivo}"
chmod 640 "${archivo}"

tamano="$(stat -c '%s' "${archivo}")"
if (( tamano < 500 )); then
    echo "ERROR: el volcado pesa ${tamano} bytes: parece vacío." >&2
    exit 1
fi

echo "Volcado correcto: ${archivo} ($(du -h "${archivo}" | cut -f1))"
