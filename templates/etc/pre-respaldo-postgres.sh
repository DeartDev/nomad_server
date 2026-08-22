#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — volcado de una base de datos PostgreSQL antes del respaldo
#  Destino  : /etc/nomad/pre-respaldo.d/10-<proyecto>-postgres.sh
#  Capítulo : docs/14_respaldos_restic.md § 3.4
#
#  Esta plantilla NO se instala sola: se copia una vez por proyecto que tenga
#  base de datos, cambiando las tres variables de abajo. El nombre del archivo
#  determina el orden de ejecución, de ahí el prefijo numérico.
#
#  CÓMO INSTALARLA
#
#      cd ~/nomad_server
#      source scripts/lib/entorno.sh
#      sudo mkdir -p /etc/nomad/pre-respaldo.d
#      nomad_plantilla etc/pre-respaldo-postgres.sh \
#          | sudo tee /etc/nomad/pre-respaldo.d/10-ejemplo-postgres.sh >/dev/null
#      sudo chmod 700 /etc/nomad/pre-respaldo.d/10-ejemplo-postgres.sh
#      sudo vim /etc/nomad/pre-respaldo.d/10-ejemplo-postgres.sh   # ← ajusta las tres variables
#
#  Y pruébala a mano ANTES de fiarte de ella:
#      sudo /etc/nomad/pre-respaldo.d/10-ejemplo-postgres.sh && echo CORRECTO
# ===========================================================================
set -euo pipefail

# --- CAMBIAR: los tres datos del proyecto ----------------------------------
contenedor="proyecto-ejemplo-db"      # nombre del contenedor de la base
usuario_bd="proyecto"                 # POSTGRES_USER del .env del proyecto
nombre_bd="proyecto"                  # POSTGRES_DB del .env del proyecto
proyecto="ejemplo"                    # nombre del proyecto, para el directorio

# ---------------------------------------------------------------------------
# El volcado NO va dentro del proyecto sino a /var/backups/nomad, que el
# respaldo recoge igual. El motivo es que el servicio de systemd corre con
# ProtectSystem=strict: si el gancho escribiera en ${DATOS_RAIZ} habría que
# darle permiso de escritura sobre TODOS los datos de TODOS los proyectos solo
# para dejar un volcado. Aquí escribe en el único sitio que ya necesita.
destino="/var/backups/nomad/volcados/${proyecto}"
mkdir -p "${destino}"
chmod 750 "${destino}"

# Un único archivo que se sobrescribe cada noche, en lugar de uno por fecha.
# El histórico lo da restic: cada instantánea guarda la versión de ese día, y
# la política de retención decide cuántas se conservan. Acumular archivos aquí
# duplicaría ese trabajo y llenaría el disco.
archivo="${destino}/${nombre_bd}.sql.gz"

# 'pg_dump' produce un volcado consistente aunque el motor esté escribiendo:
# lo hace dentro de una transacción. Eso es justo lo que copiar el directorio
# de datos NO garantiza.
docker exec "${contenedor}" \
    pg_dump --username "${usuario_bd}" --format plain --clean --if-exists "${nombre_bd}" \
    | gzip -9 > "${archivo}.parcial"

# Se renombra al final: si el volcado se corta a la mitad, el archivo bueno del
# día anterior sigue intacto en lugar de quedar sustituido por uno truncado.
mv "${archivo}.parcial" "${archivo}"
chmod 640 "${archivo}"

# Comprobación mínima: un .gz truncado se detecta aquí y no dentro de seis
# meses, cuando haga falta.
gzip -t "${archivo}"

echo "Volcado correcto: ${archivo} ($(du -h "${archivo}" | cut -f1))"
