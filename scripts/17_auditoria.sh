#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — auditoría del servidor y guardián
# ===========================================================================
#  Propósito : instalar el recolector que produce el informe diario de estado,
#              con su usuario propio y su temporizador.
#  Uso       : sudo ./scripts/17_auditoria.sh --help
#  Capítulo  : docs/17_auditoria_del_servidor.md
#
#  Requiere root: crea un usuario del sistema y escribe unidades de systemd.
# ===========================================================================
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

mostrar_ayuda() {
    cat <<'AYUDA'
Uso: sudo ./scripts/17_auditoria.sh [opciones]

Instala la auditoría diaria del servidor:

  1. Crea el usuario del sistema, sin shell y sin privilegios
  2. Prepara el directorio de informes
  3. Instala el recolector y el conserje en /usr/local/sbin
  4. Instala y activa el temporizador diario y el vigilante de proyectos

Opciones:
  -n, --check    Muestra qué cambiaría, sin tocar el sistema.
  -y, --si       No pide confirmación.
  -h, --help     Muestra esta ayuda.

LO QUE ESTE SCRIPT NO HACE:
  - No crea el monitor Push de Uptime Kuma que recibe los avisos, ni
    prueba que el aviso llega. Es un paso de interfaz web y está en el
    capítulo 17 § 5. Un sistema de avisos sin probar no es un sistema
    de avisos.
  - No interpreta el informe. Lo escribe; leerlo es cosa tuya.
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
                   AUDITORIA_HABILITADA AUDITORIA_USUARIO AUDITORIA_UID AUDITORIA_HORA

# El capítulo 17 es opcional y ningún otro depende de él. Un script que hiciera
# algo con la configuración por defecto rompería esa promesa.
if [[ "${AUDITORIA_HABILITADA}" != "si" ]]; then
    log_sinca "AUDITORIA_HABILITADA no es 'si'. No hay nada que instalar."
    log_info  "Para activarlo: ./scripts/variables.sh --fijar AUDITORIA_HABILITADA=si"
    resumen_final "17_auditoria.sh"
    exit 0
fi

# La URL de aviso, si la hay, debe ser la BASE y nada más.
#
# Kuma no enseña la URL desnuda: enseña un ejemplo listo para pegar, del tipo
#   .../api/push/TOKEN?status=up&msg=OK&ping=
# Copiarlo entero rompe el aviso de dos maneras a la vez, y las dos en
# silencio: el shell parte el comando en el primer '&' —guardando la URL a
# medias y lanzando trabajos en segundo plano—, y aunque se escape, el
# recolector añade DESPUÉS su propia cadena de consulta y queda duplicada.
#
# Nada de eso da error. Simplemente no llega ningún aviso, y eso solo se nota
# el día que hacía falta.
if [[ -n "${AUDITORIA_PUSH_URL:-}" && "${AUDITORIA_PUSH_URL}" == *[\?\&]* ]]; then
    log_error "AUDITORIA_PUSH_URL no debe llevar cadena de consulta."
    log_error "Valor actual: ${AUDITORIA_PUSH_URL}"
    log_error "Quédate solo con la parte hasta el token, y entre comillas simples:"
    log_error "    ./scripts/variables.sh --fijar 'AUDITORIA_PUSH_URL=${AUDITORIA_PUSH_URL%%\?*}'"
    die "Corrige la URL y vuelve a ejecutar."
fi

# Se valida aquí y no en el temporizador porque systemd acepta un OnCalendar
# mal formado sin rechistar y se queda sin disparar nunca. El fallo se vería
# semanas después, al preguntarse por qué no hay informes.
[[ "${AUDITORIA_HORA}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] \
    || die "AUDITORIA_HORA debe tener formato HH:MM (valor actual: '${AUDITORIA_HORA}')"

DIR_AUDITORIA="${DATOS_RAIZ}/auditoria"
DIR_INFORMES="${DIR_AUDITORIA}/informes"

# --- Paso 1: el usuario ------------------------------------------------------
log_paso "Usuario del sistema '${AUDITORIA_USUARIO}'"

# El uid se fija a mano en lugar de dejarlo al sistema porque la fase 2 se lo
# pasa al contenedor como PUID. Si aquí saliera un número distinto en cada
# servidor, el contenedor escribiría ficheros de un dueño que no existe.
if id -u "${AUDITORIA_USUARIO}" >/dev/null 2>&1; then
    UID_ACTUAL="$(id -u "${AUDITORIA_USUARIO}")"
    [[ "${UID_ACTUAL}" == "${AUDITORIA_UID}" ]] \
        || die "El usuario '${AUDITORIA_USUARIO}' ya existe con uid ${UID_ACTUAL}, no ${AUDITORIA_UID}. Resuélvelo a mano antes de seguir."
    log_sinca "Usuario ${AUDITORIA_USUARIO} ya existe con el uid correcto."
else
    if getent passwd "${AUDITORIA_UID}" >/dev/null; then
        die "El uid ${AUDITORIA_UID} ya está ocupado por '$(getent passwd "${AUDITORIA_UID}" | cut -d: -f1)'. Cambia AUDITORIA_UID."
    fi
    ejecutar groupadd --system --gid "${AUDITORIA_UID}" "${AUDITORIA_USUARIO}"
    ejecutar useradd  --system --uid "${AUDITORIA_UID}" --gid "${AUDITORIA_UID}" \
                      --home-dir "${DIR_AUDITORIA}" --no-create-home \
                      --shell /usr/sbin/nologin \
                      --comment "Auditoria del servidor (capitulo 17)" \
                      "${AUDITORIA_USUARIO}"
fi

# Comprobación explícita, no confianza: si alguien añadiera este usuario a
# 'docker' o a 'sudo' más adelante, el script lo dice en voz alta y se niega a
# seguir. Pertenecer al grupo docker equivale a ser root (capítulo 09 § 3.2),
# y todo el diseño del capítulo 17 se apoya en que este usuario no puede nada.
#
# En modo --check el usuario puede no existir todavía; entonces no hay nada
# que comprobar y tampoco nada de qué preocuparse.
if id -u "${AUDITORIA_USUARIO}" >/dev/null 2>&1; then
    for GRUPO in docker sudo adm wheel; do
        if id -nG "${AUDITORIA_USUARIO}" 2>/dev/null | tr ' ' '\n' | contiene -x "${GRUPO}"; then
            die "El usuario '${AUDITORIA_USUARIO}' pertenece al grupo '${GRUPO}'. Eso anula el diseño del capítulo 17. Quítalo con: sudo gpasswd -d ${AUDITORIA_USUARIO} ${GRUPO}"
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
for D in "${DIR_AUDITORIA}" "${DIR_INFORMES}"; do
    if [[ -d "${D}" ]]; then
        log_sinca "${D} ya existe."
    else
        ejecutar install -d -m 0750 -o "${AUDITORIA_USUARIO}" -g "${AUDITORIA_USUARIO}" "${D}"
    fi
done

# --- Paso 3: los scripts -----------------------------------------------------
log_paso "Recolector y conserje"
instalar_plantilla etc/nomad-auditoria.sh /usr/local/sbin/nomad-auditoria.sh 0750 root:root
instalar_plantilla etc/nomad-conserje.sh  /usr/local/sbin/nomad-conserje.sh  0750 root:root

# --- Paso 4: las unidades ----------------------------------------------------
log_paso "Temporizador y vigilante"

ANTES="$(cambios)"
instalar_plantilla systemd/nomad-auditoria.service /etc/systemd/system/nomad-auditoria.service
instalar_plantilla systemd/nomad-auditoria.timer   /etc/systemd/system/nomad-auditoria.timer
instalar_plantilla systemd/nomad-conserje.service  /etc/systemd/system/nomad-conserje.service
instalar_plantilla systemd/nomad-conserje.path     /etc/systemd/system/nomad-conserje.path

# Recargar solo si algo cambió de verdad. Sin el contador en archivo esto
# fallaría en silencio: 'instalar_plantilla' escribe desde dentro de una
# tubería, y una variable incrementada ahí no sobrevive al subshell
# (lib/common.sh, comentario de marcar_cambio).
if hubo_cambios_desde "${ANTES}"; then
    ejecutar systemctl daemon-reload
fi

habilitar_servicio nomad-auditoria.timer
habilitar_servicio nomad-conserje.path

# --- Aviso de lo que queda a mano --------------------------------------------
if [[ -z "${AUDITORIA_PUSH_URL:-}" ]]; then
    log_aviso "AUDITORIA_PUSH_URL está vacía: la auditoría no avisará de nada."
    log_aviso "Crea un monitor Push en Uptime Kuma (capítulo 17 § 5, paso 6) y fíjala:"
    log_aviso "    ./scripts/variables.sh --fijar AUDITORIA_PUSH_URL=<la-url>"
fi

log_info "Primera ejecución a mano, para no esperar a mañana:"
log_info "    sudo systemctl start nomad-auditoria.service"
log_info "    sudo cat ${DIR_INFORMES}/estado.txt"

resumen_final "17_auditoria.sh"
