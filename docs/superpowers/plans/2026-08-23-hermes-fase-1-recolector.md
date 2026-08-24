# Hermes fase 1 — el recolector · plan de implementación

> **Para quien ejecute este plan:** usa `superpowers:subagent-driven-development` o
> `superpowers:executing-plans`. Los pasos llevan casilla (`- [ ]`) para poder seguirlos.

**Objetivo.** Que el servidor produzca cada día, solo, un informe de estado redactado y legible,
más un resumen de lo que cambió desde ayer.

**Arquitectura.** Un script de bash que corre como root bajo un temporizador systemd, invoca los
verificadores que ya existen en el repositorio, redacta los secretos de su salida y escribe tres
ficheros en `${DATOS_RAIZ}/hermes/informes/`. No reimplementa ninguna comprobación: las llama.

**Pila.** Bash 5, systemd, las convenciones de `scripts/lib/common.sh`.

**Especificación:** `docs/superpowers/specs/2026-08-23-hermes-guardian-design.md`

**Esta fase no instala Hermes.** Al terminar no hay contenedor, ni API, ni Telegram. Hay informes
diarios. Si la integración se abandonase aquí, lo construido sigue mereciendo la pena — ese es el
criterio con el que se ordenaron las fases.

## Restricciones globales

Copiadas de la especificación. Se aplican a todas las tareas:

- **Ningún veredicto lo emite el modelo.** El recolector **invoca** `verificar_sistema.sh`; no
  reimplementa ni reinterpreta sus comprobaciones.
- **Anillo 0 intacto.** Nada de lo que se construya aquí concede a nadie un privilegio nuevo. El
  usuario `hermes` se crea con `nologin`, sin sudo, sin grupo `docker` y sin grupo `adm`.
- **Redacción que falla cerrada.** Si el detector de fugas encuentra algo después de redactar, **no
  se publica informe**. Un informe con un secreto dentro es peor que no tener informe.
- **Sobre-redactar es aceptable; sub-redactar no.** Ante la duda, el patrón se amplía.
- **Idempotencia.** `scripts/17_hermes.sh` admite `--check` y `--help`, no sobrescribe nada sin
  copia previa, y ejecutado dos veces informa de `Cambios que se aplicarían: 0`.
- **Todo valor sale de `config/servidor.env`.** Cero valores fijos en plantillas o scripts.
- **`make check` verde en cada commit.** Es el listón del repositorio, no una aspiración.
- **Los comentarios explican el porqué, no el qué.** Es la voz del repositorio: mira
  `templates/systemd/nomad-respaldo.service` para calibrar.

## Estructura de ficheros

| Fichero | Responsabilidad |
|---|---|
| `config/servidor.env.example` | Declara las cuatro variables de esta fase, etiquetadas `[CAPITULO: 17]` |
| `scripts/17_hermes.sh` | Instalador del capítulo 17. En esta fase: usuario, directorios, plantilla del recolector y unidades systemd |
| `templates/etc/nomad-auditoria.sh` | El recolector. Se instala en `/usr/local/sbin/`, fuera del repositorio |
| `templates/systemd/nomad-auditoria.service` | Cómo se ejecuta y con qué aislamiento |
| `templates/systemd/nomad-auditoria.timer` | Cuándo se ejecuta |
| `scripts/verificar_sistema.sh` | Sección `hermes` nueva: ¿hay informe y es reciente? |
| `docs/17_hermes_guardian.md` | El capítulo, con sus 10 secciones, acotado a lo que existe |

**Por qué el recolector vive en `templates/etc/` y no en `scripts/`.** Misma razón que
`nomad-respaldo.sh` (capítulo 14 § 3.5): se instala fuera del repositorio para que funcione aunque
el repositorio no esté clonado o esté a medio actualizar.

**Diferencia con `nomad-respaldo.sh`, y hay que tenerla presente:** el recolector **sí** necesita el
repositorio, porque invoca sus scripts. No puede morir si no está: debe anotarlo en el informe y
seguir con lo que sí puede recoger.

---

### Tarea 1: Las variables y este plan

Van en el mismo commit a propósito: el plan usa `${HERMES_...}` en sus bloques de código, y
`verificar_repositorio.sh` escanea `docs/` **recursivamente** buscando variables que no estén en la
plantilla. Separarlos deja `make check` en rojo entre un commit y el siguiente.

**Ficheros:**
- Modificar: `config/servidor.env.example` (bloque nuevo al final, antes del bloque de instalación)
- Crear: `docs/superpowers/plans/2026-08-23-hermes-fase-1-recolector.md` (este fichero)

- [ ] **Paso 1: Comprobar que el uid elegido está libre**

```bash
getent passwd 10000; getent group 10000
```

Esperado: sin salida, y código de salida 2. Si devuelve algo, elige otro uid libre por encima de
10000 y úsalo en el paso siguiente.

- [ ] **Paso 2: Añadir el bloque a la plantilla**

Va después del bloque de observabilidad y antes del de instalación, respetando el formato de
comentarios del resto del fichero:

