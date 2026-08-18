# 12 — Despliegue de proyectos

> Un procedimiento único y repetible para publicar cualquier proyecto: mismo esquema de
> directorios, mismas etiquetas, mismo comando. Sin decisiones nuevas cada vez.

---

## 1. Objetivo

Al terminar tendrás una convención clara para desplegar proyectos, una plantilla que sirve de punto
de partida, un script de despliegue que verifica la salud del servicio y revierte si falla, y un
proyecto de ejemplo publicado y accesible por su subdominio.

---

## 2. Requisitos previos

**Capítulos previos:** [10 — Traefik](10_traefik.md) y
[11 — Cloudflared](11_cloudflared_y_dominio.md), ambos funcionando.

**Necesitas a mano:**

- El túnel conectado y al menos un subdominio de prueba respondiendo.
- El código del proyecto que quieras desplegar, o ganas de usar el de ejemplo.

**Preparar la sesión.**

```bash
# [servidor]
cd ~/nomad_server
source scripts/lib/entorno.sh
echo "datos=${DATOS_RAIZ} dominio=${DOMINIO_PUBLICO} red=${DOCKER_RED_PROXY} tz=${SERVIDOR_ZONA_HORARIA}"
```

Salida esperada, con los valores de ejemplo:

```
datos=/srv dominio=ejemplo.com red=proxy tz=America/Bogota
```

> **Este capítulo introduce la variable temporal más peligrosa del repositorio: `PROYECTO`.**
> Aparece en rutas (`${DATOS_RAIZ}/${PROYECTO}`), en comandos de borrado (`rm -rf ${PROYECTO}`) y
> en el nombre de los subdominios. Vive solo en tu terminal y desaparece al desconectarte, así que
> es exactamente la que más veces se queda vacía sin que nadie se dé cuenta. El paso 1 explica cómo
> declararla y comprobarla; la sección 8 repite la comprobación antes de cada borrado.

**Tiempo estimado:** 40 minutos el primer proyecto; 5 minutos los siguientes.

---

## 3. Decisiones y por qué

### 3.1 Un directorio por proyecto, todo dentro

**Decisión: `${DATOS_RAIZ}/<proyecto>/` contiene el compose, las variables y los datos.**

```
${DATOS_RAIZ}/mi-proyecto/
├── docker-compose.yml     ← versionado en el repositorio del proyecto
├── .env.example           ← versionado, con valores ficticios
├── .env                   ← solo en el servidor, permisos 600, NUNCA en git
├── codigo/                ← el repositorio del proyecto, si se construye aquí
├── datos/                 ← datos persistentes de la aplicación
└── datos-db/              ← datos de la base de datos
```

La propiedad que da esto: **el proyecto entero cabe en una copia de ese directorio**. El respaldo
del capítulo 14 recoge `${DATOS_RAIZ}` completo y con eso basta para reconstruirlo. Restaurar es
copiar el directorio y ejecutar `docker compose up -d`.

### 3.2 Nada de `ports:`

**Decisión: ningún proyecto publica puertos.**

Se repite aquí porque es donde se rompe. Cuando un proyecto no funciona a la primera, la reacción
natural es «voy a exponer el puerto para probar directamente». Ese `ports: ["3000:3000"]` temporal
se queda, y a partir de ese momento el servicio está accesible desde toda la red local, saltándose
el cortafuegos.

**Para probar directamente, usa un túnel SSH**, que consigue lo mismo sin abrir nada:

```bash
# [cliente]
ssh -L 3000:localhost:3000 nomad
```

Y si necesitas alcanzar el contenedor desde el propio servidor:

```bash
# [servidor]
docker run --rm --network ${DOCKER_RED_PROXY} curlimages/curl -s http://mi-proyecto:3000/
```

### 3.3 Montajes de directorio, no volúmenes con nombre

**Decisión: los datos van en `./datos/` dentro del proyecto, no en volúmenes de Docker.**

