#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — pruebas de pantalla-hp.sh con dobles
# ===========================================================================
#  Propósito : comprobar el ORDEN de las llamadas de pantalla-hp.sh y el estado
#              en que deja las pantallas, sin tocar las pantallas reales.
#  Uso       : bash scripts/emisor/probar_pantalla_hp.sh [--help]
#  Capítulo  : docs/18_pantalla_extendida.md
#
#  Cada prueba trabaja en una caja temporal: una copia del script y de lib/, un
#  servidor.env propio y, delante en el PATH, dobles de todo lo que toca el
#  sistema. El doble de kscreen-doctor guarda el estado de las pantallas e imita
#  dos trampas reales: devuelve 0 aunque la salida no exista, y entonces no
#  aplica nada; y la virtual reaparece en 0,0, encima de la interna.
#
#  El doble de sleep no duerme: suma tiempo simulado, así que los 600 segundos
#  de una sesión se prueban en milisegundos. El doble de ssh imita un agente: con
#  BatchMode falla mientras la clave no se haya cargado con AddKeysToAgent.
#
#  Las últimas secciones prueban el lado del HP: el lanzador, ya renderizado, con
#  un Moonlight de mentira; las plantillas de las unidades; y 18_pantalla.sh
#  --check y verificar_sistema.sh con dobles de lo que consultan.
# ===========================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

mostrar_ayuda() {
    cat <<'AYUDA'
Uso: bash scripts/emisor/probar_pantalla_hp.sh [--help]

Ejecuta las pruebas de pantalla-hp.sh con dobles de kscreen-doctor, systemd-run,
systemctl, ssh, ip, curl y sleep, y las del lado del HP: el lanzador, las unidades,
18_pantalla.sh --check y verificar_sistema.sh. No toca las pantallas ni el sistema
y no se conecta a nada. Termina con 0 si todas pasan.
AYUDA
}

case "${1:-}" in
    -h|--help) mostrar_ayuda; exit 0 ;;
    "")        ;;
    *)         echo "Opción desconocida: $1 (usa --help)" >&2; exit 1 ;;
esac

RAIZ="${NOMAD_RAIZ}"
V=Virtual-hp-pantalla
I=eDP-1
IP_EMISOR=100.64.0.7
IP_HP=100.64.0.9

BASE="$(mktemp -d -t pantalla-hp-pruebas.XXXXXX)"
trap 'rm -rf "${BASE}"; nomad_limpiar_contador' EXIT

CAJA=""
RC=0
FALLOS=0
PASADAS=0
FALLADAS=0
NOMBRES_FALLIDOS=()
ENTORNO_EXTRA=()

# ===========================================================================
#  LA CAJA
# ===========================================================================

escribir_dobles() {
    local d="${CAJA}/dobles"
    mkdir -p "${d}"

    # Funciones comunes de los dobles.
    cat > "${d}/_comun" <<'DOBLE'
registrar() { printf '%s\n' "$*" >> "${CAJA}/llamadas"; }
esta_en() { [[ -f "$2" ]] && grep -qxF -- "$1" "$2"; }
quitar_de() {
    [[ -f "$2" ]] || return 0
    grep -vxF -- "$1" "$2" > "$2.tmp" || true
    mv "$2.tmp" "$2"
}
hay_virtual() {
    esta_en pantalla-hp-monitor "${CAJA}/activas" && [[ ! -e "${CAJA}/virtual_nunca_aparece" ]]
}
DOBLE

    cat > "${d}/kscreen-doctor" <<'DOBLE'
#!/bin/bash
. "${CAJA}/dobles/_comun"
registrar kscreen-doctor "$@"
P="${CAJA}/pantallas"
V=Virtual-hp-pantalla

if [[ "${1:-}" == "-o" ]]; then
    # La salida real lleva colores: el script debe limpiarlos.
    printf '\033[01;32mOutput: \033[0;0m1 eDP-1 aaaa\n\t%s\n\tconnected\n\tpriority %s\n\tGeometry: %s 1920x1080\n' \
        "$(cat "${P}/eDP-1.estado")" "$(cat "${P}/eDP-1.prioridad")" "$(cat "${P}/eDP-1.posicion")"
    if hay_virtual; then
        # Una salida virtual real no imprime 'enabled': no se puede apagar.
        printf '\033[01;32mOutput: \033[0;0m2 %s bbbb\n\tdisable unsupported\n\tconnected\n\tpriority %s\n\tGeometry: %s 1920x1080\n' \
            "${V}" "$(cat "${P}/${V}.prioridad")" "$(cat "${P}/${V}.posicion")"
    fi
    exit 0
fi

# Como el real: con una salida inexistente avisa, no aplica nada y devuelve 0.
for a in "$@"; do
    if [[ "${a}" == "output.${V}."* ]] && ! hay_virtual; then
        echo "Output with name or uuid ${V} not found." >&2
        exit 0
    fi
done

for a in "$@"; do
    resto="${a#output.}"
    if [[ "${resto}" == "${V}."* ]]; then s="${V}"; else s="eDP-1"; fi
    ajuste="${resto#"${s}".}"
    case "${ajuste}" in
        enable)
            # 'interna_rebelde' guarda cuántos encendidos debe ignorar.
            if [[ "${s}" == eDP-1 && -e "${CAJA}/interna_rebelde" ]]; then
                n="$(cat "${CAJA}/interna_rebelde")"
                if (( n > 0 )); then
                    echo "$(( n - 1 ))" > "${CAJA}/interna_rebelde"
                    continue
                fi
            fi
            echo enabled > "${P}/${s}.estado" ;;
        disable)    echo disabled > "${P}/${s}.estado" ;;
        position.*) echo "${ajuste#position.}" > "${P}/${s}.posicion" ;;
        priority.*) echo "${ajuste#priority.}" > "${P}/${s}.prioridad" ;;
    esac
done
# Una señal justo después de apagar la interna: el peor momento.
if [[ -e "${CAJA}/senal_tras_apagar" && " $* " == *" output.eDP-1.disable "* ]]; then
    kill -TERM "${PPID}"
fi
exit 0
DOBLE

    # Como el real: falla si la unidad sigue cargada, activa o fallida.
    cat > "${d}/systemd-run" <<'DOBLE'
#!/bin/bash
. "${CAJA}/dobles/_comun"
unidad=""; temporizada=0
for a in "$@"; do
    case "${a}" in
        --unit=*)     unidad="${a#--unit=}" ;;
        --on-active=*) temporizada=1 ;;
    esac
done
# La orden programada se guarda aparte: anotada aquí, parecería una llamada a
# kscreen-doctor hecha ya, y las pruebas de orden darían por buena esa línea.
if (( temporizada == 1 )); then
    unidad="${unidad}.timer"
    registrar systemd-run "${@:1:$#-1}"
else
    registrar systemd-run "$@"
fi
if esta_en "${unidad}" "${CAJA}/activas" || esta_en "${unidad}" "${CAJA}/fallidas"; then
    echo "Failed to start transient unit: ${unidad} already loaded" >&2
    exit 1
fi
[[ -e "${CAJA}/falla_${unidad}" ]] && exit 1
echo "${unidad}" >> "${CAJA}/activas"
if (( temporizada == 1 )); then
    # La última palabra es la orden que ejecutará la restauración programada.
    printf '%s' "${@: -1}" > "${CAJA}/orden_restaurar"
fi
exit 0
DOBLE

    cat > "${d}/systemctl" <<'DOBLE'
#!/bin/bash
. "${CAJA}/dobles/_comun"
registrar systemctl "$@"
args=()
for a in "$@"; do
    case "${a}" in --user|--quiet) ;; *) args+=("${a%.service}") ;; esac
done
orden="${args[0]}"
unidades=("${args[@]:1}")
case "${orden}" in
    is-active)
        for u in "${unidades[@]}"; do
            if esta_en "${u}" "${CAJA}/activas"; then echo active; exit 0; fi
        done
        echo inactive
        exit 3 ;;
    stop)
        rc=0
        for u in "${unidades[@]}"; do
            esta_en "${u}" "${CAJA}/activas" || rc=5
            quitar_de "${u}" "${CAJA}/activas"
        done
        exit "${rc}" ;;
    reset-failed)
        rc=0
        for u in "${unidades[@]}"; do
            esta_en "${u}" "${CAJA}/fallidas" || rc=1
            quitar_de "${u}" "${CAJA}/fallidas"
        done
        exit "${rc}" ;;
esac
exit 0
DOBLE

    # 'falla_ssh' guarda el trozo de la orden con el que ssh debe fallar. El agente
    # empieza vacío, como en el portátil: 'AddKeysToAgent' carga la clave, salvo
    # con 'agente_sin_clave', y BatchMode falla sin ella, porque no puede preguntar.
    cat > "${d}/ssh" <<'DOBLE'
#!/bin/bash
. "${CAJA}/dobles/_comun"
registrar ssh "$@"
if [[ -e "${CAJA}/falla_ssh" && "$*" == *"$(cat "${CAJA}/falla_ssh")"* ]]; then
    echo "ssh: connect to host: Connection timed out" >&2
    exit 255
