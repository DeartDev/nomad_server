# 10 — Traefik

> El repartidor interno: recibe todo el tráfico y lo entrega al contenedor que corresponda, sin que
> haya que tocar su configuración cada vez que se añade un proyecto.

---

## 1. Objetivo

Al terminar tendrás Traefik enrutando por nombre de subdominio, descubriendo los contenedores
automáticamente a través de un intermediario de solo lectura del socket de Docker, con cabeceras de
seguridad aplicadas a todo el tráfico público, y su panel accesible únicamente desde tu red privada.

---

## 2. Requisitos previos

**Capítulos previos:** [09 — Docker](09_docker.md), con la red `${DOCKER_RED_PROXY}` creada.

**Necesitas a mano:**

- `docker ps` funcionando sin `sudo`.
- La IP de Tailscale del servidor, si quieres acceder al panel desde el móvil:
  `tailscale ip -4`.

**Tiempo estimado:** 30 minutos.

---

## 3. Decisiones y por qué

### 3.1 Traefik con descubrimiento automático

**Decisión: Traefik v3 con el proveedor de Docker.**

Traefik lee las etiquetas de los contenedores en marcha y construye sus rutas solo. Publicar un
proyecto nuevo se reduce a añadir cuatro líneas a su fichero compose:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.mi-app.rule=Host(`mi-app.midominio.com`)"
  - "traefik.http.routers.mi-app.entrypoints=web"
  - "traefik.http.services.mi-app.loadbalancer.server.port=3000"
```

**No hay que tocar la configuración de Traefik ni reiniciarlo.** Esa es toda la diferencia frente a
las alternativas.

| Alternativa descartada | Por qué |
|---|---|
| Caddy | Configuración más legible, pero cada proyecto obliga a editar el Caddyfile y recargar |
| Nginx Proxy Manager | Interfaz web cómoda, pero su estado vive en SQLite: no se versiona ni se reconstruye desde el repositorio |
| Nginx a mano | Máximo control, máximo mantenimiento. Un archivo por proyecto y un `nginx -t` en cada cambio |
| Declarar cada ruta en `cloudflared` | Cada proyecto nuevo obliga a reiniciar el túnel, afectando a todos los demás |

### 3.2 Intermediario del socket: por qué `:ro` no basta

**Decisión: Traefik no habla con `/var/run/docker.sock`, sino con un intermediario que solo permite
consultas.**

Traefik necesita preguntar a Docker qué contenedores hay. La forma habitual es montarle el socket:

```yaml
volumes:
  - /var/run/docker.sock:/var/run/docker.sock:ro
```

Y aquí está el malentendido más extendido de todo este montaje: **`:ro` no convierte la API de
Docker en solo lectura**. Impide *escribir en el archivo del socket*, que es una operación que nadie
hace. Las peticiones a la API —incluida `POST /containers/create`— siguen funcionando exactamente
igual.

Con acceso a esa API se puede arrancar un contenedor privilegiado que monte `/` del host. Es decir:
**quien controle Traefik controla el servidor entero**. Y Traefik es, por diseño, el proceso que más
expuesto está al tráfico de internet.

La solución es un intermediario —`docker-socket-proxy`— que se sitúa entre ambos y solo deja pasar
los puntos de la API que Traefik necesita:

```
Traefik ──▶ socket-proxy ──▶ /var/run/docker.sock
            (solo GET /containers)
```

El intermediario vive además en una red marcada como `internal: true`, sin salida a internet: aunque
alguien lo tomara, no podría hablar con el exterior.

Cuesta un contenedor de 4 MB. Es la mejor relación coste/beneficio de todo el capítulo.

### 3.3 El punto de entrada público no se publica

**Decisión: el puerto 80 de Traefik existe solo dentro de la red de contenedores.**

`cloudflared` y Traefik están en la misma red `${DOCKER_RED_PROXY}`, así que `cloudflared` alcanza
`http://traefik:80` por el DNS interno de Docker. Ese puerto **no existe en el host**: `ss -tulpn`
no lo muestra y un escaneo desde la LAN no lo encuentra.

El único puerto publicado es el **interno**, y va atado a `${TRAEFIK_BIND_INTERNA}`, nunca a
`0.0.0.0`:

| Valor | Quién llega | Cómo se accede |
|---|---|---|
| `127.0.0.1` | Solo el propio servidor | `ssh -L 8080:127.0.0.1:8080 nomad` y luego `http://localhost:8080/dashboard/` |
| IP de Tailscale (`100.x.y.z`) | Cualquier dispositivo de tu tailnet | `http://100.x.y.z:8080/dashboard/` directamente, también desde el móvil |

