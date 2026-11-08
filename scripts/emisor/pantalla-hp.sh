#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — pantalla-hp: abre y cierra la pantalla extendida en el HP
# ===========================================================================
#  Propósito : desde el portátil, crear el monitor virtual, fijar la disposición,
#              arrancar Sunshine y pedir al HP que arranque su unidad; y dejarlo
#              todo como estaba al terminar, aunque nadie ejecute 'off'.
#  Uso       : pantalla-hp extender|principal|off|estado|vincular
#  Capítulo  : docs/18_pantalla_extendida.md
#
#  Corre con tu usuario, en el portátil. ~/.local/bin/pantalla-hp es un enlace a
#  este archivo: por eso la ruta se resuelve siguiendo enlaces.
#
#  LO QUE PROTEGE ESTE SCRIPT
#  --------------------------
#  Un fallo aquí deja el portátil con la pantalla negra, y ya pasó una vez. Las
#  reglas que lo evitan, y que no se deben relajar:
#
#  - Nada se toca hasta comprobar la red, que no hay sesión y que el HP responde
#    por el mismo camino, sin preguntas, que se usará con las pantallas movidas.
#  - Antes de mover una pantalla hay una restauración programada en systemd, que
#    no depende de este proceso ni de este repositorio.
#  - 'kscreen-doctor' devuelve 0 aunque la salida no exista, y entonces no aplica
#    NADA de esa llamada. Su código de salida no vale: el resultado se comprueba
#    con 'kscreen-doctor -o'. Si el monitor virtual murió, la llamada que nombra
#    a la virtual no enciende la interna, y hay que repetirla sin nombrarla.
#  - Con la interna apagada nadie ve la terminal: el ssh de después de tocar las
#    pantallas no pregunta nada y tiene un tiempo límite.
#  - 'detener' nunca aborta a medias: un paso que falla no impide el siguiente.
# ===========================================================================
set -euo pipefail

SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
source "$(dirname "${SCRIPT}")/../lib/common.sh"

mostrar_ayuda() {
    cat <<'AYUDA'
Uso: pantalla-hp <orden>

Órdenes:
  extender    El panel del HP es un segundo monitor, a la derecha de la interna.
  principal   El panel del HP es la pantalla principal; la interna se apaga.
  off         Restaura la interna y para el HP, Sunshine y el monitor virtual.
  estado      Muestra la sesión, sin cambiar nada.
  vincular    Vincula Moonlight con Sunshine. Paso único; pide dos contraseñas.

Opciones:
  -n, --check    Muestra lo que haría, sin tocar nada.
  -h, --help     Muestra esta ayuda.

LO QUE PASA SI NO EJECUTAS 'off':
  Sin cliente conectado durante 60 segundos, la sesión se cierra sola y la
  pantalla interna vuelve. Al arrancar, el HP tiene 120 segundos para conectar.
  Si además fallara ese vigilante, la interna vuelve en 10 minutos.
AYUDA
}

# --- Constantes --------------------------------------------------------------
V=Virtual-hp-pantalla
I=eDP-1

# Las unidades del HP: la de este emisor y la del otro sistema del portátil. El
# portátil es uno solo, así que una sesión de Windows abierta es una huérfana.
U_HP=nomad-pantalla@fedora.service
U_HP_OTRA=nomad-pantalla@windows.service

U_MONITOR=pantalla-hp-monitor
U_SUNSHINE=pantalla-hp-sunshine
U_VIGILANTE=pantalla-hp-vigilante
U_RESTAURAR=pantalla-restaurar

PUERTO_MONITOR=15905
BITRATE_WIFI=15000           # Kbps: tope de Sunshine si la salida a la red es Wi-Fi
SYS_NET="${SYS_NET:-/sys/class/net}"
PLAZO_RESTAURACION=600       # s: la restauración programada, si todo lo demás falla
PLAZO_PRIMERA_CONEXION=120   # s: lo que tiene el HP para conectar al arrancar
PLAZO_SIN_CLIENTE=60         # s: sin cliente tras haberlo tenido
CADENCIA_REARME=60           # s: cada cuánto se aplaza la restauración con cliente
PLAZO_SALIDA=30              # s: lo que puede tardar en aparecer la salida virtual
PLAZO_DISPOSICION=5          # s: lo que puede tardar KWin en aplicar la disposición
PLAZO_VINCULO=60             # s: lo que puede tardar la petición de Moonlight
PAUSA_TRAS_VINCULO=10        # s: Moonlight sigue el intercambio tras aceptar el PIN
LIMITE_PARADA_SUNSHINE=15    # s: tras esto, SIGKILL. Tarda varios en salir
LIMITE_SSH=20                # s: tope de una orden por ssh
SSH_SIN_PREGUNTAS=(-o BatchMode=yes -o ConnectTimeout=5)

