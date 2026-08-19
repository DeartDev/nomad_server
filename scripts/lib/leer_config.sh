#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — lectura de config/servidor.env aislada del entorno
# ===========================================================================
#  Propósito : responder a «¿qué dice el ARCHIVO?», que no es lo mismo que
#              «¿qué hay en mi shell?». Es la distinción que evita el
#              espejismo más difícil de detectar de todo el montaje.
#
#  Uso       : source scripts/lib/leer_config.sh
#              nomad_leer_config <archivo> NOMBRE [NOMBRE...]
#
#  Capítulo  : docs/98_variables_y_entorno.md § 3.6
#
#  POR QUÉ EXISTE
#  --------------
#  Durante un montaje manual es natural exportar variables a mano para que los
#  comandos de la documentación funcionen:
#
#      export ADMIN_USUARIO=compass
#
#  Si esa variable NO está en config/servidor.env, cualquier comprobación que
#  lea el archivo «encima» del entorno actual la verá igualmente y la dará por
#  buena. El archivo parece completo y no lo está.
#
#  El engaño se rompe en cuanto interviene sudo, que limpia el entorno
#  (env_reset) y deja al script viendo el archivo desnudo. El resultado es que
#  'source scripts/lib/entorno.sh' dice que todo está bien y
#  'sudo ./scripts/04_base.sh' dice que faltan variables. Tiene razón el
#  segundo.
#
#  Esta función lee el archivo en un entorno vacío, de modo que lo que informa
#  es exactamente lo que verá un script ejecutado con sudo.
#
#  Se conserva HOME a propósito: la plantilla lo usa de forma legítima en
#  ADMIN_SSH_CLAVE_PUBLICA="$HOME/.ssh/…". Y se conserva PATH por si alguna
#  línea del archivo invocara un comando externo.
#
#  Este archivo NO se ejecuta directamente: solo se importa con 'source'.
# ===========================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: leer_config.sh es una biblioteca. Impórtala con 'source'." >&2
    exit 1
fi

# Imprime una línea 'NOMBRE=valor' por cada nombre solicitado, con el valor que
# tiene en el archivo y solo en el archivo.
#
#   nomad_leer_config config/servidor.env ADMIN_USUARIO LAN_CIDR
#       ADMIN_USUARIO=compass
#       LAN_CIDR=192.168.1.0/24
#
# Una variable ausente del archivo, o presente pero vacía, produce una línea
# con el valor vacío. Las dos situaciones son equivalentes para un script: en
# ambos casos 'requerir_variables' abortará.
nomad_leer_config() {
    local archivo="${1:-}"
    shift || true
    [[ -r "${archivo}" ]] || return 1
    (( $# > 0 )) || return 0

    env -i HOME="${HOME:-/root}" PATH="${PATH:-/usr/bin:/bin}" \
        bash --noprofile --norc -c '
            archivo="$1"; shift
            set -a
            . "${archivo}" 2>/dev/null || true
            set +a
            for nombre in "$@"; do
                printf "%s=%s\n" "${nombre}" "${!nombre-}"
            done
        ' _ "${archivo}" "$@"
}

# Devuelve 0 si el nombre indicado tiene valor en el archivo.
#   nomad_config_tiene_valor config/servidor.env ADMIN_USUARIO && …
nomad_config_tiene_valor() {
    local archivo="${1:-}" nombre="${2:-}" linea
    linea="$(nomad_leer_config "${archivo}" "${nombre}")" || return 1
    [[ -n "${linea#*=}" ]]
}