Empieza con `127.0.0.1` y cámbialo a la IP de Tailscale cuando quieras la comodidad. Ambas opciones
son privadas; la segunda además es cómoda.

### 3.4 Middlewares definidos una vez, aplicados en todas partes

**Decisión: definir los middlewares en un archivo y referenciarlos con `@file`.**

Los middlewares transforman las peticiones: añaden cabeceras, comprimen, limitan la frecuencia.
Definirlos en cada proyecto significaría copiar y pegar la misma configuración, y que cada uno
acabara con una versión distinta.

| Middleware | Qué hace | Dónde se aplica |
|---|---|---|
| `seguridad` | Cabeceras: `nosniff`, `frameDeny`, `Referrer-Policy`, `Permissions-Policy`, HSTS | Automático en todo el tráfico público |
| `compresion` | Comprime respuestas, saltando lo ya comprimido | Automático en todo el tráfico público |
| `limite-peticiones` | 100 peticiones por minuto | Por proyecto, cuando tenga sentido |
| `limite-estricto` | 10 por minuto, para formularios de acceso | Por proyecto |
| `solo-privada` | Solo desde LAN, Tailscale o la red de contenedores | Panel y herramientas de operación |
| `publico` / `interno` | Cadenas que combinan las anteriores | Atajos |

**Sobre HSTS**, que merece un aviso: `stsSeconds: 31536000` obliga al navegador a usar HTTPS durante
un año, y **es difícil de revertir**. Si un subdominio tuviera que servirse por HTTP, el navegador
se negaría durante todo ese tiempo. Por eso `includeSubDomains` queda desactivado: no arrastra a
subdominios que aún no existen.

### 3.5 TLS lo hace Cloudflare

**Decisión: Traefik habla HTTP en claro; no gestiona certificados.**

```
visitante ══HTTPS══▶ Cloudflare ══túnel cifrado══▶ cloudflared ──HTTP──▶ Traefik ──HTTP──▶ app
```

El tramo HTTP en claro va **dentro de la red de contenedores del propio servidor**: no sale de la
máquina. Los dos tramos que sí viajan por internet están cifrados.

| Alternativa descartada | Por qué |
|---|---|
| Let's Encrypt en Traefik con desafío HTTP | Requiere el puerto 80 abierto desde internet. Es justo lo que evita todo este diseño |
| Let's Encrypt con desafío DNS | Funcionaría sin abrir puertos, pero añade credenciales de API de Cloudflare en el servidor y un almacén de certificados que renovar y respaldar, para cifrar un tramo que no sale de la máquina |

Ventaja concreta: **no hay ningún certificado que renovar**. Una fuente clásica de caídas a los 90
días desaparece.

### 3.6 Versiones fijadas, nunca `latest`

**Decisión: `traefik:v3.7`, no `traefik:latest` ni `traefik:v3`.**

`latest` significa que un `docker compose pull` puede traer una versión mayor con cambios
incompatibles, y descubrirlo cuando el proxy que sirve todos tus proyectos no arranca.

Fijar la **línea menor** (`v3.7`) da el equilibrio correcto: se reciben parches de seguridad y
correcciones automáticamente, pero nunca un salto de versión mayor. La actualización a `v3.8` o a
`v4` se hace a mano, leyendo antes las notas de publicación (capítulo 15).

### 3.7 Registro de accesos filtrado

**Decisión: registrar solo errores (400–599) y peticiones que tarden más de un segundo.**

Un registro completo de accesos en un servidor con tráfico real llena el disco y, sobre todo, hace
imposible encontrar lo importante. Filtrando, cada línea del registro es un problema que merece
atención.

Se descartan además casi todas las cabeceras, conservando `User-Agent`, `X-Forwarded-For` y
`Cf-Connecting-Ip`: las tres que sirven para saber quién hizo una petición fallida.

---

## 4. Variables usadas

| Variable | Uso |
|---|---|
| `DATOS_RAIZ` | Directorio donde vive la configuración de Traefik |
| `DOCKER_RED_PROXY` | Red por la que Traefik alcanza los contenedores |
| `DOCKER_RED_PROXY_SUBRED` | IPs de confianza para las cabeceras reenviadas |
| `TRAEFIK_BIND_INTERNA` | Dirección donde se publica el punto de entrada interno |
| `TRAEFIK_PUERTO_INTERNA` | Puerto de ese punto de entrada en el host |
| `TRAEFIK_DASHBOARD_HOST` | Nombre para llegar al panel |
| `LAN_CIDR`, `TS_CIDR` | Redes permitidas en el middleware `solo-privada` |

