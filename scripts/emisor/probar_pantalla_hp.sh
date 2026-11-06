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
#  de una sesión se prueban en milisegundos.
# ===========================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

mostrar_ayuda() {
    cat <<'AYUDA'
Uso: bash scripts/emisor/probar_pantalla_hp.sh [--help]

Ejecuta las pruebas de pantalla-hp.sh con dobles de kscreen-doctor, systemd-run,
systemctl, ssh, ip, curl y sleep. No toca las pantallas ni se conecta a nada.
Termina con 0 si todas pasan.
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
        printf '\033[01;32mOutput: \033[0;0m2 %s bbbb\n\t%s\n\tconnected\n\tpriority %s\n\tGeometry: %s 1920x1080\n' \
            "${V}" "$(cat "${P}/${V}.estado")" "$(cat "${P}/${V}.prioridad")" "$(cat "${P}/${V}.posicion")"
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

    # 'falla_ssh' guarda el trozo de la orden con el que ssh debe fallar.
    cat > "${d}/ssh" <<'DOBLE'
#!/bin/bash
. "${CAJA}/dobles/_comun"
registrar ssh "$@"
if [[ -e "${CAJA}/falla_ssh" && "$*" == *"$(cat "${CAJA}/falla_ssh")"* ]]; then
    echo "ssh: connect to host: Connection timed out" >&2
    exit 255
fi
exit 0
DOBLE

    cat > "${d}/ip" <<'DOBLE'
#!/bin/bash
. "${CAJA}/dobles/_comun"
registrar ip "$@"
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
sesion_montada() {
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

prueba_orden_completo_del_arranque() {
    lanzar extender
    rc_es 0
    antes "--unit=pantalla-hp-monitor" "--unit=pantalla-restaurar"
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

prueba_hp_inaccesible_restaura_interna() {
    echo "systemctl start nomad-pantalla" > "${CAJA}/falla_ssh"
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
    no_hay "systemctl start nomad-pantalla"
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
    no_hay "systemctl start nomad-pantalla"
    interna_restaurada
    pila_retirada
}

prueba_sin_temporizador_no_se_toca_nada_mas() {
    touch "${CAJA}/falla_pantalla-restaurar.timer"
    lanzar principal
    rc_no_es_cero
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
    antes "stop pantalla-hp-vigilante" "sudo -n systemctl stop nomad-pantalla.service"
    unidad_parada pantalla-hp-vigilante
}

prueba_off_restaura_tras_sunshine_y_antes_del_monitor() {
    sesion_montada
    lanzar off
    rc_es 0
    antes "stop pantalla-hp-sunshine" "${ORDEN_RESTAURAR}"
    antes "${ORDEN_RESTAURAR}" "stop pantalla-hp-monitor"
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
    (( $(veces "sleep ") == 4 )) || fallar "hizo $(veces "sleep ") sondeos, se esperaban 4"
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
    if grep -nE '(^|[[:space:]])/(usr/)?bin/(kscreen-doctor|systemctl|systemd-run|ssh|ip|sleep|curl)\b' \
        "${RAIZ}/scripts/emisor/pantalla-hp.sh"; then
        fallar "ruta absoluta en pantalla-hp.sh: estas pruebas tocarían el sistema real"
    fi
    [[ -f "${RAIZ}/scripts/emisor/pantalla-hp.sh" ]] || fallar "no existe pantalla-hp.sh"
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