```bash
# ---------------------------------------------------------------------------
#  HERMES — auditoría del servidor
# ---------------------------------------------------------------------------

# [REQUERIDA] [CAPITULO: 17] ¿Instalar la auditoría automática? 'si' o 'no'.
#
# Con 'no', scripts/17_hermes.sh no hace nada y el servidor queda exactamente
# como estaba. Todo el capítulo 17 es opcional: ningún otro capítulo depende
# de él.
HERMES_HABILITADO="no"

# [REQUERIDA] [CAPITULO: 17] Usuario del sistema dueño de los informes.
#
# Se crea con 'nologin', sin sudo, sin grupo 'docker' y sin grupo 'adm'.
# Nadie inicia sesión como él: existe para que los informes y, más adelante,
# los ficheros que escriba el agente tengan un dueño distinto del tuyo. Sin
# eso, un 'ls -l' no distingue lo que tocaste tú de lo que tocó la máquina.
HERMES_USUARIO="hermes"

# [REQUERIDA] [CAPITULO: 17] uid y gid fijos del usuario anterior.
#
# Fijo y no automático porque la imagen oficial del agente corre como uid
# 10000: al llegar la fase 2, el contenedor adopta este mismo número y los
# ficheros que escriba salen ya con el dueño correcto, sin un 'chown' de por
# medio. Comprueba que está libre con: getent passwd 10000
HERMES_UID="10000"

# [REQUERIDA] [CAPITULO: 17] Hora de la auditoría diaria, en formato HH:MM.
#
# Conviene que sea DESPUÉS del respaldo (RESTIC_HORA) y antes de que te
# levantes: así el informe ya sabe si la copia de anoche salió bien.
HERMES_AUDITORIA_HORA="06:30"
```

- [ ] **Paso 3: Comprobar que la plantilla sigue siendo coherente**

```bash
make check
./scripts/variables.sh --estado | grep -i hermes
```

Esperado: `make check` sin fallos, y las cuatro variables listadas con su valor por defecto.

- [ ] **Paso 4: Commit**

```bash
git add config/servidor.env.example docs/superpowers/plans/2026-08-23-hermes-fase-1-recolector.md
git commit -m "Las cuatro variables de la auditoria, y el plan que las usa"
```

---

### Tarea 2: El usuario y los directorios

**Ficheros:**
- Crear: `scripts/17_hermes.sh`

**Interfaces:**
- Consume: `scripts/lib/common.sh` (`procesar_argumentos_comunes`, `cargar_entorno`,
  `requerir_variables`, `requerir_root`, `ejecutar`, `log_sinca`, `resumen_final`, `die`)
- Produce: el usuario `${HERMES_USUARIO}` con uid `${HERMES_UID}`, y el árbol
  `${DATOS_RAIZ}/hermes/informes/` con dueño `${HERMES_USUARIO}` y modo `0750`

- [ ] **Paso 1: Escribir el script**

```bash
#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — auditoría del servidor y guardián
# ===========================================================================
#  Propósito : instalar el recolector que produce el informe diario de estado,
#              con su usuario propio y su temporizador.
#  Uso       : sudo ./scripts/17_hermes.sh --help
#  Capítulo  : docs/17_hermes_guardian.md
#
#  Requiere root: crea un usuario del sistema y escribe unidades de systemd.
# ===========================================================================
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

mostrar_ayuda() {
    cat <<'AYUDA'
Uso: sudo ./scripts/17_hermes.sh [opciones]

Instala la auditoría diaria del servidor:

  1. Crea el usuario del sistema, sin shell y sin privilegios
  2. Prepara el directorio de informes
  3. Instala el recolector en /usr/local/sbin
  4. Instala y activa el temporizador

Opciones:
  -n, --check    Muestra qué cambiaría, sin tocar el sistema.
  -y, --si       No pide confirmación.
  -h, --help     Muestra esta ayuda.

LO QUE ESTE SCRIPT NO HACE:
  - No instala el agente Hermes. Eso es la fase 2 del capítulo.
  - No configura el monitor de Uptime Kuma que vigila el temporizador:
    es un paso de interfaz web y está en el capítulo 17 § 5.
AYUDA
}

procesar_argumentos_comunes "$@"
(( ${#NOMAD_ARGS_RESTANTES[@]} == 0 )) \
    || die "Opción desconocida: ${NOMAD_ARGS_RESTANTES[*]} (usa --help)"

# --- Comprobaciones previas --------------------------------------------------
log_paso "Comprobaciones previas"
requerir_root
cargar_entorno
requerir_variables DATOS_RAIZ ADMIN_USUARIO \
                   HERMES_HABILITADO HERMES_USUARIO HERMES_UID HERMES_AUDITORIA_HORA

if [[ "${HERMES_HABILITADO}" != "si" ]]; then
    log_sinca "HERMES_HABILITADO no es 'si'. No hay nada que instalar."
    log_info  "Para activarlo: ./scripts/variables.sh --fijar HERMES_HABILITADO=si"
    resumen_final "17_hermes.sh"
    exit 0
fi

[[ "${HERMES_AUDITORIA_HORA}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] \
    || die "HERMES_AUDITORIA_HORA debe tener formato HH:MM (valor actual: '${HERMES_AUDITORIA_HORA}')"

DIR_HERMES="${DATOS_RAIZ}/hermes"
DIR_INFORMES="${DIR_HERMES}/informes"

# --- Paso 1: el usuario ------------------------------------------------------
log_paso "Usuario del sistema '${HERMES_USUARIO}'"

# El uid se fija a mano en lugar de dejarlo al sistema porque la fase 2 se lo
# pasa al contenedor como PUID. Si aquí saliera un número distinto en cada
# servidor, el contenedor escribiría ficheros de un dueño que no existe.
if id -u "${HERMES_USUARIO}" >/dev/null 2>&1; then
    UID_ACTUAL="$(id -u "${HERMES_USUARIO}")"
    [[ "${UID_ACTUAL}" == "${HERMES_UID}" ]] \
        || die "El usuario '${HERMES_USUARIO}' ya existe con uid ${UID_ACTUAL}, no ${HERMES_UID}. Resuélvelo a mano antes de seguir."
    log_sinca "Usuario ${HERMES_USUARIO} ya existe con el uid correcto."
else
    getent passwd "${HERMES_UID}" >/dev/null \
        && die "El uid ${HERMES_UID} ya está ocupado por otro usuario. Cambia HERMES_UID."
    ejecutar groupadd --system --gid "${HERMES_UID}" "${HERMES_USUARIO}"
    ejecutar useradd  --system --uid "${HERMES_UID}" --gid "${HERMES_UID}" \
                      --home-dir "${DIR_HERMES}" --no-create-home \
                      --shell /usr/sbin/nologin \
                      --comment "Auditoria del servidor (capitulo 17)" \
                      "${HERMES_USUARIO}"
fi

# Comprobación explícita, no confianza: si alguien añadiera este usuario a
# 'docker' o a 'sudo' más adelante, el script lo dice en voz alta. Pertenecer
# al grupo docker equivale a ser root (capítulo 09 § 3.2).
GRUPOS_PROHIBIDOS="docker sudo adm"
for grupo in ${GRUPOS_PROHIBIDOS}; do
    if id -nG "${HERMES_USUARIO}" 2>/dev/null | tr ' ' '\n' | grep -qx "${grupo}"; then
        die "El usuario '${HERMES_USUARIO}' pertenece al grupo '${grupo}'. Eso anula el diseño del capítulo 17. Quítalo con: sudo gpasswd -d ${HERMES_USUARIO} ${grupo}"
    fi
done
log_ok "El usuario no pertenece a ningún grupo con privilegios."

# --- Paso 2: los directorios -------------------------------------------------
log_paso "Directorio de informes"

# 0750 y no 0755: el informe redactado sigue describiendo la infraestructura
# con detalle. Que lo lean el dueño y su grupo, no todo el sistema.
for d in "${DIR_HERMES}" "${DIR_INFORMES}"; do
    if [[ -d "${d}" ]]; then
        log_sinca "${d} ya existe."
    else
        ejecutar install -d -m 0750 -o "${HERMES_USUARIO}" -g "${HERMES_USUARIO}" "${d}"
    fi
done

resumen_final "17_hermes.sh"
```

