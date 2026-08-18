# 13 — Observabilidad

> Saber qué está pasando dentro del servidor sin entrar por SSH, y enterarte de que algo se ha caído
> antes de que te lo diga otra persona.

---

## 1. Objetivo

Al terminar tendrás los registros de todos los contenedores en una interfaz web, un monitor que
vigila tus servicios y avisa cuando dejan de responder, y un árbol de diagnóstico para cuando algo
falle. Todo accesible únicamente desde tu red privada.

---

## 2. Requisitos previos

**Capítulos previos:** [10 — Traefik](10_traefik.md) y [08 — Tailscale](08_tailscale.md).

**Necesitas a mano:**

- Traefik en marcha con su punto de entrada `interna`.
- La red `${DOCKER_RED_SOCKET}` creada en el capítulo 09.
- Un canal donde recibir avisos: Telegram, correo, Discord o similar.
- `TS_IP` persistida (capítulo [08](08_tailscale.md) paso 10), si vas a acceder por Tailscale.

**Preparar la sesión.**

```bash
# [servidor]
cd ~/nomad_server
source scripts/lib/entorno.sh
echo "dozzle=${DOZZLE_HOST} kuma=${UPTIME_KUMA_HOST}"
echo "acceso por http://<nombre>:${TRAEFIK_PUERTO_INTERNA} en ${TRAEFIK_BIND_INTERNA}"
echo "tailnet=${TS_IP:-(sin definir)}"
```

Salida esperada, con los valores de ejemplo:

```
dozzle=logs.nomad.lan kuma=estado.nomad.lan
acceso por http://<nombre>:8080 en 127.0.0.1
tailnet=100.101.102.103
```

**Este capítulo produce un valor que el capítulo 14 necesita**: la URL del monitor *Push* de
respaldo (`RESTIC_PUSH_URL`). No se crea aquí, pero sí se crea aquí el monitor de espacio en disco,
que funciona igual y sirve de ensayo. El paso 8 lo explica.

**Tiempo estimado:** 50 minutos, incluida la configuración de los avisos.

---

## 3. Decisiones y por qué

### 3.1 Ligero antes que completo

**Decisión: Dozzle y Uptime Kuma. No Prometheus, no Grafana, no Loki.**

Es tentador montar la pila completa de observabilidad, y es un error frecuente en servidores
domésticos: se instala, se configuran unos cuantos paneles, y a los dos meses nadie los mira
mientras consumen memoria y exigen mantenimiento.

Conviene distinguir dos preguntas muy distintas:

| Pregunta | Qué hace falta | Herramienta |
|---|---|---|
| «¿Está funcionando ahora?» | Comprobación periódica y aviso | Uptime Kuma |
| «¿Por qué falló hace un momento?» | Registros recientes | Dozzle |
| «¿Cómo ha evolucionado el uso de CPU en tres meses?» | Métricas históricas | Prometheus + Grafana |

Las dos primeras son las que se responden **de verdad** en un servidor doméstico. La tercera es
interesante, y casi nunca decide nada.

| Alternativa descartada | Por qué |
|---|---|
| Prometheus + Grafana + node_exporter | Tres servicios más, con su almacenamiento, sus paneles y sus respaldos. Justificado cuando hay que analizar tendencias de decenas de servicios |
| Loki + Promtail | Registro centralizado con búsqueda. Docker ya rota los registros y Dozzle los muestra; para este volumen es un martillo demasiado grande |
| Netdata | Muy completo y muy fácil de instalar. Consume bastante y su versión en la nube envía datos fuera |
| Portainer | Cómodo para gestionar contenedores, pero invita a hacer cambios fuera de los ficheros compose versionados, que es justo lo que este repositorio evita |

Si algún día haces falta de verdad de métricas históricas, añadir Prometheus más adelante no
requiere deshacer nada de esto.

### 3.2 Dozzle también pasa por el intermediario del socket

**Decisión: Dozzle lee los registros a través de `socket-proxy`, no del socket directo.**

Dozzle necesita hablar con la API de Docker, exactamente igual que Traefik, y aplica el mismo
razonamiento del capítulo 10 § 3.2: montarle el socket le daría la API completa, incluida la
capacidad de crear contenedores privilegiados.

Como el intermediario ya existe y su red es compartida, conectar Dozzle a ella no cuesta nada.

Dozzle además **no guarda nada**: lee del socket y muestra. Sin base de datos, sin volumen y sin
nada que respaldar. Si se pierde el contenedor, se recrea y ya está.

### 3.3 Nada de esto se publica en internet

