# 15 — Mantenimiento y actualizaciones

> Lo que hay que hacer para que dentro de tres años el servidor siga siendo el mismo servidor y no
> una acumulación de parches que nadie se atreve a tocar.

---

## 1. Objetivo

Al terminar tendrás una rutina concreta —semanal, mensual y trimestral— con comandos exactos, sabrás
actualizar contenedores y ampliar volúmenes sin sustos, y tendrás el procedimiento para subir de
versión mayor de Debian cuando llegue el momento.

---

## 2. Requisitos previos

**Capítulos previos:** [14 — Respaldos con restic](14_respaldos_restic.md). La rutina incluye
verificar los respaldos, así que tienen que existir.

**Necesitas a mano:**

- Acceso por SSH.
- Un recordatorio en el calendario. Es la parte que más se incumple, y el único requisito que no
  depende del servidor.

**Preparar la sesión.** Igual que en todos los capítulos anteriores, y **también para las rutinas**:
los comandos de mantenimiento usan `${DATOS_RAIZ}`, `${CF_CONFIG_DIR}`, `${RESTIC_USB_MOUNT}` y
`${DOMINIO_PUBLICO}`.

```bash
# [servidor]
cd ~/nomad_server
source scripts/lib/entorno.sh
```

> **Meses después, este es el paso que se olvida.** Cuando vuelves al servidor tras semanas sin
> tocarlo, lo natural es pegar directamente el comando de la rutina; y `df -h ${RESTIC_USB_MOUNT}`
> con la variable vacía informa del disco raíz en lugar del de respaldo, sin dar ningún error.
> Ponlo en el calendario junto con el recordatorio: *«entrar, `source scripts/lib/entorno.sh`,
> rutina»*.

**Tiempo estimado:** 15 minutos al mes en régimen normal.

---

## 3. Decisiones y por qué

### 3.1 Lo automático y lo manual, separados a propósito

**Decisión: el sistema se parchea solo; los contenedores se actualizan a mano.**

| Qué | Cómo | Por qué |
|---|---|---|
| Parches de seguridad de Debian | Automático (capítulo 07) | Bajo riesgo de rotura, alto coste de no aplicarlos |
| Kernel y reinicio | Automático, a las 04:00 | Un parche de kernel sin reiniciar no protege |
| Imágenes de contenedor | **Manual** | Una versión mayor puede cambiar el formato de datos o la configuración |
| Versiones mayores de Debian | **Manual**, cada 2–3 años | Requiere leer las notas de publicación |

La línea divisoria es sencilla: **se automatiza lo que rara vez rompe algo, y se hace a mano lo que
puede romperlo de forma difícil de deshacer.**

### 3.2 Tres frecuencias, no una

**Decisión: rutina semanal, mensual y trimestral.**

Una sola lista mensual con veinte comprobaciones se acaba saltando. Tres listas cortas, cada una con
lo que corresponde a su frecuencia, se cumplen.

| Frecuencia | Duración | Qué responde |
|---|---|---|
| Semanal | 2 minutos | «¿Está todo en marcha y queda espacio?» |
| Mensual | 15 minutos | «¿Hay actualizaciones? ¿Los respaldos sirven?» |
| Trimestral | 45 minutos | «¿Ha empeorado algo sin que me diera cuenta?» |

### 3.3 Actualizar contenedores de uno en uno

**Decisión: nunca actualizar todas las imágenes a la vez.**

Actualizar cinco proyectos en una tarde y descubrir que algo falla deja la pregunta de cuál de los
cinco fue. De uno en uno, con su comprobación, el diagnóstico es inmediato.

El orden importa: primero la infraestructura (Traefik, cloudflared), después los proyectos. Si
Traefik falla, todo cae, y conviene descubrirlo con un cambio a la vez.

### 3.4 Respaldar antes de actualizar

**Decisión: `restic` inmediatamente antes de cualquier actualización que toque datos.**

El respaldo nocturno puede tener hasta 24 horas. Si una migración de base de datos sale mal a las
11 de la mañana, restaurar la copia de anoche pierde el trabajo del día.

```bash
sudo ./scripts/14_restic.sh --ahora
```

Tarda segundos gracias a la deduplicación. No hay excusa para saltárselo.

### 3.5 Limpiar Docker con criterio

**Decisión: `docker system prune` sin `-a`, salvo cuando hace falta espacio.**

| Comando | Qué borra | Riesgo |
|---|---|---|
| `docker system prune` | Contenedores parados, redes sin usar, caché de construcción | Bajo |
| `docker system prune -a` | Además, **todas las imágenes sin contenedor en marcha** | Hay que volver a descargarlo todo; con red lenta, el arranque tras un reinicio se alarga mucho |
| `docker volume prune` | Volúmenes sin usar | **Puede borrar datos.** Este montaje usa montajes de directorio, así que no debería haber volúmenes con datos, pero conviene revisar antes |

