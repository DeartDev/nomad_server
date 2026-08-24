#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — recolector de la auditoría diaria
#  Destino  : /usr/local/sbin/nomad-auditoria.sh
#  Generado por scripts/17_auditoria.sh
#  Capítulo : docs/17_auditoria_del_servidor.md
#
#  Propósito : ejecutar como root lo que el agente NO puede ejecutar, redactar
#              su salida y dejarla en el directorio de informes.
#
#  Se instala FUERA del repositorio, como nomad-respaldo.sh, para que el
#  temporizador no dependa de que el repositorio esté clonado y al día.
#  A diferencia de aquel, este SÍ invoca los scripts del repositorio: si no
#  los encuentra, lo anota en el informe y sigue con lo que sí puede recoger.
#
#  No lo edites aquí: edita config/servidor.env y vuelve a ejecutar
#  scripts/17_auditoria.sh
#
#  NOTA PARA QUIEN EDITE LA PLANTILLA: las variables en mayúscula y entre
#  llaves se sustituyen al generar el archivo. Las variables propias del
#  script van en minúscula para que la sustitución no las toque.
#
#  Escrito así, y no con un ejemplo entre llaves, a propósito: el ejemplo
#  parecería una variable de verdad y verificar_repositorio.sh lo exigiría en
#  config/servidor.env.example.
# ===========================================================================
set -euo pipefail

# ===========================================================================
#  REDACCIÓN
# ===========================================================================
#  Dos arrays en paralelo y no un array de pares: los patrones contienen '|'
#  para las alternativas, así que cualquier separador dentro de una cadena
#  acabaría partiendo el patrón por el sitio equivocado.
#
#  El separador de 's' es '#' y no '/' porque los patrones sí llevan barras
#  (el alfabeto base64 de las llaves SSH).
#
#  PRINCIPIO: sobre-redactar es aceptable, sub-redactar no. Si un patrón se
#  come de más, el informe pierde detalle. Si se queda corto, un secreto sale
#  del servidor hacia la API de un tercero, y de ahí no se vuelve. Ante la
#  duda, se amplía.
#  EL ORDEN IMPORTA. sed aplica las expresiones en secuencia sobre cada
#  línea, así que las que se comen el resto de la línea —las cabeceras— van
#  antes que las que buscan un token suelto.
patrones_fuga=(
    '([Aa]uthorization|[Xx]-[Aa]pi-[Kk]ey|[Pp]roxy-[Aa]uthorization):[[:space:]]*.*$'
    '[Bb]earer[[:space:]]+[A-Za-z0-9._~+/=-]{16,}'
    'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(\.[A-Za-z0-9_-]+)?'
    '(sk|xoxb|ghp|gho|glpat)-[A-Za-z0-9_-]{12,}'
    '100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}'
    '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    '(b2|s3|sftp|rest|swift|azure|gs):[^[:space:]]+'
    '(ssh-(rsa|dss|ed25519)|ecdsa-sha2-[a-z0-9-]+)[[:space:]]+[A-Za-z0-9+/=]{20,}'
    '([A-Za-z0-9_]*(PASSWORD|PASSWD|SECRET|TOKEN|APIKEY|KEY)[A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*[^[:space:]]+'
    '(AKIA|ASIA)[A-Z0-9]{16}'
)
#  Las que llevan '\1' conservan la parte que SÍ informa —el nombre de la
#  cabecera, el nombre de la variable— y tiran solo el valor. Un informe que
#  dice 'DEEPSEEK_API_KEY=[REDACTADO]' te cuenta algo; uno que dice
#  '[REDACTADO]' a secas, nada.
etiquetas_fuga=(
    '\1: [REDACTADO:cabecera]'
    '[REDACTADO:bearer]'
    '[REDACTADO:jwt]'
    '[REDACTADO:clave]'
    '[REDACTADO:ip-tailnet]'
    '[REDACTADO:uuid]'
    '[REDACTADO:repositorio]'
    '[REDACTADO:llave-ssh]'
    '\1=[REDACTADO:variable-secreta]'
    '[REDACTADO:clave-nube]'
)

# Filtro: entrada estándar redactada a salida estándar.
redactar() {
    local i args=()
    for i in "${!patrones_fuga[@]}"; do
        args+=(-e "s#${patrones_fuga[i]}#${etiquetas_fuga[i]}#g")
    done
    sed -E "${args[@]}"
}