# Enteros en segundos. Las pruebas los cambian; el vigilante cuenta sumándolos.
INTERVALO_VIGILANTE="${PANTALLA_HP_INTERVALO_VIGILANTE:-5}"
INTERVALO_ESPERA="${PANTALLA_HP_INTERVALO_ESPERA:-1}"
# Entre los dos sondeos que confirman la interna, antes de retirar el temporizador.
PAUSA_ASENTAR="${PANTALLA_HP_PAUSA_ASENTAR:-3}"

REGISTRO_SUNSHINE="${HOME}/.config/sunshine/sunshine.log"

# La virtual se mueve ANTES de encender la interna, en la misma llamada: si no,
# las dos coinciden en 0,0 y la interna se queda sin imagen.
ORDEN_INTERNA=("output.${I}.enable" "output.${I}.position.0,0" "output.${I}.priority.1")
ORDEN_RESTAURAR=("output.${V}.position.1920,0" "${ORDEN_INTERNA[@]}")

SOY_VIGILANTE=0
ID_PETICION=""
CLAVE_PANEL=""

# ===========================================================================
#  CONSULTAS
# ===========================================================================

# Espera a que una orden tenga éxito, con límite.
#   esperar <segundos> orden [argumentos]
esperar() {
    local plazo="$1" pasados=0
    shift
    until "$@"; do
        if (( pasados >= plazo )); then return 1; fi
        sleep "${INTERVALO_ESPERA}"
        pasados=$(( pasados + INTERVALO_ESPERA ))
    done
}

# 'kscreen-doctor -o' colorea la salida aunque vaya a una tubería. Una salida
# virtual no imprime 'enabled' sino 'disable unsupported': no se puede apagar.
salidas() { kscreen-doctor -o 2>/dev/null | sed -E 's/\x1b\[[0-9;]*m//g'; }

# Imprime "enabled 0,0" o "disabled 0,0", y nada si la salida no existe.
dato_salida() {
    local texto
    texto="$(salidas)" || return 1
    awk -v n="$1" '
        $1 == "Output:" { en = ($3 == n) }
        en && ($1 == "enabled" || $1 == "disabled") { estado = $1 }
        en && $1 == "disable" && $2 == "unsupported" { estado = "enabled" }
        en && $1 == "Geometry:" { posicion = $2 }
        END { if (estado != "") print estado, posicion }
    ' <<<"${texto}"
}

salida_existe()     { [[ -n "$(dato_salida "$1")" ]]; }
salida_es()         { [[ "$(dato_salida "$1")" == "$2" ]]; }
interna_encendida() { [[ "$(dato_salida "${I}")" == enabled* ]]; }

disposicion_aplicada() {
    if [[ "$1" == extender ]]; then
        salida_es "${I}" "enabled 0,0" && salida_es "${V}" "enabled 1920,0"
    else
        salida_es "${V}" "enabled 0,0" && [[ "$(dato_salida "${I}")" == disabled* ]]
    fi
}

unidad_activa() { systemctl --user is-active --quiet "$1" >/dev/null 2>&1; }

# Sunshine solo no basta: un monitor huérfano también impide crear otro.
sesion_activa() { unidad_activa "${U_SUNSHINE}" || unidad_activa "${U_MONITOR}"; }

# La última línea que coincide decide. 'Ping Timeout' cuenta como fin de sesión:
# en los cortes de cable medidos, CLIENT DISCONNECTED llegó unos 5 segundos después,
# pero no hay que depender de ello. El registro se vacía en cada arranque de
# Sunshine; si no existe, no hay cliente.
cliente_conectado() {
    local ultima
    ultima="$(grep -E 'CLIENT (CONNECTED|DISCONNECTED)|Ping Timeout' "${REGISTRO_SUNSHINE}" 2>/dev/null | tail -n 1 || true)"
    [[ "${ultima}" == *"CLIENT CONNECTED"* ]]
}