**Y hay una razón más para no usar `-a` justo después de actualizar**, que es cuando más tienta:
las imágenes «sin usar» que ves ahí incluyen **la versión anterior de lo que acabas de actualizar**.
Es exactamente la que necesitarías para volver atrás si la nueva resulta tener un problema que no se
nota el primer día.

```console
$ docker system df
TYPE      TOTAL   ACTIVE   SIZE      RECLAIMABLE
Images    13      7        2.52GB    97.56MB (3%)
```

Seis imágenes inactivas ocupando 97 MB en un disco con decenas de gigas libres no son un problema
que resolver: son tu vía de vuelta. Deja que se acumulen un ciclo o dos y límpialas cuando el
espacio apriete de verdad, o cuando la versión nueva lleve un mes funcionando.

### 3.6 Ampliar volúmenes en caliente

**Decisión: dejar espacio sin asignar en el grupo de volúmenes y ampliar cuando haga falta.**

Es la razón por la que se usó LVM en el capítulo 03. Ampliar `/var` o `/srv` no requiere reiniciar,
ni parar servicios, ni desmontar nada:

```bash
sudo lvextend -r -L +20G /dev/vg0/var
```

`-r` redimensiona el sistema de archivos en el mismo paso.

**Reducir sí es arriesgado**, y por eso el capítulo 03 asignó tamaños conservadores: siempre es
mejor crecer que tener que encoger.

---

## 4. Variables usadas

### 4.1 De `config/servidor.env`

Este capítulo no introduce ninguna variable nueva, pero sus rutinas usan varias de las existentes.
Conviene tenerlo presente porque son comandos que se ejecutan meses después, en sesiones nuevas:

| Variable | Dónde aparece en la rutina |
|---|---|
| `DATOS_RAIZ` | Actualizar Traefik, la observabilidad y los proyectos |
| `CF_CONFIG_DIR` | Actualizar `cloudflared` |
| `RESTIC_USB_MOUNT` | Comprobar el espacio del disco de respaldo (semanal) |
| `RESTIC_REPO_LOCAL` | Verificar el repositorio (mensual y trimestral) |
| `DOMINIO_PUBLICO` | Comprobar que un subdominio responde tras actualizar |
| `DEBIAN_SUITE` | Subir de versión mayor (§ 5.4) |

```bash
# [servidor] — antes de cualquier rutina
cd ~/nomad_server && source scripts/lib/entorno.sh
```

### 4.2 La única variable que este capítulo CAMBIA

| Variable | Cuándo | Cómo |
|---|---|---|
| `DEBIAN_SUITE` | Al subir de versión mayor de Debian (cada 2–3 años) | `./scripts/variables.sh --fijar DEBIAN_SUITE=forky` |

Cambiarla en `config/servidor.env` **no basta**: la suite aparece también en los tres archivos
`.sources` del sistema (Debian, Docker y Tailscale), que hay que actualizar a la vez. El § 5.4 lo
detalla.

### 4.3 Variables temporales de las rutinas

| Variable | Qué contiene | Dónde |
|---|---|---|
| `PROYECTO` | Proyecto que estás actualizando | § 5.2 paso 4 |
| `DISCO` | Disco cuya salud estás comprobando | § 5.3 paso 3 |

Las dos se declaran en el momento y desaparecen al cerrar la sesión, igual que en los capítulos
[12](12_despliegue_de_proyectos.md) y [14](14_respaldos_restic.md).

---

## 5. Procedimiento

### 5.0 El arranque de toda rutina

Los tres bloques que siguen empiezan igual. Vale la pena memorizarlo o dejarlo en el recordatorio
del calendario:

```bash
# [cliente]
ssh nomad
```

```bash
# [servidor]
cd ~/nomad_server
source scripts/lib/entorno.sh
```

El script `verificar_sistema.sh` **no lo necesita** —carga la configuración por su cuenta— pero los
comandos manuales de las rutinas sí.

### 5.1 Rutina semanal — 2 minutos

```bash
# [servidor]
./scripts/verificar_sistema.sh --rapido
```

Y si prefieres hacerlo a mano:

```bash
# [servidor] — ¿está todo en marcha?
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

Criterio: todos `Up` y `(healthy)`.

```bash
# [servidor] — ¿queda espacio?
df -h / /var /srv
[ -n "${RESTIC_USB_UUID}" ] && df -h ${RESTIC_USB_MOUNT}
```

Criterio: ninguno por encima del 80 %. El disco de respaldo solo se comprueba si lo hay: con
respaldo remoto, `${RESTIC_USB_MOUNT}` no existe y `df` daría un error que no significa nada.

```bash
# [servidor] — ¿se hizo el respaldo de anoche?
sudo ./scripts/14_restic.sh --estado
```

Criterio: la última copia tiene menos de 30 horas.

```bash
# [servidor] — ¿hay errores nuevos?
journalctl -p err --since "7 days ago" --no-pager | tail -20
```

```bash
# [servidor] — ¿sigue vigente la prueba de restauración?
cat /var/backups/nomad/ultima-prueba-restauracion 2>/dev/null \
    || echo "NUNCA se ha probado una restauración"
```

Criterio: la fecha tiene menos de un mes. Es la comprobación que separa «tengo respaldos» de «sé
que sirven», y la que más se deja para después.

### 5.2 Rutina mensual — 15 minutos

**Paso 1 — Respaldar antes de tocar nada.**

```bash
# [servidor]
sudo ./scripts/14_restic.sh --ahora
```

**Paso 2 — Comprobar el sistema base.**

```bash
# [servidor]
sudo apt update
apt list --upgradable
```

Las actualizaciones de seguridad ya se aplicaron solas. Aquí aparece lo que `unattended-upgrades` no
toca: paquetes que requieren instalar o eliminar otros.

> **Antes de lanzar esto, mira por dónde estás conectado.** Si administras por Tailscale —lo
> normal en este montaje— y la actualización incluye el paquete `tailscale`, al instalarlo se
> reinicia `tailscaled`, **cae la interfaz por la que viaja tu sesión SSH** y el terminal muere con
> `apt` a medias. Reanudar de eso es reparar `dpkg` a mano, y hacerlo desde una sesión que también
> se puede caer.
>
> Hay dos formas de no pasar por ahí, y basta con una:
>
> ```bash
> # [servidor] — dentro de tmux, la sesión sobrevive a que se corte el SSH
> tmux new -s mantenimiento
> # …y si te desconecta:  ssh nomad  →  tmux attach -t mantenimiento
> ```
>
> ```bash
> # [cliente] — o conéctate por la LAN, que no depende de Tailscale
> ssh ${ADMIN_USUARIO}@${LAN_IP}
> ```
>
> Lo mismo vale para cualquier actualización larga: `tmux` cuesta cinco segundos y evita la única
> forma habitual de romper un servidor durante el mantenimiento.

```bash
# [servidor] — dentro de tmux
sudo apt full-upgrade
sudo apt autoremove --purge
```

```bash
# [servidor] — si actualizaste tailscale, comprueba que volvió
tailscale status --peers=false
```

Criterio: aparece el servidor con su IP. Si no vuelve en un minuto,
`sudo systemctl restart tailscaled`.

```bash
# [servidor] — ¿queda algún reinicio pendiente?
[ -f /var/run/reboot-required ] && cat /var/run/reboot-required.pkgs
```

**Paso 3 — Actualizar la infraestructura**, de una en una.

```bash
# [servidor] — Traefik
cd ${DATOS_RAIZ}/traefik
# Consulta la versión actual en https://github.com/traefik/traefik/releases
vim docker-compose.yml          # cambia la etiqueta: v3.7 → v3.8
docker compose pull
docker compose up -d
docker compose ps
```

Y comprueba antes de seguir:

```bash
# [servidor] — sustituye 'miproyecto' por uno tuyo que esté publicado
docker exec traefik traefik healthcheck --ping
curl -sI https://miproyecto.${DOMINIO_PUBLICO} | head -1
```

Criterio: `OK` y `HTTP/2 200`. Si Traefik responde pero el proyecto da `404`, la versión nueva ha
cambiado algo del descubrimiento de contenedores: vuelve a la etiqueta anterior en el
`docker-compose.yml` y levanta otra vez antes de investigar. Con el sitio en pie se piensa mejor.

```bash
# [servidor] — cloudflared
cd ${CF_CONFIG_DIR}
vim docker-compose.yml
docker compose pull && docker compose up -d
docker logs cloudflared | grep -c 'Registered tunnel connection'
```

```bash
# [servidor] — observabilidad
cd ${DATOS_RAIZ}/observabilidad
vim docker-compose.yml
docker compose pull && docker compose up -d
```

**Paso 4 — Actualizar los proyectos.**

```bash
# [servidor]
./scripts/deploy.sh --listar
./scripts/deploy.sh mi-proyecto
```

**Paso 5 — Limpiar.**

```bash
# [servidor] — qué está ocupando espacio
docker system df
```

```bash
# [servidor] — limpieza segura
docker system prune -f
```

```bash
# [servidor] — ¿hay volúmenes huérfanos?
docker volume ls -f dangling=true
```

Revísalos **antes** de borrarlos. Este montaje usa montajes de directorio, así que no debería haber
volúmenes con datos.

**Paso 6 — Verificar los respaldos.** Son dos comprobaciones distintas y hacen falta las dos.

```bash
# [servidor] — integridad de los DATOS, no solo de la estructura
sudo ./scripts/14_restic.sh --verificar-datos
```

`--verificar` a secas comprueba que la estructura del repositorio es coherente, y es rápido porque
no lee el contenido. `--verificar-datos` **descarga y descifra una muestra del 5 %**, que es lo
único que detecta un repositorio degradándose en silencio: un disco con sectores que empiezan a
fallar, o un objeto que el proveedor perdió. Ese fallo no se nota nunca hasta que restauras, y
entonces ya no hay nada que hacer.

Con repositorio remoto, este comando además **mide tu velocidad real de descarga**. Si el 5 % tarda
diez minutos, restaurar el 100 % te llevará más de tres horas: conviene saberlo antes de necesitarlo,
no durante.

```bash
# [servidor] — y la prueba de restauración, que es otra cosa
sudo ./scripts/14_restic.sh --probar
```

Verificar comprueba que los datos **están íntegros**; restaurar comprueba que **sirven**. Un
repositorio puede pasar `--verificar-datos` sin un fallo y aun así no permitirte reconstruir el
servidor, porque falte un archivo que nunca se respaldó o porque los permisos no se conserven. Son
preguntas distintas y las dos importan.

La prueba deja la fecha en `/var/backups/nomad/ultima-prueba-restauracion`, y la rutina semanal
protesta si pasa de un mes. Si estás leyendo esto porque la semanal protestó, este es el paso.

**Paso 7 — Revisar los registros.**

```bash
# [servidor] — accesos rechazados por el cortafuegos
sudo journalctl -k --since "30 days ago" | grep -c 'nomad-descartado'

