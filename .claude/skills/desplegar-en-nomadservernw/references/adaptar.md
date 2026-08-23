# Adaptar un proyecto al contrato

El objetivo es un `docker-compose.yml` **autónomo** que pase
`revisar_proyecto.sh` por sí solo, sin superposiciones ni variables de tu shell.

## El repositorio va dentro del proyecto, no al revés

```
${DATOS_RAIZ}/<proyecto>/
├── docker-compose.yml    copia de deploy/nomad/docker-compose.yml
├── .env                  copia de .env.example, 600, solo en el servidor
├── datos/                lo que la aplicación escribe
├── datos-db/             lo que escribe el motor de base de datos
└── codigo/               el repositorio clonado
```

Esto no es cosmético. `revisar_proyecto.sh` ejecuta `docker compose config`
**dentro del directorio del proyecto**, sin `-f` y sin superposiciones. Si el
repositorio estuviera ahí, Compose cargaría antes su `compose.yaml` de
desarrollo —con `ports:`, con volúmenes con nombre— y la auditoría fallaría
siempre, por mucho que el compose de producción fuera perfecto.

La consecuencia a recordar: `git pull` actualiza `codigo/`, **no** el
`docker-compose.yml` que vive un nivel por encima. Cada vez que cambie hay que
volver a copiarlo, y conviene decirlo en el README del proyecto.

En el repositorio, todo esto vive en `deploy/nomad/`:

```
deploy/nomad/
├── docker-compose.yml
├── .env.example
├── pre-respaldo-<motor>.sh
└── README.md              el procedimiento, para no depender de esta skill
```

## Las nueve reglas y cómo se cumplen

| # | Regla | Cómo |
|---|---|---|
| 1 | Sin `ports:` | Traefik alcanza el contenedor por la red `proxy` |
| 2 | Sin socket de Docker | Ningún servicio lo monta |
| 3 | Datos en `./datos/` | Bind mounts relativos. Cero volúmenes con nombre |
| 4 | Imágenes con versión fija | Etiqueta concreta también en la que construyes |
| 5 | Healthcheck en todo servicio | **En el compose**, no en el Dockerfile |
| 6 | Secretos en `.env` 600 | `.env.example` versionado, `.env` no |
| 7 | Lo no publicado, en red interna | La base de datos solo en `interna: internal: true` |
| 8 | Routers únicos y prefijados | El nombre del proyecto en el router y en `container_name` |
| 9 | Gancho de volcado si hay base | Plantilla por motor en `templates/etc/` |

Añade además `restart: unless-stopped` y `security_opt: no-new-privileges:true`
en todos los servicios: el auditor los avisa y son gratis.

### Regla 5, la que más se incumple sin darse cuenta

Un `HEALTHCHECK` del Dockerfile **no aparece** en
`docker compose config --format json`, que es lo que mira el auditor. Aunque la
imagen lo traiga, el servicio cuenta como sin healthcheck. Decláralo en el
compose.

Y que compruebe algo real: un proceso colgado sigue existiendo. Pide una página
que toque la base de datos, no un `CMD true`.

`start_period` merece que lo midas. Si tu entrypoint espera al motor y aplica
migraciones, el arranque frío puede irse a un minuto largo; con un margen corto,
`deploy.sh` revierte un despliegue correcto.

### Regla 3, y lo que arrastra

Cambiar volúmenes con nombre por bind mounts tiene un efecto que no está en el
contrato: **un volumen con nombre hereda el propietario de la imagen; un bind
mount llega con el uid de quien creó el directorio en el anfitrión.** Si la
aplicación no corre como root, deja de poder escribir.

Arréglalo en el entrypoint, que corre como root antes de ceder el control:

```sh
if [ "$(id -u)" = "0" ]; then
    mkdir -p <los directorios que la app espera>
    chown -R <usuario-de-la-app> <rutas de datos>
fi
```

Hacerlo en el arranque y no en la instalación tiene la ventaja de que sobrevive
a que alguien recree el directorio a mano.

## El compose de referencia

Parte de `templates/compose/proyecto-ejemplo/docker-compose.yml` y del § 3 del
contrato. Los puntos donde se equivoca la gente:

```yaml
services:
  app:
    build:
      context: ./codigo          # el repositorio, un nivel por debajo
    image: <proyecto>:prod       # etiqueta concreta aunque la construyas tú
    container_name: <proyecto>   # el auditor comprueba este prefijo
    restart: unless-stopped
    volumes:
      - ./datos/<subdir>:<ruta en el contenedor>
    networks: [proxy, interna]
    security_opt: [no-new-privileges:true]
    healthcheck: { ... }         # en el compose, no en la imagen
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.<proyecto>.rule=Host(`${APP_HOST:?…}`)"
      - "traefik.http.routers.<proyecto>.entrypoints=web"
      - "traefik.http.routers.<proyecto>.middlewares=publico@file"
      - "traefik.http.services.<proyecto>.loadbalancer.server.port=<puerto interno>"

  db:
    image: <motor>:<versión fija>
    container_name: <proyecto>-db
    volumes:
      - ./datos-db:<ruta de datos del motor>
    networks: [interna]          # SOLO interna
    labels:
      - "traefik.enable=false"

networks:
  proxy:
    external: true
    name: ${PROXY_NETWORK:-<valor real de DOCKER_RED_PROXY>}
  interna:
    internal: true
```

Usa la forma `${VAR:?mensaje}` para lo que no tiene default razonable: si falta,
`docker compose config` falla con un mensaje claro en vez de arrancar mal.

### Nombres de router

Son **globales en todo el servidor**. Dos proyectos con un router llamado `web`
y el segundo se lleva el tráfico del primero sin decir nada. Prefija siempre con
el nombre del proyecto, y lo mismo con `container_name`: el auditor comprueba que
el contenedor que reclama un router empiece por el nombre del proyecto.

## El `.env.example`

Va versionado, con valores ficticios y un comentario por variable. Reglas que no
son obvias:

- **El centinela de "sustitúyeme" no puede aparecer en un comentario.** El
  auditor busca `CAMBIAME` con un `grep` sobre el archivo **entero**. Un
  `.env.example` cuya cabecera diga «sustituye los CAMBIAME» deja la revisión
  fallando para siempre, aunque todos los valores estén rellenos.
- Genera las contraseñas, no las inventes: `openssl rand -hex 32`. Usa hex y no
  base64 si la contraseña va dentro de una URL de conexión: el `+`, el `/` y el
  `=` de base64 la parten, y el error resultante habla de credenciales.
- Deja ya puestos los valores que salen de `servidor.env` —la red, la subred de
  proxies de confianza, el host— para que quien despliegue no tenga que
  buscarlos. Y añade el comando para contrastarlos.

## El gancho de volcado

Copiar el directorio de datos de un motor en marcha **no produce un respaldo
restaurable**, y la prueba de restauración no lo detecta porque compara
archivos. Parte de la plantilla del motor en `templates/etc/` y ajusta el
contenedor, la base y el nombre del proyecto.

La contraseña no se escribe en el gancho: se lee del entorno del propio
contenedor, que ya la tiene. Así el archivo no es un secreto más que custodiar.

El nombre del archivo instalado **tiene que contener el nombre del proyecto**:
el auditor lo busca con `*<proyecto>*`.

## Antes de dar la adaptación por terminada

Levanta el stack con el layout de producción y comprueba, dentro del
contenedor, que la aplicación puede **escribir** en cada ruta de datos. Que
responda la portada no lo demuestra: los fallos de permisos aparecen la primera
vez que alguien sube algo, no en el arranque.