fi
if [[ " $* " == *" AddKeysToAgent=yes "* && ! -e "${CAJA}/agente_sin_clave" ]]; then
    touch "${CAJA}/clave_en_agente"
fi
if [[ " $* " == *" BatchMode=yes "* && ! -e "${CAJA}/clave_en_agente" ]]; then
    echo "hp-prueba: Permission denied (publickey)." >&2
    exit 255
fi
exit 0
DOBLE

    cat > "${d}/ip" <<'DOBLE'
#!/bin/bash
. "${CAJA}/dobles/_comun"
registrar ip "$@"
if [[ "${1:-}" == route ]]; then
    echo "1.1.1.1 via 192.168.1.1 dev $(cat "${CAJA}/ruta" 2>/dev/null || echo enp1s0) src 192.168.1.20 uid 1000"
    exit 0
fi
echo "lo               UNKNOWN        127.0.0.1/8"
echo "wlp2s0           UP             192.168.1.20/24"
[[ -e "${CAJA}/sin_tailscale" ]] || echo "tailscale0       UNKNOWN        100.64.0.7/32"
exit 0
DOBLE

    # 'guion', si existe, recibe el número de tic y el PID del script.
    cat > "${d}/sleep" <<'DOBLE'
#!/bin/bash
. "${CAJA}/dobles/_comun"
registrar sleep "$@"
tics=$(( $(cat "${CAJA}/tics" 2>/dev/null || echo 0) + 1 ))
echo "${tics}" > "${CAJA}/tics"
echo $(( $(cat "${CAJA}/segundos" 2>/dev/null || echo 0) + ${1%.*} )) > "${CAJA}/segundos"
(( tics < 2000 )) || exit 1
if [[ -x "${CAJA}/guion" ]]; then "${CAJA}/guion" "${tics}" "${PPID}"; fi
exit 0
DOBLE

    cat > "${d}/curl" <<'DOBLE'
#!/bin/bash
. "${CAJA}/dobles/_comun"
registrar curl "$@"
cat >> "${CAJA}/curl_entrada"
if [[ "$*" == *"-X POST"* ]]; then
    echo '{"status":true}'
else
    cat "${CAJA}/respuesta_pin"
fi
exit 0
DOBLE

    # Nada de esto debe ejecutarse: solo systemd-run lo lanzaría de verdad.
    local n
    for n in krfb-virtualmonitor sunshine systemd-inhibit; do
        printf '#!/bin/bash\necho "%s NO debe ejecutarse" >> "${CAJA}/prohibidos"\nexit 97\n' "${n}" > "${d}/${n}"
    done

    chmod +x "${d}"/*
}

preparar() {
    CAJA="$(mktemp -d "${BASE}/caja.XXXXXX")"
    ENTORNO_EXTRA=()
    mkdir -p "${CAJA}/repo/scripts/emisor" "${CAJA}/repo/config" "${CAJA}/bin" \
             "${CAJA}/home/.config/sunshine" "${CAJA}/pantallas"
    cp -r "${RAIZ}/scripts/lib" "${CAJA}/repo/scripts/lib"
    cp "${RAIZ}/scripts/emisor/pantalla-hp.sh" "${CAJA}/repo/scripts/emisor/" 2>/dev/null || true
    {
        echo "PANTALLA_EMISOR_IP=\"${IP_EMISOR}\""
        echo 'PANTALLA_HP_SSH="hp-prueba"'
        echo "TS_IP=\"${IP_HP}\""
    } > "${CAJA}/repo/config/servidor.env"
    chmod 600 "${CAJA}/repo/config/servidor.env"
    # Se ejecuta por un enlace, igual que ~/.local/bin/pantalla-hp.
    ln -s "${CAJA}/repo/scripts/emisor/pantalla-hp.sh" "${CAJA}/bin/pantalla-hp"
    : > "${CAJA}/llamadas"; : > "${CAJA}/activas"; : > "${CAJA}/fallidas"
    fijar_pantalla "${I}" enabled 0,0 1
    # La peor disposición guardada: la virtual aparece encima de la interna.
    fijar_pantalla "${V}" enabled 0,0 2
    escribir_dobles
}

fijar_pantalla() {
    echo "$2" > "${CAJA}/pantallas/$1.estado"
    echo "$3" > "${CAJA}/pantallas/$1.posicion"
    echo "$4" > "${CAJA}/pantallas/$1.prioridad"
}

# Ejecuta pantalla-hp en la caja con un entorno limpio: ni las variables del
# usuario ni sus programas reales llegan a la prueba.
lanzar() {
    RC=0
    ( cd "${CAJA}" && env -i "PATH=${CAJA}/dobles:/usr/bin:/bin" "HOME=${CAJA}/home" \
        "CAJA=${CAJA}" TERM=dumb ${ENTORNO_EXTRA[@]+"${ENTORNO_EXTRA[@]}"} \
        timeout 20 "${CAJA}/bin/pantalla-hp" "$@" ) \
        > "${CAJA}/salida" 2>&1 < "${ENTRADA:-/dev/null}" || RC=$?
}

activa() { echo "$1" >> "${CAJA}/activas"; }
# Quien abrió la sesión ya cargó la clave en el agente.
sesion_montada() {
    touch "${CAJA}/clave_en_agente"
    activa pantalla-hp-monitor; activa pantalla-hp-sunshine
    activa pantalla-hp-vigilante; activa pantalla-restaurar.timer
}
log_sunshine() { printf '%s\n' "$@" > "${CAJA}/home/.config/sunshine/sunshine.log"; }

# ===========================================================================
#  COMPROBACIONES
# ===========================================================================

fallar() { echo "    FALLA: $*"; FALLOS=$(( FALLOS + 1 )); }

# Número de la primera línea de 'llamadas' que contiene el texto (0 si ninguna).
linea() { awk -v t="$1" 'index($0, t) { print NR; found = 1; exit } END { if (!found) print 0 }' "${CAJA}/llamadas"; }
ultima_linea() { awk -v t="$1" 'index($0, t) { n = NR } END { print n + 0 }' "${CAJA}/llamadas"; }
veces() { awk -v t="$1" 'index($0, t) { n++ } END { print n + 0 }' "${CAJA}/llamadas"; }

hay() { (( $(linea "$1") > 0 )) || fallar "falta la llamada: $1"; }
no_hay() { (( $(linea "$1") == 0 )) || fallar "no debía haber: $1"; }
antes() {
    local a b
    a="$(linea "$1")"; b="$(linea "$2")"
    if (( a == 0 || b == 0 || a >= b )); then
        fallar "'$1' (línea ${a}) debe ir antes que '$2' (línea ${b})"
    fi
}
rc_es() { [[ "${RC}" == "$1" ]] || fallar "código de salida ${RC}, se esperaba $1"; }
rc_no_es_cero() { [[ "${RC}" != 0 ]] || fallar "debía terminar con error y terminó con 0"; }
dice() { grep -qF -- "$1" "${CAJA}/salida" || fallar "la salida no dice: $1"; }
no_dice() { if grep -qF -- "$1" "${CAJA}/salida"; then fallar "la salida no debía decir: $1"; fi; }
unidad_activa() { grep -qxF -- "$1" "${CAJA}/activas" || fallar "debía estar activa: $1"; }
unidad_parada() { if grep -qxF -- "$1" "${CAJA}/activas"; then fallar "debía estar parada: $1"; fi; }
sin_prohibidos() { [[ ! -e "${CAJA}/prohibidos" ]] || fallar "se ejecutó de verdad: $(cat "${CAJA}/prohibidos")"; }

pantalla_es() {
    local actual
    actual="$(cat "${CAJA}/pantallas/$1.$2")"
    [[ "${actual}" == "$3" ]] || fallar "$1.$2 es '${actual}', se esperaba '$3'"
}
interna_restaurada() {
    pantalla_es "${I}" estado enabled
    pantalla_es "${I}" posicion 0,0
    pantalla_es "${I}" prioridad 1
}
pila_retirada() {
    unidad_parada pantalla-hp-sunshine
    unidad_parada pantalla-hp-monitor
    unidad_parada pantalla-restaurar.timer
}
pantallas_intactas() {
    no_hay "kscreen-doctor output."
    no_hay "--unit=pantalla-hp-monitor"
    no_hay "--unit=pantalla-hp-sunshine"
    no_hay "--unit=pantalla-restaurar"
}

MOSTRAR_V_PRINCIPAL="output.${V}.position.0,0"
ORDEN_RESTAURAR="kscreen-doctor output.${V}.position.1920,0 output.${I}.enable output.${I}.position.0,0 output.${I}.priority.1"

# ===========================================================================
#  ARRANQUE
# ===========================================================================

prueba_principal_fija_pantallas_antes_de_sunshine() {
    lanzar principal
    rc_es 0
    antes "${MOSTRAR_V_PRINCIPAL}" "--unit=pantalla-hp-sunshine"
    pantalla_es "${V}" posicion 0,0
    pantalla_es "${V}" prioridad 1
    pantalla_es "${V}" estado enabled
    pantalla_es "${I}" estado disabled
    sin_prohibidos
}

prueba_extender_fija_ambas_pantallas() {
    lanzar extender
    rc_es 0
    hay "output.${I}.enable"
    hay "output.${V}.position.1920,0"
    antes "output.${V}.position.1920,0" "--unit=pantalla-hp-sunshine"
    pantalla_es "${V}" posicion 1920,0
    pantalla_es "${V}" prioridad 2
    pantalla_es "${I}" estado enabled
    pantalla_es "${I}" posicion 0,0
    pantalla_es "${I}" prioridad 1
}

prueba_extender_enciende_interna_apagada() {
    fijar_pantalla "${I}" disabled 0,0 2
    lanzar extender
    rc_es 0
    pantalla_es "${I}" estado enabled
}

prueba_wifi_limita_el_bitrate() {
    mkdir -p "${CAJA}/sys/wlp2s0/wireless"
    echo wlp2s0 > "${CAJA}/ruta"
    ENTORNO_EXTRA=("SYS_NET=${CAJA}/sys")
    lanzar extender
    rc_es 0
    hay "max_bitrate=15000"
}

prueba_cable_no_limita_el_bitrate() {
    mkdir -p "${CAJA}/sys/enp1s0"
    echo enp1s0 > "${CAJA}/ruta"
    ENTORNO_EXTRA=("SYS_NET=${CAJA}/sys")
    lanzar extender
    rc_es 0
    no_hay "max_bitrate"
}

prueba_orden_completo_del_arranque() {
    lanzar extender
    rc_es 0
    antes "--unit=pantalla-restaurar" "--unit=pantalla-hp-monitor"
    antes "--unit=pantalla-hp-sunshine" "--unit=pantalla-hp-vigilante"
    antes "--unit=pantalla-hp-vigilante" "sudo -n systemctl start nomad-pantalla.service"
    unidad_activa pantalla-hp-vigilante
    unidad_activa pantalla-restaurar.timer
}

prueba_monitor_con_sus_argumentos() {
    lanzar extender
    rc_es 0
    hay "krfb-virtualmonitor --resolution 1920x1080 --name hp-pantalla --password "
    hay "--port 15905"
    local clave
    clave="$(awk '/krfb-virtualmonitor/ { for (i = 1; i <= NF; i++) if ($i == "--password") print $(i + 1) }' "${CAJA}/llamadas")"
    (( ${#clave} >= 16 )) || fallar "contraseña corta o ausente: '${clave}'"
    no_dice "${clave:-sin-clave}"
    # Dos sesiones no comparten contraseña.
    local caja1="${CAJA}" clave2
    preparar
    lanzar extender
    clave2="$(awk '/krfb-virtualmonitor/ { for (i = 1; i <= NF; i++) if ($i == "--password") print $(i + 1) }' "${CAJA}/llamadas")"
    [[ "${clave}" != "${clave2}" ]] || fallar "la contraseña no es aleatoria"
    rm -rf "${caja1}"
}

prueba_sunshine_con_inhibidor_y_ruta_fija() {
    lanzar extender
    rc_es 0
    hay "systemd-inhibit --what=handle-lid-switch:sleep:idle --who=pantalla-hp"
    hay "--mode=block /usr/bin/sunshine"
    hay "StandardInput=null"
}

prueba_vigilante_se_lanza_con_el_script() {
    lanzar extender
    rc_es 0
    hay "--unit=pantalla-hp-vigilante"
    hay "repo/scripts/emisor/pantalla-hp.sh --vigilar"
}

prueba_restauracion_se_programa_antes_de_tocar_pantallas() {
    lanzar principal
    rc_es 0
    hay "--on-active=600"
    antes "--unit=pantalla-restaurar" "kscreen-doctor output."
}

prueba_restauracion_mueve_virtual_antes_de_encender_interna() {
    sesion_montada
    fijar_pantalla "${V}" enabled 0,0 1
    fijar_pantalla "${I}" disabled 0,0 2
    lanzar off
    rc_es 0
    # Una sola llamada, atómica, con la virtual primero.
    hay "${ORDEN_RESTAURAR}"
    pantalla_es "${V}" posicion 1920,0
    interna_restaurada
}

prueba_restauracion_programada_enciende_interna_sin_virtual() {
    lanzar principal
    rc_es 0
    [[ -s "${CAJA}/orden_restaurar" ]] || fallar "no se guardó la orden de restauración"
    # Lo que haría el temporizador si el monitor ya hubiera muerto.
    grep -vxF pantalla-hp-monitor "${CAJA}/activas" > "${CAJA}/activas.tmp" || true
    mv "${CAJA}/activas.tmp" "${CAJA}/activas"
    env -i "PATH=${CAJA}/dobles:/usr/bin:/bin" "CAJA=${CAJA}" \
        bash -c "$(cat "${CAJA}/orden_restaurar")" > /dev/null 2>&1 || true
    interna_restaurada
}

prueba_restauracion_programada_no_depende_del_repositorio() {
    lanzar principal
    rc_es 0
    if grep -qF "pantalla-hp" "${CAJA}/orden_restaurar"; then
        fallar "la restauración programada llama al script: $(cat "${CAJA}/orden_restaurar")"
    fi
}

prueba_sin_ip_tailscale_no_toca_pantallas() {
    touch "${CAJA}/sin_tailscale"
    lanzar principal
    rc_no_es_cero
    hay "ip -4 -br addr"
    dice "${IP_EMISOR}"
    pantallas_intactas
}

prueba_emisor_ip_vacia_no_toca_pantallas() {
    sed -i 's/^PANTALLA_EMISOR_IP=.*/PANTALLA_EMISOR_IP=""/' "${CAJA}/repo/config/servidor.env"
    lanzar principal
    rc_no_es_cero
    dice "PANTALLA_EMISOR_IP"
    pantallas_intactas
}

