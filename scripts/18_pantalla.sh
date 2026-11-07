#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — pantalla extendida: el lado del HP
# ===========================================================================
#  Propósito : preparar el HP como cliente de pantalla extendida: un kiosco de
#              Moonlight bajo 'cage', con su usuario, su lanzador y sus unidades.
#  Uso       : sudo ./scripts/18_pantalla.sh --help
#  Capítulo  : docs/18_pantalla_extendida.md
#
#  Requiere root: instala paquetes, crea un usuario y escribe en /opt, /etc.
# ===========================================================================
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

mostrar_ayuda() {
    cat <<'AYUDA'
Uso: sudo ./scripts/18_pantalla.sh [opciones]

Prepara el HP como cliente de la pantalla extendida:

  1. Instala cage, Xwayland y los controladores de vídeo y audio
  2. Crea el usuario del sistema que ejecuta el cliente
  3. Descarga Moonlight, verifica su SHA-256 y lo extrae en /opt/nomad-pantalla
  4. Instala el lanzador, el traductor de emisores, las unidades, los límites
     del usuario y el permiso de sudo, y retira la unidad sin instancia de la
     versión anterior (nomad-pantalla.service)
  5. Comprueba que no hay gestor de pantalla en el equipo

Opciones:
  -n, --check    Muestra qué cambiaría, sin tocar el sistema.
  -y, --si       No pide confirmación.
  -h, --help     Muestra esta ayuda.

LO QUE ESTE SCRIPT NO HACE:
  - No habilita nada al arranque: la pantalla se arranca a demanda con
    'systemctl start nomad-pantalla@fedora.service' (o @windows), nunca
    con 'enable'.
  - No vincula Moonlight con el emisor. Es un paso aparte, con un PIN
    (nomad-pantalla-vincular@<emisor>-<PIN>.service, capítulo 18).
  - No exige PANTALLA_EMISOR_WINDOWS_IP: sin ella, solo funciona Fedora.
  - No retira libfuse2t64 si ya estaba instalado por una prueba anterior.
    Moonlight se extrae y no lo necesita; quítalo a mano con
    'sudo apt-get remove libfuse2t64'.
AYUDA
}