**Decisión: ambas herramientas van en el punto de entrada `interna`, con el middleware `interno@file`.**

Son dos barreras independientes:

1. **El punto de entrada.** `interna` está atado a `${TRAEFIK_BIND_INTERNA}` —una dirección
   privada— y no hay ningún registro DNS público que lleve hasta él. El túnel de Cloudflare entrega
   en el punto de entrada `web`, que es otro.
2. **El middleware `interno@file`.** Filtra por dirección de origen: solo LAN, Tailscale y la red de
   contenedores.

Merece la pena tener las dos. La primera es la que realmente protege; la segunda es la que evita que
un error de configuración futuro —añadir sin pensar `entrypoints=web` a Dozzle— lo deje expuesto.

> **Dozzle muestra los registros de todos los contenedores.** Los registros contienen tokens, rutas
> internas, correos de usuarios y mensajes de error con datos. Publicarlo sería tan grave como
> publicar el socket de Docker.

### 3.4 Cómo se llega a las herramientas

El enrutado es por nombre de host, así que hace falta que esos nombres resuelvan. Hay tres formas,
de más a menos cómoda:

| Forma | Cómo | Ventaja |
|---|---|---|
| **Registro DNS apuntando a la IP de Tailscale** | En Cloudflare, un registro `A` de `logs.midominio.com` → `100.x.y.z`, **sin proxy** (nube gris) | Funciona en todos tus dispositivos sin configurar nada más. Fuera de la tailnet, esa IP no es alcanzable: simplemente no responde |
| **Archivo `hosts` en cada cliente** | `100.x.y.z logs.midominio.com` en `/etc/hosts` | Sin dependencias externas. Hay que repetirlo en cada dispositivo |
| **Túnel SSH** | `ssh -L 8080:127.0.0.1:8080 nomad` y usar `localhost` | No necesita DNS ni Tailscale. Requiere el túnel abierto y no funciona bien con enrutado por nombre |

La primera es la que se documenta como principal. Publicar una dirección privada en un DNS público
puede chirriar, pero no revela nada útil: `100.64.0.0/10` es un rango que no se enruta por internet,
y solo tiene sentido dentro de tu tailnet.

Si `TRAEFIK_BIND_INTERNA` es la IP de Tailscale, puedes además poner `TRAEFIK_PUERTO_INTERNA=80` y
las direcciones quedan limpias: `http://logs.midominio.com`, sin puerto.

### 3.5 Los avisos importan más que los paneles

**Decisión: configurar al menos un canal de aviso en Uptime Kuma antes de dar el capítulo por
terminado.**

Un panel que hay que mirar solo sirve cuando lo miras. Un aviso llega solo. La diferencia entre
enterarte de una caída en dos minutos o en dos días está en haber dedicado cinco minutos a
configurar el canal.

Telegram es la opción más simple: se crea un bot, se copian dos valores y funciona. Correo requiere
un servidor SMTP y suele acabar en la carpeta de no deseado justamente cuando importa.

### 3.6 Diagnóstico desde la línea de comandos

**Decisión: usar lo que ya está instalado, más `ctop` como contenedor cuando haga falta.**

`btop`, `ncdu`, `journalctl`, `docker stats` y `docker compose logs` cubren prácticamente todo el
diagnóstico. No se instala `lazydocker` en el host —sería otro binario que mantener— pero se
documenta cómo ejecutarlo puntualmente en un contenedor.

---

## 4. Variables usadas

### 4.1 De `config/servidor.env`

| Variable | Uso | Dónde acaba |
|---|---|---|
| `DATOS_RAIZ` | Directorio del proyecto de observabilidad | Rutas de los comandos |
| `DOZZLE_HOST` | Nombre por el que se llega a Dozzle | Etiqueta `Host(...)` del compose |
| `UPTIME_KUMA_HOST` | Nombre por el que se llega a Uptime Kuma | Etiqueta `Host(...)` del compose |
| `DOCKER_RED_PROXY` | Red compartida con Traefik | `docker-compose.yml` |
| `DOCKER_RED_SOCKET` | Red del intermediario del socket | `docker-compose.yml` |
| `TRAEFIK_BIND_INTERNA` | Dirección privada donde responde el punto de entrada `interna` | URL de acceso |
| `TRAEFIK_PUERTO_INTERNA` | Puerto de esa dirección | URL de acceso |
| `TS_IP` | Destino de los registros DNS internos, si eliges esa vía | Panel de Cloudflare |

Cargar y comprobar:

```bash
# [servidor]
cd ~/nomad_server && source scripts/lib/entorno.sh
echo "http://${DOZZLE_HOST}:${TRAEFIK_PUERTO_INTERNA}  ·  http://${UPTIME_KUMA_HOST}:${TRAEFIK_PUERTO_INTERNA}"
```