| | Volumen con nombre | Montaje de directorio (elegido) |
|---|---|---|
| Dónde vive | `/var/lib/docker/volumes/…` | `${DATOS_RAIZ}/<proyecto>/datos/` |
| Respaldarlo | Hay que lanzar un contenedor auxiliar que empaquete el contenido | `restic backup ${DATOS_RAIZ}` lo incluye |
| Inspeccionarlo | `docker volume inspect` y luego navegar como root | `ls`, `grep`, `du` |
| Restaurarlo | Contenedor auxiliar otra vez | Copiar el directorio |
| Rendimiento | Ligeramente mejor | Suficiente |
| Permisos | Los gestiona Docker | **Hay que cuidarlos** |

Se elige el montaje de directorio porque el objetivo del repositorio es que todo sea inspeccionable
y restaurable con herramientas normales. La contrapartida es real: si el contenedor corre como un
usuario no root, hay que ajustar el propietario del directorio en el host. La sección 9 explica cómo.

### 3.4 Los secretos viven en `.env`, fuera de git

**Decisión: `.env` con permisos 600 en el servidor; `.env.example` versionado con valores ficticios.**

`.env.example` documenta **qué** variables hacen falta sin revelar sus valores. Quien clone el
proyecto sabe qué debe rellenar.

Se valoró cifrar los `.env` con SOPS + age para poder versionarlos (capítulo 00 § 3.13). Con un solo
administrador, la complejidad no compensa.

**Consecuencia asumida y que hay que tener presente:** los secretos **no** se reconstruyen desde
git. Si se pierde el servidor y no hay respaldo, hay que regenerarlos todos. Por eso el capítulo 14
los incluye explícitamente.

### 3.5 Versiones de imagen fijadas

**Decisión: `postgres:17-alpine`, nunca `postgres:latest`.**

Con `latest`, un `docker compose pull` rutinario puede traer una versión mayor de la base de datos
que no lee el formato de datos anterior. Ha pasado tantas veces que es casi un rito de paso.

Fijar la línea mayor (`17-alpine`) da parches sin saltos. La subida a la 18 se hace a mano, leyendo
antes las notas de migración.

### 3.6 Healthcheck obligatorio

**Decisión: todo servicio declara un `healthcheck`.**

Sin él, Docker considera «en marcha» a un contenedor cuyo proceso principal existe, aunque esté
colgado y no responda. El script de despliegue no tendría forma de saber si un despliegue ha salido
bien.

Con healthcheck, `deploy.sh` espera a que el servicio esté `healthy` y, si no lo consigue, revierte.

### 3.7 Red privada para lo que no se publica

**Decisión: las bases de datos van en una red `internal: true`, sin conexión a la red `proxy`.**

Un contenedor conectado a `${DOCKER_RED_PROXY}` es alcanzable por **todos** los demás contenedores
de esa red, incluidos los de otros proyectos. Poner ahí una base de datos significa que cualquier
proyecto comprometido puede intentar conectarse a ella.

Con una red `interna` por proyecto, solo el servicio web de ese proyecto la ve. Y con
`internal: true`, la base de datos tampoco tiene salida a internet: si se comprometiera, no podría
enviar nada fuera.

### 3.8 Despliegue con `git pull` y script, no con CI/CD

**Decisión: `./deploy.sh <proyecto>`, sin runner autoalojado.**

| Alternativa descartada | Por qué |
|---|---|
| Runner de GitHub Actions autoalojado | Ejecuta código en tu servidor cada vez que alguien envía un cambio. Es una superficie de ataque considerable para el ritmo de despliegues de un proyecto personal |
| Watchtower (actualización automática de imágenes) | Actualiza solo, incluidas versiones mayores que rompen. Contradice 3.5 |
| Gitea + Woodpecker autoalojados | Dos servicios más que mantener y respaldar, para automatizar algo que tarda cinco segundos |

Cuando el ritmo de despliegues lo justifique, la evolución natural es construir las imágenes fuera
(GitHub Actions publicando en un registro) y que el servidor solo haga `pull`. Eso no requiere
cambiar nada de lo montado aquí.