# ===========================================================================
#  COMPROBACIONES PREVIAS
# ===========================================================================

comprobar_red() {
    if ! ip -4 -br addr | contiene -F " ${PANTALLA_EMISOR_IP}/"; then
        die "Este equipo no tiene la IP ${PANTALLA_EMISOR_IP}: ¿Tailscale está conectado? No se ha tocado nada."
    fi
}

comprobar_previo() {
    requerir_variables PANTALLA_EMISOR_IP PANTALLA_HP_SSH
    requerir_comandos kscreen-doctor krfb-virtualmonitor systemd-run systemd-inhibit sunshine ssh
    comprobar_red
    if sesion_activa; then
        die "Ya hay una sesión activa. Ciérrala antes con: pantalla-hp off"
    fi
}

# El primer ssh sí puede preguntar la frase de la clave: es el último momento en
# que la terminal se ve seguro. 'AddKeysToAgent' la deja en el agente, porque
# todo lo que viene después va con BatchMode y no puede preguntar nada.
#
# El segundo recorre ese camino exacto antes de tocar nada: sin la clave en el
# agente o sin la regla de sudo, fallaría ya con las pantallas movidas. 'sudo -l'
# solo consulta, no arranca la unidad. Necesita la ruta completa de la orden.
#
# Un 1 es de sudo, no de ssh (255) ni de 'timeout' (124): ssh ha entrado, pero la
# regla no permite la instancia. Es lo que pasa con un HP de la versión anterior,
# cuyo sudoers solo conoce nomad-pantalla.service.
comprobar_hp() {
    if ! ssh -o AddKeysToAgent=yes -o ConnectTimeout=5 "${PANTALLA_HP_SSH}" true; then
        die "No se llega a ${PANTALLA_HP_SSH} por ssh. No se ha tocado nada."
    fi
    local rc=0
    timeout -k 2 "${LIMITE_SSH}" ssh "${SSH_SIN_PREGUNTAS[@]}" "${PANTALLA_HP_SSH}" \
        sudo -n -l /usr/bin/systemctl start "${U_HP}" < /dev/null > /dev/null || rc=$?
    if (( rc == 1 )); then
        die "El sudo de ${PANTALLA_HP_SSH} no permite arrancar ${U_HP} sin contraseña. Si el HP tiene la versión anterior, ejecuta allí: sudo ./scripts/18_pantalla.sh. No se ha tocado nada."
    elif (( rc != 0 )); then
        die "${PANTALLA_HP_SSH} no responde sin preguntas: revisa 'ssh-add -l' y la regla de sudo del HP. No se ha tocado nada."
    fi
}

# ===========================================================================
#  UNIDADES
# ===========================================================================

# Una unidad parada pero fallida sigue cargada, y systemd-run se niega a crear
# otra con su nombre. Ni 'stop' ni 'reset-failed' fallan aquí si no había nada.
retirar_unidad() {
    systemctl --user stop "$1" >/dev/null 2>&1 || true
    systemctl --user reset-failed "$1" >/dev/null 2>&1 || true
}

crear_monitor() {
    local clave
    clave="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
    systemd-run --user --quiet --unit="${U_MONITOR}" \
        krfb-virtualmonitor --resolution 1920x1080 --name hp-pantalla \
        --password "${clave}" --port "${PUERTO_MONITOR}"
}

# Programa o aplaza la restauración. No llama a este script a propósito: debe
# funcionar aunque el repositorio falte o cargar la configuración falle. La
# segunda llamada es para cuando la virtual ya no existe.
armar_restauracion() {
    retirar_unidad "${U_RESTAURAR}.timer"
    retirar_unidad "${U_RESTAURAR}.service"
    systemd-run --user --quiet --unit="${U_RESTAURAR}" --on-active="${PLAZO_RESTAURACION}" \
        bash -c "kscreen-doctor ${ORDEN_RESTAURAR[*]}; kscreen-doctor ${ORDEN_INTERNA[*]}"
}