prueba_hp_sin_ruta_antes_de_empezar_no_toca_pantallas() {
    echo "hp-prueba" > "${CAJA}/falla_ssh"
    lanzar principal
    rc_no_es_cero
    hay "ssh "
    dice "hp-prueba"
    pantallas_intactas
}

prueba_clave_se_carga_y_se_prueba_antes_de_tocar_nada() {
    lanzar principal
    rc_es 0
    antes "AddKeysToAgent=yes" "sudo -n -l"
    antes "sudo -n -l /usr/bin/systemctl start nomad-pantalla.service" "--unit=pantalla-restaurar"
    local llamada
    llamada="$(sed -n "$(linea "sudo -n -l")p" "${CAJA}/llamadas")"
    [[ "${llamada}" == *BatchMode=yes* ]] || fallar "la prueba previa no va por BatchMode: ${llamada}"
}

prueba_clave_que_no_llega_al_agente_no_toca_pantallas() {
    # Lo que pasaba: ssh preguntaba la frase, pero el agente seguía vacío.
    touch "${CAJA}/agente_sin_clave"
    lanzar principal
    rc_no_es_cero
    dice "ssh-add"
    pantallas_intactas
    no_hay "sudo -n systemctl start"
}

prueba_sudo_que_pide_contrasena_no_toca_pantallas() {
    echo "sudo -n -l" > "${CAJA}/falla_ssh"
    lanzar principal
    rc_no_es_cero
    dice "sudo"
    pantallas_intactas
}

prueba_arranque_para_la_unidad_del_hp_en_la_misma_llamada() {
    # 'start' sobre una unidad activa no hace nada: seguiría la sesión anterior.
    lanzar principal
    rc_es 0
    hay "sudo -n systemctl stop nomad-pantalla.service ; sudo -n systemctl start nomad-pantalla.service"
    (( $(veces "sudo -n systemctl") == 1 )) || fallar "'stop' y 'start' no van en una sola llamada"
}

prueba_hp_inaccesible_restaura_interna() {
    echo "sudo -n systemctl start nomad-pantalla" > "${CAJA}/falla_ssh"
    lanzar principal
    rc_no_es_cero
    hay "sudo -n systemctl start nomad-pantalla.service"
    antes "sudo -n systemctl start nomad-pantalla.service" "${ORDEN_RESTAURAR}"
    interna_restaurada
    pila_retirada
    unidad_parada pantalla-hp-vigilante
}

prueba_ssh_de_arranque_no_pregunta_ni_se_cuelga() {
    # Con la interna apagada, una pregunta en la terminal no la vería nadie.
    lanzar principal
    rc_es 0
    local n
    n="$(linea "sudo -n systemctl start nomad-pantalla.service")"
    if (( n == 0 )); then fallar "no se pidió arrancar la unidad"; return; fi
    local llamada
    llamada="$(sed -n "${n}p" "${CAJA}/llamadas")"
    [[ "${llamada}" == *BatchMode=yes* ]] || fallar "el ssh de arranque no usa BatchMode"
    [[ "${llamada}" == *ConnectTimeout=* ]] || fallar "el ssh de arranque no usa ConnectTimeout"
}

