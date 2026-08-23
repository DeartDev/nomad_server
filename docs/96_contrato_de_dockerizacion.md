# 96 · Contrato de dockerización

> **Para quién es este documento.** Para quien construye un proyecto que va a desplegarse en este
> servidor. No hace falta haber leído el resto de la documentación: aquí está todo lo que el
> proyecto tiene que cumplir, y el porqué de cada regla.
>
> Si vienes de fuera y solo quieres la lista, ve a la [§ 1](#1-lo-innegociable). Si quieres entender
> por qué el servidor exige esto, sigue leyendo en orden.

---

## 0. Qué te da el servidor y qué esperas de ti

El servidor resuelve, **de una vez para todos los proyectos**, cuatro cosas que normalmente cada
aplicación se monta por su cuenta:

| Lo resuelve el servidor | Lo que eso significa para tu proyecto |
|---|---|
| **Publicación en internet** | No abres puertos, no configuras nada de red pública. Un túnel de Cloudflare entrega el tráfico hacia dentro |
| **Certificados y HTTPS** | No gestionas certificados. El TLS termina en el borde de Cloudflare; tu contenedor habla HTTP en claro |
| **Enrutado por nombre** | No hay un servidor web delante que configurar. Traefik lee unas etiquetas de tu compose y enruta |
| **Respaldo y restauración** | Todo lo que dejes en el directorio del proyecto se respalda cifrado y fuera de casa cada noche |

A cambio, tu proyecto tiene que estar construido de una manera concreta. No es un capricho de
estilo: cada regla existe porque su alternativa rompe algo, y en la [§ 8](#8-por-qué-cada-regla)
está explicado cuál.

**Todos los proyectos se publican en un subdominio de `nordirwork.com`.** El dominio a secas queda
reservado para un único proyecto principal, que se configura igual salvo por el nombre de host.

---

## 1. Lo innegociable

Un proyecto se puede desplegar aquí si, y solo si, cumple estas nueve reglas:

| # | Regla | Se comprueba con |
|---|---|---|
| 1 | **No publica puertos.** Ninguna sección `ports:` en ningún servicio | `revisar_proyecto.sh` |
| 2 | **No monta el socket de Docker.** Ni siquiera en solo lectura | `revisar_proyecto.sh` |
| 3 | **Los datos van en `./datos/`**, dentro del directorio del proyecto. Nada de volúmenes con nombre | `revisar_proyecto.sh` |
| 4 | **Todas las imágenes con versión fija.** Nunca `:latest`, nunca sin etiqueta | `revisar_proyecto.sh` |
| 5 | **Todo servicio declara `healthcheck`** | `revisar_proyecto.sh` |
| 6 | **Los secretos van en `.env`**, con permisos `600` y fuera de git | `revisar_proyecto.sh` |
| 7 | **Lo que no se publica va en red interna**, sin acceso a `proxy` | `revisar_proyecto.sh` |
| 8 | **Nombres de router únicos en todo el servidor**, prefijados con el nombre del proyecto | `revisar_proyecto.sh` |
| 9 | **Si hay base de datos, hay gancho de volcado** antes del primer respaldo | `revisar_proyecto.sh` |

```bash
# [servidor] — la comprobación completa, antes de desplegar
./scripts/revisar_proyecto.sh <nombre-del-proyecto>
```

No sigas si eso no sale limpio. Cada punto que quede es algo que fallará más tarde y con peor
información.

---

## 2. Estructura del proyecto

```
/srv/nomad/<proyecto>/
├── docker-compose.yml     ← versionado
├── .env.example           ← versionado, con valores ficticios
├── .env                   ← NO versionado, permisos 600, solo en el servidor
├── .gitignore             ← debe contener .env
├── datos/                 ← datos de la aplicación (se respalda)
├── datos-db/              ← datos del motor de base de datos (ver § 6)
└── codigo/                ← opcional, si el proyecto se construye desde fuente
```

El nombre del directorio **es** el nombre del proyecto para `deploy.sh`, y conviene que coincida con
el subdominio: si publicas en `tienda.nordirwork.com`, llama al directorio `tienda`.

```bash
# [servidor]
PROYECTO=tienda
mkdir -p /srv/nomad/${PROYECTO}/{datos,datos-db}
```

---

## 3. El `docker-compose.yml` de referencia

Los ejemplos usan los valores de este servidor. Si trabajas en otro, imprime los tuyos y sustituye:

```bash
# [servidor]
cd ~/nomad_server && source scripts/lib/entorno.sh
cat <<VALORES
  Red compartida  : ${DOCKER_RED_PROXY}
  Dominio público : ${DOMINIO_PUBLICO}
  Directorio raíz : ${DATOS_RAIZ}
  Dominio interno : ${SERVIDOR_HOSTNAME}.${SERVIDOR_DOMINIO_LOCAL}
VALORES
```


Este es el esqueleto. Todo lo marcado con `CAMBIAR` es tuyo; el resto es el contrato.

```yaml
services:

  # -----------------------------------------------------------------------
  #  Aplicación — el único servicio que Traefik publica
  # -----------------------------------------------------------------------
  web:
    # CAMBIAR: tu imagen, SIEMPRE con versión concreta.
    image: miorganizacion/tienda:1.4.2

    # O, si se construye desde el código del propio repositorio:
    # build:
    #   context: ./codigo
    #   dockerfile: Dockerfile

    container_name: tienda          # CAMBIAR: prefijo del proyecto
    restart: unless-stopped

    env_file:
      - .env

    volumes:
      # Rutas relativas al directorio del proyecto. Nunca rutas absolutas del
      # anfitrión, y nunca volúmenes con nombre.
      - ./datos:/app/datos

    networks:
      - proxy       # para que Traefik la alcance
      - interna     # para hablar con su base de datos

    security_opt:
      - no-new-privileges:true

    # OBLIGATORIO. Ver § 5 para escribir uno que sirva.
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://localhost:3000/salud || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

    labels:
      - "traefik.enable=true"

      # CAMBIAR 'tienda' por el nombre de tu proyecto en las CUATRO líneas.
      # Ese nombre es global en todo el servidor: si dos proyectos usan el
      # mismo, el segundo pisa al primero sin decir nada.
      - "traefik.http.routers.tienda.rule=Host(`tienda.nordirwork.com`)"
      - "traefik.http.routers.tienda.entrypoints=web"
      - "traefik.http.routers.tienda.middlewares=publico@file"

      # CAMBIAR: el puerto en el que escucha TU aplicación dentro del
      # contenedor. No se publica en el anfitrión: solo se lo dices a Traefik.
      - "traefik.http.services.tienda.loadbalancer.server.port=3000"

  # -----------------------------------------------------------------------
  #  Base de datos — NO está en la red 'proxy': nadie de fuera la alcanza
  # -----------------------------------------------------------------------
  db:
    image: postgres:17-alpine       # CAMBIAR según tu motor, con versión fija
    container_name: tienda-db
    restart: unless-stopped

    env_file:
      - .env

    volumes:
      - ./datos-db:/var/lib/postgresql/data

    networks:
      - interna                     # SOLO interna

    security_opt:
      - no-new-privileges:true

    healthcheck:
      # El doble dólar es el escape de Compose: resuelve la variable el
      # CONTENEDOR, no Compose. No lo quites ni lo dupliques.
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s

    # Sin etiquetas de Traefik: esta base de datos no se publica de ninguna
    # manera, ni pública ni privada.

networks:
  # La crea el servidor. 'external' significa "ya existe, no la gestiono yo":
  # así 'docker compose down' de un proyecto no se lleva por delante la red
  # que comparten todos los demás.
  proxy:
    external: true
    name: nomadservernw_proxy

  # Esta sí es del proyecto. 'internal: true' significa SIN SALIDA A INTERNET:
  # la base de datos no puede llamar a casa aunque quiera.
  interna:
    internal: true
```

---

## 4. Enrutado: las tres formas

Cambia **solo** las tres líneas del router. El resto del compose es idéntico.

### 4.1 Público en un subdominio — el caso normal

```yaml
- "traefik.http.routers.tienda.rule=Host(`tienda.nordirwork.com`)"
- "traefik.http.routers.tienda.entrypoints=web"
- "traefik.http.routers.tienda.middlewares=publico@file"
```

Y **antes de desplegar**, crear el registro DNS:

```bash
# [servidor]
./scripts/11_cloudflared.sh --ruta tienda
```

### 4.2 Público en el dominio a secas — solo un proyecto

```yaml
- "traefik.http.routers.principal.rule=Host(`nordirwork.com`)"
- "traefik.http.routers.principal.entrypoints=web"
- "traefik.http.routers.principal.middlewares=publico@file"
```

```bash
# [servidor] — la arroba es el ápice, la convención de DNS
./scripts/11_cloudflared.sh --ruta @
```

> Si además quieres que `www.nordirwork.com` lleve al mismo sitio, añade el registro
> (`--ruta www`) y amplía la regla: ``Host(`nordirwork.com`) || Host(`www.nordirwork.com`)``.

### 4.3 Privado — herramientas internas

Sin registro DNS público y sin pasar por Cloudflare. Se llega por túnel SSH o desde la tailnet:

```yaml
- "traefik.http.routers.panel.rule=Host(`panel.nomadservernw.lan`)"
- "traefik.http.routers.panel.entrypoints=interna"
- "traefik.http.routers.panel.middlewares=interno@file"
```

### 4.4 Qué hacen las cadenas de middlewares

| Cadena | Contiene | Cuándo |
|---|---|---|
| `publico@file` | Cabeceras de seguridad + compresión | Todo lo que sale a internet |
| `interno@file` | Lo anterior **+ filtro por rango de red** | Herramientas de operación |

No las redefinas en tu proyecto: están declaradas una vez en Traefik y se aplican por nombre. Si tu
proyecto necesita algo más —un límite de peticiones estricto en un formulario de acceso, por
ejemplo— se encadena:

```yaml
- "traefik.http.routers.tienda.middlewares=publico@file,limite-estricto@file"
```

---

## 5. Healthchecks que sirven

Es la regla que más se cumple mal, porque es fácil escribir uno que siempre pasa.

**Un healthcheck que comprueba que el proceso existe no vale para nada**: un proceso colgado sigue
existiendo. Tiene que comprobar que la aplicación **responde y funciona**.

```yaml
# MAL: el contenedor está "sano" aunque la aplicación no responda
test: ["CMD", "true"]
test: ["CMD-SHELL", "ps aux | grep -q node"]

# BIEN: pide algo real y comprueba la respuesta
test: ["CMD-SHELL", "wget -q -O /dev/null http://localhost:3000/salud || exit 1"]
```

Tres cosas que fallan de forma recurrente:

- **`--spider` no es un `GET`, es un `HEAD`.** Muchas APIs lo rechazan y el healthcheck falla sin que
  nada esté roto. Usa `wget -q -O /dev/null`.
- **`curl` no existe en las imágenes Alpine.** `wget` sí. Comprueba qué hay en tu imagen antes de
  darlo por hecho: `docker run --rm <imagen> sh -c 'command -v wget curl'`.
- **Hay imágenes mínimas sin shell.** Si `CMD-SHELL` falla con *executable file not found*, tu
  imagen no tiene `/bin/sh`; usa la forma `CMD` con el binario de la aplicación, si trae uno.

**`start_period` es lo que evita los falsos negativos al arrancar.** Una aplicación que tarda 40
segundos en levantar con un `start_period: 10s` se marcará como enferma y `deploy.sh` revertirá un
despliegue correcto. Mide cuánto tarda la tuya y pon un margen.

---

## 6. Bases de datos

**Copiar el directorio de datos de un motor en marcha no produce un respaldo restaurable.** Puede
arrancar, puede arrancar con corrupción, o puede no arrancar. Por eso, todo proyecto con base de
datos instala un **gancho de volcado** que corre antes del respaldo nocturno:

```bash
# [servidor] — hay una plantilla por motor
cd ~/nomad_server && source scripts/lib/entorno.sh
sudo mkdir -p /etc/nomad/pre-respaldo.d

nomad_plantilla etc/pre-respaldo-postgres.sh \
    | sudo tee /etc/nomad/pre-respaldo.d/10-tienda-postgres.sh >/dev/null
sudo chmod 700 /etc/nomad/pre-respaldo.d/10-tienda-postgres.sh
sudo vim /etc/nomad/pre-respaldo.d/10-tienda-postgres.sh    # ajusta las variables

# Y pruébalo antes de fiarte de él
sudo /etc/nomad/pre-respaldo.d/10-tienda-postgres.sh && echo CORRECTO
```

| Motor | Plantilla |
|---|---|
| PostgreSQL | `etc/pre-respaldo-postgres.sh` |
| MySQL / MariaDB | `etc/pre-respaldo-mysql.sh` |
| MongoDB | `etc/pre-respaldo-mongodb.sh` |
| Redis | Sin plantilla: decisión propia, ver capítulo [14](14_respaldos_restic.md) § 3.4 |

**Y una consecuencia que hay que tener presente al restaurar:** la base de datos no se recupera
devolviendo `datos-db` a su sitio, sino creando el contenedor vacío y cargando el volcado. Está en
el capítulo [16](16_recuperacion_ante_desastres.md), fase 5b.

---

## 7. Secretos

```bash
# [servidor]
cp .env.example .env
chmod 600 .env
vim .env
```

- **`.env.example` va versionado**, con valores ficticios y un comentario por variable.
- **`.env` nunca se versiona.** Debe estar en `.gitignore`.
- **Genera las contraseñas, no las inventes:** `openssl rand -base64 32`.
- **Si la contraseña va dentro de una URL** —`postgresql://usuario:clave@db:5432/base`— usa
  `openssl rand -hex 32`. Base64 produce `+`, `/` y `=`, que en una URL significan otra cosa y la
  parten. El fallo resultante engaña: la aplicación no conecta y el error habla de credenciales.

---

## 8. Por qué cada regla

No son convenciones de estilo. Esto es lo que rompe cada una:

| Regla | Qué pasa si no se cumple |
|---|---|
| Sin `ports:` | Docker inserta sus propias reglas y **se salta el cortafuegos**: el puerto queda accesible desde la LAN aunque nftables no lo abra |
| Sin socket de Docker | Acceso al socket es **acceso de root al anfitrión**, aunque sea `:ro`. Un contenedor comprometido se convierte en el servidor comprometido |
| Datos en `./datos/` | El respaldo recoge el directorio del proyecto. Un volumen con nombre vive en `/var/lib/docker` y **no se respalda** |
| Versión fija | Con `latest`, un despliegue rutinario trae una versión nueva sin avisar y el mismo compose da resultados distintos según el día |
| Healthcheck | Sin él, un contenedor colgado parece «en marcha». `deploy.sh` lo usa para decidir si revertir: sin healthcheck, **nunca revierte** |
| `.env` con 600 | Contraseñas legibles por cualquier usuario del sistema, y versionadas si además falta el `.gitignore` |
| Red interna | Una base de datos en la red `proxy` es alcanzable por **todos los demás proyectos** del servidor |
| Router único | Los nombres de router son globales. Dos proyectos con `web` y el segundo se lleva el tráfico del primero, en silencio |
| Gancho de volcado | El respaldo guarda un directorio de datos copiado en caliente: **no se puede restaurar**, y la prueba de restauración no lo detecta porque compara archivos |

---

## 9. Despliegue, en orden

El orden importa. Cada paso comprueba algo que el siguiente da por hecho.

```bash
# [servidor]
cd ~/nomad_server && source scripts/lib/entorno.sh
PROYECTO=tienda
```

**1. Auditar antes de nada.**

```bash
./scripts/revisar_proyecto.sh ${PROYECTO}
```

**2. Crear el registro DNS** —antes de desplegar, no después.

```bash
./scripts/11_cloudflared.sh --ruta ${PROYECTO}
dig +short ${PROYECTO}.nordirwork.com
```

Devolverá **direcciones IP de Cloudflare**, no el nombre del túnel: el registro es proxificado, que
es lo correcto y necesario.

**3. Instalar el gancho de volcado**, si hay base de datos (§ 6).

**4. Simular el despliegue.**

```bash
./scripts/deploy.sh ${PROYECTO} --check
```

**5. Desplegar.**

```bash
./scripts/deploy.sh ${PROYECTO}
```

`deploy.sh` guarda el estado actual, actualiza el código, levanta, espera a que los servicios estén
sanos y **revierte solo si no lo consiguen**.

**6. Comprobar desde fuera.**

```bash
curl -sS -o /dev/null -m 15 -w 'HTTP %{http_code}\n' https://${PROYECTO}.nordirwork.com/
curl -sSI https://${PROYECTO}.nordirwork.com/ | grep -iE 'x-frame|x-content|referrer'
```

Criterio: `200`, y las cabeceras de seguridad presentes. Si llegan las cabeceras, el middleware
`publico@file` se está aplicando de verdad y no solo la página carga.

**7. Añadir su monitor** en Uptime Kuma: tipo HTTP(s), la URL pública, intervalo 60 s.

---

## 10. Errores frecuentes

| Síntoma | Causa | Solución |
|---|---|---|
| El contenedor está sano y el sitio da `404` | Falta el registro DNS, o el `Host()` de la etiqueta no coincide con el nombre real | `dig +short <host>` y comparar con la etiqueta |
| El sitio da `502` | Traefik no alcanza el contenedor: no está en la red `proxy`, o el puerto de `loadbalancer.server.port` no es el que escucha | `docker compose ps` y revisar el puerto |
| Carga la página pero las llamadas a `/api` dan `404` | Colisión con el router del panel de Traefik | Comprobar que Traefik tiene `traefik.http.routers.panel.priority=1` |
| El despliegue revierte siempre | El `healthcheck` nunca pasa a `healthy` | `docker inspect -f '{{json .State.Health}}' <contenedor>` |
| Arranca bien y a los 40 s revierte | `start_period` demasiado corto | Medir el arranque real y ampliarlo |
| Otro proyecto dejó de responder tras desplegar este | Nombre de router repetido | Prefijar con el nombre del proyecto y volver a desplegar los dos |
| `.env` versionado por error | Falta en `.gitignore` | Añadirlo, `git rm --cached .env`, y **rotar los secretos**: ya están en el histórico |

---

## 11. Referencias

- Capítulo [12](12_despliegue_de_proyectos.md) — el procedimiento completo, paso a paso
- Capítulo [10](10_traefik.md) — enrutado, middlewares y por qué no se toca el socket
- Capítulo [11](11_cloudflared_y_dominio.md) — el túnel y los registros DNS
- Capítulo [14](14_respaldos_restic.md) — respaldos y ganchos de volcado
- Plantilla de referencia: `templates/compose/proyecto-ejemplo/docker-compose.yml`