# La ruta debe ser /usr/bin/sunshine: KWin concede la captura por ruta ejecutable.
# El HP pide siempre el mismo bitrate. El tope va en Sunshine, en este equipo,
# para pasar del cable al Wi-Fi sin tocar el HP ni usar sudo.
tope_bitrate() {
    local dev
    dev="$(ip route get 1.1.1.1 2>/dev/null \
        | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
    if [[ -n "${dev}" && -d "${SYS_NET}/${dev}/wireless" ]]; then
        log_info "Salida por Wi-Fi (${dev}): bitrate limitado a ${BITRATE_WIFI} Kbps." >&2
        echo "max_bitrate=${BITRATE_WIFI}"
    fi
}

arrancar_sunshine() {
    local tope
    tope="$(tope_bitrate)"
    systemd-run --user --quiet --unit="${U_SUNSHINE}" \
        --property=StandardInput=null \
        --property=TimeoutStopSec="${LIMITE_PARADA_SUNSHINE}" \
        systemd-inhibit --what=handle-lid-switch:sleep:idle --who=pantalla-hp \
        --why="Pantalla extendida en el HP" --mode=block /usr/bin/sunshine ${tope:+"${tope}"}
}

# El modo va en el entorno: la orden solo admite un argumento.
lanzar_vigilante() {
    systemd-run --user --quiet --unit="${U_VIGILANTE}" \
        --setenv=PANTALLA_HP_MODO="$1" "${SCRIPT}" --vigilar
}

# ===========================================================================
#  PANTALLAS
# ===========================================================================

disposicion() {
    if [[ "$1" == extender ]]; then
        kscreen-doctor \
            "output.${V}.enable" "output.${V}.position.1920,0" "output.${V}.priority.2" \
            "output.${I}.enable" "output.${I}.position.0,0" "output.${I}.priority.1"
    else
        kscreen-doctor \
            "output.${V}.enable" "output.${V}.position.0,0" "output.${V}.priority.1" \
            "output.${I}.priority.2" "output.${I}.disable"
    fi
}

# Enciende la interna si sigue apagada, ya sin nombrar a la virtual.
asegurar_interna() {
    if esperar "${PLAZO_DISPOSICION}" interna_encendida; then return 0; fi
    kscreen-doctor "${ORDEN_INTERNA[@]}"
    esperar "${PLAZO_DISPOSICION}" interna_encendida
}

restaurar() {
    kscreen-doctor "${ORDEN_RESTAURAR[@]}"
    asegurar_interna
}

# La interna debe seguir encendida en dos sondeos separados: KDE reaplica su
# disposición un momento después de desaparecer la virtual, y un solo sondeo
# pasaría justo antes.
interna_estable() {
    asegurar_interna || return 1
    sleep "${PAUSA_ASENTAR}"
    interna_encendida
}

# ===========================================================================
#  ARRANQUE Y PARADA
# ===========================================================================

# Restauración programada, monitor, disposición y Sunshine, en ese orden.
#
# La restauración va antes del monitor porque crearlo ya mueve las pantallas: KDE
# puede reaplicar una disposición guardada en cuanto aparece la virtual. La orden
# programada funciona aunque la virtual todavía no exista.
#
# El modo se aplica ANTES de Sunshine: al revés, Sunshine calcula el ratón con la
# geometría antigua y este solo alcanza media pantalla.
#
# Se llama dentro de un 'if', donde 'set -e' no actúa: cada paso devuelve su
# error a mano para que quien llama pueda ejecutar 'detener'.
levantar_pila() {
    local modo="$1"

    retirar_unidad "${U_VIGILANTE}"
    retirar_unidad "${U_SUNSHINE}"
    retirar_unidad "${U_MONITOR}"

    armar_restauracion || { log_error "No se pudo programar la restauración."; return 1; }

    log_paso "Monitor virtual"
    crear_monitor || { log_error "No se pudo crear el monitor virtual."; return 1; }
    if ! esperar "${PLAZO_SALIDA}" salida_existe "${V}"; then
        log_error "La salida ${V} no ha aparecido en ${PLAZO_SALIDA} segundos."
        return 1
    fi

    log_paso "Disposición: ${modo}"
    disposicion "${modo}" || { log_error "kscreen-doctor ha fallado."; return 1; }
    if ! esperar "${PLAZO_DISPOSICION}" disposicion_aplicada "${modo}"; then
        log_error "La disposición '${modo}' no se ha aplicado. ${I}: $(dato_salida "${I}"). ${V}: $(dato_salida "${V}")."
        return 1
    fi

    log_paso "Sunshine"
    arrancar_sunshine || { log_error "No se pudo arrancar Sunshine."; return 1; }
}

