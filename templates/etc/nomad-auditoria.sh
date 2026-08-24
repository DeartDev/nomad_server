#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — recolector de la auditoría diaria
#  Destino  : /usr/local/sbin/nomad-auditoria.sh
#  Generado por scripts/17_hermes.sh
#  Capítulo : docs/17_hermes_guardian.md
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
#  scripts/17_hermes.sh
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