- [ ] **Paso 2: Comprobar que es sintácticamente válido y pasa el listado**

```bash
bash -n scripts/17_hermes.sh && echo "sintaxis correcta"
chmod +x scripts/17_hermes.sh
make check
```

Esperado: «sintaxis correcta» y `make check` sin fallos. Si `shellcheck` está instalado,
`make check` lo pasa también por él; si no, lo avisa y sigue.

- [ ] **Paso 3: Probar la salida temprana**

```bash
sudo ./scripts/17_hermes.sh --check
```

Esperado, porque `HERMES_HABILITADO` vale `"no"` de fábrica:

```
[=]     HERMES_HABILITADO no es 'si'. No hay nada que instalar.
```

Este caso importa: el capítulo entero es opcional, y un script que hiciera algo con la
configuración por defecto rompería esa promesa.

- [ ] **Paso 4: Probar el camino real, en simulación**

```bash
./scripts/variables.sh --fijar HERMES_HABILITADO=si
sudo ./scripts/17_hermes.sh --check
```

Esperado: enumera el `groupadd`, el `useradd` y los dos `install -d` sin ejecutarlos, y termina con
`Cambios que se aplicarían: 4`.

- [ ] **Paso 5: Aplicar y comprobar la idempotencia**

```bash
sudo ./scripts/17_hermes.sh --si
sudo ./scripts/17_hermes.sh --check
```

Esperado en la segunda ejecución: `Cambios que se aplicarían: 0`. **Ese es el criterio de
«terminado» de este repositorio**; si sale distinto de cero, el script no es idempotente todavía.

- [ ] **Paso 6: Pruebas negativas — tienen que fallar**

```bash
sudo -u hermes -s              # esperado: This account is currently not available
id -nG hermes                  # esperado: solo 'hermes'
stat -c '%a %U:%G' /srv/hermes/informes   # esperado: 750 hermes:hermes
```

- [ ] **Paso 7: Commit**

```bash
git add scripts/17_hermes.sh
git commit -m "Un usuario que no puede hacer nada, que es justo lo que se le pide"
```

---

### Tarea 3: La redacción, y su detector

La pieza de la que depende que el informe se pueda enviar a un tercero. Se construye y se prueba
**aislada**, antes de que exista el recolector que la usa.

**Ficheros:**
- Crear: `templates/etc/nomad-auditoria.sh` (solo la cabecera y las dos funciones, de momento)

**Interfaces:**
- Produce: `redactar()` — filtro de entrada estándar a salida estándar; `fugas()` — devuelve 0 **si
  encuentra** algo que debería haberse redactado, como `grep`

- [ ] **Paso 1: Escribir la muestra que debe quedar limpia**

```bash
cat > /tmp/muestra-fugas.txt <<'FIN'
DEEPSEEK_API_KEY=sk-abcdef0123456789abcdef0123
La IP de Tailscale del servidor es 100.101.102.103
CF_TUNEL_ID=8a1b2c3d-4e5f-6789-abcd-ef0123456789
restic -r b2:nomad-nordirwork-respaldos:nomadservernw snapshots
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIabcdefghijklmnopqrstuvwxyz012345 deart@equipo
Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0
B2_ACCOUNT_KEY=K005abcdefghijklmnopqrstuvwxyz
Esta linea no tiene nada que ocultar y debe sobrevivir intacta.
FIN
```

- [ ] **Paso 2: Escribir la cabecera y las dos funciones**