# 'start' sobre una unidad ya activa no hace nada y devuelve 0: seguiría el
# Moonlight de una sesión anterior, ya sin conexión. Se para antes, en la misma
# llamada, y el 'stop' puede fallar sin más: decide el 'start'. Se para también
# la sesión de Windows, por si quedó huérfana. Cada 'stop' va aparte: sudo
# compara la orden entera, y la regla nombra una unidad por orden.
pedir_hp() {
    log_paso "Unidad del HP"
    if ! timeout -k 2 "${LIMITE_SSH}" ssh "${SSH_SIN_PREGUNTAS[@]}" "${PANTALLA_HP_SSH}" \
            sudo -n systemctl stop "${U_HP}" ';' \
            sudo -n systemctl stop "${U_HP_OTRA}" ';' \
            sudo -n systemctl start "${U_HP}" < /dev/null; then
        log_error "${PANTALLA_HP_SSH} no ha arrancado ${U_HP}."
        return 1
    fi
}

parar_hp() {
    if [[ -z "${PANTALLA_HP_SSH:-}" ]]; then
        log_aviso "Sin PANTALLA_HP_SSH: no se ha podido parar la unidad del HP."
        return 0
    fi
    # El tope no es opcional: es tiempo con la interna apagada. Funciona aunque
    # 'detener' ignore SIGTERM, porque el hijo de 'timeout' no hereda ese ignorar
    # (medido). '-k' solo cubre un ssh que no salga con SIGTERM.
    # Las dos: un 'off' también recoge una sesión de Windows huérfana. El código
    # es el del último 'stop', y parar una unidad ya parada da 0: el aviso de
    # abajo cubre sobre todo un HP que no contesta.
    if ! timeout -k 2 "${LIMITE_SSH}" ssh "${SSH_SIN_PREGUNTAS[@]}" "${PANTALLA_HP_SSH}" \
            sudo -n systemctl stop "${U_HP}" ';' \
            sudo -n systemctl stop "${U_HP_OTRA}" < /dev/null; then
        log_aviso "${PANTALLA_HP_SSH} no ha respondido: su unidad puede seguir en marcha."
    fi
}

# Deja el portátil como estaba. Se puede repetir y nunca aborta a medias: las
# señales se ignoran y 'set -e' se apaga, porque un Ctrl-C o una terminal cerrada
# no pueden dejar la interna apagada.
#
# El vigilante va primero: vería caer Sunshine y haría otro 'detener' a la vez.
# Pero el propio vigilante no se para a sí mismo, o moriría a mitad de esto.
# Restaurar va justo después, antes que nada que pueda tardar o fallar: es local,
# y con la virtual aún viva la llamada que la nombra se aplica entera. Parar antes
# el HP costaría hasta LIMITE_SSH segundos con la interna apagada.
# El monitor se para después de restaurar: si la virtual desaparece con la interna
# apagada, no queda ninguna pantalla.
detener() {
    set +e
    trap '' INT TERM HUP PIPE

    if (( SOY_VIGILANTE == 0 )); then retirar_unidad "${U_VIGILANTE}"; fi
    restaurar
    parar_hp
    retirar_unidad "${U_SUNSHINE}"
    retirar_unidad "${U_MONITOR}"

    # Se comprueba otra vez: KDE reaplica disposiciones al desaparecer la virtual.
    if interna_estable; then
        retirar_unidad "${U_RESTAURAR}.timer"
        retirar_unidad "${U_RESTAURAR}.service"
        log_ok "Pantalla interna restaurada."
        return 0
    fi

    # Un último intento, sin esperar al temporizador. Este se conserva pase lo que
    # pase: la interna ya ha demostrado que no se queda encendida.
    asegurar_interna
    log_error "La pantalla ${I} no se ha mantenido encendida. A mano: kscreen-doctor ${ORDEN_INTERNA[*]}"
    return 1
}

interrumpir() {
    log_aviso "Interrumpido: se deshace lo hecho." || true
    detener
    exit 130
}