Criterio de aceptación: dos URL completas. Si alguna sale como `http://:8080`, el compose se
escribiría con una etiqueta `Host()` vacía y Traefik no crearía el router.

### 4.2 Variables que se DESCUBREN aquí y usa el capítulo 14

| Variable | Qué es | Cómo se obtiene | La necesita |
|---|---|---|---|
| `RESTIC_PUSH_URL` | URL del monitor *Push* del respaldo nocturno | Se crea en Uptime Kuma, capítulo [14](14_respaldos_restic.md) paso 8 | Capítulo 14 |

El monitor de espacio en disco del paso 8 de **este** capítulo funciona igual y es un buen ensayo:
si entiendes cómo se obtiene su URL, el del capítulo 14 no tiene misterio.

### 4.3 Valores que viven solo en Uptime Kuma

Estos no van a ningún archivo del repositorio: son estado de la aplicación, y por eso el directorio
`datos-kuma/` entra en el respaldo del capítulo 14.

| Valor | Dónde vive |
|---|---|
| La cuenta de administrador de Uptime Kuma | `datos-kuma/` |
| Los monitores y su histórico | `datos-kuma/` |
| El token del bot de Telegram y el ID de chat | `datos-kuma/` |

> **Si se pierde `datos-kuma/`, se pierden los monitores y los avisos**, y el servidor deja de
> avisarte sin que nada lo indique. Es una de las razones por las que el capítulo 14 respalda
> `${DATOS_RAIZ}` entero.

---

## 5. Procedimiento

### Paso 0 — Prepara la sesión

```bash
# [servidor]
cd ~/nomad_server
source scripts/lib/entorno.sh
```

Comprobaciones previas: Traefik en marcha y la red del socket existente.

```bash
# [servidor]
docker ps --filter name=traefik --filter name=socket-proxy --format '{{.Names}} {{.Status}}'
docker network inspect "${DOCKER_RED_SOCKET}" --format 'red {{.Name}} internal={{.Internal}}'
```

Criterio de aceptación: los dos contenedores `Up (healthy)` y la red con `internal=true`.

### Paso 1 — Prepara el directorio

```bash
# [servidor]
mkdir -p ${DATOS_RAIZ}/observabilidad/datos-kuma
cd ${DATOS_RAIZ}/observabilidad
pwd
```

Criterio de aceptación: `pwd` muestra la ruta completa bajo `${DATOS_RAIZ}`, no `/observabilidad`.

### Paso 2 — Fichero compose

```bash
# [servidor]
cd ~/nomad_server
nomad_plantilla compose/observabilidad/docker-compose.yml \
    > ${DATOS_RAIZ}/observabilidad/docker-compose.yml
cd ${DATOS_RAIZ}/observabilidad
```

Eso deja el archivo con tus nombres ya sustituidos. Compruébalo antes de levantar nada, porque una
etiqueta `Host()` vacía hace que Traefik no cree el router y la herramienta quede inaccesible sin
mensaje de error:

```bash
# [servidor]
grep -E 'Host\(|entrypoints|middlewares' docker-compose.yml
```

Salida esperada, con los valores de ejemplo:

```
      - "traefik.http.routers.dozzle.rule=Host(`logs.nomad.lan`)"
      - "traefik.http.routers.dozzle.entrypoints=interna"
      - "traefik.http.routers.dozzle.middlewares=interno@file"
      - "traefik.http.routers.kuma.rule=Host(`estado.nomad.lan`)"
      - "traefik.http.routers.kuma.entrypoints=interna"
      - "traefik.http.routers.kuma.middlewares=interno@file"
```

Criterio de aceptación: los dos `Host()` llevan nombres reales, y **los dos `entrypoints` dicen
`interna`, nunca `web`**. Un `web` aquí publicaría los registros de todos tus contenedores en
internet.

```bash
# [servidor] — validación completa antes de levantar
docker compose config | grep -E 'published|Host\(|external'
```

Criterio de aceptación: **ninguna línea `published`** —estas herramientas no publican puertos— y las
dos redes como externas.

### Paso 3 — Levanta

```bash
# [servidor]
docker compose up -d
docker compose ps
```

Criterio de aceptación: ambos `running` y, tras el período de arranque, `healthy`.

### Paso 4 — Configura el acceso por nombre

**Opción recomendada — registro DNS a la IP de Tailscale:**