procesar_argumentos_comunes "$@"
(( ${#NOMAD_ARGS_RESTANTES[@]} == 0 )) \
    || die "Opción desconocida: ${NOMAD_ARGS_RESTANTES[*]} (usa --help)"

# --- Comprobaciones previas --------------------------------------------------
log_paso "Comprobaciones previas"
requerir_root
cargar_entorno

# El capítulo 18 es opcional y ningún otro depende de él. Va antes de exigir el
# resto de las variables: con 'no' no hacen falta, y un servidor.env anterior a
# este capítulo ni siquiera las tiene.
if [[ "${PANTALLA_HABILITADA:-no}" != "si" ]]; then
    log_sinca "PANTALLA_HABILITADA no es 'si'. No hay nada que instalar."
    log_info  "Para activarlo: ./scripts/variables.sh --fijar PANTALLA_HABILITADA=si"
    resumen_final "18_pantalla.sh"
    exit 0
fi

requerir_variables ADMIN_USUARIO PANTALLA_USUARIO PANTALLA_BITRATE \
                   MOONLIGHT_VERSION MOONLIGHT_SHA256

# Sin IP el lanzador quedaría con un argumento menos: 'stream Desktop ...' en
# lugar de 'stream <ip> Desktop ...', y Moonlight interpretaría 'Desktop' como
# el anfitrión. No da error claro, simplemente no conecta.
[[ -n "${PANTALLA_EMISOR_IP:-}" ]] \
    || die "PANTALLA_EMISOR_IP está vacía. Averigua la IP con 'tailscale ip -4' en el emisor y fíjala: ./scripts/variables.sh --fijar PANTALLA_EMISOR_IP=<ip>"

if [[ -z "${PANTALLA_EMISOR_WINDOWS_IP:-}" ]]; then
    log_info "PANTALLA_EMISOR_WINDOWS_IP está sin fijar: la sesión de Windows no arrancará. Fedora no se ve afectado."
fi

DIR_PANTALLA="/opt/nomad-pantalla"
DIR_MOONLIGHT="${DIR_PANTALLA}/moonlight"
# La unidad sin instancia de la versión anterior. Con las de ahora, seguiría
# arrancable a mano contra una IP fija y fuera de la regla de sudo.
UNIDAD_SIN_INSTANCIA=/etc/systemd/system/nomad-pantalla.service
URL_MOONLIGHT="https://github.com/moonlight-stream/moonlight-qt/releases/download/v${MOONLIGHT_VERSION}/Moonlight-${MOONLIGHT_VERSION}-x86_64.AppImage"

# --- Paso 1: paquetes --------------------------------------------------------
log_paso "Paquetes"
# libfuse2t64 NO está en la lista: el AppImage se extrae y se ejecuta con
# AppRun, sin FUSE.
instalar_paquetes "${PAQUETES_PANTALLA[@]}"

if dpkg-query -W -f='${Status}' libfuse2t64 2>/dev/null | contiene "ok installed"; then
    log_aviso "libfuse2t64 está instalado (de una prueba anterior). Nada lo necesita ya."
    log_aviso "Retíralo a mano si quieres: sudo apt-get remove libfuse2t64"
fi

# --- Paso 2: el usuario ------------------------------------------------------
log_paso "Usuario del sistema '${PANTALLA_USUARIO}'"

# Si ya existe NO se recrea: guarda el vínculo con el emisor en su directorio
# personal, y perderlo obliga a repetir el PIN. Solo se corrigen sus grupos.
# 'input' daría acceso a todos los teclados del equipo, no solo a los de 'cage'.
if id -u "${PANTALLA_USUARIO}" >/dev/null 2>&1; then
    log_sinca "Usuario ${PANTALLA_USUARIO} ya existe; no se recrea."
    for GRUPO in sudo docker adm input; do
        if id -nG "${PANTALLA_USUARIO}" 2>/dev/null | tr ' ' '\n' | contiene -x "${GRUPO}"; then
            die "El usuario '${PANTALLA_USUARIO}' pertenece al grupo '${GRUPO}'. Quítalo con: sudo gpasswd -d ${PANTALLA_USUARIO} ${GRUPO}"
        fi
    done
    log_ok "El usuario no pertenece a ningún grupo con privilegios."
    for GRUPO in video render audio; do
        if ! id -nG "${PANTALLA_USUARIO}" 2>/dev/null | tr ' ' '\n' | contiene -x "${GRUPO}"; then
            ejecutar usermod -aG "${GRUPO}" "${PANTALLA_USUARIO}"
        fi
    done
else
    ejecutar useradd --system --create-home --shell /usr/sbin/nologin \
                     --groups video,render,audio \
                     --comment "Cliente de pantalla extendida (capitulo 18)" \
                     "${PANTALLA_USUARIO}"
fi

# --- Paso 3: Moonlight -------------------------------------------------------
log_paso "Moonlight ${MOONLIGHT_VERSION}"

VERSION_INSTALADA="$(cat "${DIR_MOONLIGHT}/.version" 2>/dev/null || true)"
if [[ "${VERSION_INSTALADA}" == "${MOONLIGHT_VERSION}" ]]; then
    log_sinca "Moonlight ${MOONLIGHT_VERSION} ya está en ${DIR_MOONLIGHT}."
elif (( MODO_CHECK == 1 )); then
    log_check "descargaría ${URL_MOONLIGHT}"
    log_check "instalaría Moonlight ${MOONLIGHT_VERSION} en ${DIR_MOONLIGHT} (ahora: '${VERSION_INSTALADA:-sin versión}')"
    marcar_cambio
else
    command -v curl >/dev/null || die "Falta curl para descargar Moonlight."
    TMP_MOON="$(mktemp -d)"
    log_info "Descargando ${URL_MOONLIGHT}"
    curl -fsSL --retry 3 -o "${TMP_MOON}/moonlight.AppImage" "${URL_MOONLIGHT}" \
        || { rm -rf "${TMP_MOON}"; die "No se pudo descargar Moonlight desde ${URL_MOONLIGHT}"; }

    SUMA="$(sha256sum "${TMP_MOON}/moonlight.AppImage" | cut -d' ' -f1)"
    if [[ "${SUMA}" != "${MOONLIGHT_SHA256}" ]]; then
        rm -rf "${TMP_MOON}"
        die "El SHA-256 de Moonlight no coincide. Esperado ${MOONLIGHT_SHA256}, obtenido ${SUMA}. No se instala."
    fi
    log_ok "SHA-256 verificado."

    chmod +x "${TMP_MOON}/moonlight.AppImage"
    # Se extrae en un directorio propio y vacío; así nada depende de FUSE.
    ( cd "${TMP_MOON}" && ./moonlight.AppImage --appimage-extract >/dev/null ) \
        || { rm -rf "${TMP_MOON}"; die "Falló la extracción del AppImage."; }
    [[ -x "${TMP_MOON}/squashfs-root/AppRun" ]] \
        || { rm -rf "${TMP_MOON}"; die "El AppImage extraído no contiene AppRun."; }

    install -d -m 755 -o root -g root "${DIR_PANTALLA}"
    rm -rf "${DIR_MOONLIGHT}"
    mv "${TMP_MOON}/squashfs-root" "${DIR_MOONLIGHT}"
    rm -rf "${TMP_MOON}"
    # La extracción hereda modos restrictivos del squashfs: sin esto el
    # usuario de la pantalla no podría entrar en el árbol.
    chown -R root:root "${DIR_MOONLIGHT}"
    chmod -R u=rwX,go=rX "${DIR_MOONLIGHT}"
    printf '%s\n' "${MOONLIGHT_VERSION}" > "${DIR_MOONLIGHT}/.version"
    chmod 644 "${DIR_MOONLIGHT}/.version"
    log_ok "Moonlight ${MOONLIGHT_VERSION} instalado en ${DIR_MOONLIGHT}"
    marcar_cambio
fi

# --- Paso 4: lanzador, unidades y sudoers ------------------------------------
log_paso "Lanzador y unidades"

ANTES="$(cambios)"
instalar_plantilla etc/nomad-pantalla-lanzar.sh /opt/nomad-pantalla/lanzar.sh 755 root:root
instalar_plantilla etc/nomad-pantalla-emisor.sh /opt/nomad-pantalla/emisor.sh 755 root:root
instalar_plantilla systemd/nomad-pantalla@.service           /etc/systemd/system/nomad-pantalla@.service
instalar_plantilla systemd/nomad-pantalla-vincular@.service  /etc/systemd/system/nomad-pantalla-vincular@.service

# Se retira solo si está parada: con una sesión abierta, borrarla dejaría una
# unidad en marcha sin archivo. Se avisa y se sigue; la próxima ejecución la quita.
if [[ -e "${UNIDAD_SIN_INSTANCIA}" ]]; then
    if systemctl is-active --quiet nomad-pantalla.service; then
        log_aviso "nomad-pantalla.service está en marcha: no se retira. Párala (sudo systemctl stop nomad-pantalla.service) y ejecuta este script otra vez."
    else
        ejecutar rm -f "${UNIDAD_SIN_INSTANCIA}"
    fi
fi

# Los límites van en la porción del usuario, no en la unidad: PAMName mueve los
# procesos a session-N.scope, fuera de ella. El nombre lleva su uid, que no está
# en servidor.env: por eso la ruta se calcula aquí y no en la plantilla.
if UID_PANTALLA="$(id -u "${PANTALLA_USUARIO}" 2>/dev/null)"; then
    instalar_plantilla systemd/nomad-pantalla-usuario.conf \
        "/etc/systemd/system/user-${UID_PANTALLA}.slice.d/50-nomad-pantalla.conf"
else
    # Solo con --check: al aplicar, el paso 2 ya ha creado el usuario.
    log_check "escribiría /etc/systemd/system/user-<uid>.slice.d/50-nomad-pantalla.conf"
    marcar_cambio
fi
if hubo_cambios_desde "${ANTES}"; then
    ejecutar systemctl daemon-reload
fi

log_paso "Permiso de sudo"
# Un sudoers roto deja al administrador sin sudo. Se valida SIEMPRE una copia
# renderizada antes de instalar nada.
TMP_SUDOERS="$(mktemp)"
envsubst "$(formato_envsubst)" < "${NOMAD_TEMPLATES}/etc/sudoers-nomad-pantalla" > "${TMP_SUDOERS}"
if ! visudo -cf "${TMP_SUDOERS}" >/dev/null; then
    rm -f "${TMP_SUDOERS}"
    die "La plantilla sudoers-nomad-pantalla no pasa 'visudo -cf'. No se instala."
fi
rm -f "${TMP_SUDOERS}"
log_ok "sudoers validado con visudo."
instalar_plantilla etc/sudoers-nomad-pantalla /etc/sudoers.d/nomad-pantalla 440 root:root

# --- Paso 5: salvaguardas ----------------------------------------------------
log_paso "Salvaguardas"
if systemctl cat display-manager.service >/dev/null 2>&1; then
    die "Hay un gestor de pantalla (display-manager.service). Competiría con 'cage' por la GPU. Retíralo antes de seguir."
fi
log_ok "No hay gestor de pantalla."
log_info "La pantalla NO se habilita al arranque: se lanza a demanda."
log_info "Siguiente: vincular con el emisor (capítulo 18)."

resumen_final "18_pantalla.sh"