# Detector: devuelve 0 SI ENCUENTRA algo que debería estar redactado, igual
# que grep. Se ejecuta DESPUÉS de redactar, sobre el resultado: es la red que
# convierte un fallo de la redacción en un informe que no se publica, en vez
# de en un secreto que sale del servidor.
#
# Se descartan las coincidencias que YA son una marca de redacción. Sin ese
# filtro el detector se dispararía siempre: el patrón de una cabecera sigue
# casando con 'Authorization: [REDACTADO:cabecera]', que es justo el resultado
# correcto.
#
# LO QUE ESTE DETECTOR NO PUEDE HACER: cazar lo que ningún patrón sabe
# nombrar. Es una red contra el fallo de la redacción, no contra el hueco en
# la lista de patrones. Ese hueco solo lo encuentra un humano leyendo el
# informe entero, y por eso el capítulo 17 § 5 lo exige la primera vez y el
# capítulo 15 lo repite cada trimestre.
fugas() {
    local i args=()
    for i in "${!patrones_fuga[@]}"; do
        args+=(-e "${patrones_fuga[i]}")
    done
    grep -oE "${args[@]}" | grep -v 'REDACTADO'
}

# ===========================================================================
#  LO VOLÁTIL
# ===========================================================================
#  Líneas que cambian en cada ejecución sin que haya cambiado nada del
#  servidor. Se quitan ANTES de comparar, no del informe: en el informe la
#  marca de tiempo del verificador es información legítima; en el diff es
#  ruido que aparecería todos los días.
#
#  Esto no es cosmética. En la fase 3 el agente lee este diff a diario, así
#  que cada línea de ruido se paga en tokens todas las mañanas y, peor, tapa
#  lo que sí cambió.
sin_volatil() {
    sed -E \
        -e '/^==> Verificación de .* — [0-9]{4}-[0-9]{2}-[0-9]{2}/d' \
        -e 's/Up [0-9]+ (second|minute|hour|day|week|month)s?/Up …/g' \
        -e 's/\(healthy\)/(sano)/g'
}

# ===========================================================================
#  VALORES SUSTITUIDOS AL INSTALAR
# ===========================================================================
dir_informes="${DATOS_RAIZ}/auditoria/informes"
usuario="${AUDITORIA_USUARIO}"
repo="/home/${ADMIN_USUARIO}/nomad_server"
push_url="${AUDITORIA_PUSH_URL}"

estado="${dir_informes}/estado.txt"
anterior="${dir_informes}/estado.anterior.txt"
sello="${dir_informes}/sello.txt"
cambios="${dir_informes}/cambios.txt"

# Donde se deja el informe SIN publicar cuando la redacción no lo deja limpio.
# En /root y con permisos 600: fuera del directorio de informes, así que el
# agente no puede leerlo ni siquiera en la fase 2.
fuga="/root/nomad-auditoria-fuga.txt"

# ===========================================================================
#  AVISO
# ===========================================================================
#  Se reutiliza el monitor Push de Uptime Kuma del capítulo 14: ya tiene
#  configurado y probado el canal de avisos, así que no hace falta ningún bot
#  nuevo ni ninguna credencial nueva.
#
#  TRES SEÑALES CON UNA SOLA URL:
#    up    — la auditoría corrió y el verificador no encontró fallos
#    down  — la auditoría corrió y SÍ encontró fallos; Kuma te avisa con el
#            recuento, que es el "dime qué pasa" sin que nadie lo interprete
#    nada  — la auditoría no llegó a ejecutarse, y el monitor salta solo por
#            ausencia de aviso, igual que hace el del respaldo (capítulo 14
#            § 3.6). Es la única señal que sobrevive a un servidor apagado.
#
#  El mensaje va con '+' en vez de espacios porque viaja en una cadena de
#  consulta, sin escapar nada más: se construye aquí, no viene de fuera.
avisar() {
    local estado_aviso="$1" mensaje="$2"
    [[ -n "${push_url}" ]] || return 0
    curl -fsS -m 10 "${push_url}?status=${estado_aviso}&msg=${mensaje}" >/dev/null 2>&1 \
        || echo "nomad-auditoria: no se ha podido avisar al monitor" >&2
}

inicio="$(date +%s)"
crudo="$(mktemp)"
limpio="$(mktemp)"
trap 'rm -f "${crudo}" "${limpio}"' EXIT

# ===========================================================================
#  RECOLECCIÓN
# ===========================================================================
#  Cada bloque termina en '|| true'. Un recolector que aborta al primer
#  comando que falla produce justo el informe que no sirve: el del día en que
#  algo iba mal. Los fallos se anotan y se sigue.
titulo() { printf '\n===== %s =====\n' "$1"; }

codigo_verificador=""