```bash
# [servidor]
echo "Apunta los registros A a: ${TS_IP}"
echo "  ${DOZZLE_HOST}      → ${TS_IP}"
echo "  ${UPTIME_KUMA_HOST} → ${TS_IP}"
```

Si `TS_IP` sale vacía, vuelve al capítulo [08](08_tailscale.md) paso 10 y persístela.

En el panel de Cloudflare → **DNS → Records**, añade dos registros:

| Tipo | Nombre | Contenido | Proxy |
|---|---|---|---|
| A | `logs` | `100.x.y.z` | **DNS only** (nube gris) |
| A | `estado` | `100.x.y.z` | **DNS only** (nube gris) |

> La nube **debe** estar gris. Si estuviera naranja, Cloudflare intentaría alcanzar una dirección
> privada desde internet y devolvería un error.

**Opción sin DNS — archivo `hosts` del cliente:**

```bash
# [cliente] — con el entorno cargado en tu equipo
cd ~/nomad_server && source scripts/lib/entorno.sh
echo "${TS_IP}  ${DOZZLE_HOST} ${UPTIME_KUMA_HOST}" | sudo tee -a /etc/hosts
getent hosts ${DOZZLE_HOST}
```

Criterio de aceptación: la última línea devuelve la IP de Tailscale. Hay que repetirlo en cada
dispositivo desde el que quieras entrar, que es la pega de esta opción.

### Paso 5 — Comprueba Dozzle

```bash
# [servidor] — la URL exacta, ya resuelta
echo "http://${DOZZLE_HOST}:${TRAEFIK_PUERTO_INTERNA}"
```

Ábrela desde un dispositivo de tu tailnet.

Deberías ver la lista de contenedores y sus registros en tiempo real.

Criterio de aceptación: aparecen `traefik`, `cloudflared`, `socket-proxy` y tus proyectos.

Si Dozzle carga pero no muestra ningún contenedor, el problema está en la conexión con el
intermediario del socket:

```bash
# [servidor]
docker logs dozzle | tail -20
docker exec dozzle wget -qO- http://socket-proxy:2375/v1.24/containers/json | head -c 200
```

### Paso 6 — Configura Uptime Kuma

```bash
# [servidor]
echo "http://${UPTIME_KUMA_HOST}:${TRAEFIK_PUERTO_INTERNA}"
```

La primera vez pide crear una cuenta de administrador. Usa una contraseña de tu gestor.

> Aunque solo sea accesible desde tu red privada, ponle una contraseña buena: es la única barrera si
> un dispositivo de tu tailnet se compromete.

**Monitores recomendados**, en orden de utilidad:

| Nombre | Tipo | Configuración | Qué detecta |
|---|---|---|---|
| Proyecto público | HTTP(s) | `https://mi-proyecto.midominio.com`, cada 60 s | La cadena completa: Cloudflare, túnel, Traefik y aplicación |
| Traefik interno | HTTP(s) | `http://traefik:8080/ping`, cada 60 s | Que el proxy responde |
| Túnel | HTTP(s) | `https://prueba.midominio.com`, cada 5 min | Que el túnel sigue en pie |
| Espacio en disco | Push | Lo empuja un temporizador del servidor | Que queda espacio |
| Certificado TLS | Se activa en el monitor HTTP | Aviso 14 días antes | Caducidad (Cloudflare renueva solo, pero conviene vigilarlo) |

Los monitores internos (`http://traefik:8080/ping`) funcionan porque Uptime Kuma está en la red
`${DOCKER_RED_PROXY}` y resuelve los nombres de los contenedores.

### Paso 7 — Configura los avisos

**Ajustes → Notificaciones → Configurar notificación.**

Con Telegram, que es lo más rápido:

1. En Telegram, habla con `@BotFather` y crea un bot con `/newbot`.
2. Copia el **token** que te da.
3. Habla con tu bot nuevo y envíale cualquier mensaje.
4. En Uptime Kuma, elige Telegram, pega el token y pulsa **Obtener ID de chat**.
5. **Envía una notificación de prueba.** No des el paso por bueno hasta verla llegar.

Después, en cada monitor, marca esa notificación como activa.

Ajustes recomendados:

| Ajuste | Valor | Motivo |
|---|---|---|
| Reintentos antes de avisar | 2 | Evita avisos por un fallo puntual de red |
| Intervalo de reintento | 60 s | Suficiente para distinguir un parpadeo de una caída |
| Reenvío del aviso | Cada 30 min | Recuerda que sigue caído sin llegar a ser molesto |

### Paso 8 — Monitor de espacio en disco

El disco lleno es la causa más frecuente de caída en un servidor doméstico, y ningún monitor HTTP la
detecta hasta que ya es tarde.