# [servidor] — intentos de acceso bloqueados
sudo fail2ban-client status sshd

# [servidor] — errores de Traefik
docker logs traefik --since 720h 2>&1 | grep -i error | tail -20
```

### 5.3 Rutina trimestral — 45 minutos

**Paso 1 — La prueba de restauración.**

```bash
# [servidor]
sudo ./scripts/14_restic.sh --probar
```

Esto es lo más importante de la rutina trimestral. Un respaldo que no se restaura desde hace meses
es un respaldo cuya validez es una suposición.

**Paso 2 — Verificación profunda del repositorio.**

```bash
# [servidor]
sudo ./scripts/14_restic.sh --verificar-datos
```

Lee y descifra una muestra real: es lo único que detecta un disco degradándose en silencio.

**Paso 3 — Salud del hardware.**

```bash
# [servidor] — todos los discos, no solo el primero
for DISCO in $(lsblk -dno PATH,TYPE | awk '$2=="disk"{print $1}'); do
    echo "=== ${DISCO}"
    sudo smartctl -H "${DISCO}" | grep -E 'result|SMART'
    sudo smartctl -A "${DISCO}" | grep -E 'Reallocated|Pending|Wear|Percent|Power_On_Hours'
done
sensors 2>/dev/null || echo "(ejecuta sensors-detect si quieres temperaturas)"
```

Criterio: `PASSED` en todos, y ningún sector reasignado **nuevo** respecto al trimestre anterior.
Anota los valores: un `Reallocated_Sector_Ct` que sube de 0 a 4 no rompe nada hoy, pero es el aviso
que da un disco antes de morirse.

**Paso 4 — Comparar la auditoría de seguridad.**

```bash
# [servidor]
sudo lynis audit system --quick --quiet \
    --report-file ~/nomad_server/inventario/lynis-$(date +%F).dat

# Sin este chown el informe queda de root dentro de tu directorio y el grep de
# abajo se salta precisamente el que acabas de generar, en silencio.
sudo chown "${USER}:" ~/nomad_server/inventario/lynis-$(date +%F).dat

grep -h '^hardening_index' ~/nomad_server/inventario/lynis-*.dat | tail -5
```

Criterio: aparece una línea **por cada auditoría**, la de hoy incluida. Si ves menos líneas que
archivos hay en `inventario/`, alguna no se puede leer.

El número absoluto no dice nada. **Que haya bajado sí**: significa que algo se desactivó por el
camino.

**Paso 5 — Revisar la superficie expuesta.**

```bash
# [servidor] — qué escucha en TODAS las interfaces, mirando la columna local
ss -tulnH | awk '{print $5}' | grep -E '^(0\.0\.0\.0|\*|\[::\]):' | sort -u

