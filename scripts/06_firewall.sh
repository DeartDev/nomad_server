#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — red estática y cortafuegos nftables
# ===========================================================================
#  Propósito : fijar la dirección IP del servidor y aplicar un cortafuegos con
#              política de denegación por omisión que no interfiera con las
#              reglas de Docker.
#  Uso       : sudo ./scripts/06_firewall.sh --help
#  Capítulo  : docs/06_red_y_firewall.md
#
#  SALVAGUARDA: antes de cargar el cortafuegos programa su retirada automática.
#  Si al terminar el script sigue habiendo sesión, la cancela; si te quedas sin
#  acceso, el cortafuegos se retira solo y recuperas la conexión.
# ===========================================================================
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

MARGEN=300
SIN_RED=0
SIN_FIREWALL=0

mostrar_ayuda() {
    cat <<'AYUDA'
Uso: sudo ./scripts/06_firewall.sh [opciones]

Configura la red y el cortafuegos del servidor:

  1. Instala nftables
  2. Escribe /etc/nftables.conf y valida su sintaxis
  3. Aplica el cortafuegos con una red de seguridad temporal
  4. Fija la IP estática en /etc/network/interfaces
  5. Escribe /etc/resolv.conf

Opciones:
  --margen <seg>   Segundos de la red de seguridad antes de retirar el
                   cortafuegos automáticamente (por omisión: 300).
                   Usa 0 para desactivarla (no recomendado en remoto).
  --sin-red        Solo cortafuegos: no toca la dirección IP ni el DNS.
                   Útil para hacerlo en dos tandas.
  --sin-firewall   Solo red: no toca el cortafuegos.
  -n, --check      Muestra qué cambiaría, sin modificar nada.
  -y, --si         No pide confirmación.
  -h, --help       Muestra esta ayuda.

ATENCIÓN: cambiar la IP corta la sesión SSH en curso. El script pide
confirmación explícita antes de hacerlo y explica cómo volver a conectarse.

Si te quedas sin acceso y la red de seguridad está activa, espera los segundos
de --margen: el cortafuegos se retirará solo.
AYUDA
}

# --- Argumentos --------------------------------------------------------------
ARGS=()
while (( $# > 0 )); do
    case "$1" in
        --margen)       MARGEN="${2:-300}"; shift ;;
        --sin-red)      SIN_RED=1 ;;
        --sin-firewall) SIN_FIREWALL=1 ;;
        *)              ARGS+=("$1") ;;
    esac
    shift