En Uptime Kuma, **Añadir nuevo monitor** de tipo **Push**, llamado `Espacio en disco`. Nada más
crearlo, la propia pantalla muestra una **Push URL** con este aspecto:

```
http://estado.nomad.lan:8080/api/push/a1B2c3D4e5
```

De ahí solo interesa el identificador final (`a1B2c3D4e5` en el ejemplo). **Anótalo ahora**: es un
valor que solo existe en esa pantalla.

> Cómo funciona un monitor *Push*, porque es al revés de lo habitual: Uptime Kuma **espera** recibir
> una petición cada cierto tiempo. Si llega, verde. Si no llega, rojo. Por eso el script de abajo
> avisa solo cuando **todo está bien**, y el silencio es la señal de alarma. Es el mismo mecanismo
> del respaldo nocturno del capítulo [14](14_respaldos_restic.md) § 3.6.

**Así queda el script** (con el identificador de ejemplo):

```bash
#!/usr/bin/env bash
set -euo pipefail
URL="http://uptime-kuma:3001/api/push/a1B2c3D4e5"
UMBRAL=85
USO=$(df --output=pcent / | tail -1 | tr -dc '0-9')
USO_VAR=$(df --output=pcent /var | tail -1 | tr -dc '0-9')
if (( USO < UMBRAL && USO_VAR < UMBRAL )); then
    curl -fsS "${URL}?status=up&msg=raiz+${USO}%25+var+${USO_VAR}%25" >/dev/null
fi
# Si supera el umbral no se envía nada: Uptime Kuma lo detecta como caída.
```

**Y estos son los comandos que lo instalan.** Declara primero el identificador como variable
temporal, para no tener que buscarlo tres veces:

```bash
# [servidor]
PUSH_ID=a1B2c3D4e5        # ← el tuyo, de la pantalla del monitor
echo "URL: http://uptime-kuma:3001/api/push/${PUSH_ID}"
```

```bash
# [servidor]
sudo tee /usr/local/bin/nomad-espacio.sh >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail
URL="http://uptime-kuma:3001/api/push/${PUSH_ID}"
UMBRAL=85
USO=\$(df --output=pcent / | tail -1 | tr -dc '0-9')
USO_VAR=\$(df --output=pcent /var | tail -1 | tr -dc '0-9')
if (( USO < UMBRAL && USO_VAR < UMBRAL )); then
    curl -fsS "\${URL}?status=up&msg=raiz+\${USO}%25+var+\${USO_VAR}%25" >/dev/null
fi
EOF
sudo chmod +x /usr/local/bin/nomad-espacio.sh
```

Fíjate en las barras invertidas: `${PUSH_ID}` **sí** se expande (es tuya, ahora), mientras que
`\${URL}`, `\${USO}` y `\${USO_VAR}` se escapan para que lleguen literales al archivo y las
resuelva el script cuando se ejecute. Es la mezcla de los dos casos del anexo
[98 § 4.1](98_variables_y_entorno.md).

Compruébalo antes de seguir:

```bash
# [servidor]
grep -n 'api/push' /usr/local/bin/nomad-espacio.sh
sudo bash -n /usr/local/bin/nomad-espacio.sh && echo "SINTAXIS CORRECTA"
```

Criterio de aceptación: la URL contiene tu identificador real y la sintaxis es válida.

> **Sobre la dirección del monitor.** Se usa `http://uptime-kuma:3001` —el nombre del contenedor—
> en lugar de `localhost:8080`, y no es un detalle: el script corre en el **host**, no dentro de un
> contenedor, así que ese nombre no resolvería. Usa la dirección que sí funcione en tu caso:
> `http://${TRAEFIK_BIND_INTERNA}:${TRAEFIK_PUERTO_INTERNA}/api/push/…` si el punto de entrada
> interno está publicado, que es lo habitual. Compruébalo con el `curl` del final del paso.

```bash
# [servidor] — el servicio y el temporizador de systemd
sudo tee /etc/systemd/system/nomad-espacio.service >/dev/null <<'EOF'
[Unit]
Description=Avisa a Uptime Kuma si queda espacio suficiente

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nomad-espacio.sh
EOF
```

```bash
# [servidor]
sudo tee /etc/systemd/system/nomad-espacio.timer >/dev/null <<'EOF'
[Unit]
Description=Comprobación periódica de espacio en disco

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
EOF
```

```bash
# [servidor]
sudo systemctl daemon-reload
sudo systemctl enable --now nomad-espacio.timer
sudo systemctl start nomad-espacio.service
sudo journalctl -u nomad-espacio -n 20 --no-pager
```