---

## 4. Variables usadas

### 4.1 De `config/servidor.env`

| Variable | Uso | Dónde acaba |
|---|---|---|
| `DATOS_RAIZ` | Directorio raíz de los proyectos | Rutas de todos los comandos |
| `DOMINIO_PUBLICO` | Dominio de los subdominios | Etiquetas de Traefik y `.env` del proyecto |
| `DOCKER_RED_PROXY` | Red compartida con Traefik | `docker-compose.yml` del proyecto |
| `SERVIDOR_ZONA_HORARIA` | Zona horaria dentro de los contenedores | `.env` del proyecto |
| `CF_TUNEL_NOMBRE` | Túnel donde se registra el subdominio | Comando `tunnel route dns` |

### 4.2 Variables temporales de esta sesión

| Variable | Qué contiene | Se declara en | Riesgo si está vacía |
|---|---|---|---|
| `PROYECTO` | Nombre del proyecto que estás desplegando | Paso 1 | **Alto**: aparece en rutas y en comandos de borrado |

Declararla y comprobarla:

```bash
# [servidor]
PROYECTO=mi-proyecto
echo "Trabajando en: ${DATOS_RAIZ}/${PROYECTO}"
```

Criterio de aceptación: la ruta impresa es completa (`/srv/mi-proyecto`). Si imprime `/srv/` o `/`,
**para**: los comandos siguientes actuarían sobre el directorio de proyectos entero.

> **`PROYECTO` no va en `config/servidor.env`.** No describe el servidor, sino lo que estás haciendo
> ahora mismo, y cambia varias veces al día. Cada vez que te reconectes tendrás que volver a
> declararla: es el comportamiento correcto, no un descuido del repositorio (anexo
> [98 § 2.3](98_variables_y_entorno.md)).

### 4.3 Variables del PROYECTO, que son otra cosa

No confundas las variables del **despliegue** (`config/servidor.env`, describen el servidor) con las
del **proyecto** (`${DATOS_RAIZ}/<proyecto>/.env`, describen la aplicación):

| | `config/servidor.env` | `<proyecto>/.env` |
|---|---|---|
| Describe | El servidor | Una aplicación concreta |
| Quién lo lee | Los scripts y `scripts/lib/entorno.sh` | Docker Compose, al levantar ese proyecto |
| Contiene | Red, dominio, rutas, política de respaldos | Contraseñas de base de datos, claves de API, URL pública |
| Permisos | `600` | `600` |
| ¿Se versiona? | No | No. Sí su `.env.example`, con valores ficticios |
| Se carga en tu shell | Sí, con `source scripts/lib/entorno.sh` | **No**: lo lee Compose por su cuenta |

Un `.env` de proyecto **no** se carga en tu terminal. Si necesitas consultar un valor:

```bash
# [servidor]
grep '^POSTGRES_USER=' ${DATOS_RAIZ}/${PROYECTO}/.env
```

---

## 5. Procedimiento

### Paso 0 — Prepara la sesión

```bash
# [servidor]
cd ~/nomad_server
source scripts/lib/entorno.sh
```

Comprobación de que el capítulo 11 sigue en pie:

```bash
# [servidor]
docker ps --filter name=traefik --filter name=cloudflared --format '{{.Names}} {{.Status}}'
```

Criterio de aceptación: los dos aparecen como `Up` y `(healthy)`.

### Paso 1 — Crea el directorio del proyecto

```bash
# [servidor]
PROYECTO=mi-proyecto
echo "Ruta del proyecto: ${DATOS_RAIZ}/${PROYECTO}"
```

Criterio de aceptación: la ruta es completa, del tipo `/srv/mi-proyecto`. **Si imprime `/srv/` o
`/`, para aquí**: los comandos siguientes crearían directorios en sitios equivocados y los de la
sección 8 borrarían el directorio de proyectos entero.

