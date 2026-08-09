# 09 — Docker

> Instalar el motor de contenedores y dejar la única regla que sostiene todo el diseño de seguridad
> de este servidor: **ningún contenedor publica puertos en el host**.

---

## 1. Objetivo

Al terminar tendrás Docker CE y Compose v2 instalados desde el repositorio oficial, con rotación de
registros, subredes que no colisionan con tu LAN, la red compartida `${DOCKER_RED_PROXY}` creada, y
un contenedor de prueba funcionando.

---

## 2. Requisitos previos

**Capítulos previos:** [07 — Endurecimiento](07_endurecimiento_del_sistema.md).

**Necesitas a mano:**

- Acceso por SSH con llave.
- Salida a internet (se descargan unos 400 MB).
- Espacio en `/var`: las imágenes viven ahí. Comprueba con `df -h /var`.

**Tiempo estimado:** 25 minutos.

---

## 3. Decisiones y por qué

### 3.1 Docker CE oficial, no `docker.io` de Debian

**Decisión: repositorio `download.docker.com`.**

| Alternativa descartada | Por qué |
|---|---|
| `docker.io` de Debian | Se congela con la versión de la distribución y **no incluye el plugin `compose` v2**. Habría que instalar Compose aparte, quedándose atrás en ambos |
| Podman | Sin demonio y con soporte de *rootless* más maduro. Su compatibilidad con `docker-compose` ha mejorado mucho, pero la mayoría de proyectos y de documentación asumen Docker, y Traefik depende del socket de Docker para descubrir contenedores |
| Docker *rootless* | Elimina la equivalencia entre el grupo `docker` y root, que es la principal pega de este montaje. A cambio complica el acceso al socket desde Traefik, las redes y los volúmenes. Merece la pena cuando varias personas comparten el servidor; con un solo administrador, no |

### 3.2 La regla central: ningún contenedor publica puertos

**Decisión: no usar `ports:` en ningún fichero compose. Solo `expose:` y redes internas.**

Esta es **la** decisión de la que dependen las demás. Merece la pena entender por qué.

Cuando un contenedor publica un puerto (`ports: ["8080:80"]`), Docker crea una regla de DNAT en
netfilter que se evalúa **antes** que las reglas de UFW y, según cómo esté escrito el conjunto de
reglas, puede evaluarse antes que las tuyas. El resultado clásico es un servicio accesible desde
toda la red aunque el cortafuegos indique que ese puerto está cerrado.

La solución habitual es parchear la cadena `DOCKER-USER`. Funciona, pero deja el sistema en un
estado que hay que recordar, documentar y no romper.

Aquí se ataca la raíz: **si nadie publica puertos, no hay nada que filtrar.**

```
                  ┌─────────────────────────────────────────┐
   internet  ────▶│ cloudflared ──▶ Traefik ──▶ proyecto-a   │
   (túnel         │      (red docker "proxy", interna)       │
    saliente)     │                       └──▶ proyecto-b    │
                  └─────────────────────────────────────────┘
                        ningún puerto publicado en el host
```

Los contenedores se comunican **por nombre** dentro de la red `${DOCKER_RED_PROXY}`. Traefik llega a
`proyecto-a:3000` sin que ese puerto exista en el host. Y el único que recibe tráfico de fuera es
`cloudflared`, que lo recibe por un túnel que él mismo inicia.

**La única excepción, y es acotada:** el punto de entrada *interno* de Traefik (capítulo 10) sí se
publica, pero **nunca en `0.0.0.0`**. Se ata a `127.0.0.1` —accesible solo mediante un túnel SSH— o
a la dirección de Tailscale del servidor, accesible solo desde tu red privada. En ninguno de los dos
casos queda expuesto a la red local ni a internet.

Enunciada con precisión, la regla es: **ningún contenedor publica un puerto en `0.0.0.0`**. Es
exactamente lo que comprueba la validación de la sección 7, y la comprobación se repite en todos los
capítulos posteriores.

**Consecuencia práctica**: para depurar un servicio desde tu equipo se usa un túnel SSH, no un
puerto abierto:

```bash
# [cliente]
ssh -L 8080:127.0.0.1:8080 nomad
```

### 3.3 Subredes que no colisionan con la LAN

**Decisión: fijar `default-address-pools` a `172.20.0.0/14`.**