# [servidor] — y qué abre el cortafuegos, ENTERO
# Filtrar por 'dport' se deja fuera las reglas por interfaz o por origen, que
# son las que dejan entrar a Tailscale: verías menos superficie de la que hay.
sudo nft list chain inet nomad_filter entrada

# [servidor] — ningún puerto publicado por Docker en todas las interfaces
sudo ss -tulpnH | awk '$5 ~ /^(0\.0\.0\.0|\*|\[::\]):/ && /docker-proxy/'

docker ps --format 'table {{.Names}}\t{{.Ports}}'
```

Criterio: la intersección de las dos primeras listas es SSH y, tras el capítulo
[08](08_tailscale.md), el `udp 41641` de Tailscale. Ten presente que la cadena tiene además reglas
**por interfaz y por rango** —`iifname tailscale0 accept` y el CGNAT `100.64.0.0/10`—, así que todo
lo que escuche en la loopback o en la IP de Tailscale es alcanzable **desde tu tailnet** aunque no
aparezca en la primera lista. Es el diseño, no un descuido: la tailnet es red de confianza. El tercer comando no debe imprimir nada:
**Docker se salta la cadena de entrada**, así que un puerto suyo en `0.0.0.0` está expuesto tenga o
no regla (capítulo [07](07_endurecimiento_del_sistema.md) § 7).

> No filtres por la línea entera buscando `0.0.0.0`: `ss` imprime `0.0.0.0:*` en la columna del par
> remoto de **todo** socket en escucha, así que casaría con todas y el criterio dejaría de decir
> nada. Se mira la quinta columna, la dirección local.

```bash
# [cliente, desde fuera de tu red]
nmap -Pn -F <tu-ip-publica>
```

Criterio: nada abierto.

**Paso 6 — Revisar accesos y credenciales.**

```bash
# [servidor] — llaves SSH autorizadas
ssh-keygen -lf ~/.ssh/authorized_keys
```

¿Reconoces todas? Elimina las de equipos que ya no uses.

En <https://login.tailscale.com/admin/machines>: elimina los dispositivos que ya no existan y
comprueba que el servidor sigue con la caducidad de clave desactivada.

En Cloudflare, **DNS → Records**: elimina los registros de proyectos que ya no estén desplegados.

**Paso 7 — Revisar el espacio a medio plazo.**

```bash
# [servidor]
sudo vgs
sudo lvs
df -h
sudo ncdu /var --exclude /var/lib/docker
```

Si algún volumen supera el 70 %, amplíalo ahora en lugar de esperar a que se llene:

```bash
# [servidor] — el nombre del grupo es el de TU servidor, no 'vg0'
VG="$(sudo vgs --noheadings -o vg_name | tr -d ' ')"
echo "Grupo de volúmenes: ${VG}"
sudo lvextend -r -L +20G "/dev/${VG}/var"
df -h /var
```

El nombre del grupo lo eligió el instalador en el capítulo [03](03_instalacion_debian.md) y suele ser
el del servidor. Copiar un `/dev/vg0/var` de ejemplo falla sin más, pero conviene sacarlo del sistema
en lugar de adivinarlo: `lvextend` sobre el volumen equivocado sí haría algo, y no lo que querías.

> `-r` redimensiona además el sistema de archivos. Sin él amplías el volumen y `df` sigue mostrando
> el tamaño antiguo, que es un desconcierto clásico.

### 5.4 Subir de versión mayor de Debian

Cada 2–3 años. Debian 13 tiene soporte estándar hasta agosto de 2028 y LTS hasta junio de 2030: no
hay ninguna prisa.

**Antes de empezar:**

```bash
# [servidor]
sudo ./scripts/14_restic.sh --ahora
sudo ./scripts/14_restic.sh --probar
```

Lee las notas de publicación de la versión de destino **enteras**. No es un formalismo: ahí están
los cambios que romperán algo.

```bash
# [servidor] — 1. partir de un sistema completamente al día
sudo apt update && sudo apt full-upgrade
sudo apt autoremove --purge
sudo reboot
```

```bash
# [servidor] — 2. comprobar que no hay paquetes retenidos ni a medio configurar
dpkg --audit
apt-mark showhold
```

```bash
# [servidor] — 3. cambiar la suite en los repositorios
sudo mkdir -p /var/backups/nomad/config/etc/apt/sources.list.d
sudo cp -a /etc/apt/sources.list.d/debian.sources \
    /var/backups/nomad/config/etc/apt/sources.list.d/debian.sources.bak-$(date +%F)