```bash
# [servidor]
mkdir -p ${DATOS_RAIZ}/${PROYECTO}/{datos,datos-db}
cd ${DATOS_RAIZ}/${PROYECTO}
pwd
```

Criterio de aceptación: `pwd` confirma que estás dentro del proyecto.

> **Si te desconectas a partir de aquí**, `PROYECTO` desaparece. Al volver, vuelve a declararla
> antes de seguir; y si has cerrado la sesión, carga también el entorno:
>
> ```bash
> # [servidor]
> cd ~/nomad_server && source scripts/lib/entorno.sh
> PROYECTO=mi-proyecto
> cd ${DATOS_RAIZ}/${PROYECTO}
> ```

### Paso 2 — Copia la plantilla

Hay dos formas de traer la plantilla, y la diferencia importa:

**Opción A — con las variables ya sustituidas** (recomendada la primera vez, porque el archivo queda
legible y listo para editar):

```bash
# [servidor]
cd ~/nomad_server
nomad_plantilla compose/proyecto-ejemplo/docker-compose.yml \
    > ${DATOS_RAIZ}/${PROYECTO}/docker-compose.yml
nomad_plantilla compose/proyecto-ejemplo/env.example \
    > ${DATOS_RAIZ}/${PROYECTO}/.env.example
cd ${DATOS_RAIZ}/${PROYECTO}
```

Así, `${DOMINIO_PUBLICO}` y `${SERVIDOR_ZONA_HORARIA}` quedan resueltas en el archivo.

**Opción B — la plantilla tal cual**, dejando las variables para que las resuelva Docker Compose al
levantar el proyecto:

```bash
# [servidor]
cp ~/nomad_server/templates/compose/proyecto-ejemplo/docker-compose.yml .
cp ~/nomad_server/templates/compose/proyecto-ejemplo/env.example .env.example
```

Compose sustituye `${VARIABLE}` con lo que encuentre en el `.env` del proyecto **o en el entorno**,
así que esta opción funciona solo si esas variables están en el `.env`. Es más flexible pero menos
evidente al leer el archivo.

> **Ojo con el `$$` de la plantilla.** El healthcheck de la base de datos lleva
> `pg_isready -U $${POSTGRES_USER}`: ese doble dólar es el escape de Compose para que la variable la
> resuelva **el contenedor**, no Compose. No lo quites ni lo dupliques (anexo
> [98 § 4.4](98_variables_y_entorno.md)).

Después, edita `docker-compose.yml` y cambia lo marcado con «CAMBIAR»: la imagen, el nombre del
contenedor, el subdominio, el puerto interno del servicio y el nombre del router.

> **Los nombres de router y de servicio deben ser únicos en todo el servidor.** Si dos proyectos
> usan `traefik.http.routers.web`, el segundo pisa al primero. Usa el nombre del proyecto como
> prefijo y no habrá colisiones.

### Paso 3 — Configura las variables

```bash
# [servidor]
cp .env.example .env
chmod 600 .env
vim .env
```

Genera las contraseñas al azar, no las inventes:

```bash
# [servidor]
openssl rand -base64 32
```

```bash
# [servidor] — comprobación
ls -l .env
grep -c 'CAMBIAME' .env || echo "0 (correcto)"
```

Criterio de aceptación: permisos `-rw-------` y **cero** apariciones de `CAMBIAME`. Cada `CAMBIAME`
que quede es una contraseña que no has generado.

### Paso 4 — Crea el registro DNS

```bash
# [servidor]
cd ~/nomad_server
./scripts/11_cloudflared.sh --ruta ${PROYECTO}
```

```bash
# [cliente]
dig ${PROYECTO}.${DOMINIO_PUBLICO} +short
```

Criterio de aceptación: devuelve direcciones de Cloudflare.

**Si el proyecto es privado** (solo accesible por tu red), sáltate este paso y usa el punto de
entrada `interna` en las etiquetas.

### Paso 5 — Despliega

```bash
# [servidor]
cd ${DATOS_RAIZ}/${PROYECTO}
docker compose config          # valida la sintaxis y muestra el resultado
```