Por omisión, Docker asigna redes desde `172.17.0.0/16` en adelante y, cuando se le agotan, **desde
`192.168.0.0/16`**. Si tu LAN es `192.168.1.0/24`, llega un momento —normalmente cuando ya tienes
varios proyectos— en que Docker crea una red que solapa con tu red local.

El síntoma es memorable: el servidor deja de alcanzar el router, o un contenedor concreto no llega a
un equipo de tu casa, y nada en la configuración explica por qué.

Con `172.20.0.0/14` hay espacio para 1024 redes de contenedores, todas dentro del rango privado que
no se usa en la LAN.

### 3.4 Rotación de registros

**Decisión: `json-file` con `max-size` y `max-file`.**

Por omisión Docker **no rota los registros de los contenedores**. Un contenedor con un bucle de
error puede escribir gigabytes en `/var/lib/docker/containers/`. Es una de las causas más frecuentes
de disco lleno en servidores con Docker, y como los archivos no están donde uno los busca, cuesta
encontrarlos.

Con `${DOCKER_LOG_MAX_SIZE}` por archivo y `${DOCKER_LOG_MAX_FILE}` archivos, cada contenedor tiene
un techo conocido.

### 3.5 `live-restore`

**Decisión: activarlo.**

Permite que los contenedores sigan corriendo mientras se reinicia el demonio de Docker, por ejemplo
al aplicar una actualización. Sin él, `apt upgrade` de Docker tira todos los servicios.

### 3.6 El grupo `docker` equivale a root

**Decisión: añadir `${ADMIN_USUARIO}` al grupo `docker`, sabiendo lo que implica.**

Quien puede hablar con el socket de Docker puede arrancar un contenedor que monte `/` del host y
modificar cualquier cosa. **Pertenecer al grupo `docker` es, a efectos prácticos, ser root sin
contraseña.**

Se acepta porque en este servidor `${ADMIN_USUARIO}` ya tiene `sudo`: no se concede ningún poder que
no tuviera. Lo que sí cambia es que ese poder deja de requerir contraseña.

Si esto te incomoda, la alternativa es no añadir el usuario al grupo y usar `sudo docker` siempre.
Es perfectamente viable; solo hay que recordar el `sudo` en todos los comandos y en los scripts.

**Lo que no se debe hacer nunca:** exponer el socket de Docker por red (`tcp://`), ni montarlo en un
contenedor con permiso de escritura. Traefik lo monta **en solo lectura** (capítulo 10) y aun así es
la parte más delicada de ese capítulo.

### 3.7 Una red compartida, declarada como externa

**Decisión: crear `${DOCKER_RED_PROXY}` a mano y referenciarla como `external: true`.**

Si cada fichero compose creara su propia red, Traefik no podría llegar a los contenedores: estarían
en redes aisladas. Se crea una vez, fuera de cualquier proyecto, y todos se conectan a ella.

Declararla como externa tiene además una ventaja concreta: `docker compose down` de un proyecto no
puede borrar la red compartida por accidente.

Los proyectos que necesiten servicios internos (una base de datos, por ejemplo) crean **además** su
propia red privada, y solo el contenedor web se conecta a la red `proxy`. Así la base de datos no es
alcanzable ni siquiera desde otros contenedores publicados.

### 3.8 Política de reinicio

**Decisión: `restart: unless-stopped` en todos los servicios.**

| Política | Comportamiento |
|---|---|
| `no` | No se reinicia. Un corte de luz deja todo caído |
| `always` | Se reinicia siempre, **incluso los que paraste a mano**. Muy molesto al depurar |
| `unless-stopped` | Se reinicia salvo que lo hayas parado tú explícitamente |
| `on-failure` | Solo si el proceso falla. No arranca tras reiniciar el servidor |

`unless-stopped` es la que hace que el servidor vuelva solo tras un corte de luz o tras el reinicio
automático del capítulo 07, respetando a la vez lo que hayas parado a propósito.

---

## 4. Variables usadas

| Variable | Uso |
|---|---|
| `DEBIAN_SUITE` | Suite del repositorio de Docker |
| `ADMIN_USUARIO` | Usuario que se añade al grupo `docker` |
| `DOCKER_RED_PROXY` | Nombre de la red compartida |
| `DOCKER_RED_PROXY_SUBRED` | Subred de esa red |
| `DOCKER_LOG_MAX_SIZE`, `DOCKER_LOG_MAX_FILE` | Rotación de registros |
| `DATOS_RAIZ` | Directorio raíz de los proyectos |

