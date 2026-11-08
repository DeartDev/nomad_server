#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — lanzador del cliente de la pantalla extendida
#  Destino  : /opt/nomad-pantalla/lanzar.sh
#  Generado por scripts/18_pantalla.sh
#  Capítulo : docs/18_pantalla_extendida.md
#
#  Propósito : arrancar Moonlight a pantalla completa contra el emisor, y cerrarlo
#              si el emisor desaparece. Lo lanza 'cage' desde
#              nomad-pantalla@<emisor>.service, que le pasa el nombre del emisor.
#
#  Uso       : lanzar.sh <emisor>     ('fedora' o 'windows'; lo traduce emisor.sh)
#
#  CÓMO APLICARLA A MANO (equivalente a lo que hace el script)
#
#      cd ~/nomad_server
#      source scripts/lib/entorno.sh
#      sudo install -d -m 755 /opt/nomad-pantalla
#      nomad_diff etc/nomad-pantalla-lanzar.sh /opt/nomad-pantalla/lanzar.sh
#      nomad_plantilla etc/nomad-pantalla-lanzar.sh \
#          | sudo tee /opt/nomad-pantalla/lanzar.sh >/dev/null
#      sudo chmod 755 /opt/nomad-pantalla/lanzar.sh
#
#  No lleva 'pair': vincular es un paso aparte (nomad-pantalla-vincular@.service).
#  Tampoco --performance-overlay: la superposición tapa la imagen.
#  Sí lleva --capture-system-keys: sin él, Moonlight se queda la tecla Win y no
#  la envía al emisor (medido en Windows, 2026-11-07).
#
#  POR QUÉ NO HACE 'exec' DE MOONLIGHT
#
#  Si el portátil cae, nadie en él puede pedir el 'stop' por SSH, y Moonlight se
#  queda en su diálogo de error con el panel ocupado. Por eso este proceso sigue
#  vivo y lo cierra por dos vías:
#
#  - Su propia salida: cuando escribe 'Connection terminated', la sesión ya ha
#    acabado. Es lo que cubre un corte con el portátil aún accesible, por
#    ejemplo al quitar el cable con el Wi-Fi activo: el emisor sigue
#    respondiendo y el sondeo no ve nada (medido en Windows, 2026-11-07).
#  - El sondeo del puerto de Sunshine, para un portátil que desaparece sin que
#    Moonlight llegue a enterarse. Sale del HP hacia el portátil, como la propia
#    sesión: el cortafuegos del HP no cambia.
#
#  La salida de Moonlight se sigue copiando entera al journal.
# ===========================================================================
# Sin 'set -e': 'wait' devuelve el código de Moonlight, y un sondeo que falla es
# parte del funcionamiento normal.
set -uo pipefail

export QT_QPA_PLATFORM=xcb
# La tarjeta del HP por nombre: un audio USB en un hub le quita el número 0.
export ALSA_CARD=PCH
export SDL_AUDIODRIVER=alsa
export LIBVA_DRIVER_NAME=iHD

MOONLIGHT=/opt/nomad-pantalla/moonlight/AppRun
RESOLVER=/opt/nomad-pantalla/emisor.sh

# Un emisor desconocido o sin IP termina aquí, antes de arrancar Moonlight. El
# motivo lo escribe emisor.sh y queda en el journal de la unidad.
EMISOR="$("${RESOLVER}" "${1:-}")" || exit 1

PUERTO_SONDEO=47989    # el puerto HTTP de Sunshine
ESPERA_INICIAL=10      # s: Sunshine puede estar arrancando todavía
INTERVALO_SONDEO=5     # s entre dos sondeos
FALLOS_MAXIMOS=3       # sondeos fallidos seguidos que cierran la sesión
LIMITE_CONEXION=3      # s: un portátil caído no rechaza, solo no contesta
PLAZO_CIERRE=5         # s que tiene Moonlight para salir antes de SIGKILL
FIN_DE_SESION='Connection terminated'   # lo que escribe Moonlight 6.2.0 al perderla

PID_MOONLIGHT=""

cerrar_moonlight() {
    [[ -n "${PID_MOONLIGHT}" ]] || return 0
    echo "$1: se cierra Moonlight." >&2
    kill -TERM "${PID_MOONLIGHT}" 2>/dev/null
    sleep "${PLAZO_CIERRE}"
    kill -KILL "${PID_MOONLIGHT}" 2>/dev/null
}

# Copia la salida de Moonlight al journal y avisa al proceso principal, una sola
# vez, cuando anuncia el fin de la sesión. Corre en una sustitución de procesos:
# ahí '$$' sigue siendo el PID de este script.
filtrar_salida() {
    local linea avisado=0
    while IFS= read -r linea; do
        printf '%s\n' "${linea}" >&2
        if (( avisado == 0 )) && [[ "${linea}" == *"${FIN_DE_SESION}"* ]]; then
            avisado=1
            kill -USR1 "$$" 2>/dev/null
        fi
    done
}

emisor_responde() {
    timeout "${LIMITE_CONEXION}" bash -c 'exec 3<>"/dev/tcp/$0/$1"' \
        "${EMISOR}" "${PUERTO_SONDEO}" 2>/dev/null
}

# Corre aparte para que el proceso principal solo espere a Moonlight: así sale en
# cuanto este termina y atiende las señales sin esperar a un sondeo.
vigilar_emisor() {
    local fallos=0

    sleep "${ESPERA_INICIAL}"
    while true; do
        if emisor_responde; then
            fallos=0
        else
            fallos=$(( fallos + 1 ))
        fi
        if (( fallos >= FALLOS_MAXIMOS )); then break; fi
        sleep "${INTERVALO_SONDEO}"
    done

    cerrar_moonlight "Sin respuesta de ${EMISOR}:${PUERTO_SONDEO} en ${FALLOS_MAXIMOS} sondeos seguidos"
}

# En segundo plano: el proceso principal vuelve enseguida a esperar a Moonlight.
trap 'cerrar_moonlight "Moonlight ha anunciado el fin de la conexión" &' USR1

"${MOONLIGHT}" stream "${EMISOR}" Desktop \
    --1080 --fps 60 --bitrate ${PANTALLA_BITRATE} --no-vsync \
    --packet-size 1024 --display-mode fullscreen \
    --video-decoder hardware --video-codec HEVC \
    --audio-config stereo --absolute-mouse --capture-system-keys fullscreen \
    > >(filtrar_salida) 2>&1 &
PID_MOONLIGHT=$!

# Al parar la unidad, 'cage' espera a este proceso: la señal debe llegar a Moonlight.
trap 'kill -TERM "${PID_MOONLIGHT}" 2>/dev/null' TERM INT HUP

vigilar_emisor &
PID_VIGIA=$!

# Una señal atendida interrumpe 'wait': se repite hasta que Moonlight termine.
wait "${PID_MOONLIGHT}"
ESTADO=$?
while kill -0 "${PID_MOONLIGHT}" 2>/dev/null; do
    wait "${PID_MOONLIGHT}"
    ESTADO=$?
done

kill "${PID_VIGIA}" 2>/dev/null
exit "${ESTADO}"