Antes de levantar nada, revisa la salida de `docker compose config`: es el fichero **ya resuelto**,
con todas las variables sustituidas. Tres cosas que mirar:

```bash
# [servidor]
docker compose config | grep -E 'image:|Host\(|published|external'
```

Criterio de aceptación:

- Las imágenes llevan **versión fijada**, no `latest`.
- La regla `Host(...)` tiene tu subdominio real, no `${DOMINIO_PUBLICO}` literal ni `ejemplo.com`.
- **No aparece ninguna línea `published`**: este proyecto no publica puertos.

```bash
# [servidor]
docker compose up -d
docker compose ps
```

Criterio de aceptación: los servicios en estado `running` y, tras el `start_period`, `healthy`.

```bash
# [servidor]
docker compose logs --tail 50
```

### Paso 6 — Comprueba

```bash
# [servidor] — desde dentro de la red de contenedores
docker run --rm --network ${DOCKER_RED_PROXY} curlimages/curl:latest \
    -s -o /dev/null -w '%{http_code}\n' \
    -H "Host: ${PROYECTO}.${DOMINIO_PUBLICO}" http://traefik/
```

Criterio de aceptación: `200`.

```bash
# [cliente] — desde internet
curl -sI https://${PROYECTO}.${DOMINIO_PUBLICO} | head -3
```

Criterio de aceptación: `HTTP/2 200` y `server: cloudflare`.

Y la comprobación que se repite en cada capítulo:

```bash
# [servidor]
docker ps --format '{{.Names}}\t{{.Ports}}'
```

Criterio de aceptación: la columna de puertos vacía para el proyecto nuevo.

### Paso 7 — Actualizaciones posteriores

```bash
# [servidor]
cd ~/nomad_server
./scripts/deploy.sh ${PROYECTO}
```

El script hace `git pull` si el proyecto es un repositorio, descarga o construye las imágenes,
levanta los servicios, espera a que estén sanos y **revierte si no lo consiguen**.

### Paso 8 — Estructura para un proyecto con código propio

Si el proyecto se construye desde su código fuente:

```bash
# [servidor]
cd ${DATOS_RAIZ}/${PROYECTO}
git clone <url-del-proyecto> codigo
```

Y en el compose, en lugar de `image:`:

```yaml
build:
  context: ./codigo
  dockerfile: Dockerfile
```

`deploy.sh` detecta el directorio `codigo/`, hace `git pull` dentro y reconstruye la imagen.

---

## 6. Script asociado

### 6.1 Vía A — con el script

`scripts/deploy.sh` es el que se usará a diario, mucho después de terminar este montaje.

```bash
# [servidor] — SIN sudo
cd ~/nomad_server
./scripts/deploy.sh --help
./scripts/deploy.sh mi-proyecto --check
./scripts/deploy.sh mi-proyecto
```

**El nombre del proyecto se pasa como argumento, no como variable de entorno.** Es deliberado: así
no depende de que `PROYECTO` esté declarada, y un descuido no puede desplegar el proyecto
equivocado.

Qué hace, en orden:

1. Comprueba que el proyecto existe y que su `.env` tiene permisos 600.
2. Valida el fichero compose antes de tocar nada.
3. **Guarda el estado actual**: el commit de git y los identificadores de las imágenes en marcha.
4. Actualiza el código (`git pull`) si es un repositorio.
5. Descarga o construye las imágenes.
6. Levanta los servicios.
7. Espera a que todos estén `healthy` (hasta 120 segundos, ajustable con `--espera`).
8. **Si alguno no llega a estar sano, revierte** al commit anterior y vuelve a levantar.

```bash
# [servidor] — desplegar sin actualizar el código
./scripts/deploy.sh mi-proyecto --sin-pull

# [servidor] — reconstruir las imágenes desde cero
./scripts/deploy.sh mi-proyecto --construir

# [servidor] — dar más margen a un servicio que tarda en arrancar
./scripts/deploy.sh mi-proyecto --espera 300

# [servidor] — ver el estado de todos los proyectos
./scripts/deploy.sh --listar
```