```bash
#!/usr/bin/env bash
# ===========================================================================
#  nomad_server — recolector de la auditoría diaria
#  Destino  : /usr/local/sbin/nomad-auditoria.sh
#  Generado por scripts/17_hermes.sh
#  Capítulo : docs/17_hermes_guardian.md
#
#  Propósito : ejecutar como root lo que el agente NO puede ejecutar, redactar
#              su salida y dejarla en ${DATOS_RAIZ}/hermes/informes/.
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
#  config/servidor.env.example. Le pasa a nomad-respaldo.sh, que se libra solo
#  porque el validador no mira los .sh de templates/.
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
#  del servidor. Ante la duda, se amplía.
patrones_fuga=(
    '(sk|xoxb|ghp|gho|glpat)-[A-Za-z0-9_-]{12,}'
    '100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}'
    '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    '(b2|s3|sftp|rest|swift|azure|gs):[^[:space:]]+'
    '(ssh-(rsa|dss|ed25519)|ecdsa-sha2-[a-z0-9-]+)[[:space:]]+[A-Za-z0-9+/=]{20,}'
    '[A-Z_]*(PASSWORD|PASSWD|SECRET|TOKEN|KEY)[A-Z_]*[[:space:]]*=[[:space:]]*[^[:space:]]+'
    '([Aa]uthorization|[Xx]-[Aa]pi-[Kk]ey):[[:space:]]*[^[:space:]]+'
    '(AKIA|ASIA)[A-Z0-9]{16}'
)
etiquetas_fuga=(
    '[REDACTADO:clave]'
    '[REDACTADO:ip-tailnet]'
    '[REDACTADO:uuid]'
    '[REDACTADO:repositorio]'
    '[REDACTADO:llave-ssh]'
    '[REDACTADO:variable-secreta]'
    '[REDACTADO:cabecera]'
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
fugas() {
    local i args=()
    for i in "${!patrones_fuga[@]}"; do
        args+=(-e "${patrones_fuga[i]}")
    done
    grep -nE "${args[@]}"
}
```

- [ ] **Paso 3: Probar la redacción sobre la muestra**

Se prueba el fichero tal cual, sin copiar las funciones a ningún sitio. En esta tarea el fichero
solo contiene cabecera y funciones, así que cargarlo con `source` no ejecuta nada. El `bash -c`
aísla el `set -euo pipefail` de la plantilla, que si no se te queda pegado a la terminal.

```bash
bash -c 'source templates/etc/nomad-auditoria.sh
         redactar < /tmp/muestra-fugas.txt'
```

Esperado, línea a línea:

```
DEEPSEEK_API_KEY=[REDACTADO:variable-secreta]
La IP de Tailscale del servidor es [REDACTADO:ip-tailnet]
CF_TUNEL_ID=[REDACTADO:uuid]
restic -r [REDACTADO:repositorio] snapshots
[REDACTADO:llave-ssh] deart@equipo
[REDACTADO:cabecera]
B2_ACCOUNT_KEY=[REDACTADO:variable-secreta]
Esta linea no tiene nada que ocultar y debe sobrevivir intacta.
```

Fíjate en la última línea: **tiene que salir idéntica**. Un redactor que destroza el informe es tan
inútil como uno que no redacta.

- [ ] **Paso 4: Probar que el detector caza lo que la redacción no**

```bash
# a) Sobre el texto ya redactado: NO debe encontrar nada.
bash -c 'source templates/etc/nomad-auditoria.sh
         redactar < /tmp/muestra-fugas.txt | fugas' ; echo "codigo: $?"
```

Esperado: sin salida y `codigo: 1` — grep no encontró nada, que es el resultado bueno.

```bash
# b) Sobre el texto original: DEBE encontrar las siete líneas con secreto.
bash -c 'source templates/etc/nomad-auditoria.sh
         fugas < /tmp/muestra-fugas.txt' | wc -l
```

Esperado: `7`. Si sale menos, hay un patrón que no está cazando lo que dice cazar, y eso es
exactamente el fallo que este paso existe para descubrir.

- [ ] **Paso 5: Commit**

```bash
git add templates/etc/nomad-auditoria.sh
git commit -m "Redactar antes de publicar, y no publicar si la redaccion falla"
```

---

### Tarea 4: La recolección

**Ficheros:**
- Modificar: `templates/etc/nomad-auditoria.sh` (añadir tras las funciones de la tarea 3)

**Interfaces:**
- Consume: `redactar()`, `fugas()` de la tarea 3
- Produce: `${DATOS_RAIZ}/hermes/informes/estado.txt`, `cambios.txt` y `sello.txt`

- [ ] **Paso 1: Añadir el cuerpo del recolector**

