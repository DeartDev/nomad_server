#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — volcado de MySQL o MariaDB antes del respaldo
#  Destino  : /etc/nomad/pre-respaldo.d/10-<proyecto>-mysql.sh
#  Capítulo : docs/14_respaldos_restic.md § 3.4
#
#  Vale para MySQL y para MariaDB: el comando de volcado es el mismo, solo
#  cambia su nombre según la imagen (mysqldump o mariadb-dump).
#
#  CÓMO INSTALARLA
#
#      cd ~/nomad_server
#      source scripts/lib/entorno.sh
#      sudo mkdir -p /etc/nomad/pre-respaldo.d
#      nomad_plantilla etc/pre-respaldo-mysql.sh \
#          | sudo tee /etc/nomad/pre-respaldo.d/10-miproyecto-mysql.sh >/dev/null
#      sudo chmod 700 /etc/nomad/pre-respaldo.d/10-miproyecto-mysql.sh
#      sudo vim /etc/nomad/pre-respaldo.d/10-miproyecto-mysql.sh   # ← las variables
#
#  Y pruébala a mano ANTES de fiarte de ella:
#      sudo /etc/nomad/pre-respaldo.d/10-miproyecto-mysql.sh && echo CORRECTO
# ===========================================================================
set -euo pipefail

# --- CAMBIAR: los datos del proyecto ---------------------------------------
contenedor="miproyecto-db"            # nombre del contenedor de la base
nombre_bd="miproyecto"                # el de MYSQL_DATABASE en el .env
proyecto="miproyecto"                 # nombre del proyecto

# La contraseña NO se escribe aquí. Se lee del entorno del propio contenedor,
# que ya la tiene: así este archivo no es un secreto más que custodiar.
variable_clave="MYSQL_ROOT_PASSWORD"  # o MARIADB_ROOT_PASSWORD

# ---------------------------------------------------------------------------
destino="/var/backups/nomad/volcados/${proyecto}"
mkdir -p "${destino}"
chmod 750 "${destino}"
archivo="${destino}/${nombre_bd}.sql.gz"

# El nombre del programa cambió en MariaDB 11: se prueban los dos.
if docker exec "${contenedor}" sh -c 'command -v mariadb-dump' >/dev/null 2>&1; then
    volcador="mariadb-dump"
else
    volcador="mysqldump"
fi

# --single-transaction es lo que hace el volcado CONSISTENTE sin bloquear la
# base: sin él, un volcado de una base en uso puede mezclar el estado de unas
# tablas con el de otras. Solo funciona con motores transaccionales (InnoDB),
# que es el que usa cualquier aplicación moderna.
docker exec "${contenedor}" sh -c \
    "${volcador} --single-transaction --quick --routines --triggers \
        --user=root --password=\"\${${variable_clave}}\" ${nombre_bd}" \
    | gzip -9 > "${archivo}.parcial"

# Se renombra al final: si el volcado se corta a la mitad, el archivo bueno del
# día anterior sigue intacto en lugar de quedar sustituido por uno truncado.
mv "${archivo}.parcial" "${archivo}"
chmod 640 "${archivo}"

gzip -t "${archivo}"

# Un volcado vacío pesa unos cientos de bytes y pasaría desapercibido.
tamano="$(stat -c '%s' "${archivo}")"
if (( tamano < 500 )); then
    echo "ERROR: el volcado pesa ${tamano} bytes: parece vacío." >&2
    exit 1
fi

echo "Volcado correcto: ${archivo} ($(du -h "${archivo}" | cut -f1))"
