#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — validación automática de proyectos
#  Destino  : /usr/local/sbin/nomad-conserje.sh
#  Generado por scripts/17_auditoria.sh
#  Capítulo : docs/17_auditoria_del_servidor.md
#
#  Propósito : ejecutar revisar_proyecto.sh sobre cada proyecto cuyo fichero
#              compose cambie, y dejar el veredicto donde se pueda leer.
#
#  POR QUÉ EXISTE
#  --------------
#  revisar_proyecto.sh ya sabía decir si un proyecto cumple el anexo 96. Lo
#  que faltaba era que alguien se acordara de ejecutarlo. Un proyecto copiado
#  a la raíz de datos un martes por la noche no se auditaba hasta que alguien
#  lo recordaba, y para entonces ya estaba desplegado.
#
#  Este script NO decide nada: invoca revisar_proyecto.sh y transcribe su
#  salida y su código. El veredicto sigue siendo del mismo sitio de siempre.
#
#  No lo edites aquí: edita config/servidor.env y vuelve a ejecutar
#  scripts/17_auditoria.sh
# ===========================================================================
set -euo pipefail

datos_raiz="${DATOS_RAIZ}"
dir_informes="${DATOS_RAIZ}/auditoria/informes"
usuario="${AUDITORIA_USUARIO}"
repo="/home/${ADMIN_USUARIO}/nomad_server"
push_url="${AUDITORIA_PUSH_URL}"

# Ver el comentario de nomad-auditoria.sh: el grupo del administrador, para
# que el informe lo pueda leer quien lo va a leer.
grupo_admin="$(id -gn "${ADMIN_USUARIO}")"

revisor="${repo}/scripts/revisar_proyecto.sh"

if [[ ! -x "${revisor}" ]]; then
    echo "nomad-conserje: no se encuentra ${revisor}" >&2
    exit 1
fi

# Los proyectos que hay ahora mismo. Se recorren todos y no solo el que
# disparó la unidad: systemd.path avisa de que ALGO cambió en el directorio,
# no de qué cambió, y averiguarlo costaría más que revisarlos todos —son
# unos pocos y cada revisión tarda menos de un segundo.
hubo_fallo=0
revisados=0
vistos=""

# LA INFRAESTRUCTURA NO ES UN PROYECTO, Y NO SE MIDE CON EL ANEXO 96
#
# Estos directorios los montan los propios capítulos del repositorio, y
# incumplen el contrato A PROPÓSITO, porque el contrato está escrito para lo
# que va DETRÁS del proxy, no para el proxy:
#
#   traefik        publica el punto de entrada interno en el host (cap. 10),
#                  que es justo lo que la regla 1 prohíbe a un proyecto
#   observabilidad el intermediario del socket monta /var/run/docker.sock
#                  (cap. 13), que es justo lo que prohíbe la regla 2
#   cloudflared    el túnel monta sus credenciales del host (cap. 11)
#   auditoria      no es un proyecto, es este capítulo
#
# Medirlos con la vara equivocada produce tres fallos todos los días, y una
# alarma que suena siempre deja de ser una alarma.
infraestructura="traefik observabilidad cloudflared auditoria"

for compose in "${datos_raiz}"/*/docker-compose.yml; do
    [[ -f "${compose}" ]] || continue

    proyecto="$(basename "$(dirname "${compose}")")"

    # 'case' y no una tubería a 'grep -qx': con 'pipefail', grep -q cierra la
    # tubería en cuanto encuentra y el printf de arriba recibe SIGPIPE, así que
    # el estado de la tubería puede acabar siendo el del printf muerto y la
    # condición evaluarse al revés. Falla pocas veces, que es lo peor que puede
    # hacer. Es la misma razón por la que lib/common.sh tiene contiene().
    case " ${infraestructura} " in
        *" ${proyecto} "*)
            echo "nomad-conserje: ${proyecto} es infraestructura del servidor; no se mide con el anexo 96."
            continue
            ;;
    esac

    destino="${dir_informes}/${proyecto}.auditoria"
    tmp="$(mktemp)"

    codigo=0
    {
        printf 'AUDITORIA DE PROYECTO: %s\n' "${proyecto}"
        printf 'Ejecutada: %s\n' "$(date --iso-8601=seconds)"
        printf 'Comando: revisar_proyecto.sh %s\n\n' "${proyecto}"
    } > "${tmp}"

    # Se ejecuta como el usuario administrador y no como root: revisar_proyecto
    # necesita hablar con Docker, y el acceso a Docker lo tiene ese usuario por
    # pertenecer al grupo, no por ser root. Ejecutarlo como root funcionaría
    # también, pero dejaría ficheros de caché de compose con dueño root en el
    # directorio del proyecto.
    runuser -u "${ADMIN_USUARIO}" -- "${revisor}" "${proyecto}" >> "${tmp}" 2>&1 || codigo=$?

    printf '\n[codigo de salida: %s]\n' "${codigo}" >> "${tmp}"

    install -m 0640 -o "${usuario}" -g "${grupo_admin}" "${tmp}" "${destino}"
    rm -f "${tmp}"

    revisados=$(( revisados + 1 ))
    vistos="${vistos} ${proyecto}"
    if (( codigo != 0 )); then
        hubo_fallo=1
        echo "nomad-conserje: ${proyecto} NO cumple el contrato (codigo ${codigo})" >&2
    fi
done

# Informes huérfanos: de un proyecto que se borró, o de uno que ha pasado a
# considerarse infraestructura. Si no se retiran, siguen contando como
# incumplimiento para siempre y nadie entiende por qué.
for informe in "${dir_informes}"/*.auditoria; do
    [[ -f "${informe}" ]] || continue
    proyecto="$(basename "${informe}" .auditoria)"
    case " ${vistos} " in
        *" ${proyecto} "*) ;;
        *)  echo "nomad-conserje: retirando informe huérfano de '${proyecto}'."
            rm -f "${informe}"
            ;;
    esac
done

# El aviso solo se manda cuando algo incumple. Un conserje que avisa cada vez
# que tocas un compose se convierte en ruido, y el ruido se acaba silenciando.
if (( hubo_fallo == 1 )) && [[ -n "${push_url}" ]]; then
    curl -fsS -m 10 "${push_url}?status=down&msg=algun+proyecto+incumple+el+anexo+96" \
        >/dev/null 2>&1 || true
fi

echo "nomad-conserje: ${revisados} proyecto(s) revisado(s)."
exit 0