### 6.2 Correspondencia entre el script y los pasos manuales

| Paso de la sección 5 | ¿Lo hace `deploy.sh`? | Nota |
|---|---|---|
| 0 — preparar la sesión | Sí | Carga la configuración por su cuenta |
| 1 — crear el directorio | **No** | Es la creación inicial del proyecto |
| 2 — copiar la plantilla | **No** | Cada proyecto tiene su compose |
| 3 — escribir el `.env` | **No** | Contiene secretos que solo tú conoces. Sí **comprueba** que tiene permisos `600` |
| 4 — registro DNS | **No** | Lo hace `11_cloudflared.sh --ruta` |
| 5 — desplegar | Sí | Valida, guarda el estado previo, levanta y espera a que esté sano |
| 6 — comprobar | Sí | Y **revierte** si algún servicio no llega a `healthy` |
| 7 — actualizaciones posteriores | Sí | Es su uso principal |
| 8 — proyecto con código propio | Sí, detecta `codigo/` | Hace `git pull` y reconstruye |

### 6.3 Si prefieres la vía manual

El equivalente completo de `deploy.sh` para un proyecto ya creado:

```bash
# [servidor]
cd ~/nomad_server && source scripts/lib/entorno.sh
PROYECTO=mi-proyecto
cd ${DATOS_RAIZ}/${PROYECTO}
```

```bash
# [servidor] — 1. guardar el estado actual, por si hay que volver
git -C codigo rev-parse HEAD 2>/dev/null > /tmp/${PROYECTO}-commit-anterior || true
docker compose images
```

```bash
# [servidor] — 2. validar antes de tocar nada
docker compose config >/dev/null && echo "COMPOSE VALIDO"
```

```bash
# [servidor] — 3. actualizar y levantar
git -C codigo pull 2>/dev/null || true
docker compose pull
docker compose up -d
```

```bash
# [servidor] — 4. esperar a que estén sanos
for i in $(seq 1 24); do
    estado="$(docker compose ps --format '{{.Health}}' | sort -u | tr '\n' ' ')"
    echo "  intento ${i}: ${estado}"
    case "${estado}" in *unhealthy*|*starting*) sleep 5 ;; *) break ;; esac
done
docker compose ps
```

```bash
# [servidor] — 5. si algo no está sano, volver atrás
git -C codigo checkout "$(cat /tmp/${PROYECTO}-commit-anterior)"
docker compose up -d --force-recreate
```

Lo que asumes al hacerlo a mano: los cinco pasos anteriores, y sobre todo **acordarte de respaldar
antes de un despliegue que migre datos** (§ 3.4 del capítulo [15](15_mantenimiento_y_actualizaciones.md)).

**Sobre la reversión automática**, conviene ser preciso: revierte el *código y la configuración* al
commit anterior. **No revierte migraciones de base de datos.** Si un despliegue ha migrado el
esquema y falla después, la reversión deja código antiguo con datos nuevos. Para eso está el
respaldo del capítulo 14, y por eso el script recomienda respaldar antes de un despliegue que
incluya migraciones.

---

## 7. Validación

```bash
# [servidor]
cd ${DATOS_RAIZ}/${PROYECTO} && docker compose ps --format 'table {{.Name}}\t{{.State}}\t{{.Status}}'
```

Criterio de aceptación: todos los servicios `running` y `(healthy)`.

```bash
# [servidor] — permisos del archivo de variables
find ${DATOS_RAIZ} -name '.env' -exec stat -c '%n %a' {} \;
```

Criterio de aceptación: todos con `600`.

```bash
# [servidor] — ningún proyecto publica puertos
docker ps --format '{{.Names}}\t{{.Ports}}' | grep '0.0.0.0' && echo "REVISAR" || echo "CORRECTO"
```

Criterio de aceptación: `CORRECTO`.