---

## 5. Procedimiento

### Paso 1 — Prepara el directorio

```bash
# [servidor]
mkdir -p ${DATOS_RAIZ}/traefik/config/dinamica
cd ${DATOS_RAIZ}/traefik
```

### Paso 2 — Configuración estática

```bash
# [servidor]
vim ${DATOS_RAIZ}/traefik/config/traefik.yml
```

El contenido completo está en `templates/compose/traefik/traefik.yml`. Los puntos clave:

```yaml
entryPoints:
  web:                      # tráfico público, NO publicado en el host
    address: ":80"
    http:
      middlewares:
        - seguridad@file
        - compresion@file
  interna:                  # panel y herramientas, publicado en dirección privada
    address: ":8080"

providers:
  docker:
    endpoint: "tcp://socket-proxy:2375"   # nunca el socket directo
    exposedByDefault: false               # nada se publica sin pedirlo
    network: "proxy"
  file:
    directory: "/etc/traefik/dinamica"
    watch: true

api:
  dashboard: true
  insecure: false
```

`exposedByDefault: false` merece un momento: sin él, **cualquier contenedor nuevo quedaría publicado
automáticamente**, incluidos los que arranques para una prueba rápida. Con él, solo se enruta lo que
lleva `traefik.enable=true`.

### Paso 3 — Middlewares

```bash
# [servidor]
vim ${DATOS_RAIZ}/traefik/config/dinamica/middlewares.yml
```

El contenido está en `templates/compose/traefik/dinamica/middlewares.yml`. Este archivo se recarga
solo al guardarlo: no hace falta reiniciar Traefik.

### Paso 4 — Fichero compose

```bash
# [servidor]
vim ${DATOS_RAIZ}/traefik/docker-compose.yml
```

El contenido está en `templates/compose/traefik/docker-compose.yml`. Fíjate en tres cosas:

1. El servicio `traefik` **no publica el puerto 80**.
2. El único `ports:` está atado a `${TRAEFIK_BIND_INTERNA}`.
3. `socket-proxy` está en una red `internal: true`, sin salida a internet.

### Paso 5 — Levanta

```bash
# [servidor]
cd ${DATOS_RAIZ}/traefik
docker compose up -d
docker compose ps
```

Criterio de aceptación: los dos contenedores en estado `running` y, tras unos segundos, `healthy`.

```bash
# [servidor]
docker compose logs traefik | tail -30
```

Busca líneas `Configuration loaded from file` y ninguna de nivel `ERR`.

### Paso 6 — Comprueba que no se ha expuesto nada

```bash
# [servidor]
docker ps --format 'table {{.Names}}\t{{.Ports}}'
sudo ss -tulpn | grep LISTEN
```

Criterio de aceptación: el único puerto publicado es `${TRAEFIK_BIND_INTERNA}:${TRAEFIK_PUERTO_INTERNA}`,
y en el host solo escuchan SSH y ese puerto en su dirección privada. **Nada en `0.0.0.0` salvo
SSH.**

### Paso 7 — Abre el panel

**Si `TRAEFIK_BIND_INTERNA` es `127.0.0.1`:**

```bash
# [cliente]
ssh -L 8080:127.0.0.1:8080 nomad
```

Y en el navegador: <http://localhost:8080/dashboard/>

**Si es la IP de Tailscale:**

```bash
# [servidor]
tailscale ip -4
```

Y en el navegador, desde cualquier dispositivo de tu tailnet:
`http://100.x.y.z:8080/dashboard/`

> La barra final de `/dashboard/` **es obligatoria**. Sin ella Traefik devuelve un 404 y parece que
> el panel no funciona. Es la confusión número uno con Traefik.

En el panel deberías ver el router `panel`, el punto de entrada `interna` y los middlewares
cargados.

### Paso 8 — Prueba de enrutado

Levanta un contenedor de prueba para comprobar el descubrimiento automático:

```bash
# [servidor]
docker run -d --name prueba-traefik \
    --network ${DOCKER_RED_PROXY} \
    --label traefik.enable=true \
    --label 'traefik.http.routers.prueba.rule=Host(`prueba.local`)' \
    --label traefik.http.routers.prueba.entrypoints=web \
    --label traefik.http.services.prueba.loadbalancer.server.port=80 \
    traefik/whoami:latest
```

Y comprueba desde otro contenedor de la misma red, ya que el puerto 80 no existe en el host:

