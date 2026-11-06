#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — lanzador del cliente de la pantalla extendida
#  Destino  : /opt/nomad-pantalla/lanzar.sh
#  Generado por scripts/18_pantalla.sh
#  Capítulo : docs/18_pantalla_extendida.md
#
#  Propósito : arrancar Moonlight a pantalla completa contra el emisor.
#              Lo lanza 'cage' desde nomad-pantalla.service.
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
# ===========================================================================
set -euo pipefail

export QT_QPA_PLATFORM=xcb
export SDL_AUDIODRIVER=alsa
export LIBVA_DRIVER_NAME=iHD

exec /opt/nomad-pantalla/moonlight/AppRun stream ${PANTALLA_EMISOR_IP} Desktop \
    --1080 --fps 60 --bitrate ${PANTALLA_BITRATE} --no-vsync \
    --packet-size 1024 --display-mode fullscreen \
    --video-decoder hardware --video-codec HEVC \
    --audio-config stereo --absolute-mouse