Criterio de aceptación: el servicio termina sin errores y el monitor pasa a verde en Uptime Kuma en
pocos minutos. Si el `curl` falla, prueba la URL a mano para ver qué responde:

```bash
# [servidor]
curl -v "http://${TRAEFIK_BIND_INTERNA}:${TRAEFIK_PUERTO_INTERNA}/api/push/${PUSH_ID}?status=up&msg=prueba"
```

### Paso 9 — Herramientas de línea de comandos

Para el diagnóstico puntual desde SSH:

```bash
# [servidor] — recursos del sistema
btop

# [servidor] — recursos por contenedor
docker stats --no-stream

# [servidor] — qué está ocupando el disco
sudo ncdu /var

# [servidor] — registros de un servicio del sistema
journalctl -u docker -n 100 --no-pager
journalctl -u ssh --since "1 hour ago"

# [servidor] — registros de un contenedor
docker logs --tail 100 -f <contenedor>
docker compose logs --tail 50

# [servidor] — vista interactiva de contenedores, sin instalar nada
docker run --rm -it --network none \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    quay.io/vektorlab/ctop:latest
```

### Paso 10 — Árbol de diagnóstico

Cuando algo falla, este es el orden que ahorra tiempo:

```
Un proyecto no responde desde internet
│
├─ ¿Responde https://otro-proyecto.midominio.com?
│  ├─ NO → el problema es común: sigue por el túnel
│  └─ SÍ → el problema es de ese proyecto: sigue por el contenedor
│
├─ TÚNEL
│  ├─ docker logs cloudflared | tail -30
│  ├─ ¿«Registered tunnel connection»?  NO → ¿hay internet? ping 1.1.1.1
│  └─ ¿Error 1033 en el navegador? → el túnel está caído
│
├─ TRAEFIK
│  ├─ docker ps | grep traefik        ¿está en marcha?
│  ├─ panel → ¿aparece el router del proyecto?
│  └─ docker logs traefik | grep -i error
│
├─ CONTENEDOR
│  ├─ docker compose ps               ¿running? ¿healthy?
│  ├─ docker compose logs --tail 100  ¿qué dice al arrancar?
│  └─ ¿está en la red proxy? docker inspect <c> | grep -A5 Networks
│
└─ SISTEMA
   ├─ df -h                           ¿disco lleno?
   ├─ free -h                         ¿memoria agotada?
   ├─ journalctl -p err --since today ¿errores del sistema?
   └─ sudo nft list ruleset           ¿cambió el cortafuegos?
```

---

## 6. Script asociado

### 6.1 Vía A — con el script

`scripts/13_observabilidad.sh` automatiza los pasos 1 a 3 y comprueba el acceso.

```bash
# [servidor] — SIN sudo
cd ~/nomad_server
./scripts/13_observabilidad.sh --help
./scripts/13_observabilidad.sh --check
./scripts/13_observabilidad.sh
```

Comportamiento destacable:

- Comprueba que Traefik y la red del socket existen antes de nada.
- **Verifica que Dozzle llega al intermediario del socket** y avisa si no, porque es el fallo más
  probable y el más confuso (Dozzle carga bien pero sale vacío).
- Comprueba que ninguno de los dos servicios ha quedado publicado en el punto de entrada `web`.
- Recuerda los pasos que no puede hacer: crear la cuenta de Uptime Kuma, configurar los monitores y
  los avisos.

En modo `--check` muestra las diferencias del compose y valida su sintaxis, sin levantar nada.

### 6.2 Correspondencia entre el script y los pasos manuales

| Paso de la sección 5 | ¿Lo hace el script? | Nota |
|---|---|---|
| 0 — preparar la sesión | Sí | Comprueba Traefik y las redes |
| 1 — directorio | Sí | |
| 2 — fichero compose | Sí | Desde `templates/compose/observabilidad/docker-compose.yml` |
| 3 — levantar | Sí | Y verifica que Dozzle alcanza el intermediario del socket |
| 4 — acceso por nombre | **No** | Registros DNS o `/etc/hosts` |
| 5 — comprobar Dozzle | Parcial | Verifica el socket; mirar la interfaz es tuyo |
| 6 — cuenta y monitores de Uptime Kuma | **No** | Interfaz web con estado propio |
| 7 — canal de avisos y su prueba | **No** | Depende de un servicio externo |
| 8 — monitor de espacio en disco | **No** | Necesita el identificador que da Uptime Kuma |
| 9–10 — herramientas y árbol de diagnóstico | — | Son referencia, no configuración |