```bash
# [servidor]
docker run --rm --network ${DOCKER_RED_PROXY} curlimages/curl:latest \
    -s -H 'Host: prueba.local' http://traefik/
```

Criterio de aceptación: responde con la información del contenedor `whoami` (`Hostname`, `IP`,
`RemoteAddr`…).

Comprueba también que las cabeceras de seguridad se están aplicando:

```bash
# [servidor]
docker run --rm --network ${DOCKER_RED_PROXY} curlimages/curl:latest \
    -s -I -H 'Host: prueba.local' http://traefik/ | grep -iE 'x-frame|x-content|referrer'
```

Criterio de aceptación: aparecen `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff` y
`Referrer-Policy`.

Limpia:

```bash
# [servidor]
docker rm -f prueba-traefik
```

---

## 6. Script asociado

`scripts/10_traefik.sh` automatiza los pasos 1 a 6 y ejecuta la prueba del paso 8.

```bash
# [servidor]
cd ~/nomad_server
./scripts/10_traefik.sh --help
./scripts/10_traefik.sh --check
./scripts/10_traefik.sh
```

Comportamiento destacable:

- **No requiere root**: opera con el grupo `docker` sobre `${DATOS_RAIZ}`.
- Comprueba que la red `${DOCKER_RED_PROXY}` existe antes de nada.
- **Rechaza `TRAEFIK_BIND_INTERNA=0.0.0.0`**, que expondría el panel a toda la red.
- Si la dirección elegida es una IP de Tailscale, comprueba que existe en el sistema: Docker se
  niega a arrancar si intenta atarse a una dirección inexistente.
- Ejecuta la prueba de enrutado de extremo a extremo y falla si no responde.
- Comprueba al terminar que ningún contenedor publica en `0.0.0.0`.

En modo `--check` muestra las diferencias de los tres archivos de configuración y valida el fichero
compose con `docker compose config`, sin levantar nada.

---

## 7. Validación

```bash
# [servidor]
cd ${DATOS_RAIZ}/traefik && docker compose ps
```

Criterio de aceptación: `traefik` y `socket-proxy` en estado `running (healthy)`.

```bash
# [servidor] — ningún puerto en 0.0.0.0 salvo SSH
sudo ss -tulpn | grep LISTEN | grep '0.0.0.0' | grep -vc ':22'
```

Criterio de aceptación: `0`.

```bash
# [servidor] — el puerto 80 de Traefik no existe en el host
sudo ss -tlnp | grep -c ':80 ' || echo "0 (correcto)"
```

Criterio de aceptación: `0`.

```bash
# [servidor] — Traefik responde a su comprobación de salud
docker exec traefik traefik healthcheck --ping
```

Criterio de aceptación: `OK: http://:8080/ping`.

```bash
# [servidor] — el intermediario del socket permite consultar contenedores
docker exec traefik wget -qO- http://socket-proxy:2375/v1.24/containers/json | head -c 100
```

Criterio de aceptación: devuelve JSON.

```bash
# [servidor] — pero NO permite crear contenedores
docker exec traefik wget -qO- --post-data='{}' \
    http://socket-proxy:2375/v1.24/containers/create 2>&1 | head -2
```

Criterio de aceptación: responde `403 Forbidden`. **Esta es la comprobación que demuestra que el
intermediario está haciendo su trabajo.** Si devolviera otra cosa, revisa las variables de entorno
de `socket-proxy`.

```bash
# [servidor] — los middlewares están cargados
docker exec traefik wget -qO- http://localhost:8080/api/http/middlewares \
    | jq -r '.[].name' 2>/dev/null | sort
```

Criterio de aceptación: aparecen `seguridad@file`, `compresion@file`, `solo-privada@file` y las
cadenas.

```bash
# [servidor] — la red del intermediario no tiene salida a internet
docker network inspect ${DOCKER_RED_SOCKET} --format '{{.Internal}}'
```

Criterio de aceptación: `true`.

**Prueba de reinicio:** `sudo reboot` y comprobar que ambos contenedores vuelven solos y el panel
responde.

---

## 8. Reversión

```bash
# [servidor]
cd ${DATOS_RAIZ}/traefik
docker compose down
```

```bash
# [servidor] — eliminar también la configuración
docker compose down -v
cd ~ && rm -rf ${DATOS_RAIZ}/traefik
```

La red `${DOCKER_RED_PROXY}` **no se borra** con `docker compose down` porque está declarada como
externa. Es deliberado: otros proyectos dependen de ella.