done
procesar_argumentos_comunes "${ARGS[@]+"${ARGS[@]}"}"
(( ${#NOMAD_ARGS_RESTANTES[@]} == 0 )) \
    || die "Opción desconocida: ${NOMAD_ARGS_RESTANTES[*]} (usa --help)"

[[ "${MARGEN}" =~ ^[0-9]+$ ]] || die "--margen debe ser un número de segundos."

# --- Comprobaciones previas --------------------------------------------------
log_paso "Comprobaciones previas"
requerir_root "$@"
requerir_debian "trixie"
cargar_entorno
requerir_variables LAN_IP LAN_PREFIJO LAN_GATEWAY LAN_DNS LAN_CIDR \
                   SSH_PUERTO TS_CIDR TS_INTERFAZ SERVIDOR_HOSTNAME

# La interfaz puede venir de la configuración o detectarse.
LAN_INTERFAZ="$(interfaz_lan)"
export LAN_INTERFAZ
log_ok "Interfaz de red: ${LAN_INTERFAZ}"

if [[ -z "${LAN_INTERFAZ:-}" ]]; then
    die "No se ha podido determinar la interfaz de red. Defínela en LAN_INTERFAZ."
fi

# Comprobación de coherencia: la IP debe pertenecer a la red declarada.
comprobar_ip_en_red() {
    local ip="$1" cidr="$2"
    local red="${cidr%/*}" bits="${cidr#*/}"
    local ip_num red_num mascara
    ip_a_numero() {
        local IFS=. a b c d
        read -r a b c d <<<"$1"
        echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
    }
    ip_num="$(ip_a_numero "${ip}")"
    red_num="$(ip_a_numero "${red}")"
    mascara=$(( 0xFFFFFFFF << (32 - bits) & 0xFFFFFFFF ))
    (( (ip_num & mascara) == (red_num & mascara) ))
}

if comprobar_ip_en_red "${LAN_IP}" "${LAN_CIDR}"; then
    log_ok "${LAN_IP} pertenece a ${LAN_CIDR}."
else
    log_error "${LAN_IP} NO pertenece a ${LAN_CIDR}."
    log_error "Con esa combinación el cortafuegos rechazaría tus propias conexiones."
    die "Corrige LAN_IP o LAN_CIDR en config/servidor.env."
fi

# ===========================================================================
#  1. CORTAFUEGOS
# ===========================================================================
if (( SIN_FIREWALL == 1 )); then
    log_paso "Cortafuegos omitido por --sin-firewall"
else
    log_paso "1/3 · Cortafuegos nftables"

    instalar_paquetes nftables
    instalar_plantilla etc/nftables.conf /etc/nftables.conf 644 root:root

    # Validar SIEMPRE antes de cargar, también en modo simulación.
    log_info "Validando la sintaxis de las reglas…"
    if nft -c -f /etc/nftables.conf; then
        log_ok "Las reglas son sintácticamente correctas."
    else
        die "Las reglas tienen errores. No se ha cargado nada."
    fi

    if (( MODO_CHECK == 1 )); then
        log_check "cargaría las reglas y habilitaría nftables.service"
    else
        # --- Red de seguridad ---------------------------------------------
        # Se cancela borrando un archivo centinela, no matando un PID.
        #
        # Guardar el PID de 'setsid' no sirve: no es el del proceso que duerme.
        # Y un 'pkill -f' sobre la línea de comando es frágil. Si la
        # cancelación falla, lo que queda no es un proceso inofensivo: es un
        # 'nft flush ruleset' armado que se dispara minutos después, cuando ya
        # nadie lo relaciona con este script, y que se lleva por delante también
        # las reglas de Docker.
        CENTINELA=""
        if (( MARGEN > 0 )); then
            CENTINELA="$(mktemp /run/nomad-red-seguridad.XXXXXX)"
            log_info "Red de seguridad: el cortafuegos se retirará en ${MARGEN}s si algo falla."
            log_info "  (para cancelarla a mano: sudo rm -f ${CENTINELA})"
            setsid bash -c "
                sleep ${MARGEN}
                [[ -e '${CENTINELA}' ]] || exit 0
                rm -f '${CENTINELA}'
                nft flush ruleset
                logger -t nomad_server 'red de seguridad: cortafuegos retirado tras ${MARGEN}s'
            " >/dev/null 2>&1 &
        else
            log_aviso "Red de seguridad desactivada (--margen 0)."
        fi

        systemctl enable --now nftables
        if systemctl reload nftables 2>/dev/null || systemctl restart nftables; then
            marcar_cambio
            log_ok "Cortafuegos cargado."
        else
            [[ -n "${CENTINELA}" ]] && rm -f "${CENTINELA}"
            die "No se ha podido cargar el cortafuegos. Revisa: systemctl status nftables"
        fi

        # Comprobar que la política es la esperada. Se reintenta: dar por bueno
        # un 'no' a la primera sería tan malo como dar por bueno un 'sí'.
        POLITICA_OK=0
        for _ in 1 2 3; do
            if nft list chain inet nomad_filter entrada 2>/dev/null | grep -q 'policy drop'; then
                POLITICA_OK=1
                break
            fi
            sleep 1
        done

        if (( POLITICA_OK == 1 )); then
            log_ok "Cadena de entrada con política 'drop'."
        else
            # Sin política 'drop' no hay nada bloqueando, así que no puedes
            # quedarte fuera: la red de seguridad ya no protege de nada y
            # dejarla armada solo serviría para borrarle las reglas a Docker.
            [[ -n "${CENTINELA}" ]] && rm -f "${CENTINELA}"
            log_error "La cadena de entrada NO tiene política 'drop'."
            log_error "El cortafuegos no está protegiendo el servidor."
            log_error "Diagnostica con:"
            log_error "    sudo nft list ruleset | head -30"
            log_error "    systemctl status nftables"
            die "Se detiene antes de tocar la red."
        fi

        # Si seguimos aquí y hay sesión SSH, la conexión ha sobrevivido.
        if [[ -n "${CENTINELA}" ]]; then
            echo
            log_aviso "COMPRUEBA AHORA, desde OTRA terminal, que puedes entrar:"
            log_aviso "    ssh ${ADMIN_USUARIO:-usuario}@${LAN_IP}"
            log_aviso ""
            log_aviso "Si NO puedes, no hagas nada: en ${MARGEN}s el cortafuegos se retira solo."
            echo
            if confirmar "¿Has comprobado que sigues teniendo acceso?"; then
                rm -f "${CENTINELA}"
                log_ok "Red de seguridad cancelada."
            else
                log_aviso "Red de seguridad ACTIVA: el cortafuegos se retirará en breve."
                log_aviso "Corrige la configuración y vuelve a ejecutar el script."
                exit 1
            fi
        fi
    fi
fi

# ===========================================================================
#  2. DNS
# ===========================================================================
if (( SIN_RED == 1 )); then
    log_paso "Configuración de red omitida por --sin-red"
    resumen_final "06_firewall"
    exit 0
fi

log_paso "2/3 · Resolución de nombres"

# 'dns-nameservers' en /etc/network/interfaces NO tiene efecto sin el paquete
# resolvconf, que una instalación mínima no lleva (capítulo 06 § 3.3).
#
# Pero resolvconf no es el único que reclama /etc/resolv.conf. Si algo lo está
# generando, escribirlo a mano da una falsa sensación de control: el archivo
# vuelve a su sitio en la siguiente renovación del arrendamiento DHCP o al
# reiniciar, y el síntoma —«el DNS se me cambia solo»— cuesta de atribuir.
for GESTOR in resolvconf openresolv systemd-resolved; do
    if dpkg-query -W -f='${Status}' "${GESTOR}" 2>/dev/null | grep -q "ok installed"; then
        log_aviso "El paquete '${GESTOR}' está instalado: gestionará /etc/resolv.conf por su cuenta."
        log_aviso "Lo que escriba este script podría perderse. Considera desinstalarlo."
    fi
done

# El caso más frecuente y el que no delata ningún paquete sospechoso: la
# interfaz sigue en DHCP y es el cliente quien reescribe resolv.conf.
if head -3 /etc/resolv.conf 2>/dev/null | grep -qiE '^#.*(generated|dhcpcd|dhclient|NetworkManager)'; then
    log_aviso "/etc/resolv.conf lo genera un cliente DHCP:"
    head -1 /etc/resolv.conf | sed 's/^/          /'
    log_aviso "Mientras ${LAN_INTERFAZ} siga en DHCP, lo que se escriba aquí"
    log_aviso "se perderá en la siguiente renovación. Fijar la IP estática (paso 3/3) es lo"
    log_aviso "que hace que este archivo pase a estar bajo tu control."
fi

# dhcpcd viene de serie en Debian y gestiona /etc/resolv.conf por omisión. Con
# la interfaz en estático deja de hacerlo, pero al soltar el arrendamiento
# RETIRA las entradas que había puesto y deja el archivo sin ningún
# 'nameserver'. El servidor se queda sin resolución de nombres, y el síntoma no
# aparece al hacer el cambio: aparece en el siguiente reinicio, cuando ya nadie
# lo relaciona con esto. Desactivarle el hook lo cierra de raíz.
if [[ -f /etc/dhcpcd.conf ]]; then
    if grep -qE '^[[:space:]]*nohook[[:space:]]+resolv\.conf' /etc/dhcpcd.conf; then
        log_sinca "dhcpcd ya tiene desactivado el hook de resolv.conf."
    else
        log_aviso "dhcpcd puede reescribir /etc/resolv.conf: se le desactiva ese hook."
        respaldar_archivo /etc/dhcpcd.conf
        if (( MODO_CHECK == 1 )); then
            log_check "añadiría 'nohook resolv.conf' a /etc/dhcpcd.conf"
            marcar_cambio
        else
            {
                echo
                echo "# Añadido por scripts/06_firewall.sh — docs/06_red_y_firewall.md § 3.3"
                echo "# Este servidor gestiona /etc/resolv.conf a mano."
                echo "nohook resolv.conf"
            } >> /etc/dhcpcd.conf
            marcar_cambio
            log_ok "'nohook resolv.conf' añadido a /etc/dhcpcd.conf"
        fi
    fi
fi

DOMINIO_BUSQUEDA="${SERVIDOR_DOMINIO_LOCAL:-}"
{
    echo "# Generado por scripts/06_firewall.sh — docs/06_red_y_firewall.md"
    echo "# No lo edites a mano: edita config/servidor.env y vuelve a ejecutar el script."
    for servidor in ${LAN_DNS}; do
        echo "nameserver ${servidor}"
    done
    [[ -n "${DOMINIO_BUSQUEDA}" ]] && echo "search ${DOMINIO_BUSQUEDA}"
    echo "options timeout:2 attempts:2"
} | instalar_archivo /etc/resolv.conf 644 root:root

# ===========================================================================
#  3. DIRECCIÓN ESTÁTICA
# ===========================================================================
log_paso "3/3 · Dirección IP estática"

IP_ACTUAL="$(ip -o -4 addr show "${LAN_INTERFAZ}" | awk '{print $4}' | cut -d/ -f1 | head -1)"
log_info "Dirección actual: ${IP_ACTUAL:-ninguna}"
log_info "Dirección objetivo: ${LAN_IP}"

instalar_plantilla etc/interfaces /etc/network/interfaces 644 root:root

if (( MODO_CHECK == 1 )); then
    log_check "reiniciaría la red para aplicar la nueva dirección"
    resumen_final "06_firewall"
    exit 0
fi

if [[ "${IP_ACTUAL}" == "${LAN_IP}" ]]; then
    log_sinca "La dirección ya es la correcta: no hace falta reiniciar la red."
else
    echo
    log_aviso "Aplicar la nueva dirección CORTARÁ esta sesión SSH."
    log_aviso "Después tendrás que reconectar a: ${LAN_IP}"
    log_aviso ""
    log_aviso "La forma más limpia es reiniciar el servidor:  sudo reboot"
    echo
    if confirmar "¿Reiniciar la red AHORA y perder esta sesión?"; then
        log_info "Reiniciando la red en 2 segundos…"
        setsid bash -c 'sleep 2; systemctl restart networking' >/dev/null 2>&1 &
        marcar_cambio
        log_ok "Reconéctate con:  ssh ${ADMIN_USUARIO:-usuario}@${LAN_IP}"
        log_ok "Actualiza también HostName en tu ~/.ssh/config."
        exit 0
    else
        log_info "La configuración está escrita pero no aplicada."
        log_info "Se aplicará en el próximo reinicio, o con:"
        log_info "    sudo systemctl restart networking"
    fi
fi

resumen_final "06_firewall"
log_info "Valida el capítulo con la sección 7 de docs/06_red_y_firewall.md"
log_info "Siguiente paso: docs/07_endurecimiento_del_sistema.md"