prueba_sesion_activa_se_rechaza() {
    sesion_montada
    lanzar extender
    rc_no_es_cero
    dice "off"
    no_hay "systemd-run"
    no_hay "kscreen-doctor output."
    no_hay "ssh "
    unidad_activa pantalla-hp-sunshine
}

prueba_monitor_huerfano_tambien_se_rechaza() {
    activa pantalla-hp-monitor
    lanzar principal
    rc_no_es_cero
    no_hay "systemd-run"
}

prueba_unidades_fallidas_no_impiden_arrancar() {
    # Una unidad fallida sigue cargada y systemd-run se negaría a crearla.
    printf '%s\n' pantalla-hp-monitor pantalla-hp-sunshine pantalla-hp-vigilante > "${CAJA}/fallidas"
    lanzar extender
    rc_es 0
    unidad_activa pantalla-hp-monitor
    unidad_activa pantalla-hp-sunshine
    unidad_activa pantalla-hp-vigilante
}

prueba_extender_aborta_si_interna_apagada() {
    fijar_pantalla "${I}" disabled 0,0 2
    echo 1 > "${CAJA}/interna_rebelde"
    lanzar extender
    rc_no_es_cero
    dice "${I}"
    no_hay "--unit=pantalla-hp-sunshine"
    no_hay "sudo -n systemctl start nomad-pantalla"
    interna_restaurada
    pila_retirada
}

prueba_salida_que_nunca_aparece_falla_limpio() {
    touch "${CAJA}/virtual_nunca_aparece"
    lanzar principal
    rc_no_es_cero
    dice "${V}"
    no_hay "--unit=pantalla-hp-sunshine"
    no_hay "output.${I}.disable"
    (( $(veces "kscreen-doctor -o") > 1 )) || fallar "no reintentó"
    interna_restaurada
    pila_retirada
}

prueba_espera_salida_tarda_unos_segundos() {
    touch "${CAJA}/virtual_nunca_aparece"
    cat > "${CAJA}/guion" <<'GUION'
#!/bin/bash
if (( $1 == 3 )); then rm -f "${CAJA}/virtual_nunca_aparece"; fi
GUION
    chmod +x "${CAJA}/guion"
    lanzar extender
    rc_es 0
    pantalla_es "${V}" posicion 1920,0
}

prueba_sunshine_que_no_se_crea_restaura() {
    touch "${CAJA}/falla_pantalla-hp-sunshine"
    lanzar principal
    rc_no_es_cero
    no_hay "sudo -n systemctl start nomad-pantalla"
    interna_restaurada
    pila_retirada
}

prueba_sin_temporizador_no_se_toca_nada_mas() {
    touch "${CAJA}/falla_pantalla-restaurar.timer"
    lanzar principal
    rc_no_es_cero
    no_hay "--unit=pantalla-hp-monitor"
    no_hay "output.${I}.disable"
    unidad_parada pantalla-hp-monitor
}

prueba_interrupcion_al_arrancar_restaura() {
    touch "${CAJA}/virtual_nunca_aparece"
    cat > "${CAJA}/guion" <<'GUION'
#!/bin/bash
if (( $1 == 2 )); then kill -TERM "$2"; fi
GUION
    chmod +x "${CAJA}/guion"
    lanzar principal
    rc_no_es_cero
    interna_restaurada
    pila_retirada
}

prueba_interrupcion_con_interna_apagada_restaura() {
    touch "${CAJA}/senal_tras_apagar"
    lanzar principal
    rc_no_es_cero
    hay "output.${I}.disable"
    no_hay "--unit=pantalla-hp-sunshine"
    interna_restaurada
    pila_retirada
}

# ===========================================================================
#  PARADA
# ===========================================================================

prueba_off_para_hp_antes_que_sunshine() {
    sesion_montada
    lanzar off
    rc_es 0
    hay "sudo -n systemctl stop nomad-pantalla.service"
    antes "sudo -n systemctl stop nomad-pantalla.service" "stop pantalla-hp-sunshine"
    pila_retirada
}

prueba_off_para_vigilante_primero() {
    # Si no, vería caer Sunshine y haría un segundo 'detener' a la vez.
    sesion_montada
    lanzar off
    rc_es 0
    antes "stop pantalla-hp-vigilante" "${ORDEN_RESTAURAR}"
    antes "stop pantalla-hp-vigilante" "sudo -n systemctl stop nomad-pantalla.service"
    unidad_parada pantalla-hp-vigilante
}

prueba_off_restaura_antes_que_nada_de_lo_demas() {
    # Es local y la virtual sigue viva: la interna no espera a un ssh de 20 s.
    sesion_montada
    lanzar off
    rc_es 0
    antes "${ORDEN_RESTAURAR}" "sudo -n systemctl stop nomad-pantalla.service"
    antes "${ORDEN_RESTAURAR}" "stop pantalla-hp-sunshine"
    antes "stop pantalla-hp-sunshine" "stop pantalla-hp-monitor"
}

prueba_off_con_interna_apagada_la_enciende_antes_de_llamar_al_hp() {
    # La llamada a ssh ve ya el resultado: se comprueba con el estado, no solo
    # con el orden de las líneas.
    sesion_montada
    fijar_pantalla "${V}" enabled 0,0 1
    fijar_pantalla "${I}" disabled 0,0 2
    sed -i '/^registrar ssh/a cp "${CAJA}/pantallas/eDP-1.estado" "${CAJA}/interna_al_llamar_al_hp"' "${CAJA}/dobles/ssh"
    lanzar off
    rc_es 0
    [[ "$(cat "${CAJA}/interna_al_llamar_al_hp")" == enabled ]] \
        || fallar "el ssh salió con la interna apagada"
}

prueba_off_sigue_si_ssh_falla() {
    sesion_montada
    fijar_pantalla "${I}" disabled 0,0 2
    echo "hp-prueba" > "${CAJA}/falla_ssh"
    lanzar off
    rc_es 0
    dice "hp-prueba"
    interna_restaurada
    pila_retirada
}

prueba_off_sin_configuracion_restaura() {
    sesion_montada
    fijar_pantalla "${I}" disabled 0,0 2
    rm "${CAJA}/repo/config/servidor.env"
    lanzar off
    interna_restaurada
    pila_retirada
}

prueba_off_sin_virtual_enciende_interna() {
    # El monitor murió: la llamada con la virtual avisa, devuelve 0 y no aplica.
    sesion_montada
    grep -vxF pantalla-hp-monitor "${CAJA}/activas" > "${CAJA}/activas.tmp" || true
    mv "${CAJA}/activas.tmp" "${CAJA}/activas"
    fijar_pantalla "${I}" disabled 0,0 2
    lanzar off
    rc_es 0
    interna_restaurada
}

prueba_off_si_la_interna_no_vuelve_conserva_temporizador() {
    sesion_montada
    fijar_pantalla "${I}" disabled 0,0 2
    echo 9999 > "${CAJA}/interna_rebelde"
    lanzar off
    rc_no_es_cero
    dice "${I}"
    unidad_activa pantalla-restaurar.timer
}

# En 'off' el único sleep sin fallos es la pausa entre los dos sondeos: el primer
# tic es el momento en que KDE reaplica y apaga la interna.
apagar_interna_en_primer_tic() {
    cat > "${CAJA}/guion" <<'GUION'
#!/bin/bash
if (( $1 == 1 )); then echo disabled > "${CAJA}/pantallas/eDP-1.estado"; fi
GUION
    chmod +x "${CAJA}/guion"
}

prueba_off_asienta_antes_de_retirar_temporizador() {
    sesion_montada
    ENTORNO_EXTRA=(PANTALLA_HP_PAUSA_ASENTAR=7)
    lanzar off
    rc_es 0
    hay "sleep 7"
    antes "stop pantalla-hp-monitor" "sleep 7"
    antes "sleep 7" "stop pantalla-restaurar.timer"
    unidad_parada pantalla-restaurar.timer
}

prueba_off_interna_que_se_apaga_al_asentar_conserva_temporizador() {
    sesion_montada
    apagar_interna_en_primer_tic
    lanzar off
    rc_no_es_cero
    dice "${I}"
    unidad_activa pantalla-restaurar.timer
    # El temporizador se conserva, pero no se le espera para reintentar.
    interna_restaurada
}

prueba_off_interna_rebelde_al_asentar_conserva_temporizador() {
    sesion_montada
    apagar_interna_en_primer_tic
    echo 9999 > "${CAJA}/interna_rebelde"
    lanzar off
    rc_no_es_cero
    unidad_activa pantalla-restaurar.timer
}

prueba_off_sin_sesion_no_falla() {
    lanzar off
    rc_es 0
    interna_restaurada
}

prueba_unidades_limpias_tras_off() {
    sesion_montada
    printf '%s\n' pantalla-hp-sunshine > "${CAJA}/fallidas"
    lanzar off
    rc_es 0
    [[ ! -s "${CAJA}/fallidas" ]] || fallar "quedan unidades fallidas: $(cat "${CAJA}/fallidas")"
}