```bash
# ===========================================================================
#  VALORES SUSTITUIDOS AL INSTALAR
# ===========================================================================
dir_informes="${DATOS_RAIZ}/hermes/informes"
usuario="${HERMES_USUARIO}"
repo="/home/${ADMIN_USUARIO}/nomad_server"

estado="${dir_informes}/estado.txt"
anterior="${dir_informes}/estado.anterior.txt"
sello="${dir_informes}/sello.txt"
cambios="${dir_informes}/cambios.txt"

inicio="$(date +%s)"
tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

# ===========================================================================
#  RECOLECCIÓN
# ===========================================================================
#  Cada bloque va con '|| true'. Un recolector que aborta al primer comando
#  que falla produce justo el informe que no sirve: el del día en que algo iba
#  mal. Los fallos se anotan y se sigue.
titulo() { printf '\n===== %s =====\n' "$1"; }

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
    # No se ejecuta un autotest: solo se lee lo que el disco ya sabe de sí
    # mismo. Un test largo cada mañana desgasta más de lo que informa.
    for disco in /dev/nvme?n? /dev/sd?; do
        [[ -b "${disco}" ]] || continue
        printf -- '--- %s\n' "${disco}"
        smartctl -H "${disco}" 2>&1 | grep -iE 'result|health' || true
    done

    titulo "ÍNDICE DE ENDURECIMIENTO"
    # Se LEE el último informe de lynis; no se ejecuta lynis. Ejecutarlo tarda
    # minutos y necesita escribir en /var/log, que esta unidad no permite. Que
    # el informe esté viejo también es información: la rutina trimestral del
    # capítulo 15 es la que lo renueva.
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
        printf 'SI — hay un reinicio pendiente desde %s\n' \
               "$(date -r /var/run/reboot-required --iso-8601=seconds)"
    else
        printf 'No.\n'
    fi
} > "${tmp}" 2>&1 || true

# ===========================================================================
#  REDACCIÓN Y PUBLICACIÓN
# ===========================================================================
limpio="$(mktemp)"
trap 'rm -f "${tmp}" "${limpio}"' EXIT
redactar < "${tmp}" > "${limpio}"

# FALLA CERRADA. Si algo sobrevivió a la redacción, no se publica informe: se
# publica el aviso. Un informe con un secreto dentro acabaría en la API de un
# tercero, y de ahí no se vuelve.
if fugas < "${limpio}" >/dev/null 2>&1; then
    {
        printf 'INFORME NO PUBLICADO — %s\n' "$(date --iso-8601=seconds)"
        printf '\nLa redacción no ha dejado limpio el informe: quedaban patrones\n'
        printf 'que corresponden a secretos. No se publica nada.\n\n'
        printf 'Revísalo a mano en el servidor:\n'
        printf '    sudo /usr/local/sbin/nomad-auditoria.sh --depurar\n'
    } > "${estado}"
    chown "${usuario}:${usuario}" "${estado}"; chmod 0640 "${estado}"
    printf 'fecha=%s\nresultado=fuga-detectada\n' "$(date --iso-8601=seconds)" > "${sello}"
    chown "${usuario}:${usuario}" "${sello}"; chmod 0640 "${sello}"
    echo "nomad-auditoria: fuga detectada tras redactar; informe no publicado" >&2
    exit 1
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

install -m 0640 -o "${usuario}" -g "${usuario}" "${limpio}" "${estado}"

# ===========================================================================
#  QUÉ CAMBIÓ DESDE AYER
# ===========================================================================
#  Esto es control de coste, no comodidad: en la fase 3 el agente lee este
#  fichero y no el informe entero.
#
#  El '|| true' no es decorativo: diff devuelve 1 cuando encuentra
#  diferencias, que es el caso normal, y con 'set -e' eso mataría el script
#  justo cuando hay algo que contar.
{
    if [[ -f "${anterior}" ]]; then
        printf 'CAMBIOS DESDE EL INFORME ANTERIOR\n'
        printf 'Anterior: %s\n\n' "$(date -r "${anterior}" --iso-8601=seconds)"
        # Se descartan las dos primeras líneas del informe (nombre y fecha):
        # cambian siempre y ensucian el diff de todos los días.
        diff -u <(tail -n +3 "${anterior}") <(tail -n +3 "${estado}") \
            | tail -n +3 || true
    else
        printf 'Primera ejecución: no hay informe anterior con el que comparar.\n'
    fi
} > "${cambios}"
chown "${usuario}:${usuario}" "${cambios}"; chmod 0640 "${cambios}"

# El sello permite detectar desde fuera que el recolector dejó de correr, que
# es un fallo silencioso: sin él, un informe de hace tres semanas se lee igual
# de convincente que el de esta mañana.
{
    printf 'fecha=%s\n'              "$(date --iso-8601=seconds)"
    printf 'resultado=publicado\n'
    printf 'codigo_verificador=%s\n' "${codigo_verificador:-desconocido}"
    printf 'duracion_segundos=%s\n'  "$(( $(date +%s) - inicio ))"
    printf 'lineas_cambiadas=%s\n'   "$(grep -c '^[+-]' "${cambios}" 2>/dev/null || echo 0)"
} > "${sello}"
chown "${usuario}:${usuario}" "${sello}"; chmod 0640 "${sello}"

exit 0
```

- [ ] **Paso 2: Comprobar la sintaxis con las variables sin sustituir**

```bash
bash -n templates/etc/nomad-auditoria.sh && echo "sintaxis correcta"
```

Esperado: «sintaxis correcta». `templates/` no lo revisa `shellcheck` en `make check` —solo mira
`scripts/`—, así que este paso es la única red que hay aquí.

- [ ] **Paso 3: `make check`**

```bash
make check
```

Esperado: sin fallos. En particular, la comprobación de variables debe aceptar
`${DATOS_RAIZ}`, `${HERMES_USUARIO}` y `${ADMIN_USUARIO}` porque las tres están en la plantilla
desde la tarea 1.

- [ ] **Paso 4: Commit**

```bash
git add templates/etc/nomad-auditoria.sh
git commit -m "Recoger lo que el agente no podra recoger, y anotar cuando fallo"
```

---

### Tarea 5: Las unidades de systemd y su instalación

**Ficheros:**
- Crear: `templates/systemd/nomad-auditoria.service`
- Crear: `templates/systemd/nomad-auditoria.timer`
- Modificar: `scripts/17_hermes.sh` (añadir antes de `resumen_final`)

**Interfaces:**
- Consume: el recolector de la tarea 4, `instalar_plantilla` y `habilitar_servicio` de `common.sh`
- Produce: `nomad-auditoria.timer` activo y habilitado

- [ ] **Paso 1: Escribir el servicio**