---

## 5. Procedimiento

### Paso 1 — Comprueba el espacio y el reenvío de paquetes

```bash
# [servidor]
df -h /var
```

Criterio de aceptación: al menos 20 GB libres.

```bash
# [servidor]
grep -rn 'ip_forward' /etc/sysctl.conf /etc/sysctl.d/ 2>/dev/null && echo "REVISAR" || echo "CORRECTO"
```

Criterio de aceptación: `CORRECTO`. Si algún archivo pone `net.ipv4.ip_forward = 0`, **elimínalo
antes de instalar Docker** o los contenedores no tendrán red (capítulo 07 § 3.3).

### Paso 2 — Añade el repositorio de Docker

```bash
# [servidor]
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
```

```bash
# [servidor]
sudo vim /etc/apt/sources.list.d/docker.sources
```

```
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
```

```bash
# [servidor]
sudo apt update
```

### Paso 3 — Instala

```bash
# [servidor]
sudo apt install -y docker-ce docker-ce-cli containerd.io \
                    docker-buildx-plugin docker-compose-plugin
```

```bash
# [servidor]
docker --version
docker compose version
```

Salida esperada: dos líneas con las versiones. Fíjate en que es `docker compose` (con espacio), el
plugin v2, y no `docker-compose` (con guion), la herramienta antigua en Python.

### Paso 4 — Configura el demonio

```bash
# [servidor]
sudo vim /etc/docker/daemon.json
```

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true,
  "default-address-pools": [
    { "base": "172.20.0.0/14", "size": 24 }
  ],
  "storage-driver": "overlay2",
  "features": {
    "buildkit": true
  }
}
```

> **Lo que deliberadamente NO está aquí:** `"iptables": false`. Aparece en muchas guías de
> endurecimiento y **rompe por completo la red de los contenedores**. Docker necesita gestionar sus
> propias reglas; el diseño de este servidor no depende de impedírselo, sino de no publicar puertos
> (§ 3.2).

```bash
# [servidor]
sudo systemctl restart docker
sudo systemctl enable docker
docker info | grep -E 'Storage Driver|Logging Driver|Live Restore'
```

### Paso 5 — Añade tu usuario al grupo `docker`

```bash
# [servidor]
sudo usermod -aG docker ${ADMIN_USUARIO}
```

Cierra la sesión y vuelve a entrar para que el grupo tenga efecto:

```bash
# [servidor]
exit
```

```bash
# [cliente]
ssh nomad
```

```bash
# [servidor]
groups | grep -q docker && echo "GRUPO DOCKER OK"
docker ps
```

Criterio de aceptación: `docker ps` funciona **sin `sudo`**.

Recuerda 3.6: esto equivale a tener root sin contraseña.

### Paso 6 — Crea la red compartida

```bash
# [servidor]
docker network create \
    --driver bridge \
    --subnet ${DOCKER_RED_PROXY_SUBRED} \
    ${DOCKER_RED_PROXY}
docker network ls
docker network inspect ${DOCKER_RED_PROXY} | jq '.[0].IPAM.Config'
```

Criterio de aceptación: la red existe con la subred indicada.

### Paso 7 — Prepara el directorio de proyectos

```bash
# [servidor]
sudo mkdir -p ${DATOS_RAIZ}
sudo chown ${ADMIN_USUARIO}:${ADMIN_USUARIO} ${DATOS_RAIZ}
ls -ld ${DATOS_RAIZ}
```

### Paso 8 — Prueba de humo

```bash
# [servidor]
docker run --rm hello-world
```

Criterio de aceptación: aparece `Hello from Docker!`.

Y una prueba más completa, que valida red y DNS **dentro** de un contenedor:

```bash
# [servidor]
docker run --rm --network ${DOCKER_RED_PROXY} alpine:latest \
    sh -c 'ping -c2 1.1.1.1 && nslookup deb.debian.org'