prueba_sunshine_tiene_parada_acotada() {
    # 'detener' espera a que pare; sin límite, 90 segundos con la pantalla negra.
    lanzar extender
    rc_es 0
    hay "TimeoutStopSec="
}

# ===========================================================================
#  VIGILANTE
# ===========================================================================

# Tras el tic indicado, el cliente se desconecta.
desconectar_en_tic() {
    cat > "${CAJA}/guion" <<GUION
#!/bin/bash
if (( \$1 == $1 )); then
    printf '%s\n' 'CLIENT CONNECTED' 'CLIENT DISCONNECTED' > "\${CAJA}/home/.config/sunshine/sunshine.log"
fi
GUION
    chmod +x "${CAJA}/guion"
}

segundos() { cat "${CAJA}/segundos" 2>/dev/null || echo 0; }

prueba_vigilante_restaura_sin_cliente_60s() {
    sesion_montada
    fijar_pantalla "${I}" disabled 0,0 2
    log_sunshine 'CLIENT CONNECTED'
    # Se va en el tic 3, a los 15 s: el vigilante ya lo ha visto conectado.
    desconectar_en_tic 3
    lanzar --vigilar
    rc_es 0
    local s
    s="$(segundos)"
    (( s >= 70 && s <= 80 )) || fallar "paró a los ${s} s, se esperaban 60 tras irse a los 15"
    hay "${ORDEN_RESTAURAR}"
    interna_restaurada
    pila_retirada
}

prueba_vigilante_ping_timeout_cuenta_como_fin() {
    # Sin CLIENT DISCONNECTED: la última línea que cuenta es el Ping Timeout.
    sesion_montada
    fijar_pantalla "${I}" disabled 0,0 2
    log_sunshine 'CLIENT CONNECTED'
    cat > "${CAJA}/guion" <<'GUION'
#!/bin/bash
if (( $1 == 3 )); then
    printf '%s\n' 'Info: CLIENT CONNECTED' '[2026-11-05 21:39:12]: Warning: 192.0.2.1: Ping Timeout' \
        > "${CAJA}/home/.config/sunshine/sunshine.log"
fi
GUION
    chmod +x "${CAJA}/guion"
    lanzar --vigilar
    rc_es 0
    local s
    s="$(segundos)"
    (( s >= 70 && s <= 83 )) || fallar "paró a los ${s} s, se esperaban 60 tras el corte a los 15"
    interna_restaurada
    pila_retirada
}

prueba_cliente_que_vuelve_tras_ping_timeout_cuenta() {
    sesion_montada
    log_sunshine 'CLIENT CONNECTED' 'x: Ping Timeout' 'CLIENT DISCONNECTED' 'CLIENT CONNECTED'
    lanzar estado
    rc_es 0
    dice "conectado"
}

prueba_vigilante_da_120s_a_la_primera_conexion() {
    sesion_montada
    fijar_pantalla "${I}" disabled 0,0 2
    log_sunshine 'arrancando'
    lanzar --vigilar
    rc_es 0
    local s
    s="$(segundos)"
    (( s >= 120 && s <= 135 )) || fallar "paró a los ${s} s, se esperaban unos 120"
    interna_restaurada
}

prueba_vigilante_primera_conexion_tardia_no_corta() {
    sesion_montada
    log_sunshine 'arrancando'
    cat > "${CAJA}/guion" <<'GUION'
#!/bin/bash
L="${CAJA}/home/.config/sunshine/sunshine.log"
if (( $1 == 20 )); then echo 'CLIENT CONNECTED' > "${L}"; fi
if (( $1 == 60 )); then printf '%s\n' 'CLIENT CONNECTED' 'CLIENT DISCONNECTED' > "${L}"; fi
GUION
    chmod +x "${CAJA}/guion"
    lanzar --vigilar
    rc_es 0
    local s
    s="$(segundos)"
    # Se va en el tic 60, a los 300 s, y el sondeo de ese instante ya lo cuenta.
    (( s >= 355 )) || fallar "paró a los ${s} s, antes de que el cliente se fuera"
}

prueba_vigilante_rearma_restauracion_con_cliente() {
    sesion_montada
    log_sunshine 'CLIENT CONNECTED'
    # Unos 10 minutos con cliente: más que el plazo de la restauración.
    desconectar_en_tic 120
    lanzar --vigilar
    rc_es 0
    local n
    n="$(veces "--on-active=600")"
    (( n >= 9 && n <= 11 )) || fallar "rearmó ${n} veces en 10 minutos, se esperaba una por minuto"
    no_hay "stop pantalla-hp-vigilante"
    (( $(ultima_linea "stop pantalla-restaurar") > $(linea "--on-active=600") )) \
        || fallar "el rearme no retira el temporizador anterior"
}

prueba_vigilante_reintenta_rearme_fallido_en_el_siguiente_sondeo() {
    sesion_montada
    log_sunshine 'CLIENT CONNECTED'
    # El temporizador no existe en el doble: el rearme crea uno, y falla en el
    # minuto 1. Se arregla en el tic siguiente y el cliente se va a los 100 s.
    grep -vxF pantalla-restaurar.timer "${CAJA}/activas" > "${CAJA}/activas.tmp" || true
    mv "${CAJA}/activas.tmp" "${CAJA}/activas"
    touch "${CAJA}/falla_pantalla-restaurar.timer"
    cat > "${CAJA}/guion" <<'GUION'
#!/bin/bash
L="${CAJA}/home/.config/sunshine/sunshine.log"
if (( $1 == 13 )); then rm -f "${CAJA}/falla_pantalla-restaurar.timer"; fi
if (( $1 == 20 )); then printf '%s\n' 'CLIENT CONNECTED' 'CLIENT DISCONNECTED' > "${L}"; fi
GUION
    chmod +x "${CAJA}/guion"
    lanzar --vigilar
    rc_es 0
    (( $(veces "--on-active=600") == 2 )) \
        || fallar "hubo $(veces "--on-active=600") intentos de rearme, se esperaban 2 (a los 60 y 65 s)"
}

prueba_vigilante_reconexion_no_corta() {
    sesion_montada
    log_sunshine 'CLIENT CONNECTED'
    cat > "${CAJA}/guion" <<'GUION'
#!/bin/bash
L="${CAJA}/home/.config/sunshine/sunshine.log"
if (( $1 == 2 )); then printf '%s\n' 'CLIENT CONNECTED' 'CLIENT DISCONNECTED' > "${L}"; fi
if (( $1 == 8 )); then printf '%s\n' 'CLIENT DISCONNECTED' 'CLIENT CONNECTED' > "${L}"; fi
if (( $1 == 30 )); then printf '%s\n' 'CLIENT CONNECTED' 'CLIENT DISCONNECTED' > "${L}"; fi
GUION
    chmod +x "${CAJA}/guion"
    lanzar --vigilar
    rc_es 0
    local s
    s="$(segundos)"
    (( s >= 200 )) || fallar "paró a los ${s} s, durante la desconexión breve"
}

prueba_vigilante_sunshine_muerto_restaura() {
    # El registro se queda en CONNECTED: Sunshine no llegó a escribir el adiós.
    sesion_montada
    grep -vxF pantalla-hp-sunshine "${CAJA}/activas" > "${CAJA}/activas.tmp" || true
    mv "${CAJA}/activas.tmp" "${CAJA}/activas"
    fijar_pantalla "${V}" enabled 0,0 1
    fijar_pantalla "${I}" disabled 0,0 2
    log_sunshine 'CLIENT CONNECTED'
    lanzar --vigilar
    rc_es 0
    (( $(segundos) <= 15 )) || fallar "tardó $(segundos) s con Sunshine muerto"
    interna_restaurada
    pila_retirada
}

prueba_vigilante_monitor_muerto_restaura() {
    sesion_montada
    grep -vxF pantalla-hp-monitor "${CAJA}/activas" > "${CAJA}/activas.tmp" || true
    mv "${CAJA}/activas.tmp" "${CAJA}/activas"
    fijar_pantalla "${I}" disabled 0,0 2
    log_sunshine 'CLIENT CONNECTED'
    lanzar --vigilar
    rc_es 0
    interna_restaurada
    pila_retirada
}

prueba_vigilante_no_se_para_a_si_mismo() {
    # Parar su propia unidad lo mataría a mitad de 'detener'.
    sesion_montada
    log_sunshine 'arrancando'
    lanzar --vigilar
    rc_es 0
    no_hay "stop pantalla-hp-vigilante"
    hay "stop pantalla-hp-monitor"
}

prueba_vigilante_solo_abre_ssh_para_parar() {
    sesion_montada
    log_sunshine 'arrancando'
    lanzar --vigilar
    rc_es 0
    (( $(veces "ssh ") == 1 )) || fallar "abrió ssh $(veces "ssh ") veces"
    hay "sudo -n systemctl stop nomad-pantalla.service"
}

prueba_vigilante_sin_registro_cuenta_como_sin_cliente() {
    sesion_montada
    lanzar --vigilar
    rc_es 0
    pila_retirada
}