{
    printf 'INFORME DE ESTADO — %s\n' "$(hostname)"
    printf 'Generado: %s\n' "$(date --iso-8601=seconds)"
    printf 'En marcha desde: %s\n' "$(uptime -p 2>/dev/null || echo desconocido)"

    titulo "VERIFICACIÓN DEL SISTEMA"
    # El verificador del repositorio es la fuente de verdad de este informe.
    # Aquí no se reinterpreta su salida: se pega entera, con su código.
    if [[ -x "${repo}/scripts/verificar_sistema.sh" ]]; then
        codigo_verificador=0
        "${repo}/scripts/verificar_sistema.sh" 2>&1 || codigo_verificador=$?
        printf '\n[codigo de salida del verificador: %s]\n' "${codigo_verificador}"
    else
        codigo_verificador=127
        printf 'NO DISPONIBLE: no se encuentra %s/scripts/verificar_sistema.sh\n' "${repo}"
        printf 'El resto del informe sigue siendo válido, pero le falta lo principal.\n'
    fi

    titulo "SERVICIOS FALLIDOS"
    systemctl --failed --no-legend --no-pager 2>&1 || true

    titulo "ESPACIO EN DISCO"
    df -h / /var /srv 2>&1 || true

    titulo "SALUD DE LOS DISCOS"
    # No se lanza ningún autotest: solo se lee lo que el disco ya sabe de sí
    # mismo. Un test largo cada mañana desgasta más de lo que informa.
    #
    # Si smartctl no está, se dice. Una sección vacía se lee como 'todo bien'
    # y en realidad significa 'no se ha medido nada', que es lo contrario.
    if ! command -v smartctl >/dev/null 2>&1; then
        printf 'NO MEDIDO: smartctl no está instalado (paquete smartmontools).\n'
    else
        for disco in /dev/nvme?n? /dev/sd?; do
            [[ -b "${disco}" ]] || continue
            printf -- '--- %s\n' "${disco}"
            salida_smart="$(smartctl -H "${disco}" 2>&1 | grep -iE 'result|health' || true)"
            if [[ -n "${salida_smart}" ]]; then
                printf '%s\n' "${salida_smart}"
            else
                printf 'NO MEDIDO: smartctl no devolvió veredicto para este disco.\n'
            fi
        done
    fi

    titulo "ÍNDICE DE ENDURECIMIENTO"
    # Se LEE el último informe de lynis; no se ejecuta lynis. Ejecutarlo tarda
    # minutos y necesita escribir en /var/log, que esta unidad no permite. Que
    # el informe esté viejo también es información: quien lo renueva es la
    # rutina trimestral del capítulo 15.
    if [[ -r /var/log/lynis-report.dat ]]; then
        grep -E '^hardening_index=' /var/log/lynis-report.dat || true
        printf 'medido el: %s\n' "$(date -r /var/log/lynis-report.dat --iso-8601=seconds)"
    else
        printf 'Sin informe de lynis. Lo genera la rutina trimestral (capítulo 15 § 5.3).\n'
    fi

    titulo "CONTENEDORES"
    docker ps --format 'table {{.Names}}\t{{.State}}\t{{.Status}}' 2>&1 || true

    titulo "REINICIO PENDIENTE"
    if [[ -f /var/run/reboot-required ]]; then
        printf 'SI — pendiente desde %s\n' \
               "$(date -r /var/run/reboot-required --iso-8601=seconds)"
    else
        printf 'No.\n'
    fi
} > "${crudo}" 2>&1 || true

# ===========================================================================
#  REDACCIÓN Y PUBLICACIÓN
# ===========================================================================
redactar < "${crudo}" > "${limpio}"

escribir_para_el_agente() {
    install -m 0640 -o "${usuario}" -g "${usuario}" "$1" "$2"
}

# FALLA CERRADA. Si algo sobrevivió a la redacción, no se publica el informe:
# se publica el aviso. Un informe con un secreto dentro acabaría en la API de
# un tercero, y de ahí no se vuelve.
if fugas < "${limpio}" >/dev/null 2>&1; then
    n_fugas="$(fugas < "${limpio}" 2>/dev/null | wc -l || true)"

    # EL ORDEN IMPORTA. Primero la alarma, después la ayuda de depuración.
    #
    # Al revés —guardar el crudo y luego avisar— un fallo al guardarlo mata el
    # script con 'set -e' y deja en su sitio el informe de AYER, con su sello
    # diciendo 'publicado'. Es el peor resultado posible: parece que todo va
    # bien y nadie se entera de nada. Ocurrió al probar esta rama.
    {
        printf 'INFORME NO PUBLICADO — %s\n\n' "$(date --iso-8601=seconds)"
        printf 'La redacción no ha dejado limpio el informe: han sobrevivido %s\n' "${n_fugas}"
        printf 'coincidencias con patrones de secreto. No se publica nada.\n\n'
        printf 'El informe sin publicar se guarda en %s con permisos 600 y\n' "${fuga}"
        printf 'dueño root: fuera de este directorio a propósito, para que no lo\n'
        printf 'lea nadie más. Revísalo como root:\n\n'
        printf '    sudo less %s\n\n' "${fuga}"
        printf 'Cuando sepas qué patrón falta, añádelo a patrones_fuga en\n'
        printf 'templates/etc/nomad-auditoria.sh y vuelve a ejecutar\n'
        printf 'scripts/17_auditoria.sh. Capítulo 17 § 9.\n'
    } > "${crudo}"
    escribir_para_el_agente "${crudo}" "${estado}"

    printf 'fecha=%s\nresultado=fuga-detectada\ncoincidencias=%s\n' \
           "$(date --iso-8601=seconds)" "${n_fugas}" > "${crudo}"
    escribir_para_el_agente "${crudo}" "${sello}"

    # Ahora sí, la copia para depurar. Si falla, se anota y se sigue: la
    # alarma ya está dada, que es lo que no podía perderse.
    if ! install -m 0600 -o root -g root "${limpio}" "${fuga}" 2>/dev/null; then
        echo "nomad-auditoria: no se pudo guardar ${fuga}" >&2
    fi

    avisar down "auditoria+SIN+publicar:+${n_fugas}+fugas+tras+redactar"
    echo "nomad-auditoria: ${n_fugas} fugas tras redactar; informe no publicado" >&2
    exit 1