```ini
# ===========================================================================
#  nomad_server — servicio de la auditoría diaria
#  Destino  : /etc/systemd/system/nomad-auditoria.service
#  Generado por scripts/17_hermes.sh
#  Capítulo : docs/17_hermes_guardian.md
#
#  CÓMO APLICARLA A MANO (equivalente a lo que hace el script)
#
#      cd ~/nomad_server
#      source scripts/lib/entorno.sh
#      nomad_diff systemd/nomad-auditoria.service /etc/systemd/system/nomad-auditoria.service
#      nomad_plantilla systemd/nomad-auditoria.service \
#          | sudo tee /etc/systemd/system/nomad-auditoria.service >/dev/null
#      sudo chmod 644 /etc/systemd/system/nomad-auditoria.service
#
#  Y después:  sudo systemctl daemon-reload
# ===========================================================================

[Unit]
Description=Auditoria diaria del servidor
Documentation=file:///home/${ADMIN_USUARIO}/nomad_server/docs/17_hermes_guardian.md

# 'Wants' y no 'Requires': si Docker estuviera parado, el resto del informe
# —disco, servicios fallidos, reinicio pendiente— sigue mereciendo la pena. Y
# que Docker esté parado es justo lo que quieres leer en el informe.
Wants=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nomad-auditoria.sh

# La auditoría no compite con nada: puede tardar lo que haga falta.
Nice=19
IOSchedulingClass=idle

# Un verificador colgado no debe dejar el temporizador bloqueado para siempre.
TimeoutStartSec=20min

# --- Aislamiento -----------------------------------------------------------
# Necesita leer prácticamente todo el sistema y escribir en un solo sitio.
ProtectSystem=strict
ReadWritePaths=${DATOS_RAIZ}/hermes
PrivateTmp=true
NoNewPrivileges=true
ProtectKernelTunables=true
ProtectControlGroups=true

# ProtectHome NO se activa: el recolector invoca los scripts del repositorio,
# que vive en /home/${ADMIN_USUARIO}/nomad_server. Con 'ProtectHome=yes' el
# servicio arrancaría igual y el informe saldría todos los días diciendo que
# no encuentra el verificador — un fallo que se lee como si faltara el
# repositorio, y no como lo que es.
```

- [ ] **Paso 2: Escribir el temporizador**

```ini
# ===========================================================================
#  nomad_server — temporizador de la auditoría diaria
#  Destino  : /etc/systemd/system/nomad-auditoria.timer
#  Generado por scripts/17_hermes.sh
#  Capítulo : docs/17_hermes_guardian.md
#
#  CÓMO APLICARLA A MANO (equivalente a lo que hace el script)
#
#      cd ~/nomad_server
#      source scripts/lib/entorno.sh
#      nomad_plantilla systemd/nomad-auditoria.timer \
#          | sudo tee /etc/systemd/system/nomad-auditoria.timer >/dev/null
#      sudo systemctl daemon-reload && sudo systemctl enable --now nomad-auditoria.timer
# ===========================================================================

[Unit]
Description=Auditoria diaria del servidor

[Timer]
OnCalendar=*-*-* ${HERMES_AUDITORIA_HORA}:00

# Si el servidor estuvo apagado a esa hora, auditar en cuanto arranque: el
# informe del día que el servidor no estaba es precisamente el que interesa.
Persistent=true

# Cinco minutos de margen. Menos que el respaldo porque aquí no hay disco que
# compartir, solo se trata de no coincidir al segundo con otra tarea.
RandomizedDelaySec=5min

Unit=nomad-auditoria.service

[Install]
WantedBy=timers.target
```

- [ ] **Paso 3: Añadir la instalación al script, antes de `resumen_final`**

```bash
# --- Paso 3: el recolector ---------------------------------------------------
log_paso "Recolector"
instalar_plantilla etc/nomad-auditoria.sh /usr/local/sbin/nomad-auditoria.sh 0750 root:root

# --- Paso 4: las unidades ----------------------------------------------------
log_paso "Temporizador"

ANTES="$(cambios)"
instalar_plantilla systemd/nomad-auditoria.service /etc/systemd/system/nomad-auditoria.service
instalar_plantilla systemd/nomad-auditoria.timer   /etc/systemd/system/nomad-auditoria.timer

# Recargar solo si algo cambió de verdad. Sin el contador en archivo esto
# fallaría en silencio: 'instalar_plantilla' escribe desde dentro de una
# tubería, y una variable incrementada ahí no sobrevive al subshell
# (lib/common.sh § marcar_cambio).
if hubo_cambios_desde "${ANTES}"; then
    ejecutar systemctl daemon-reload
fi

habilitar_servicio nomad-auditoria.timer

log_info "Primera ejecución a mano, para no esperar a mañana:"
log_info "    sudo systemctl start nomad-auditoria.service"
log_info "    sudo cat ${DIR_INFORMES}/estado.txt"
```

- [ ] **Paso 4: Validar las unidades sin instalarlas**

```bash
source scripts/lib/entorno.sh
mkdir -p /tmp/unidades
nomad_plantilla systemd/nomad-auditoria.service > /tmp/unidades/nomad-auditoria.service
nomad_plantilla systemd/nomad-auditoria.timer   > /tmp/unidades/nomad-auditoria.timer
systemd-analyze verify /tmp/unidades/nomad-auditoria.service
systemd-analyze verify /tmp/unidades/nomad-auditoria.timer
grep -n 'OnCalendar\|ReadWritePaths\|Documentation' /tmp/unidades/*
```

Esperado: `systemd-analyze verify` sin salida (así informa de que están bien), y en el `grep` los
valores ya sustituidos —la hora real, `/srv/hermes`, el usuario real—, **ninguna `${VARIABLE}` sin
resolver**. Una variable que se cuela sin sustituir produce un temporizador que systemd acepta y
que no dispara nunca.

- [ ] **Paso 5: Aplicar en el servidor y comprobar**

```bash
sudo ./scripts/17_hermes.sh --check      # revisa el diff antes de aplicar
sudo ./scripts/17_hermes.sh --si
sudo ./scripts/17_hermes.sh --check      # esperado: Cambios que se aplicarían: 0
systemctl list-timers nomad-auditoria.timer --no-pager
```

- [ ] **Paso 6: Ejecutarla de verdad**

```bash
sudo systemctl start nomad-auditoria.service
systemctl status nomad-auditoria.service --no-pager
sudo ls -l /srv/hermes/informes/
sudo cat /srv/hermes/informes/sello.txt
```