prueba_intervalo_se_puede_cambiar() {
    sesion_montada
    log_sunshine 'arrancando'
    ENTORNO_EXTRA=(PANTALLA_HP_INTERVALO_VIGILANTE=30)
    lanzar --vigilar
    rc_es 0
    hay "sleep 30"
    (( $(veces "sleep 30") == 4 )) || fallar "hizo $(veces "sleep 30") sondeos, se esperaban 4"
}

# ===========================================================================
#  VÍNCULO
# ===========================================================================

preparar_vinculo() {
    printf '{"pairings":[{"address":"%s","id":"ab12","name":"nomad"}]}\n' "$1" > "${CAJA}/respuesta_pin"
    printf 'cl"ave\\secreta\n' > "${CAJA}/clave"
    ENTRADA="${CAJA}/clave"
}

prueba_vincular_confirma_el_pin() {
    preparar_vinculo "${IP_HP}"
    lanzar vincular
    ENTRADA=""
    rc_es 0
    hay "ssh -t hp-prueba sudo systemctl start nomad-pantalla-vincular@"
    antes "--unit=pantalla-hp-sunshine" "nomad-pantalla-vincular@"
    antes "nomad-pantalla-vincular@" "https://${IP_EMISOR}:47990/api/pin"
    hay "-X POST"
    local pin
    pin="$(awk 'match($0, /vincular@[0-9]+/) { print substr($0, RSTART + 9, RLENGTH - 9); exit }' "${CAJA}/llamadas")"
    [[ "${pin}" =~ ^[0-9]{4}$ ]] || fallar "PIN no válido: '${pin}'"
    hay "\"pin\":\"${pin}\""
    hay '"pairing_id":"ab12"'
    hay '"name":"hp-pantalla"'
    no_hay "--unit=pantalla-hp-vigilante"
    interna_restaurada
    pila_retirada
}

prueba_vincular_acepta_direccion_ipv4_en_ipv6() {
    preparar_vinculo "::ffff:${IP_HP}"
    lanzar vincular
    ENTRADA=""
    rc_es 0
    hay "-X POST"
}

prueba_vincular_no_pone_la_clave_en_argumentos() {
    preparar_vinculo "${IP_HP}"
    lanzar vincular
    ENTRADA=""
    rc_es 0
    no_hay "secreta"
    no_dice "secreta"
    grep -qF 'nomad:cl\"ave\\secreta' "${CAJA}/curl_entrada" \
        || fallar "la clave no llegó a curl por su entrada, bien escapada: $(cat "${CAJA}/curl_entrada" 2>/dev/null)"
}

prueba_vincular_rechaza_direccion_ajena() {
    preparar_vinculo 100.64.0.99
    lanzar vincular
    ENTRADA=""
    rc_no_es_cero
    no_hay "-X POST"
    dice "${IP_HP}"
    interna_restaurada
    pila_retirada
}

prueba_vincular_comprueba_el_hp_antes_de_montar_nada() {
    preparar_vinculo "${IP_HP}"
    lanzar vincular
    ENTRADA=""
    rc_es 0
    antes "AddKeysToAgent=yes" "--unit=pantalla-restaurar"
    antes "sudo -n -l /usr/bin/systemctl start nomad-pantalla.service" "--unit=pantalla-restaurar"
}

prueba_vincular_sin_agente_no_toca_pantallas() {
    # Sin esto, el 'stop' de 'detener' no podría entrar en el HP.
    touch "${CAJA}/agente_sin_clave"
    preparar_vinculo "${IP_HP}"
    lanzar vincular
    ENTRADA=""
    rc_no_es_cero
    pantallas_intactas
    no_hay "nomad-pantalla-vincular@"
}

prueba_vincular_se_rechaza_con_sesion_activa() {
    sesion_montada
    preparar_vinculo "${IP_HP}"
    lanzar vincular
    ENTRADA=""
    rc_no_es_cero
    no_hay "systemd-run"
    no_hay "ssh "
}

# ===========================================================================
#  LÍNEA DE ÓRDENES
# ===========================================================================

prueba_ayuda() {
    lanzar --help
    rc_es 0
    dice "extender"
    dice "principal"
    dice "vincular"
    no_dice "--vigilar"
    no_hay "kscreen-doctor"
}

prueba_check_no_toca_nada() {
    lanzar principal --check
    rc_es 0
    dice "CHECK"
    pantallas_intactas
    no_hay "ssh "
}

prueba_orden_desconocida() {
    lanzar apagar
    rc_no_es_cero
    pantallas_intactas
    no_hay "systemctl"
}

prueba_sin_argumentos_no_hace_nada() {
    lanzar
    rc_no_es_cero
    pantallas_intactas
}

prueba_estado_solo_consulta() {
    sesion_montada
    log_sunshine 'CLIENT CONNECTED'
    lanzar estado
    rc_es 0
    dice "pantalla-hp-sunshine"
    dice "conectado"
    no_hay "kscreen-doctor output."
    no_hay "systemctl --user stop"
    no_hay "systemd-run"
    no_hay "ssh "
}

prueba_no_usa_rutas_absolutas_que_salten_los_dobles() {
    # 'sudo -l' es la excepción: esa ruta es un argumento para el HP.
    if grep -vF 'sudo -n -l /usr/bin/systemctl' "${RAIZ}/scripts/emisor/pantalla-hp.sh" \
        | grep -nE '(^|[[:space:]])/(usr/)?bin/(kscreen-doctor|systemctl|systemd-run|ssh|ip|sleep|curl)\b'; then
        fallar "ruta absoluta en pantalla-hp.sh: estas pruebas tocarían el sistema real"
    fi
    [[ -f "${RAIZ}/scripts/emisor/pantalla-hp.sh" ]] || fallar "no existe pantalla-hp.sh"
}

# ===========================================================================
#  EL LANZADOR DEL HP
# ===========================================================================

