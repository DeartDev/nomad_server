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
#
#  POR DÓNDE SALE EL SONIDO
#
#  El emisor lo elige en cada sesión ('pantalla-hp <modo> --audio ...') y lo
#  deja por SSH, sin sudo, en /var/lib/nomad-pantalla/audio, una carpeta del
#  administrador que crea 18_pantalla.sh. Este script solo acepta tres valores;
#  cualquier otro, o ninguno, es 'hp':
#
#    hp        la tarjeta interna del HP (PCH): altavoces o jack.
#    hp-usb    la primera tarjeta USB del HP (auriculares, altavoz USB). Si no
#              hay ninguna, sale por la interna y lo dice en el journal.
#    portatil  suena en lo que el portátil tenga como salida: Moonlight pide
#              al emisor que lo reproduzca allí (--audio-on-host), y el HP lo
#              descarta (SDL_AUDIODRIVER=dummy). Hacen falta las dos cosas:
#              Apollo sigue enviando el sonido con --audio-on-host, y sin la
#              segunda sonaba también en el HP (medido, 2026-11-19).
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
ARCHIVO_AUDIO=/var/lib/nomad-pantalla/audio
TARJETAS=/proc/asound/cards
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

# El nombre de la primera tarjeta USB, como lo usa ALSA_CARD:
#  0 [Audio          ]: USB-Audio - USB Audio
tarjeta_usb() {
    sed -nE 's/^ *[0-9]+ \[([^] ]+) *\]: USB-Audio.*/\1/p' "${TARJETAS}" 2>/dev/null | head -n 1
}

# Lo lee una sola vez y como texto: no se ejecuta nada de lo que contenga.
AUDIO="$(head -c 32 "${ARCHIVO_AUDIO}" 2>/dev/null | tr -d '[:space:]')"
OPCIONES_AUDIO=()
case "${AUDIO}" in
    portatil)
        OPCIONES_AUDIO=(--audio-on-host)
        # El SDL2 de Moonlight es la capa de compatibilidad sobre SDL3, que lee
        # SDL_AUDIO_DRIVER: se fijan las dos.
        export SDL_AUDIODRIVER=dummy SDL_AUDIO_DRIVER=dummy
        echo "Audio: en el portátil (--audio-on-host; el HP no lo reproduce)." >&2 ;;
    hp-usb)
        TARJETA="$(tarjeta_usb)"
        if [[ -n "${TARJETA}" ]]; then
            export ALSA_CARD="${TARJETA}"
            echo "Audio: tarjeta USB del HP (${TARJETA})." >&2
        else
            echo "Audio: se pidió una tarjeta USB y el HP no tiene ninguna; sale por la interna." >&2
        fi ;;
    hp|"")
        echo "Audio: tarjeta interna del HP." >&2 ;;
    *)
        echo "Audio: valor desconocido en ${ARCHIVO_AUDIO}; sale por la interna del HP." >&2 ;;
esac

# En segundo plano: el proceso principal vuelve enseguida a esperar a Moonlight.
trap 'cerrar_moonlight "Moonlight ha anunciado el fin de la conexión" &' USR1

"${MOONLIGHT}" stream "${EMISOR}" Desktop \
    --1080 --fps 60 --bitrate ${PANTALLA_BITRATE} --no-vsync \
    --packet-size 1024 --display-mode fullscreen \
    --video-decoder hardware --video-codec HEVC \
    --audio-config stereo --absolute-mouse --capture-system-keys fullscreen \
    ${OPCIONES_AUDIO[@]+"${OPCIONES_AUDIO[@]}"} \
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
