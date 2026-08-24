#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — auditoría del servidor y guardián
# ===========================================================================
#  Propósito : instalar el recolector que produce el informe diario de estado,
#              con su usuario propio y su temporizador.
#  Uso       : sudo ./scripts/17_hermes.sh --help
#  Capítulo  : docs/17_hermes_guardian.md
#
#  Requiere root: crea un usuario del sistema y escribe unidades de systemd.
# ===========================================================================
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

mostrar_ayuda() {
    cat <<'AYUDA'
Uso: sudo ./scripts/17_hermes.sh [opciones]

Instala la auditoría diaria del servidor:

  1. Crea el usuario del sistema, sin shell y sin privilegios
  2. Prepara el directorio de informes

Opciones:
  -n, --check    Muestra qué cambiaría, sin tocar el sistema.
  -y, --si       No pide confirmación.
  -h, --help     Muestra esta ayuda.

LO QUE ESTE SCRIPT NO HACE:
  - No instala el agente Hermes. Eso es la fase 2 del capítulo.
  - No configura el monitor de Uptime Kuma que vigila el temporizador:
    es un paso de interfaz web y está en el capítulo 17 § 5.
AYUDA
}

procesar_argumentos_comunes "$@"
(( ${#NOMAD_ARGS_RESTANTES[@]} == 0 )) \
    || die "Opción desconocida: ${NOMAD_ARGS_RESTANTES[*]} (usa --help)"

# --- Comprobaciones previas --------------------------------------------------
log_paso "Comprobaciones previas"
requerir_root
cargar_entorno
requerir_variables DATOS_RAIZ ADMIN_USUARIO \
                   HERMES_HABILITADO HERMES_USUARIO HERMES_UID HERMES_AUDITORIA_HORA

# El capítulo 17 es opcional y ningún otro depende de él. Un script que hiciera
# algo con la configuración por defecto rompería esa promesa.
if [[ "${HERMES_HABILITADO}" != "si" ]]; then
    log_sinca "HERMES_HABILITADO no es 'si'. No hay nada que instalar."
    log_info  "Para activarlo: ./scripts/variables.sh --fijar HERMES_HABILITADO=si"
    resumen_final "17_hermes.sh"
    exit 0
fi

# Se valida aquí y no en el temporizador porque systemd acepta un OnCalendar
# mal formado sin rechistar y se queda sin disparar nunca. El fallo se vería
# semanas después, al preguntarse por qué no hay informes.
[[ "${HERMES_AUDITORIA_HORA}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] \
    || die "HERMES_AUDITORIA_HORA debe tener formato HH:MM (valor actual: '${HERMES_AUDITORIA_HORA}')"

DIR_HERMES="${DATOS_RAIZ}/hermes"
DIR_INFORMES="${DIR_HERMES}/informes"

# --- Paso 1: el usuario ------------------------------------------------------
log_paso "Usuario del sistema '${HERMES_USUARIO}'"

# El uid se fija a mano en lugar de dejarlo al sistema porque la fase 2 se lo
# pasa al contenedor como PUID. Si aquí saliera un número distinto en cada
# servidor, el contenedor escribiría ficheros de un dueño que no existe.
if id -u "${HERMES_USUARIO}" >/dev/null 2>&1; then
    UID_ACTUAL="$(id -u "${HERMES_USUARIO}")"
    [[ "${UID_ACTUAL}" == "${HERMES_UID}" ]] \
        || die "El usuario '${HERMES_USUARIO}' ya existe con uid ${UID_ACTUAL}, no ${HERMES_UID}. Resuélvelo a mano antes de seguir."
    log_sinca "Usuario ${HERMES_USUARIO} ya existe con el uid correcto."
else
    if getent passwd "${HERMES_UID}" >/dev/null; then
        die "El uid ${HERMES_UID} ya está ocupado por '$(getent passwd "${HERMES_UID}" | cut -d: -f1)'. Cambia HERMES_UID."
    fi
    ejecutar groupadd --system --gid "${HERMES_UID}" "${HERMES_USUARIO}"
    ejecutar useradd  --system --uid "${HERMES_UID}" --gid "${HERMES_UID}" \
                      --home-dir "${DIR_HERMES}" --no-create-home \
                      --shell /usr/sbin/nologin \
                      --comment "Auditoria del servidor (capitulo 17)" \
                      "${HERMES_USUARIO}"
fi

# Comprobación explícita, no confianza: si alguien añadiera este usuario a
# 'docker' o a 'sudo' más adelante, el script lo dice en voz alta y se niega a
# seguir. Pertenecer al grupo docker equivale a ser root (capítulo 09 § 3.2),
# y todo el diseño del capítulo 17 se apoya en que este usuario no puede nada.
#
# En modo --check el usuario puede no existir todavía; entonces no hay nada
# que comprobar y tampoco nada de qué preocuparse.
if id -u "${HERMES_USUARIO}" >/dev/null 2>&1; then
    for GRUPO in docker sudo adm wheel; do
        if id -nG "${HERMES_USUARIO}" 2>/dev/null | tr ' ' '\n' | contiene -x "${GRUPO}"; then
            die "El usuario '${HERMES_USUARIO}' pertenece al grupo '${GRUPO}'. Eso anula el diseño del capítulo 17. Quítalo con: sudo gpasswd -d ${HERMES_USUARIO} ${GRUPO}"
        fi
    done
    log_ok "El usuario no pertenece a ningún grupo con privilegios."
else
    log_check "el usuario aún no existe: la comprobación de grupos se hará al aplicar."
fi

# --- Paso 2: los directorios -------------------------------------------------
log_paso "Directorio de informes"

# 0750 y no 0755: el informe redactado sigue describiendo la infraestructura
# con bastante detalle. Que lo lean su dueño y su grupo, no todo el sistema.
for D in "${DIR_HERMES}" "${DIR_INFORMES}"; do
    if [[ -d "${D}" ]]; then
        log_sinca "${D} ya existe."
    else
        ejecutar install -d -m 0750 -o "${HERMES_USUARIO}" -g "${HERMES_USUARIO}" "${D}"
    fi
done

resumen_final "17_hermes.sh"