Esperado: los tres ficheros con dueño `hermes:hermes` y modo `640`, y en `sello.txt`
`resultado=publicado`.

- [ ] **Paso 7: La prueba que de verdad importa — leer el informe entero a mano**

```bash
sudo less /srv/hermes/informes/estado.txt
```

**No te saltes este paso.** Es la única vez que un humano va a leer el informe completo antes de
que empiece a salir del servidor. Busca a conciencia lo que la redacción se haya podido dejar:
rutas con nombres de cliente, cabeceras, un token en un mensaje de error de Docker. Lo que
encuentres se convierte en un patrón nuevo en `patrones_fuga` y se vuelve a la tarea 3.

- [ ] **Paso 8: Comprobar el `cambios.txt` al segundo pase**

```bash
sudo systemctl start nomad-auditoria.service
sudo cat /srv/hermes/informes/cambios.txt
```

Esperado: un diff corto. Si sale enorme, hay ruido que cambia en cada ejecución —tiempos de
actividad, contadores— y hay que filtrarlo antes de la fase 3, porque en la fase 3 eso se paga en
tokens todos los días.

- [ ] **Paso 9: Commit**

```bash
git add templates/systemd/nomad-auditoria.service templates/systemd/nomad-auditoria.timer scripts/17_hermes.sh
git commit -m "Un temporizador que no compite con nada y un informe que se lee"
```

---

### Tarea 6: Que el verificador del sistema sepa de esto

Sin esto, el recolector es un fallo silencioso: deja de correr y nadie se entera hasta que alguien
mira un informe viejo creyéndolo de hoy.

**Ficheros:**
- Modificar: `scripts/verificar_sistema.sh` (sección nueva `hermes`, y su mención en `--help`)

- [ ] **Paso 1: Añadir `hermes` a la ayuda**

En `mostrar_ayuda`, la línea de secciones pasa a:

```
  --seccion <nombre>  Ejecuta solo un bloque:
                        sistema | seguridad | red | docker |
                        publicacion | respaldos | hermes
```

- [ ] **Paso 2: Añadir la sección**

Sigue el patrón de las secciones existentes, usando `fallo` y `aviso`:

```bash
seccion_hermes() {
    log_paso "Auditoría (capítulo 17)"

    # El capítulo es opcional. Si no está activado, no hay nada que comprobar
    # y decirlo no es un fallo.
    if [[ "${HERMES_HABILITADO:-no}" != "si" ]]; then
        log_sinca "HERMES_HABILITADO no es 'si': el capítulo 17 no está instalado."
        return 0
    fi

    local sello="${DATOS_RAIZ}/hermes/informes/sello.txt"

    if ! systemctl is-enabled --quiet nomad-auditoria.timer 2>/dev/null; then
        fallo "nomad-auditoria.timer no está habilitado."
    else
        log_ok "nomad-auditoria.timer habilitado."
    fi

    if [[ ! -r "${sello}" ]]; then
        fallo "No hay ${sello}: la auditoría no ha llegado a publicar nunca."
        return 0
    fi

    # Un informe viejo es peor que ninguno: se lee con la misma confianza que
    # uno de esta mañana. 36 horas da margen a un reinicio o a un apagón sin
    # convertir cada incidencia en un fallo.
    local edad_horas
    edad_horas=$(( ( $(date +%s) - $(stat -c %Y "${sello}") ) / 3600 ))
    if (( edad_horas > 36 )); then
        fallo "El último informe tiene ${edad_horas} horas. La auditoría no está corriendo."
    else
        log_ok "Informe de hace ${edad_horas} h."
    fi

    # 'fuga-detectada' significa que la redacción no dejó limpio el informe y
    # el recolector se negó a publicarlo. Es un fallo, no un aviso: mientras
    # dure, no hay informe.
    local resultado
    resultado="$(sed -n 's/^resultado=//p' "${sello}")"
    case "${resultado}" in
        publicado)      log_ok "Último informe publicado correctamente." ;;
        fuga-detectada) fallo "La redacción detectó una fuga y no publicó informe. Revisa el capítulo 17 § 9." ;;
        *)              aviso "Resultado desconocido en el sello: '${resultado}'" ;;
    esac
}
```

- [ ] **Paso 3: Engancharla al despachador**

En el `case` de secciones —el que hoy termina en `*) die "Sección desconocida..."`— añade
`hermes)` junto a las demás, y añade la llamada a `seccion_hermes` en el recorrido completo, después
de `seccion_respaldos`. **No** la añadas al modo `--rapido`: la rutina semanal son 30 segundos y
esto no es esencial para saber si el servidor está en pie.

- [ ] **Paso 4: Probar los tres caminos**

```bash
./scripts/verificar_sistema.sh --seccion hermes          # con HERMES_HABILITADO=si → CORRECTO
sudo touch -d '3 days ago' /srv/hermes/informes/sello.txt
./scripts/verificar_sistema.sh --seccion hermes          # → fallo por edad, codigo 1
sudo systemctl start nomad-auditoria.service             # lo repara
./scripts/verificar_sistema.sh --seccion hermes          # → CORRECTO otra vez
```

Esperado: el segundo comando falla con `72 horas` y devuelve 1. **Una comprobación que nunca has
visto fallar no sabes si funciona.**

- [ ] **Paso 5: Commit**

```bash
git add scripts/verificar_sistema.sh
git commit -m "Un informe viejo se lee igual de convincente que uno de hoy"
```

---

### Tarea 7: El capítulo

Escribir la documentación al final es lo contrario de lo que hace este repositorio, pero aquí es
deliberado: el capítulo describe **lo que quedó construido**, y hasta la tarea 6 no se sabe del todo.