```

Criterio de aceptación: responden el ping y la resolución de nombres. **Si el ping funciona pero la
resolución no**, el problema es el DNS del host (capítulo 06 § 3.3). **Si no funciona ninguno**,
revisa `net.ipv4.ip_forward` (capítulo 07 § 3.3).

### Paso 9 — Comprueba que no hay puertos publicados

```bash
# [servidor]
docker ps --format 'table {{.Names}}\t{{.Ports}}'
sudo ss -tulpn | grep LISTEN
```

Criterio de aceptación: la columna de puertos está vacía y en el host solo escucha SSH. Esta
comprobación se repetirá en todos los capítulos siguientes: es la que confirma que el diseño se
mantiene.

---

## 6. Script asociado

`scripts/09_docker.sh` automatiza los pasos 1 a 8.

```bash
# [servidor]
cd ~/nomad_server
./scripts/09_docker.sh --help
sudo ./scripts/09_docker.sh --check
sudo ./scripts/09_docker.sh
```

Comportamiento destacable:

- **Aborta si encuentra `net.ipv4.ip_forward = 0`** en `/etc/sysctl.d/`, antes de instalar nada.
- **Avisa si `daemon.json` contiene `"iptables": false`**, aunque lo hayas puesto tú.
- Comprueba que `${DOCKER_RED_PROXY_SUBRED}` no solapa con `${LAN_CIDR}`.
- Ejecuta la prueba de humo del paso 8 y da el capítulo por bueno solo si pasa.
- Recuerda que hay que cerrar sesión para que el grupo `docker` tenga efecto.

En modo `--check` muestra las diferencias de `daemon.json` y del repositorio, y verifica las
condiciones previas, sin instalar ni descargar nada.

---

## 7. Validación

```bash
# [servidor]
docker --version && docker compose version
```

Criterio de aceptación: ambas responden; Compose es v2.

```bash
# [servidor]
systemctl is-enabled docker && systemctl is-active docker
```

Criterio de aceptación: `enabled` y `active`.

```bash
# [servidor]
docker info --format '{{.LoggingDriver}} {{.LiveRestoreEnabled}} {{.Driver}}'
```

Criterio de aceptación: `json-file true overlay2`.

```bash
# [servidor]
docker network inspect ${DOCKER_RED_PROXY} --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
```

Criterio de aceptación: devuelve `${DOCKER_RED_PROXY_SUBRED}`.

```bash
# [servidor] — las subredes de Docker no deben solapar con la LAN
docker network ls --format '{{.Name}}' | while read -r r; do
    docker network inspect "$r" --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}}{{end}}'
done
```

Criterio de aceptación: ninguna subred cae dentro de `${LAN_CIDR}`.

```bash
# [servidor]
sysctl -n net.ipv4.ip_forward
```

Criterio de aceptación: `1`. Lo activa Docker al arrancar.

```bash
# [servidor]
grep -c 'iptables' /etc/docker/daemon.json || echo "0 (correcto)"
```

Criterio de aceptación: `0`.

```bash
# [servidor]
docker run --rm --network ${DOCKER_RED_PROXY} alpine sh -c 'nslookup deb.debian.org' >/dev/null \
    && echo "RED DE CONTENEDORES OK"
```

Criterio de aceptación: `RED DE CONTENEDORES OK`.

```bash
# [servidor] — ningún puerto publicado
docker ps --format '{{.Ports}}' | grep -c '0.0.0.0' || echo "0 (correcto)"
```

Criterio de aceptación: `0`.

```bash
# [servidor] — el cortafuegos sigue en pie
sudo nft list chain inet nomad_filter entrada | grep -c 'policy drop'
```

Criterio de aceptación: `1`. Instalar Docker no debe haber alterado nuestra tabla.

**Prueba de reinicio:** `sudo reboot`, y después comprobar que `docker ps` responde y que la red
`${DOCKER_RED_PROXY}` sigue existiendo.

---

## 8. Reversión

```bash
# [servidor] — solo la configuración del demonio
sudo mv /etc/docker/daemon.json /etc/docker/daemon.json.desactivado
sudo systemctl restart docker
```

```bash
# [servidor] — quitar el usuario del grupo docker
sudo gpasswd -d ${ADMIN_USUARIO} docker
```

```bash
# [servidor] — desinstalar Docker por completo
docker compose ls --format json | jq -r '.[].ConfigFiles' | while read -r f; do
    docker compose -f "$f" down
done
sudo systemctl disable --now docker docker.socket containerd
sudo apt purge -y docker-ce docker-ce-cli containerd.io \
                  docker-buildx-plugin docker-compose-plugin