# Renderiza el lanzador igual que instalar_plantilla, con un Moonlight de mentira
# que anota su PID y sus argumentos y hace lo que indique $1. El doble de 'timeout'
# hace de sondeo: consume un resultado de 'sondeos' por llamada, y 0 si no quedan.
# El doble de 'sleep' duerme de verdad, poco: el sondeo no debe ir a toda velocidad.
preparar_lanzador() {
    local d="${CAJA}/dobles_lanzador"
    mkdir -p "${d}"
    (
        export PANTALLA_EMISOR_IP="${IP_EMISOR}" PANTALLA_BITRATE=15000
        envsubst "$(formato_envsubst)" < "${RAIZ}/templates/etc/nomad-pantalla-lanzar.sh"
    ) | sed "s|^MOONLIGHT=.*|MOONLIGHT=${CAJA}/moonlight|" > "${CAJA}/lanzar.sh"
    chmod +x "${CAJA}/lanzar.sh"

    cat > "${CAJA}/moonlight" <<DOBLE
#!/bin/bash
echo "\$\$" > "${CAJA}/pid_moonlight"
echo "\$*" > "${CAJA}/args_moonlight"
$1
DOBLE
    chmod +x "${CAJA}/moonlight"

    cat > "${d}/timeout" <<'DOBLE'
#!/bin/bash
. "${CAJA}/dobles/_comun"
registrar timeout "$@"
rc=0
if [[ -s "${CAJA}/sondeos" ]]; then
    rc="$(head -n 1 "${CAJA}/sondeos")"
    sed -i 1d "${CAJA}/sondeos"
fi
exit "${rc}"
DOBLE
    cat > "${d}/sleep" <<'DOBLE'
#!/bin/bash
. "${CAJA}/dobles/_comun"
registrar sleep "$@"
exec /usr/bin/sleep 0.01
DOBLE
    chmod +x "${d}"/*
}

ejecutar_lanzador() {
    RC=0
    env -i "PATH=${CAJA}/dobles_lanzador:${CAJA}/dobles:/usr/bin:/bin" "CAJA=${CAJA}" \
        /usr/bin/timeout 15 "${CAJA}/lanzar.sh" > "${CAJA}/salida" 2>&1 < /dev/null || RC=$?
}

moonlight_muerto() {
    if kill -0 "$(cat "${CAJA}/pid_moonlight")" 2>/dev/null; then
        fallar "Moonlight sigue vivo"
        kill -KILL "$(cat "${CAJA}/pid_moonlight")" 2>/dev/null || true
    fi
}

prueba_lanzador_pasa_sus_argumentos_a_moonlight() {
    preparar_lanzador 'exit 0'
    ejecutar_lanzador
    rc_es 0
    local args
    args="$(cat "${CAJA}/args_moonlight")"
    [[ "${args}" == "stream ${IP_EMISOR} Desktop --1080 --fps 60 --bitrate 15000 "* ]] \
        || fallar "argumentos inesperados: ${args}"
    [[ "${args}" == *"--absolute-mouse" ]] || fallar "faltan argumentos: ${args}"
    if grep -nE '\$\{(PANTALLA|MOONLIGHT_V)[A-Z_]*\}' "${CAJA}/lanzar.sh"; then
        fallar "quedan variables sin sustituir"
    fi
}

prueba_lanzador_cierra_moonlight_tras_tres_sondeos_fallidos() {
    preparar_lanzador 'exec /usr/bin/sleep 30'
    printf '%s\n' 1 1 1 > "${CAJA}/sondeos"
    ejecutar_lanzador
    rc_no_es_cero
    (( RC != 124 )) || fallar "nadie cerró Moonlight: venció el tope de la prueba"
    (( $(veces "timeout ") == 3 )) || fallar "hizo $(veces "timeout ") sondeos, se esperaban 3"
    dice "${IP_EMISOR}:47989"
    moonlight_muerto
}

prueba_lanzador_sondea_cada_5_segundos_tras_la_espera_inicial() {
    preparar_lanzador 'exec /usr/bin/sleep 30'
    printf '%s\n' 1 1 1 > "${CAJA}/sondeos"
    ejecutar_lanzador
    # La primera línea es la espera: un sondeo antes competiría con Sunshine.
    [[ "$(sed -n 1p "${CAJA}/llamadas")" == "sleep 10" ]] \
        || fallar "lo primero no es la espera inicial: $(sed -n 1p "${CAJA}/llamadas")"
    [[ "$(sed -n 3p "${CAJA}/llamadas")" == "sleep 5" ]] || fallar "entre sondeos no hay 5 s"
    [[ "$(sed -n 5p "${CAJA}/llamadas")" == "sleep 5" ]] || fallar "entre sondeos no hay 5 s"
    hay "timeout 3 "
}

prueba_lanzador_solo_cuenta_fallos_seguidos() {
    preparar_lanzador 'exec /usr/bin/sleep 30'
    printf '%s\n' 1 1 0 1 1 0 1 1 1 > "${CAJA}/sondeos"
    ejecutar_lanzador
    (( $(veces "timeout ") == 9 )) || fallar "hizo $(veces "timeout ") sondeos, se esperaban 9"
    moonlight_muerto
}

prueba_lanzador_sale_con_el_codigo_de_moonlight() {
    preparar_lanzador 'exit 7'
    ejecutar_lanzador
    rc_es 7
}

prueba_lanzador_mata_a_moonlight_si_ignora_sigterm() {
    preparar_lanzador "trap '' TERM; exec /usr/bin/sleep 30"
    printf '%s\n' 1 1 1 > "${CAJA}/sondeos"
    ejecutar_lanzador
    rc_es 137
    moonlight_muerto
}

prueba_lanzador_pasa_sigterm_a_moonlight() {
    # Al parar la unidad, 'cage' espera a que el lanzador termine.
    preparar_lanzador 'exec /usr/bin/sleep 30'
    env -i "PATH=${CAJA}/dobles_lanzador:${CAJA}/dobles:/usr/bin:/bin" "CAJA=${CAJA}" \
        "${CAJA}/lanzar.sh" > "${CAJA}/salida" 2>&1 < /dev/null &
    local pid=$! i
    for (( i = 0; i < 300; i++ )); do
        if [[ -s "${CAJA}/pid_moonlight" ]]; then break; fi
        /usr/bin/sleep 0.01
    done
    kill -TERM "${pid}"
    RC=0
    wait "${pid}" || RC=$?
    rc_es 143
    moonlight_muerto
}

prueba_lanzador_sondeo_real_contra_un_puerto_cerrado() {
    # Sin doble de 'timeout': la línea del sondeo debe funcionar de verdad.
    preparar_lanzador 'exec /usr/bin/sleep 30'
    rm "${CAJA}/dobles_lanzador/timeout"
    sed -i 's/^EMISOR=.*/EMISOR=127.0.0.1/; s/^PUERTO_SONDEO=[0-9]*/PUERTO_SONDEO=1/' "${CAJA}/lanzar.sh"
    ejecutar_lanzador
    rc_no_es_cero
    (( RC != 124 )) || fallar "nadie cerró Moonlight: venció el tope de la prueba"
    dice "127.0.0.1:1"
    moonlight_muerto
}

# ===========================================================================
#  LAS UNIDADES DEL HP
# ===========================================================================

UNIDADES=(nomad-pantalla.service nomad-pantalla-vincular@.service)

# Número de la línea de la plantilla que contiene el texto (0 si ninguna).
linea_de() { awk -v t="$2" 'index($0, t) { print NR; f = 1; exit } END { if (!f) print 0 }' "$1"; }

prueba_unidades_sin_cambio_de_consola_en_cage() {
    local u
    for u in "${UNIDADES[@]}"; do
        if grep -nE '^ExecStart=.*cage -s' "${RAIZ}/templates/systemd/${u}"; then
            fallar "${u}: 'cage -s' deja cambiar de consola desde el kiosco"
        fi
        grep -qE '^ExecStart=/usr/bin/cage -- ' "${RAIZ}/templates/systemd/${u}" \
            || fallar "${u}: falta el ExecStart de cage"
    done
}

prueba_audio_usa_la_tarjeta_por_nombre() {
    local raiz
    raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    grep -q -- '-c PCH sset Master' "${raiz}/templates/systemd/nomad-pantalla.service" \
        || fallar "la unidad debe ajustar el volumen en la tarjeta PCH"
    grep -qE -- 'amixer .*-c [0-9]' "${raiz}/templates/systemd/nomad-pantalla.service" \
        && fallar "un número de tarjeta cambia con los periféricos USB"
    grep -q '^export ALSA_CARD=PCH$' "${raiz}/templates/etc/nomad-pantalla-lanzar.sh" \
        || fallar "el lanzador debe fijar ALSA_CARD=PCH"
    return 0
}

prueba_unidades_limpian_al_usuario_antes_de_volver_a_tty1() {
    local u f pkill chvt
    for u in "${UNIDADES[@]}"; do
        f="${RAIZ}/templates/systemd/${u}"
        # shellcheck disable=SC2016  # la plantilla lleva la variable sin expandir
        pkill="$(linea_de "${f}" 'ExecStopPost=-+/usr/bin/loginctl terminate-user ${PANTALLA_USUARIO}')"
        chvt="$(linea_de "${f}" 'ExecStopPost=+/usr/bin/chvt 1')"
        (( pkill > 0 && chvt > pkill )) || fallar "${u}: pkill (línea ${pkill}) debe ir antes de chvt (línea ${chvt})"
    done
}

prueba_unidades_se_descargan_al_fallar() {
    # Va en [Unit]: en [Service], systemd la ignora con solo un aviso.
    local u
    for u in "${UNIDADES[@]}"; do
        sed -n '/^\[Unit\]/,/^\[Service\]/p' "${RAIZ}/templates/systemd/${u}" \
            | contiene -x 'CollectMode=inactive-or-failed' \
            || fallar "${u}: falta CollectMode en [Unit]"
    done
}

prueba_unidad_de_vinculo_y_de_sesion_no_coinciden() {
    local f="${RAIZ}/templates/systemd/nomad-pantalla-vincular@.service"
    grep -qx 'Conflicts=nomad-pantalla.service' "${f}" || fallar "falta Conflicts"
    # Sin orden, el pkill de la que para mataría a la que arranca.
    grep -qE '^After=.*nomad-pantalla\.service' "${f}" || fallar "falta After"
}

prueba_unidad_el_sonido_no_impide_la_imagen() {
    local f="${RAIZ}/templates/systemd/nomad-pantalla.service"
    (( $(grep -c '^ExecStartPre=-/usr/bin/amixer' "${f}") == 2 )) || fallar "amixer sin '-'"
    if grep -n '^ExecStartPre=/usr/bin/amixer' "${f}"; then fallar "queda un amixer sin '-'"; fi
}

prueba_limites_en_la_porcion_del_usuario() {
    local f="${RAIZ}/templates/systemd/nomad-pantalla-usuario.conf"
    grep -qx '\[Slice\]' "${f}" || fallar "falta [Slice]"
    grep -qx 'CPUWeight=50' "${f}" || fallar "falta CPUWeight"
    grep -qx 'MemoryMax=2G' "${f}" || fallar "falta MemoryMax"
}

# ===========================================================================
#  EL MONTAJE Y LA VERIFICACIÓN EN EL HP
# ===========================================================================

