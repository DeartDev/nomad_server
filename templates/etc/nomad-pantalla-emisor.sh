#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — traductor de emisores de la pantalla extendida
#  Destino  : /opt/nomad-pantalla/emisor.sh
#  Generado por scripts/18_pantalla.sh
#  Capítulo : docs/18_pantalla_extendida.md
#
#  Propósito : traducir el nombre de un emisor ('fedora', 'windows') a su IP de
#              Tailscale. Es el único sitio del HP que guarda esas IP: la unidad
#              y el lanzador solo conocen el nombre, que llega de la instancia.
#
#  Uso:
#      emisor.sh <emisor>                     imprime la IP, o sale con 1
#      emisor.sh --vincular <emisor>-<PIN>    vincula Moonlight con ese emisor
#
#  Un nombre desconocido, o un emisor sin IP en servidor.env, sale con 1 y sin
#  imprimir nada en la salida estándar: quien lo llama no puede confundir un
#  mensaje de error con una dirección.
#
#  CÓMO APLICARLA A MANO (equivalente a lo que hace el script)
#
#      cd ~/nomad_server
#      source scripts/lib/entorno.sh
#      sudo install -d -m 755 /opt/nomad-pantalla
#      nomad_diff etc/nomad-pantalla-emisor.sh /opt/nomad-pantalla/emisor.sh
#      nomad_plantilla etc/nomad-pantalla-emisor.sh \
#          | sudo tee /opt/nomad-pantalla/emisor.sh >/dev/null
#      sudo chmod 755 /opt/nomad-pantalla/emisor.sh
#
#  Las IP se escriben al renderizar: tras cambiarlas en servidor.env, ejecuta
#  18_pantalla.sh otra vez.
# ===========================================================================
set -uo pipefail

MOONLIGHT=/opt/nomad-pantalla/moonlight/AppRun

# Las variables propias van en minúsculas: envsubst solo sustituye los nombres de
# servidor.env.example, y los de aquí deben llegar intactos.
direccion_de() {
    case "$1" in
        fedora)  printf '%s' "${PANTALLA_EMISOR_IP}" ;;
        windows) printf '%s' "${PANTALLA_EMISOR_WINDOWS_IP}" ;;
        *)       return 1 ;;
    esac
}

variable_de() {
    case "$1" in
        fedora)  printf 'PANTALLA_EMISOR_IP' ;;
        windows) printf 'PANTALLA_EMISOR_WINDOWS_IP' ;;
    esac
}

resolver() {
    local nombre="$1" direccion
    if ! direccion="$(direccion_de "${nombre}")"; then
        echo "Emisor desconocido: '${nombre}'. Los válidos son 'fedora' y 'windows'." >&2
        return 1
    fi
    if [[ -z "${direccion}" ]]; then
        echo "El emisor '${nombre}' no tiene IP: fija $(variable_de "${nombre}") en servidor.env y ejecuta 18_pantalla.sh." >&2
        return 1
    fi
    printf '%s\n' "${direccion}"
}

if [[ "${1:-}" == --vincular ]]; then
    instancia="${2:-}"
    nombre="${instancia%-*}"
    pin="${instancia##*-}"
    if [[ "${instancia}" != *-* || ! "${pin}" =~ ^[0-9]{4}$ ]]; then
        echo "Vínculo mal formado: '${instancia}'. Se espera <emisor>-<PIN de 4 cifras>, por ejemplo windows-1234." >&2
        exit 1
    fi
    direccion="$(resolver "${nombre}")" || exit 1
    exec "${MOONLIGHT}" pair "${direccion}" --pin "${pin}"
fi

resolver "${1:-}"