```bash
# [servidor] — la base de datos no está en la red compartida
docker inspect ${PROYECTO}-db --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'
```

Criterio de aceptación: **no aparece** `${DOCKER_RED_PROXY}`.

```bash
# [servidor] — todos los servicios tienen healthcheck
docker ps --format '{{.Names}}' | while read -r c; do
    printf '%-28s %s\n' "$c" "$(docker inspect "$c" --format '{{if .Config.Healthcheck}}sí{{else}}NO{{end}}')"
done
```

Criterio de aceptación: `sí` en todos.

```bash
# [cliente] — respuesta desde internet con las cabeceras de seguridad
curl -sI https://${PROYECTO}.${DOMINIO_PUBLICO} | grep -iE 'HTTP/|x-frame|x-content'
```

Criterio de aceptación: `HTTP/2 200`, `x-frame-options: DENY`, `x-content-type-options: nosniff`.

```bash
# [servidor] — ningún secreto se ha colado en git
cd ${DATOS_RAIZ}/${PROYECTO} && git status --porcelain 2>/dev/null | grep -c '\.env$' || echo "0 (correcto)"
```

Criterio de aceptación: `0`.

**Prueba de reinicio:** `sudo reboot` y comprobar que el proyecto vuelve solo y responde por su
subdominio sin intervención.

---

## 8. Reversión

```bash
# [servidor] — parar un proyecto conservando sus datos
cd ${DATOS_RAIZ}/${PROYECTO} && docker compose down
```

```bash
# [servidor] — volver a la versión anterior del código
cd ${DATOS_RAIZ}/${PROYECTO}/codigo
git log --oneline -5
git checkout <commit-anterior>
cd .. && docker compose up -d --force-recreate
```

```bash
# [servidor] — eliminar un proyecto por completo
# COMPROBACIÓN OBLIGATORIA antes de un rm -rf con una variable dentro:
[ -n "${PROYECTO}" ] && [ -d "${DATOS_RAIZ}/${PROYECTO}" ] \
  && echo "Se va a borrar: ${DATOS_RAIZ}/${PROYECTO}" \
  || echo "PARA: PROYECTO vacío o el directorio no existe"
```

```bash
# [servidor] — y solo si la línea anterior mostró la ruta correcta
cd ${DATOS_RAIZ}/${PROYECTO}
docker compose down
cd .. && rm -rf "${PROYECTO}"
```

> `rm -rf` **borra también `datos/` y `datos-db/`**, es decir, todo el contenido del proyecto.
> Respalda antes si hay algo que conservar:
>
> ```bash
> sudo ./scripts/14_restic.sh --ahora
> ```
>
> Y fíjate en que `"${PROYECTO}"` va entrecomillado y el `cd ..` es previo: si `PROYECTO` estuviera
> vacía, `rm -rf ""` no borra nada, mientras que `rm -rf ${DATOS_RAIZ}/${PROYECTO}` sin comillas y
> con la variable vacía borraría **todo `${DATOS_RAIZ}`**. La comprobación de arriba existe
> precisamente por eso.

Elimina también el registro DNS del subdominio en el panel de Cloudflare, o quedará apuntando a un
servicio que ya no existe.

---

## 9. Errores frecuentes