arrancar() {
    local modo="$1"
    comprobar_previo
    comprobar_hp

    trap interrumpir INT TERM HUP
    if ! levantar_pila "${modo}" || ! lanzar_vigilante "${modo}" || ! pedir_hp; then
        log_error "No se ha podido abrir la sesión: se deshace lo hecho."
        detener
        exit 1
    fi
    trap - INT TERM HUP

    log_ok "Sesión '${modo}' en marcha. Se cierra con: pantalla-hp off"
}

# ===========================================================================
#  VIGILANTE
# ===========================================================================

# Sin Sunshine o sin monitor no puede volver ningún cliente, así que no se
# esperan los plazos. Además el registro no sirve: si Sunshine muere, su última
# línea sigue diciendo que hay cliente.
#
# El tiempo se cuenta sumando intervalos, no con el reloj: da unos segundos más
# de plazo en el peor caso y permite probar 10 minutos sin esperarlos.
#
# No abre ssh salvo para el 'stop' de 'detener': 'who' contaría esa sesión en el
# HP y bloquearía su reinicio automático.
#
# En 'principal' mantiene además la disposición. Al cerrar la tapa, KWin aplica
# la que tenga guardada para la tapa cerrada; si es la del extensor, enciende la
# interna como principal y la barra de Plasma se va con ella, fuera de la vista
# (medido el 2026-11-08). Reaplicarla con la tapa cerrada la deja guardada para
# la próxima vez. En 'extender' no se toca: no hay nada que fijar.
vigilar() {
    local limite="${PLAZO_PRIMERA_CONEXION}" sin_cliente=0 desde_rearme=0
    local modo="${PANTALLA_HP_MODO:-}"

    while true; do
        sleep "${INTERVALO_VIGILANTE}"
        desde_rearme=$(( desde_rearme + INTERVALO_VIGILANTE ))

        if ! unidad_activa "${U_SUNSHINE}" || ! unidad_activa "${U_MONITOR}"; then
            log_aviso "Sunshine o el monitor han terminado: se cierra la sesión."
            detener
            return
        fi

        if cliente_conectado; then
            limite="${PLAZO_SIN_CLIENTE}"
            sin_cliente=0
            if [[ "${modo}" == principal ]] && ! disposicion_aplicada principal; then
                log_aviso "KDE ha cambiado la disposición (¿tapa cerrada?): se vuelve a aplicar 'principal'."
                disposicion principal || log_aviso "kscreen-doctor ha fallado; se reintenta en el próximo sondeo."
            fi
            if (( desde_rearme >= CADENCIA_REARME )); then
                # Si falla no se reinicia la cuenta: se reintenta en el próximo
                # sondeo, porque ahora mismo puede no haber temporizador.
                if armar_restauracion; then
                    desde_rearme=0
                else
                    log_aviso "No se pudo aplazar la restauración; se reintenta."
                fi
            fi
            continue
        fi

        sin_cliente=$(( sin_cliente + INTERVALO_VIGILANTE ))
        if (( sin_cliente >= limite )); then
            log_info "Sin cliente durante ${sin_cliente} segundos: se cierra la sesión."
            detener
            return
        fi
    done
}

# ===========================================================================
#  VÍNCULO
# ===========================================================================

# La contraseña va por la entrada de curl: en los argumentos la vería 'ps'.
api_sunshine() {
    local escapada="${CLAVE_PANEL//\\/\\\\}"
    escapada="${escapada//\"/\\\"}"
    printf 'user = "nomad:%s"\n' "${escapada}" \
        | curl -fsS -k --max-time 10 -K - "$@" "https://${PANTALLA_EMISOR_IP}:47990/api/pin"
}

# Busca la petición del HP y deja su id, con su tipo JSON, en ID_PETICION.
buscar_peticion() {
    local respuesta
    respuesta="$(api_sunshine 2>/dev/null)" || return 1
    ID_PETICION="$(jq -c --arg ip "${TS_IP}" \
        'first(.pairings[]? | select((.address // "" | sub("^::ffff:"; "")) == $ip) | .id) // empty' \
        <<<"${respuesta}" 2>/dev/null)" || return 1
    [[ -n "${ID_PETICION}" ]]
}

