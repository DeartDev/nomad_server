#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — lanzador del cliente de la pantalla extendida
#  Destino  : /opt/nomad-pantalla/lanzar.sh
#  Generado por scripts/18_pantalla.sh
#  Capítulo : docs/18_pantalla_extendida.md
#
#  Propósito : arrancar Moonlight a pantalla completa contra el emisor, y cerrarlo
#              si el emisor desaparece. Lo lanza 'cage' desde nomad-pantalla.service.
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
#
#  POR QUÉ NO HACE 'exec' DE MOONLIGHT
#
#  Si el portátil cae, nadie en él puede pedir el 'stop' por SSH, y Moonlight se
#  queda en su diálogo de error con el panel ocupado. Por eso este proceso sigue
#  vivo y sondea el puerto de Sunshine. El sondeo sale del HP hacia el portátil,
#  como la propia sesión: el cortafuegos del HP no cambia.
# ===========================================================================
# Sin 'set -e': 'wait' devuelve el código de Moonlight, y un sondeo que falla es
# parte del funcionamiento normal.
set -uo pipefail

export QT_QPA_PLATFORM=xcb
export SDL_AUDIODRIVER=alsa
export LIBVA_DRIVER_NAME=iHD

MOONLIGHT=/opt/nomad-pantalla/moonlight/AppRun
EMISOR=${PANTALLA_EMISOR_IP}

PUERTO_SONDEO=47989    # el puerto HTTP de Sunshine
ESPERA_INICIAL=10      # s: Sunshine puede estar arrancando todavía
INTERVALO_SONDEO=5     # s entre dos sondeos
FALLOS_MAXIMOS=3       # sondeos fallidos seguidos que cierran la sesión
LIMITE_CONEXION=3      # s: un portátil caído no rechaza, solo no contesta
PLAZO_CIERRE=5         # s que tiene Moonlight para salir antes de SIGKILL

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

    echo "Sin respuesta de ${EMISOR}:${PUERTO_SONDEO} en ${FALLOS_MAXIMOS} sondeos seguidos: se cierra Moonlight." >&2
    kill -TERM "${PID_MOONLIGHT}" 2>/dev/null
    sleep "${PLAZO_CIERRE}"
    kill -KILL "${PID_MOONLIGHT}" 2>/dev/null
}

"${MOONLIGHT}" stream "${EMISOR}" Desktop \
    --1080 --fps 60 --bitrate ${PANTALLA_BITRATE} --no-vsync \
    --packet-size 1024 --display-mode fullscreen \
    --video-decoder hardware --video-codec HEVC \
    --audio-config stereo --absolute-mouse &
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