# Una caja con los scripts del HP y dobles de lo que consultan. 18_pantalla.sh
# solo se ejecuta con --check: su doble de 'requerir_root' deja correrlo sin ser
# root, y nada escribe en el sistema.
#
#   usuario_grupos  los grupos de 'pantalla'; sin él, el usuario no existe.
#   sin_paquetes    los paquetes que dpkg-query no encuentra, uno por línea.
#   sudoers         lo que tiene /etc/sudoers.d/nomad-pantalla.
#   sin_sudo        sudo -n falla.
#   apprun_cerrado  'pantalla' no puede ejecutar AppRun.
preparar_hp() {
    local d="${CAJA}/dobles_hp"
    mkdir -p "${d}" "${CAJA}/repo/templates"
    cp "${RAIZ}/scripts/18_pantalla.sh" "${RAIZ}/scripts/verificar_sistema.sh" "${CAJA}/repo/scripts/"
    cp -r "${RAIZ}/templates/." "${CAJA}/repo/templates/"
    cp "${RAIZ}/config/servidor.env.example" "${CAJA}/repo/config/"
    echo 'requerir_root() { :; }' >> "${CAJA}/repo/scripts/lib/common.sh"
    {
        echo 'ADMIN_USUARIO="admin"'
        echo 'PANTALLA_HABILITADA="si"'
        echo 'PANTALLA_USUARIO="pantalla"'
        echo "PANTALLA_EMISOR_IP=\"${IP_EMISOR}\""
        echo 'PANTALLA_BITRATE="40000"'
        echo 'MOONLIGHT_VERSION="6.2.0"'
        echo 'MOONLIGHT_SHA256="abc"'
    } > "${CAJA}/repo/config/servidor.env"
    echo "pantalla video render audio" > "${CAJA}/usuario_grupos"
    echo "admin ALL=(root) NOPASSWD: /usr/bin/systemctl start nomad-pantalla.service, /usr/bin/systemctl stop nomad-pantalla.service" \
        > "${CAJA}/sudoers"

    cat > "${d}/id" <<'DOBLE'
#!/bin/bash
[[ -e "${CAJA}/usuario_grupos" && "${*: -1}" == pantalla ]] || exit 1
if [[ "$1" == -u ]]; then echo 999; else cat "${CAJA}/usuario_grupos"; fi
DOBLE
    cat > "${d}/dpkg-query" <<'DOBLE'
#!/bin/bash
paquete="${*: -1}"
if [[ -e "${CAJA}/sin_paquetes" ]] && grep -qxF -- "${paquete}" "${CAJA}/sin_paquetes"; then exit 1; fi
[[ "${paquete}" == libfuse2t64 ]] && exit 1
echo "install ok installed"
DOBLE
    cat > "${d}/sudo" <<'DOBLE'
#!/bin/bash
[[ ! -e "${CAJA}/sin_sudo" ]] || exit 1
case "$*" in
    "-n true")                 exit 0 ;;
    "-n cat "*)                cat "${CAJA}/sudoers" ;;
    "-n test ! -e "*)          exit 1 ;;
    "-n -u pantalla true")     exit 0 ;;
    "-n -u pantalla test -x "*) [[ ! -e "${CAJA}/apprun_cerrado" ]] ;;
    "-n -u pantalla vainfo")   echo "VAProfileHEVCMain : VAEntrypointVLD" ;;
    *)                         exit 1 ;;
esac
DOBLE
    cat > "${d}/systemctl" <<'DOBLE'
#!/bin/bash
[[ "$1" != cat ]] || exit 1
[[ "$1" != is-enabled ]] || echo static
exit 0
DOBLE
    printf '#!/bin/bash\nexit 0\n' > "${d}/visudo"
    chmod +x "${d}"/*
}

ejecutar_hp() {
    RC=0
    ( cd "${CAJA}" && env -i "PATH=${CAJA}/dobles_hp:${CAJA}/dobles:/usr/bin:/bin" "HOME=${CAJA}/home" \
        "CAJA=${CAJA}" TERM=dumb /usr/bin/timeout 20 "$@" ) > "${CAJA}/salida" 2>&1 < /dev/null || RC=$?
}
montar_hp()    { ejecutar_hp "${CAJA}/repo/scripts/18_pantalla.sh" --check; }
verificar_hp() { ejecutar_hp "${CAJA}/repo/scripts/verificar_sistema.sh" --seccion pantalla; }

prueba_hp_con_no_no_exige_el_resto_de_variables() {
    preparar_hp
    echo 'PANTALLA_HABILITADA="no"' > "${CAJA}/repo/config/servidor.env"
    chmod 600 "${CAJA}/repo/config/servidor.env"
    montar_hp
    rc_es 0
    dice "no es 'si'"
    no_dice "Paquetes"
}

prueba_hp_sin_la_variable_tampoco_hace_nada() {
    preparar_hp
    : > "${CAJA}/repo/config/servidor.env"
    montar_hp
    rc_es 0
    dice "no es 'si'"
}

prueba_hp_con_si_exige_las_variables() {
    preparar_hp
    sed -i '/^PANTALLA_BITRATE=/d' "${CAJA}/repo/config/servidor.env"
    montar_hp
    rc_no_es_cero
    dice "PANTALLA_BITRATE"
}

prueba_hp_instala_xwayland_y_kbd() {
    preparar_hp
    printf '%s\n' xwayland kbd > "${CAJA}/sin_paquetes"
    montar_hp
    rc_es 0
    dice "Paquetes por instalar: xwayland kbd"
}

prueba_hp_usuario_existente_recibe_los_grupos_que_le_faltan() {
    preparar_hp
    echo "pantalla video" > "${CAJA}/usuario_grupos"
    montar_hp
    rc_es 0
    dice "ejecutaría: usermod -aG render pantalla"
    dice "ejecutaría: usermod -aG audio pantalla"
    no_dice "usermod -aG video"
}

prueba_hp_usuario_con_sus_grupos_no_se_toca() {
    preparar_hp
    montar_hp
    rc_es 0
    no_dice "usermod"
}

prueba_hp_rechaza_al_usuario_en_input() {
    preparar_hp
    echo "pantalla video render audio input" > "${CAJA}/usuario_grupos"
    montar_hp
    rc_no_es_cero
    dice "gpasswd -d pantalla input"
}

prueba_hp_limites_en_la_porcion_del_uid_con_recarga() {
    preparar_hp
    montar_hp
    rc_es 0
    dice "escribiría /etc/systemd/system/user-999.slice.d/50-nomad-pantalla.conf"
    dice "ejecutaría: systemctl daemon-reload"
}

prueba_hp_sin_usuario_avisa_de_los_limites_con_check() {
    preparar_hp
    rm "${CAJA}/usuario_grupos"
    montar_hp
    rc_es 0
    dice "ejecutaría: useradd"
    dice "user-<uid>.slice.d/50-nomad-pantalla.conf"
}

prueba_verificar_sudoers_exacto_con_comentarios_pasa() {
    preparar_hp
    sed -i '1i # comentario\n' "${CAJA}/sudoers"
    verificar_hp
    dice "sudoers con las dos reglas exactas"
}

prueba_verificar_sudoers_con_una_regla_de_mas_falla() {
    preparar_hp
    echo "admin ALL=(root) NOPASSWD: ALL" >> "${CAJA}/sudoers"
    verificar_hp
    rc_no_es_cero
    dice "no contiene exactamente las reglas esperadas"
    no_dice "sudoers con las dos reglas exactas"
}

prueba_verificar_paquete_que_falta_falla() {
    preparar_hp
    echo kbd > "${CAJA}/sin_paquetes"
    verificar_hp
    rc_no_es_cero
    dice "Faltan paquetes: kbd"
}

prueba_verificar_con_todos_los_paquetes() {
    preparar_hp
    verificar_hp
    dice "Paquetes de la pantalla instalados."
}

prueba_verificar_apprun_como_su_usuario() {
    preparar_hp
    verificar_hp
    dice "ejecutable por pantalla"
    touch "${CAJA}/apprun_cerrado"
    verificar_hp
    rc_no_es_cero
    dice "pantalla no puede ejecutar"
}

prueba_verificar_sin_sudo_es_aviso_y_no_fallo() {
    preparar_hp
    touch "${CAJA}/sin_sudo" "${CAJA}/apprun_cerrado"
    verificar_hp
    dice "No puedo comprobar sin sudo que pantalla ejecute"
    no_dice "no puede ejecutar"
    no_dice "Faltan paquetes"
}

prueba_verificar_rechaza_el_grupo_input() {
    preparar_hp
    echo "pantalla video render audio input" > "${CAJA}/usuario_grupos"
    verificar_hp
    rc_no_es_cero
    dice "gpasswd -d pantalla input"
}

prueba_verificar_usuario_por_defecto_es_pantalla() {
    preparar_hp
    sed -i '/^PANTALLA_USUARIO=/d' "${CAJA}/repo/config/servidor.env"
    verificar_hp
    dice "pantalla sin grupos sudo, docker, adm ni input."
}

# ===========================================================================
#  EJECUCIÓN
# ===========================================================================

while read -r prueba; do
    preparar
    ENTRADA=""
    FALLOS=0
    echo "- ${prueba}"
    "${prueba}" || fallar "la prueba ha terminado con error"
    if (( FALLOS == 0 )); then
        PASADAS=$(( PASADAS + 1 ))
    else
        FALLADAS=$(( FALLADAS + 1 ))
        NOMBRES_FALLIDOS+=("${prueba}")
        sed 's/^/      | /' "${CAJA}/salida" 2>/dev/null | tail -n 5 || true
    fi
    rm -rf "${CAJA}"
done < <(declare -F | awk '$3 ~ /^prueba_/ { print $3 }')

echo
echo "Pasan: ${PASADAS}. Fallan: ${FALLADAS}."
if (( FALLADAS > 0 )); then
    printf '  %s\n' "${NOMBRES_FALLIDOS[@]}"
    exit 1
fi