confirmar_pin() {
    local pin="$1" cuerpo respuesta
    cuerpo="$(jq -cn --argjson id "${ID_PETICION}" --arg pin "${pin}" \
        '{pairing_id: $id, pin: $pin, name: "hp-pantalla"}')" || return 1
    respuesta="$(api_sunshine -X POST -H 'Content-Type: application/json' -d "${cuerpo}")" || return 1
    [[ "$(jq -r '.status' <<<"${respuesta}")" == true ]]
}

vincular_con_hp() {
    local pin="$1"
    log_paso "Petición de vínculo en el HP"
    log_info "Te pedirá la contraseña de sudo del HP."
    if ! ssh -t "${PANTALLA_HP_SSH}" sudo systemctl start "nomad-pantalla-vincular@fedora-${pin}.service"; then
        log_error "El HP no ha arrancado la unidad de vínculo."
        return 1
    fi
    if ! esperar "${PLAZO_VINCULO}" buscar_peticion; then
        log_error "Sunshine no ha recibido en ${PLAZO_VINCULO} segundos una petición desde ${TS_IP}, la IP del HP."
        return 1
    fi
    confirmar_pin "${pin}" || { log_error "Sunshine no ha aceptado el PIN."; return 1; }
    log_info "PIN aceptado: Moonlight termina el intercambio."
    sleep "${PAUSA_TRAS_VINCULO}"
}

vincular() {
    comprobar_previo
    requerir_variables TS_IP
    requerir_comandos curl jq
    comprobar_hp

    local pin
    pin="$(printf '%04d' "$(( RANDOM % 10000 ))")"
    # Se pregunta ahora: después ya hay un monitor virtual esperando.
    read -r -s -p "Contraseña del panel de Sunshine (usuario nomad): " CLAVE_PANEL \
        || die "No se ha recibido la contraseña."
    echo
    [[ -n "${CLAVE_PANEL}" ]] || die "La contraseña no puede estar vacía."

    trap interrumpir INT TERM HUP
    if ! levantar_pila extender || ! vincular_con_hp "${pin}"; then
        log_error "No se ha podido vincular: se deshace lo hecho."
        detener
        exit 1
    fi
    trap - INT TERM HUP

    detener
    log_ok "Vínculo hecho. Abre la sesión con: pantalla-hp extender"
    log_ok "La unidad de vínculo del HP se cierra sola en 90 segundos, o al abrir la sesión."
}

# ===========================================================================
#  ESTADO
# ===========================================================================

estado() {
    local unidad
    for unidad in "${U_SUNSHINE}" "${U_MONITOR}" "${U_VIGILANTE}" "${U_RESTAURAR}.timer"; do
        printf '%-28s %s\n' "${unidad}" "$(systemctl --user is-active "${unidad}" 2>/dev/null || true)"
    done
    if sesion_activa && cliente_conectado; then
        printf '%-28s %s\n' "cliente" "conectado"
    else
        printf '%-28s %s\n' "cliente" "ninguno"
    fi
    printf '%-28s %s\n' "${I}" "$(dato_salida "${I}" || true)"
    printf '%-28s %s\n' "${V}" "$(dato_salida "${V}" || true)"
}

# ===========================================================================
#  PRINCIPAL
# ===========================================================================

# Para cerrar, la configuración solo aporta el alias del HP: que falte no puede
# impedir que vuelva la pantalla interna.
cargar_si_existe() {
    if [[ -r "${NOMAD_CONFIG}" ]]; then
        cargar_entorno
    else
        log_aviso "No se encuentra ${NOMAD_CONFIG}."
    fi
}

procesar_argumentos_comunes "$@"
(( ${#NOMAD_ARGS_RESTANTES[@]} == 1 )) || die "Indica una sola orden (usa --help)."
ORDEN="${NOMAD_ARGS_RESTANTES[0]}"

case "${ORDEN}" in
    extender|principal|off|estado|vincular|--vigilar) ;;
    *) die "Orden desconocida: ${ORDEN} (usa --help)" ;;
esac

if (( MODO_CHECK == 1 )); then
    log_check "ejecutaría: pantalla-hp ${ORDEN}. No se ha tocado nada."
    exit 0
fi

case "${ORDEN}" in
    extender|principal) cargar_entorno; arrancar "${ORDEN}" ;;
    vincular)           cargar_entorno; vincular ;;
    off)                cargar_si_existe; detener ;;
    estado)             estado ;;
    --vigilar)          SOY_VIGILANTE=1; cargar_si_existe; vigilar ;;
esac