### 6.3 Lo que ninguna vía hace por ti

Y esta vez la lista importa más que de costumbre, porque **un sistema de avisos a medias es peor que
no tenerlo**: da la sensación de estar cubierto.

- [ ] Crear la cuenta de administrador de Uptime Kuma con una contraseña de tu gestor.
- [ ] Configurar al menos tres monitores (§ 5 paso 6).
- [ ] Configurar el canal de avisos **y enviar una notificación de prueba**.
- [ ] Marcar esa notificación como activa **en cada monitor**. Configurarla no basta.
- [ ] Crear el monitor de espacio en disco y comprobar que pasa a verde.
- [ ] Hacer la prueba real: parar un contenedor y ver llegar el aviso (§ 7).

---

## 7. Validación

```bash
# [servidor]
cd ${DATOS_RAIZ}/observabilidad && docker compose ps
```

Criterio de aceptación: `dozzle` y `uptime-kuma` en `running (healthy)`.

```bash
# [servidor] — Dozzle alcanza el intermediario del socket
docker exec dozzle wget -qO- http://socket-proxy:2375/v1.24/containers/json | head -c 50
```

Criterio de aceptación: devuelve JSON.

```bash
# [servidor] — ninguna herramienta está en el punto de entrada público
docker inspect dozzle uptime-kuma --format '{{.Name}} {{index .Config.Labels "traefik.http.routers.dozzle.entrypoints"}}{{index .Config.Labels "traefik.http.routers.kuma.entrypoints"}}'
```

Criterio de aceptación: aparece `interna` en ambos, nunca `web`.

```bash
# [servidor] — no hay registro DNS público que lleve a las herramientas
dig ${DOZZLE_HOST} +short
```

Criterio de aceptación: o no devuelve nada, o devuelve una dirección `100.x.y.z` de Tailscale.
**Nunca una dirección de Cloudflare**, que significaría que está expuesto por el túnel.

```bash
# [cliente, desde fuera de tu red y sin Tailscale]
curl -s -m 10 -o /dev/null -w '%{http_code}\n' https://${DOZZLE_HOST}
```

Criterio de aceptación: falla o devuelve un error. **Si devuelve 200, está expuesto a internet.**

```bash
# [cliente, desde la tailnet]
curl -s -o /dev/null -w '%{http_code}\n' http://${DOZZLE_HOST}:${TRAEFIK_PUERTO_INTERNA}
```

Criterio de aceptación: `200`.

```bash
# [servidor] — el temporizador de espacio en disco está activo
systemctl is-active nomad-espacio.timer
systemctl show nomad-espacio.service -p Result --value
```

Criterio de aceptación: `active` y `success`.

```bash
# [servidor] — el compose no quedó con variables sin sustituir
grep -n '\${' ${DATOS_RAIZ}/observabilidad/docker-compose.yml && echo "REVISAR" || echo "CORRECTO"
```

Criterio de aceptación: `CORRECTO`.

```bash
# [servidor] — el script de espacio apunta a una URL real
grep 'api/push' /usr/local/bin/nomad-espacio.sh
```

Criterio de aceptación: aparece un identificador, no `XXXXXX` ni una URL cortada.

**Comprobaciones manuales:**

- [ ] Dozzle lista todos los contenedores y muestra sus registros en vivo.
- [ ] Uptime Kuma tiene al menos tres monitores en verde.
- [ ] La notificación de prueba **ha llegado** a tu Telegram o correo.
- [ ] El monitor de espacio en disco está en verde.

**Prueba real del sistema de avisos:** para un contenedor a propósito y comprueba que el aviso llega.

```bash
# [servidor]
docker stop <un-proyecto>
# espera 2-3 minutos: debe llegar el aviso
docker start <un-proyecto>
# debe llegar el aviso de recuperación
```

Sin hacer esta prueba, no sabes si el sistema de avisos funciona: solo sabes que está configurado.

---

## 8. Reversión

```bash
# [servidor]
cd ${DATOS_RAIZ}/observabilidad
docker compose down
```

```bash
# [servidor] — eliminar también los datos de Uptime Kuma (monitores e histórico)
docker compose down
rm -rf ${DATOS_RAIZ}/observabilidad
```

```bash
# [servidor] — quitar solo el monitor de espacio en disco
sudo systemctl disable --now nomad-espacio.timer
sudo rm /etc/systemd/system/nomad-espacio.{timer,service}
sudo rm /usr/local/bin/nomad-espacio.sh
sudo systemctl daemon-reload
```

Dozzle no guarda nada, así que eliminarlo no pierde información. Uptime Kuma sí: sus monitores y su
histórico están en `datos-kuma/`, que el respaldo del capítulo 14 recoge.