sudo sed -i 's/trixie/forky/g' /etc/apt/sources.list.d/debian.sources
sudo apt update
```

```bash
# [servidor] — 4. actualización en dos fases
sudo apt upgrade --without-new-pkgs
sudo apt full-upgrade
sudo reboot
```

La primera fase actualiza lo que no requiere instalar paquetes nuevos, lo que reduce mucho el riesgo
de dejar el sistema a medias.

```bash
# [servidor] — 5. después
cat /etc/os-release | grep VERSION
sudo apt autoremove --purge
./scripts/verificar_sistema.sh
```

```bash
# [servidor] — 6. actualizar la suite en la configuración del repositorio
cd ~/nomad_server
./scripts/variables.sh --fijar DEBIAN_SUITE=forky
source scripts/lib/entorno.sh
echo "DEBIAN_SUITE=${DEBIAN_SUITE}"
```

Y con la variable ya cambiada, **vuelve a instalar los tres archivos de repositorio desde sus
plantillas**, que es lo que garantiza que los tres queden coherentes:

```bash
# [servidor]
nomad_diff etc/debian.sources    /etc/apt/sources.list.d/debian.sources
nomad_diff etc/docker.sources    /etc/apt/sources.list.d/docker.sources
nomad_diff etc/tailscale.sources /etc/apt/sources.list.d/tailscale.sources
```

```bash
# [servidor]
nomad_plantilla etc/debian.sources    | sudo tee /etc/apt/sources.list.d/debian.sources    >/dev/null
nomad_plantilla etc/docker.sources    | sudo tee /etc/apt/sources.list.d/docker.sources    >/dev/null
nomad_plantilla etc/tailscale.sources | sudo tee /etc/apt/sources.list.d/tailscale.sources >/dev/null
sudo apt update
```

Alternativa rápida, si prefieres no tocar las plantillas:

```bash
# [servidor]
sudo sed -i 's/trixie/forky/' /etc/apt/sources.list.d/docker.sources
sudo sed -i 's/trixie/forky/' /etc/apt/sources.list.d/tailscale.sources
sudo apt update
```

**Comprobación final de coherencia.** Es lo que evita el fallo silencioso de quedarse con un
repositorio apuntando a la versión antigua:

```bash
# [servidor]
grep -H '^Suites:' /etc/apt/sources.list.d/*.sources
echo "esperado: ${DEBIAN_SUITE}"
```

Criterio de aceptación: los tres archivos mencionan la suite nueva. Un repositorio que se quede en
`trixie` deja de recibir paquetes y `apt` lo dirá con un aviso fácil de pasar por alto.

Recuerda también que `${distro_codename}` de `unattended-upgrades` **no hay que tocarla**: APT la
resuelve sola a la suite nueva. Es justo el motivo por el que se dejó como variable (capítulo
[07 § 4.2](07_endurecimiento_del_sistema.md)).

---

## 6. Script asociado

### 6.1 Vía A — con los scripts

`scripts/verificar_sistema.sh` recorre todas las comprobaciones de los capítulos 04 a 14 y da un
veredicto único.

```bash
# [servidor]
./scripts/verificar_sistema.sh --help
./scripts/verificar_sistema.sh --rapido       # rutina semanal, 2 minutos
sudo ./scripts/verificar_sistema.sh           # completo, para la rutina mensual
./scripts/verificar_sistema.sh --seccion red  # solo un bloque
```

Algunas comprobaciones necesitan privilegios (nftables, fail2ban, restic): para el informe completo,
ejecútalo con `sudo`.

Los otros dos scripts del día a día:

```bash
# [servidor]
./scripts/deploy.sh --listar                  # estado de todos los proyectos
sudo ./scripts/14_restic.sh --estado          # estado de los respaldos
./scripts/variables.sh --estado               # ¿sigue la configuración como la dejaste?
```

Comprueba, por bloques:

| Bloque | Qué verifica |
|---|---|
| `sistema` | Versión, reinicios pendientes, actualizaciones, hora, suspensión |
| `seguridad` | SSH, fail2ban, AppArmor, actualizaciones automáticas, puertos en escucha |
| `red` | Cortafuegos con política `drop`, IP estática, DNS, Tailscale |
| `docker` | Demonio, redes, contenedores sanos, puertos publicados |
| `publicacion` | Traefik, túnel, respuesta de un subdominio |
| `respaldos` | Disco montado, temporizador, antigüedad de la última copia |

No modifica nada: solo lee.

### 6.2 Correspondencia entre el script y las rutinas manuales

| Bloque de la rutina | ¿Lo cubre `verificar_sistema.sh`? | Lo que sigue siendo tuyo |
|---|---|---|
| Semanal, entera | **Sí**, con `--rapido` | Leer el resultado |
| Mensual: comprobar el estado | Sí | — |
| Mensual: **aplicar** actualizaciones | No | `apt full-upgrade`, `docker compose pull`, `deploy.sh` |
| Mensual: limpiar Docker | No | `docker system prune -f` |
| Mensual: verificar respaldos | Sí, lo comprueba; `14_restic.sh --verificar` lo ejecuta | — |
| Trimestral: prueba de restauración | No | `sudo ./scripts/14_restic.sh --probar` |
| Trimestral: hardware, Lynis, credenciales | Parcial | Comparar con el trimestre anterior |

### 6.3 Si prefieres la vía manual

Las rutinas de la sección 5 son la vía manual completa. Lo que asumes:

- [ ] Cargar el entorno antes de empezar (§ 5.0), o los comandos con `${…}` no harán lo que dicen.
- [ ] Respaldar **antes** de cualquier actualización que toque datos (§ 3.4).
- [ ] Actualizar de una en una y comprobar entre medias (§ 3.3).
- [ ] Revisar los volúmenes huérfanos antes de borrarlos (§ 3.5).
- [ ] Anotar los valores de Lynis y de SMART para poder compararlos el trimestre siguiente.

---

## 7. Validación

```bash
# [servidor]
./scripts/verificar_sistema.sh
```

Criterio de aceptación: termina con `Todas las comprobaciones han pasado` y código de salida 0.

```bash
# [servidor] — el sistema está al día
apt-get -s upgrade 2>/dev/null | grep -c '^Inst'
```

Criterio de aceptación: `0`.

```bash
# [servidor] — el respaldo es reciente
sudo ./scripts/14_restic.sh --estado | grep 'Última copia'
```

Criterio de aceptación: menos de 30 horas.

```bash
# [servidor] — el disco no está cerca de llenarse
df -h / /var /srv | awk 'NR>1 {gsub("%","",$5); if ($5+0 > 80) print "LLENO: " $6 " " $5 "%"}'
```

Criterio de aceptación: no imprime nada.

```bash
# [servidor] — el índice de endurecimiento no ha bajado
grep '^hardening_index' ~/nomad_server/inventario/lynis-*.dat | tail -3
```

Criterio de aceptación: la tendencia es estable o al alza.

```bash
# [servidor] — la configuración del repositorio sigue coincidiendo con la realidad
cd ~/nomad_server && source scripts/lib/entorno.sh
./scripts/variables.sh --estado | grep -E 'FALTA|SIN CAMBIAR' || echo "CORRECTO"
```

Criterio de aceptación: `CORRECTO`. Si algo aparece como pendiente meses después del montaje,
significa que se cambió algo en el servidor sin reflejarlo en `config/servidor.env`, y la
reconstrucción del capítulo [16](16_recuperacion_ante_desastres.md) fallaría por ahí.

```bash
# [servidor] — las tres suites coinciden
grep -h '^Suites:' /etc/apt/sources.list.d/*.sources | sort -u
```

Criterio de aceptación: todas mencionan `${DEBIAN_SUITE}`.

**Comprobaciones de calendario, que son las que fallan:**

- [ ] Tengo un recordatorio mensual en el calendario.
- [ ] Tengo un recordatorio trimestral.
- [ ] La última prueba de restauración fue hace menos de tres meses.

---

## 8. Reversión

Este capítulo no aplica configuración: describe una rutina. Lo que sí conviene saber revertir es
cada operación de mantenimiento.

**Una actualización de contenedor que ha salido mal:**

```bash
# [servidor]
cd ${DATOS_RAIZ}/<proyecto>
vim docker-compose.yml          # vuelve a la etiqueta anterior
docker compose up -d
```

Si la versión nueva migró datos, volver a la anterior puede no bastar: restaura desde el respaldo
(capítulo [16](16_recuperacion_ante_desastres.md)).

**Una actualización del sistema que ha roto algo:**

```bash
# [servidor] — arrancar con el kernel anterior
# En el menú de GRUB: Advanced options → una versión anterior
```

Debian no admite revertir paquetes de forma segura. Si el sistema queda inservible, la vía es la
reconstrucción del capítulo 16, que con los respaldos al día lleva unas dos horas.

**Una subida de versión mayor a medias:**

```bash
# [servidor]
sudo dpkg --configure -a
sudo apt --fix-broken install
```

Si no se recupera, restaura desde el respaldo. Es la razón por la que el paso previo a la subida es
respaldar **y probar la restauración**.

---

## 9. Errores frecuentes

| Síntoma | Causa probable | Solución | Documentación |
|---|---|---|---|
| `/var` se llena de golpe | Imágenes antiguas y caché de construcción | `docker system df` y luego `docker system prune -f` | § 3.5 |
| `/boot` se llena al actualizar el kernel | Kernels antiguos sin eliminar | `sudo apt autoremove --purge`. Verifica `Remove-Unused-Kernel-Packages` | Capítulo [07](07_endurecimiento_del_sistema.md) |
| `docker system prune -a` dejó el servidor sin imágenes | `-a` elimina todas las que no tengan contenedor en marcha | Se vuelven a descargar solas al levantar. Evita `-a` salvo emergencia de espacio | § 3.5 |
| Un contenedor no arranca tras actualizar | Cambio incompatible en la versión nueva | Vuelve a la etiqueta anterior. Lee las notas de publicación antes de subir | § 3.3 |
| La base de datos no arranca tras actualizar su imagen | Cambio de versión mayor con otro formato de datos | Restaura el respaldo previo a la actualización | Capítulo [16](16_recuperacion_ante_desastres.md) |
| `apt` avisa de paquetes retenidos | `unattended-upgrades` no instala cambios que requieran eliminar paquetes | `sudo apt full-upgrade` en la rutina mensual | § 5.2 |
| El respaldo tiene más de 30 horas | El temporizador no se ejecutó, o el disco estaba desconectado | `journalctl -u nomad-respaldo -n 50` | Capítulo [14](14_respaldos_restic.md) |
| `lvextend` dice «Insufficient free space» | El grupo de volúmenes está agotado | `sudo vgs` para verlo. Habría que añadir un disco al grupo | [Debian Wiki — LVM](https://wiki.debian.org/LVM) |
| Tras `lvextend` el espacio no aparece | Falta redimensionar el sistema de archivos | Usa `-r`, o `sudo resize2fs /dev/vg0/var` después | [`lvextend(8)`](https://manpages.debian.org/trixie/lvm2/lvextend.8.en.html) |
| Tras subir de versión mayor, Docker o Tailscale no actualizan | Sus repositorios siguen apuntando a la suite antigua | Cambia la suite en sus `.sources` | § 5.4 |
| El índice de Lynis ha bajado varios puntos | Algo se desactivó por el camino | `sudo lynis show suggestions` y compara con el informe anterior | Capítulo [07](07_endurecimiento_del_sistema.md) |
| Llevo meses sin hacer la rutina | Sin recordatorio en el calendario | Ponlo ahora. Es el único requisito que no depende del servidor | § 7 |
| `df -h ${RESTIC_USB_MOUNT}` informa del disco raíz | El entorno no estaba cargado y la variable se expandió a nada | `source scripts/lib/entorno.sh` antes de la rutina | § 5.0 |
| Tras subir de versión, Docker o Tailscale no reciben paquetes | Sus `.sources` siguen con la suite antigua | Reinstala las tres plantillas con la nueva `DEBIAN_SUITE` | § 5.4 |
| `config/servidor.env` ya no coincide con el servidor | Se hicieron cambios sin reflejarlos | `./scripts/variables.sh --estado` y corrige. La reconstrucción depende de ello | § 7 |
| `cd ${DATOS_RAIZ}/traefik` no encuentra el directorio | Ídem: variable vacía | Ídem | § 5.0 |

---

## 10. Referencias

- [Debian — Notas de publicación de Trixie](https://www.debian.org/releases/trixie/releasenotes)
- [Debian — Actualizar desde la versión anterior](https://www.debian.org/releases/trixie/amd64/release-notes/ch-upgrading.html)
- [Debian Wiki — UnattendedUpgrades](https://wiki.debian.org/UnattendedUpgrades)
- [Debian Wiki — LVM](https://wiki.debian.org/LVM)
- [Docker — Limpieza de recursos](https://docs.docker.com/engine/manage-resources/pruning/)
- [restic — Trabajar con repositorios](https://restic.readthedocs.io/en/stable/045_working_with_repos.html)
- [Traefik — Notas de publicación](https://github.com/traefik/traefik/releases)
- [checklists/mantenimiento.md](../checklists/mantenimiento.md) — la versión imprimible de estas rutinas
- Anexo [98 — Variables, entorno y sesiones](98_variables_y_entorno.md) § 5.3, el ritual al volver

---

**Anterior:** [14 — Respaldos con restic](14_respaldos_restic.md) · **Siguiente:** [16 — Recuperación ante desastres](16_recuperacion_ante_desastres.md)