El capítulo se crea con sus 10 secciones completas y **acotado a la fase 1**. Crecerá en cada fase.
`verificar_repositorio.sh` exige las 10 secciones a todo `docs/[0-9]*.md`, así que un capítulo a
medias deja `make check` en rojo.

**Ficheros:**
- Crear: `docs/17_hermes_guardian.md`

- [ ] **Paso 1: Escribir el capítulo**

Las 10 secciones obligatorias, en este orden exacto —cópialas de la estructura de
`docs/13_observabilidad.md`, que es el capítulo más parecido en tamaño:

1. **Objetivo** — al terminar, el servidor produce solo un informe diario redactado.
2. **Requisitos previos** — depende de los capítulos 04 a 15. El paso 0 carga el entorno.
3. **Decisiones y por qué** — trae de la especificación: por qué contenedor y no host (§ 3), por
   qué los hechos los recoge bash (§ 2), por qué el usuario no tiene privilegios (§ 6.5), por qué
   la redacción falla cerrada (§ 7), por qué se lee el informe de lynis en vez de ejecutarlo
   (tarea 4), y **por qué esta fase no instala Hermes**.
4. **Variables usadas** — las cuatro de la tarea 1, con su procedencia.
5. **Procedimiento** — paso 0 (preparar la sesión) y los pasos manuales equivalentes a lo que hace
   el script, incluido el paso de leer el informe entero a mano la primera vez.
6. **Script asociado** — `17_hermes.sh`: qué automatiza, qué no, y la correspondencia con los pasos
   manuales. Debe decir en voz alta que **no** configura el monitor de Uptime Kuma que vigila el
   temporizador, porque eso es interfaz web.
7. **Validación** — los comandos de las tareas 5 y 6, con criterio de aceptación:
   `verificar_sistema.sh --seccion hermes` en CORRECTO y `17_hermes.sh --check` en cero cambios.
8. **Reversión** — la de la especificación § 13, acotada a lo que existe:
   `systemctl disable --now nomad-auditoria.timer`, borrar las unidades y el script, `userdel`.
9. **Errores frecuentes** — síntoma → causa → solución. Empieza por estos cuatro, que son los que
   este plan ha ido descubriendo:
   - *El informe dice que no encuentra `verificar_sistema.sh`* → el repositorio no está en
     `/home/${ADMIN_USUARIO}/nomad_server`, o la unidad tiene `ProtectHome`.
   - *`sello.txt` dice `fuga-detectada`* → un patrón nuevo se coló; cómo depurarlo sin publicar.
   - *El temporizador está habilitado y no dispara* → una `${VARIABLE}` sin sustituir en
     `OnCalendar`; se ve con `systemctl cat nomad-auditoria.timer`.
   - *`cambios.txt` sale enorme cada día* → ruido que cambia en cada ejecución; qué filtrar.
10. **Referencias** — `systemd.timer(5)`, `systemd.exec(5)`, `sed(1)`, y la especificación.

- [ ] **Paso 2: Comprobar la estructura**

```bash
make check
```

Esperado: `17_hermes_guardian.md tiene las 10 secciones` y ningún fallo. Si falla por enlaces,
recuerda que los relativos se resuelven desde `docs/`.

- [ ] **Paso 3: Actualizar la cuenta de capítulos**

`README.md` dice «17 capítulos» en tres sitios: la tabla de principios, el índice y la sección de
estructura. Pasan a ser 18. Busca las tres:

```bash
grep -n '17 capítulos\|los 17\|17 capitulos' README.md docs/00_planificacion.md
```

Añade también la fila del capítulo 17 al índice del README, en el bloque «Operación».

- [ ] **Paso 4: Comprobación final**

```bash
make check
sudo ./scripts/17_hermes.sh --check
./scripts/verificar_sistema.sh --seccion hermes
```

Esperado: los tres limpios. `Cambios que se aplicarían: 0` es el criterio de «capítulo terminado»
de este repositorio.

- [ ] **Paso 5: Commit**

```bash
git add docs/17_hermes_guardian.md README.md
git commit -m "El capitulo 17, acotado a lo que existe de verdad"
```

---

## Lo que esta fase deja pendiente a propósito

Para que quien lea el plan no lo confunda con un olvido:

| Pendiente | Fase |
|---|---|
| El contenedor de Hermes, la clave del proveedor, el anexo 96 como skill | 2 |
| Telegram y el panel por tailnet | 3 |
| El conserje de `/srv` y las ramas `hermes/*` | 4 |
| El monitor de Uptime Kuma que vigila el temporizador | 5 (paso manual, capítulo 17 § 5) |
| Las filas nuevas del modelo de amenazas en `docs/00` | 5 |
| El portero de despliegue | 6 |

## Riesgos de esta fase

1. **`templates/` no pasa por `shellcheck`.** `verificar_repositorio.sh` solo recorre `scripts/`
   (`find scripts -name '*.sh'`), así que `nomad-auditoria.sh` —y el `nomad-respaldo.sh` que ya
   existe— nunca se revisan. `bash -n` es lo único que hay. Ampliar esa comprobación es una mejora
   pequeña y transversal; conviene proponerla aparte, no colarla en esta fase.
2. **La lista de patrones se quedará corta.** Por eso el paso 7 de la tarea 5 obliga a leer el
   informe entero a mano. Repetirlo en la rutina trimestral del capítulo 15.
3. **`cambios.txt` puede salir ruidoso** y no se sabrá hasta ver dos ejecuciones reales seguidas.
   Es barato de arreglar ahora y caro en la fase 3, cuando cada línea de ruido se paga en tokens.
4. **`ProtectSystem=strict` con `ReadWritePaths` a un directorio inexistente impide arrancar el
   servicio**, y falla antes de ejecutar una sola línea. Por eso la tarea 2 crea el directorio
   antes que la tarea 5 instale la unidad. No cambies ese orden.