**Para volver atrás solo un cambio de configuración:** los archivos que escribe el script tienen
copia en `<archivo>.bak-<fecha>`. Restaura y reinicia:

```bash
# [servidor]
cd ${DATOS_RAIZ}/traefik
cp config/traefik.yml.bak-* config/traefik.yml
docker compose restart traefik
```

---

## 9. Errores frecuentes

| Síntoma | Causa probable | Solución | Documentación |
|---|---|---|---|
| El panel devuelve 404 | Falta la barra final en `/dashboard/` | Usa `http://…/dashboard/` con barra | [Traefik — Dashboard](https://doc.traefik.io/traefik/operations/dashboard/) |
| Traefik no arranca: «cannot assign requested address» | `TRAEFIK_BIND_INTERNA` apunta a una IP que no existe en el host | Comprueba con `ip -br addr`. Si es la de Tailscale, la VPN debe estar levantada antes | Capítulo [08](08_tailscale.md) |
| Traefik no ve ningún contenedor | El intermediario del socket no responde, o falta `traefik.enable=true` | `docker logs socket-proxy` y `docker exec traefik wget -qO- http://socket-proxy:2375/v1.24/containers/json` | § 3.2 |
| «Gateway Timeout» al llegar a un proyecto | El contenedor no está en la red `${DOCKER_RED_PROXY}`, o el puerto de la etiqueta es incorrecto | `docker network inspect ${DOCKER_RED_PROXY}` y revisa `loadbalancer.server.port` | [Traefik — Docker](https://doc.traefik.io/traefik/providers/docker/) |
| Un contenedor aparece publicado sin querer | `exposedByDefault` no está en `false` | Revisa la configuración estática (§ 3.2, paso 2) | [Traefik — Docker](https://doc.traefik.io/traefik/providers/docker/) |
| Los registros muestran la IP del túnel, no la del visitante | Falta `forwardedHeaders.trustedIPs` | Añade `${DOCKER_RED_PROXY_SUBRED}` en el punto de entrada `web` | [Traefik — EntryPoints](https://doc.traefik.io/traefik/routing/entrypoints/) |
| Un cambio en `middlewares.yml` no se aplica | Error de sintaxis YAML: Traefik ignora el archivo entero | `docker logs traefik \| grep -i error`. Valida el YAML antes de guardar | [Traefik — Proveedor de archivo](https://doc.traefik.io/traefik/providers/file/) |
| El navegador insiste en HTTPS en un dominio de pruebas | HSTS quedó grabado con un año de duración | Borra la política HSTS del navegador. Por eso `includeSubDomains` está desactivado (§ 3.4) | [MDN — HSTS](https://developer.mozilla.org/docs/Web/HTTP/Headers/Strict-Transport-Security) |
| Tras `docker compose pull` Traefik no arranca | Se usaba `latest` y llegó una versión mayor | Fija la línea menor (`v3.7`) y lee las notas antes de subir | § 3.6 |
| `socket-proxy` responde 403 a todo | Falta `CONTAINERS: 1` entre sus variables de entorno | Revisa el fichero compose | [docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy) |
| El panel es accesible desde toda la LAN | `TRAEFIK_BIND_INTERNA` está en `0.0.0.0` | Cámbialo a `127.0.0.1` o a la IP de Tailscale y recrea el contenedor | § 3.3 |
| Dos routers con el mismo nombre | Dos proyectos usan la misma etiqueta `routers.<nombre>` | Usa nombres únicos por proyecto | [Traefik — Routers](https://doc.traefik.io/traefik/routing/routers/) |

---

## 10. Referencias

- [Traefik Proxy v3 — Documentación](https://doc.traefik.io/traefik/)
- [Traefik — Proveedor de Docker](https://doc.traefik.io/traefik/providers/docker/)
- [Traefik — Routers y reglas](https://doc.traefik.io/traefik/routing/routers/)
- [Traefik — Middlewares HTTP](https://doc.traefik.io/traefik/middlewares/http/overview/)
- [Traefik — EntryPoints](https://doc.traefik.io/traefik/routing/entrypoints/)
- [Tecnativa — docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy)
- [Docker — Seguridad del socket](https://docs.docker.com/engine/security/#docker-daemon-attack-surface)
- [MDN — Cabeceras de seguridad HTTP](https://developer.mozilla.org/docs/Web/HTTP/Headers)

---

**Anterior:** [09 — Docker](09_docker.md) · **Siguiente:** [11 — Cloudflared y dominio](11_cloudflared_y_dominio.md)