sudo rm -rf /var/lib/docker /var/lib/containerd
sudo rm -f /etc/apt/sources.list.d/docker.sources /etc/apt/keyrings/docker.asc
sudo apt update
```

> `rm -rf /var/lib/docker` **borra todos los volúmenes**, es decir, los datos de todos los
> proyectos. Antes de ejecutarlo, respalda con el procedimiento del capítulo
> [14](14_respaldos_restic.md).

---

## 9. Errores frecuentes

| Síntoma | Causa probable | Solución | Documentación |
|---|---|---|---|
| Los contenedores no tienen red | `net.ipv4.ip_forward = 0` en algún archivo de sysctl | `grep -rn ip_forward /etc/sysctl.d/`, elimínalo y `sudo sysctl -w net.ipv4.ip_forward=1` | Capítulo [07](07_endurecimiento_del_sistema.md) § 3.3 |
| El ping funciona pero no resuelve nombres | DNS del host mal configurado: los contenedores heredan sus resolutores | Revisa `/etc/resolv.conf` | Capítulo [06](06_red_y_firewall.md) § 3.3 |
| Todo se rompe tras `"iptables": false` | Docker no puede crear sus reglas de red | Quita esa línea de `daemon.json` y reinicia Docker | [Docker — Filtrado de paquetes](https://docs.docker.com/engine/network/packet-filtering-firewalls/) |
| El servidor pierde acceso al router al crear proyectos | Docker asignó una subred que solapa con la LAN | Configura `default-address-pools` (§ 3.3) y recrea las redes afectadas | [Docker — daemon.json](https://docs.docker.com/reference/cli/dockerd/) |
| `/var` se llena de golpe | Registros de contenedores sin rotar | Verifica `log-opts` en `daemon.json`. Limpia con `docker system prune -a` | § 3.4 |
| `permission denied` al hablar con el socket | El usuario no está en el grupo `docker`, o no se ha reiniciado la sesión | `sudo usermod -aG docker $USER` y **vuelve a entrar** | [Docker — Post-instalación](https://docs.docker.com/engine/install/linux-postinstall/) |
| `docker-compose: command not found` | Se busca la herramienta antigua | Usa `docker compose` (con espacio), que es el plugin v2 | [Docker Compose v2](https://docs.docker.com/compose/) |
| Los contenedores se caen al actualizar Docker | Falta `live-restore` | Añádelo a `daemon.json` (§ 3.5) | [Docker — Live restore](https://docs.docker.com/engine/daemon/live-restore/) |
| Un contenedor no arranca tras reiniciar el servidor | Política de reinicio `no` o `on-failure` | Usa `restart: unless-stopped` | § 3.8 |
| Las reglas del cortafuegos desaparecen al recargar nftables | `/etc/nftables.conf` tiene `flush ruleset` | Elimínalo (capítulo 06 § 3.4) y `sudo systemctl restart docker` | Capítulo [06](06_red_y_firewall.md) |
| `docker network create` falla con «Pool overlaps» | Ya existe una red con esa subred | `docker network ls` y elimina la que sobre, o cambia `DOCKER_RED_PROXY_SUBRED` | [Docker — Redes](https://docs.docker.com/engine/network/) |
| Un contenedor no llega a otro por su nombre | No están en la misma red | Conecta ambos a `${DOCKER_RED_PROXY}` y comprueba con `docker network inspect` | [Docker — DNS interno](https://docs.docker.com/engine/network/#dns-services) |

---

## 10. Referencias

- [Docker — Instalación en Debian](https://docs.docker.com/engine/install/debian/)
- [Docker — Pasos posteriores a la instalación](https://docs.docker.com/engine/install/linux-postinstall/)
- [Docker — Filtrado de paquetes y cortafuegos](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
- [Docker — Configuración del demonio](https://docs.docker.com/reference/cli/dockerd/)
- [Docker — Redes](https://docs.docker.com/engine/network/)
- [Docker Compose — Especificación](https://docs.docker.com/reference/compose-file/)
- [Docker — Live restore](https://docs.docker.com/engine/daemon/live-restore/)
- [Docker — Seguridad](https://docs.docker.com/engine/security/)

---

**Anterior:** [08 — Tailscale](08_tailscale.md) · **Siguiente:** [10 — Traefik](10_traefik.md)