| Síntoma | Causa probable | Solución | Documentación |
|---|---|---|---|
| Error 502 desde internet | El contenedor no está en la red `${DOCKER_RED_PROXY}`, o el puerto de la etiqueta no coincide | Comprueba `docker network inspect ${DOCKER_RED_PROXY}` y `loadbalancer.server.port` | Capítulo [10](10_traefik.md) |
| Error 404 desde internet | Traefik no tiene router para ese host: falta `traefik.enable=true` o el `rule` está mal | Revisa las etiquetas y el panel de Traefik | Capítulo [10](10_traefik.md) |
| Un proyecto «pisa» a otro | Dos proyectos usan el mismo nombre de router o de servicio | Prefija con el nombre del proyecto | § 5 paso 2 |
| «Permission denied» al escribir en `./datos` | El contenedor corre con un UID distinto al dueño del directorio | Averigua el UID con `docker exec <c> id` y ajusta: `sudo chown -R <uid>:<gid> datos/` | § 3.3 |
| El contenedor arranca y se para en bucle | Falta una variable en `.env`, o un error de configuración | `docker compose logs --tail 100 <servicio>` | [Docker Compose](https://docs.docker.com/compose/) |
| El healthcheck nunca pasa a `healthy` | El comando de comprobación no existe en la imagen (p. ej. `curl` en Alpine) | Usa `wget -q --spider` en Alpine, o instálalo en la imagen | § 3.6 |
| `docker compose up` avisa de variables no definidas | Falta `.env`, o una variable sin valor | `cp .env.example .env` y rellénalo | § 5 paso 3 |
| Tras `docker compose pull` la base de datos no arranca | Se usaba `latest` y llegó una versión mayor con otro formato de datos | Fija la versión mayor. Restaura desde el respaldo si hace falta | § 3.5 |
| El subdominio no resuelve | Falta el registro DNS | `./scripts/11_cloudflared.sh --ruta <proyecto>` | Capítulo [11](11_cloudflared_y_dominio.md) |
| El proyecto se ve desde toda la LAN | Se añadió un `ports:` al compose | Quítalo y usa un túnel SSH para depurar | § 3.2 |
| Se perdieron los datos al recrear el contenedor | Los datos estaban dentro del contenedor, sin montaje | Todo lo persistente debe estar en `./datos` o `./datos-db` | § 3.1 |
| Un proyecto llega a la base de datos de otro | Ambas bases de datos están en la red `proxy` | Ponlas en una red `interna` por proyecto | § 3.7 |
| Se creó el proyecto en `/mi-proyecto`, en la raíz | `${DATOS_RAIZ}` vacía: el entorno no estaba cargado | Muévelo a su sitio, carga el entorno y repite | § 5 paso 1 |
| Un `rm -rf` borró más de lo previsto | `${PROYECTO}` estaba vacía | Restaura desde el respaldo. La comprobación de la § 8 existe para esto | § 8 |
| `docker compose config` muestra `Host(\`${DOMINIO_PUBLICO}\`)` sin sustituir | La variable no está ni en el entorno ni en el `.env` del proyecto | Añádela al `.env`, o renderiza el compose con `nomad_plantilla` | § 5 paso 2 |
| El healthcheck de Postgres falla siempre | Se quitó el `$$` de `$${POSTGRES_USER}` | Restaura el doble dólar | § 5 paso 2 |
| Volví al día siguiente y los comandos usan rutas raras | `PROYECTO` y el entorno se perdieron al desconectar | Vuelve a declarar ambos (paso 1) | § 4.2 |
| `deploy.sh` no encuentra el proyecto | El nombre pasado como argumento no coincide con el directorio | `./scripts/deploy.sh --listar` | § 6.1 |

---

## 10. Referencias

- [Docker Compose — Especificación del fichero](https://docs.docker.com/reference/compose-file/)
- [Docker Compose — Healthchecks](https://docs.docker.com/reference/compose-file/services/#healthcheck)
- [Docker — Redes](https://docs.docker.com/engine/network/)
- [Docker — Montajes de directorio](https://docs.docker.com/engine/storage/bind-mounts/)
- [Traefik — Enrutado con Docker](https://doc.traefik.io/traefik/routing/providers/docker/)
- [Docker — Buenas prácticas de seguridad](https://docs.docker.com/engine/security/)
- [Docker Compose — Interpolación de variables](https://docs.docker.com/reference/compose-file/interpolation/)
- [templates/README.md](../templates/README.md) — la plantilla de proyecto
- Anexo [98 — Variables, entorno y sesiones](98_variables_y_entorno.md) § 2.3, sobre variables temporales

---

**Anterior:** [11 — Cloudflared y dominio](11_cloudflared_y_dominio.md) · **Siguiente:** [13 — Observabilidad](13_observabilidad.md)