fi

# Una fuga anterior ya resuelta no debe dejar el fichero crudo ahí para
# siempre: en cuanto se publica un informe limpio, se retira.
if [[ -f "${fuga}" ]]; then
    rm -f "${fuga}"
fi

# El informe de ayer se conserva para poder comparar. Solo uno: el histórico
# lo guarda restic, que para eso respalda /srv entero.
#
# 'if' y no '[[ ... ]] && cp': bajo 'set -e' una lista '&&' cuya condición es
# falsa devuelve 1 y mata el script. Aquí eso significaría que la PRIMERA
# ejecución —cuando aún no hay informe anterior— aborta siempre.
if [[ -f "${estado}" ]]; then
    cp -a "${estado}" "${anterior}"
fi

escribir_para_el_agente "${limpio}" "${estado}"

# ===========================================================================
#  QUÉ CAMBIÓ DESDE AYER
# ===========================================================================
#  Esto es control de coste, no comodidad: en la fase 3 el agente lee este
#  fichero y no el informe entero.
#
#  El '|| true' del diff no es decorativo: diff devuelve 1 cuando encuentra
#  diferencias, que es el caso normal, y con 'set -e' eso mataría el script
#  justo cuando hay algo que contar.
{
    if [[ -f "${anterior}" ]]; then
        printf 'CAMBIOS DESDE EL INFORME ANTERIOR\n'
        printf 'Anterior: %s\n\n' "$(date -r "${anterior}" --iso-8601=seconds)"
        # Se descartan las tres primeras líneas de cada informe (nombre, fecha
        # y tiempo en marcha) y después lo volátil. Sin esto, dos ejecuciones
        # seguidas sin ningún cambio real producen igualmente un diff.
        diff -u <(tail -n +4 "${anterior}" | sin_volatil) \
                <(tail -n +4 "${estado}"   | sin_volatil) \
            | tail -n +3 || true
    else
        printf 'Primera ejecución: no hay informe anterior con el que comparar.\n'
    fi
} > "${crudo}"
escribir_para_el_agente "${crudo}" "${cambios}"

lineas_cambiadas="$(grep -c '^[+-]' "${cambios}" 2>/dev/null || true)"

# El sello permite detectar desde fuera que el recolector dejó de correr, que
# es un fallo silencioso: sin él, un informe de hace tres semanas se lee igual
# de convincente que el de esta mañana.
{
    printf 'fecha=%s\n'              "$(date --iso-8601=seconds)"
    printf 'resultado=publicado\n'
    printf 'codigo_verificador=%s\n' "${codigo_verificador:-desconocido}"
    printf 'duracion_segundos=%s\n'  "$(( $(date +%s) - inicio ))"
    # 'grep -c' ya imprime el número, incluso cuando es cero, y ADEMÁS
    # devuelve 1 en ese caso. Un '|| echo 0' añadiría un segundo cero en una
    # línea suelta y rompería el formato clave=valor del sello.
    printf 'lineas_cambiadas=%s\n'   "${lineas_cambiadas:-0}"
} > "${crudo}"
escribir_para_el_agente "${crudo}" "${sello}"

# ===========================================================================
#  Y AVISAR
# ===========================================================================
#  El recuento sale del propio verificador, no de una interpretación de su
#  salida: es la misma línea que ves al ejecutarlo a mano.
fallidas="$(sed -n 's/.*Comprobaciones fallidas: \([0-9]*\).*/\1/p' "${estado}" | tail -1)"
fallidas="${fallidas:-0}"

if (( codigo_verificador == 0 )); then
    avisar up "sin+fallos+·+${lineas_cambiadas:-0}+lineas+cambiadas"
else
    avisar down "${fallidas}+comprobaciones+fallidas+·+${lineas_cambiadas:-0}+lineas+cambiadas"
fi

exit 0