---

## 9. Errores frecuentes

| Síntoma | Causa probable | Solución | Documentación |
|---|---|---|---|
| Dozzle carga pero no muestra contenedores | No llega al intermediario del socket | Comprueba que está en la red `${DOCKER_RED_SOCKET}` y que `DOZZLE_REMOTE_HOST` apunta a `tcp://socket-proxy:2375` | § 3.2 |
| «Bad Gateway» al abrir las herramientas | El contenedor no está en la red `${DOCKER_RED_PROXY}` o el puerto de la etiqueta es incorrecto | Dozzle usa el 8080; Uptime Kuma el 3001 | Capítulo [10](10_traefik.md) |
| El nombre no resuelve | Falta el registro DNS o la entrada en `hosts` | Revisa el paso 4 | § 3.4 |
| El registro DNS devuelve una IP de Cloudflare | El registro está proxiado (nube naranja) | Cámbialo a **DNS only** (nube gris) | § 5 paso 4 |
| Uptime Kuma no puede alcanzar los servicios internos | No está en la red `${DOCKER_RED_PROXY}` | Comprueba el compose. Los nombres de contenedor solo resuelven dentro de la misma red | Capítulo [09](09_docker.md) |
| Los avisos no llegan | La notificación no se probó, o no está activada en los monitores | Envía una prueba desde Ajustes, y marca la notificación en cada monitor | § 5 paso 7 |
| Avisos constantes por parpadeos | Sin reintentos configurados | Pon 2 reintentos con 60 s de intervalo | § 5 paso 7 |
| El monitor de espacio nunca pasa a verde | La URL de push es incorrecta, o el script no llega a Uptime Kuma | Ejecuta el script a mano y mira su salida. Comprueba la URL del monitor | § 5 paso 8 |
| Dozzle es accesible desde internet | Se le puso `entrypoints=web` | Cámbialo a `interna` y elimina cualquier registro DNS proxiado | § 3.3 |
| Uptime Kuma consume mucha CPU | Demasiados monitores con intervalo muy corto | Sube el intervalo a 60 s o más. 20 segundos rara vez aporta algo | [Uptime Kuma](https://github.com/louislam/uptime-kuma/wiki) |
| Tras actualizar Uptime Kuma se pierden los monitores | El volumen `datos-kuma` no estaba montado | Restaura desde el respaldo. Verifica el montaje en el compose | Capítulo [14](14_respaldos_restic.md) |
| Traefik no crea el router de Dozzle | La etiqueta quedó como ``Host(`` `` `)`` porque `${DOZZLE_HOST}` estaba vacía | Renderiza el compose con el entorno cargado y recrea | § 5 paso 2 |
| El script de espacio no avisa nunca | La URL de push apunta a un nombre que el host no resuelve | Usa `${TRAEFIK_BIND_INTERNA}:${TRAEFIK_PUERTO_INTERNA}` y prueba con `curl -v` | § 5 paso 8 |
| El script de espacio se escribió con `${URL}` vacío | No se escaparon las variables internas al usar el heredoc | Reescríbelo con las barras invertidas del paso 8 | § 5 paso 8 |
| Los registros DNS internos apuntan a la nada | `TS_IP` estaba vacía al crearlos | Capítulo [08](08_tailscale.md) paso 10, y corrige los registros | § 4.1 |
| Perdí los monitores y los avisos al recrear el proyecto | Se borró `datos-kuma/` | Restaura desde el respaldo del capítulo 14 | § 4.3 |

---

## 10. Referencias

- [Dozzle — Documentación](https://dozzle.dev/)
- [Uptime Kuma — Wiki](https://github.com/louislam/uptime-kuma/wiki)
- [Uptime Kuma — Notificaciones](https://github.com/louislam/uptime-kuma/wiki/Notification-Methods)
- [Docker — Comando stats](https://docs.docker.com/reference/cli/docker/container/stats/)
- [systemd — Temporizadores](https://www.freedesktop.org/software/systemd/man/systemd.timer.html)
- [`journalctl(1)`](https://manpages.debian.org/trixie/systemd/journalctl.1.en.html)
- [templates/README.md](../templates/README.md) — el compose de observabilidad
- Anexo [98 — Variables, entorno y sesiones](98_variables_y_entorno.md) § 4.1, sobre escapar variables en un heredoc

---

**Anterior:** [12 — Despliegue de proyectos](12_despliegue_de_proyectos.md) · **Siguiente:** [14 — Respaldos con restic](14_respaldos_restic.md)
