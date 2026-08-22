# 06 — Red y cortafuegos

> Fijar la dirección del servidor para que no cambie nunca, y cerrar todo lo que no tenga que estar
> abierto — sin romper Docker en el intento, que es donde falla la mayoría de las guías.

---

## 1. Objetivo

Al terminar el servidor tendrá una IP fija, resolución DNS estable, y un cortafuegos nftables que
descarta por omisión todo lo entrante salvo SSH desde la red local y el tráfico de Tailscale, sin
interferir con las reglas que Docker creará en el capítulo 09.

---

## 2. Requisitos previos

**Capítulos previos:** [05 — Usuarios y acceso SSH](05_usuarios_y_acceso_ssh.md).

**Necesitas a mano:**

- Acceso por SSH con llave, ya funcionando.
- `${LAN_IP}` reservada en el router (capítulo 00, paso 4).
- **Acceso físico al servidor o un plan alternativo.** Este capítulo puede dejarte sin conexión:
  cambiar la IP corta la sesión SSH, y una regla mal puesta cierra el puerto.

> **Sobre el orden de los capítulos.** El cortafuegos debe permitir `tailscale0` **antes** de que el
> capítulo 08 levante la VPN. Al revés, si estuvieras administrando por Tailscale, te cortarías el
> acceso a ti mismo. Por eso 06 va antes que 08.

**Preparar la sesión.**

```bash
# [servidor]
cd ~/nomad_server
source scripts/lib/entorno.sh
```

Y **una segunda terminal libre**, igual que en el capítulo 05: aquí se aplica un cortafuegos con
política de denegación por defecto, y la única forma de saber si sigues teniendo acceso es
comprobarlo desde otra sesión sin cerrar la actual.

> **Dos avisos sobre las sesiones, propios de este capítulo:**
>
> 1. **La red de seguridad del paso 5 no sobrevive a un reinicio.** Es un `sleep` en segundo plano:
>    si el servidor se reinicia, desaparece y el cortafuegos se carga con las reglas que hayas
>    dejado escritas. Si te has cerrado el acceso, la vía de rescate tras un reinicio es la consola
>    física, no esperar cinco minutos.
> 2. **El paso 8 corta tu sesión** a propósito, porque cambia la dirección a la que estás conectado.
>    Al volver entrarás por `${LAN_IP}`, y el entorno habrá que cargarlo de nuevo.

**Tiempo estimado:** 45 minutos.

---

## 3. Decisiones y por qué

### 3.1 IP fija en el servidor *y* reserva en el router

**Decisión: las dos cosas, no una.**

| Solo reserva DHCP | Solo IP fija en el servidor | Ambas |
|---|---|---|
| Si el router se reinicia o pierde la configuración, la IP cambia | El router puede entregar esa misma IP a otro equipo y provocar un conflicto | El servidor siempre tiene su IP y el router nunca se la da a nadie más |

La reserva ya la hiciste en el capítulo 00. Aquí se añade la configuración estática en el propio
servidor, de modo que la dirección no dependa de que el router esté sano.

### 3.2 `ifupdown`, no `systemd-networkd`

**Decisión: mantener `ifupdown`, que es lo que dejó el instalador.**

| Alternativa descartada | Por qué |
|---|---|
| `systemd-networkd` | Más moderno y con mejor integración en systemd. Pero migrar implica desactivar `networking.service` y activar otro servicio: si algo sale mal en un servidor sin monitor, te quedas sin red. |
| `NetworkManager` | Pensado para equipos que cambian de red constantemente. Un servidor no lo hace. |

`ifupdown` es sencillo, está en un solo archivo legible y es lo que Debian configura por omisión.
Migrar tendría que aportar algo, y aquí no aporta nada.

### 3.3 DNS escrito directamente en `/etc/resolv.conf`

**Decisión: escribir `/etc/resolv.conf` a mano, sin `resolvconf`.**

Aquí hay una trampa que hace perder horas: en una configuración estática de `ifupdown`, la directiva
`dns-nameservers` **no hace nada** si el paquete `resolvconf` no está instalado. Y una instalación
mínima de Debian no lo lleva.

El resultado es un servidor con IP correcta, puerta de enlace correcta, que responde al ping por IP
y no resuelve ningún nombre. Se diagnostica mal porque todo *parece* bien configurado.

Se puede resolver instalando `resolvconf`, pero eso añade un paquete y una capa de indirección para
gestionar tres líneas de texto que no van a cambiar. Se escribe el archivo y se acabó.

### 3.4 nftables sin `flush ruleset`

**Decisión: nuestro archivo declara y borra únicamente su propia tabla.**

La plantilla que trae Debian en `/etc/nftables.conf` empieza así:

```
flush ruleset
```

Eso borra **todas** las reglas del sistema. Mientras solo haya un cortafuegos, no pasa nada. En
cuanto Docker esté instalado (capítulo 09), Docker crea sus propias reglas al arrancar, y un
`systemctl reload nftables` las borraría: los contenedores se quedan sin red hasta que se reinicie
Docker, y el síntoma —«los contenedores dejaron de tener internet y no toqué Docker»— no apunta en
absoluto a la causa.

La alternativa es el par de líneas:

```
table inet nomad_filter
delete table inet nomad_filter
```

La primera crea la tabla si no existe (y no hace nada si ya existe); la segunda la borra. Juntas
dejan el archivo idempotente **sin tocar las reglas de nadie más**.

### 3.5 Sin cadena `forward`

**Decisión: no declarar ninguna cadena `forward` en nuestra tabla.**

En netfilter, varias tablas pueden enganchar una cadena en el mismo punto. Todas se evalúan, y
**basta con que una descarte el paquete** para que se descarte. Si declaráramos una cadena `forward`
con política `drop`, se sumaría a la de Docker y los contenedores perderían la red.

Se podrían replicar las reglas de Docker en nuestra tabla, pero habría que mantenerlas sincronizadas
con cada red que se cree, y un descuido significa contenedores incomunicados.

**Lo que hace que esto sea seguro no es el cortafuegos, es el diseño**: ningún contenedor publica
puertos en el host (capítulo 09), así que no hay nada que Docker pueda exponer sin que lo decidamos.
El cortafuegos protege los servicios del **host**; los contenedores se protegen no siendo
alcanzables.

### 3.6 Qué se permite y por qué

| Regla | Motivo |
|---|---|
| `ct state established,related accept` | Respuestas a lo que hemos iniciado nosotros. Sin esto, el servidor no podría ni actualizarse |
| `ct state invalid drop` | Paquetes que no encajan en ninguna conexión: basura o escaneo |
| `iif lo accept` | Tráfico interno de la propia máquina |
| ICMP | Diagnóstico y descubrimiento de MTU. Bloquear ICMP entero rompe conexiones de forma sutil y muy difícil de depurar |
| `${LAN_CIDR}` → puerto `${SSH_PUERTO}` | Administración desde la red local |
| `iifname ${TS_INTERFAZ}` | Todo lo que llega por la VPN. WireGuard ya autenticó y cifró el paquete antes de que aparezca aquí |
| `udp dport 41641` | Conexiones directas de Tailscale. Sin ella la VPN funciona igual, pero pasando por un relé, con más latencia |
| `limit rate … log` | Registro de lo descartado, con límite para que un escaneo no llene el disco |

**Lo que deliberadamente no se abre:** HTTP y HTTPS. Puede sorprender en un servidor que publica
webs, pero es la consecuencia directa del diseño: el tráfico web entra por el túnel saliente de
Cloudflare, no por un puerto de escucha (capítulo 11).

### 3.7 Política de salida: `accept`

**Decisión: no filtrar el tráfico saliente.**

Filtrar la salida protegería contra la exfiltración desde un contenedor comprometido. A cambio, hay
que mantener una lista de destinos permitidos que cambia constantemente: réplicas de Debian,
registros de imágenes, Cloudflare, Tailscale, cualquier API que use un proyecto.

En la práctica esas listas acaban con una regla comodín, o rompen algo cada pocas semanas hasta que
alguien las desactiva. Para un servidor doméstico de un solo administrador, la complejidad no
compensa.

---

## 4. Variables usadas

### 4.1 De `config/servidor.env`

| Variable | Uso | Si está mal |
|---|---|---|
| `LAN_CIDR` | Red autorizada a conectar por SSH | **Te quedas fuera del servidor** |
| `SSH_PUERTO` | Puerto permitido en el cortafuegos | **Te quedas fuera del servidor** |
| `LAN_IP`, `LAN_PREFIJO`, `LAN_GATEWAY` | Dirección estática | El servidor pierde la red al reiniciar |
| `LAN_DNS` | Servidores DNS en `/etc/resolv.conf` | Todo responde por IP y nada por nombre |
| `TS_CIDR`, `TS_INTERFAZ` | Tráfico de Tailscale permitido | El capítulo 08 no podrá conectar |
| `SERVIDOR_HOSTNAME`, `SERVIDOR_DOMINIO_LOCAL` | Dominio de búsqueda en `resolv.conf` | Molestia menor |

Cargar y comprobar, **antes de tocar nada**:

```bash
# [servidor]
cd ~/nomad_server && source scripts/lib/entorno.sh
echo "lan=${LAN_CIDR} ip=${LAN_IP}/${LAN_PREFIJO} gw=${LAN_GATEWAY} ssh=${SSH_PUERTO} ts=${TS_CIDR}"
```

Salida esperada, con los valores de ejemplo:

```
lan=192.168.1.0/24 ip=192.168.1.50/24 gw=192.168.1.1 ssh=22 ts=100.64.0.0/10
```

> **Este es el capítulo donde una variable vacía duele más.** Un `LAN_CIDR` sin valor genera una
> regla de nftables sin origen válido: el archivo ni siquiera compila, lo que al menos es ruidoso.
> Un `SSH_PUERTO` vacío sí compila y deja el puerto 22 cerrado, que es silencioso y te expulsa.
> El paso 4 valida la sintaxis antes de aplicar precisamente por esto.

Y comprueba que la red declarada es de verdad la tuya:

```bash
# [servidor]
ip -br -4 addr | grep -v '^lo'
```

Criterio de aceptación: la dirección que muestra pertenece a `${LAN_CIDR}`. Si tu servidor está en
`192.168.0.x` y `LAN_CIDR` dice `192.168.1.0/24`, **corrígelo ahora**: aplicar el cortafuegos así
te deja sin acceso.

### 4.2 Variables que se DESCUBREN en este capítulo

| Variable | Qué es | Cómo se obtiene |
|---|---|---|
| `LAN_INTERFAZ` | Nombre real de la interfaz cableada | Paso 1 |

Puede que ya la anotaras en el capítulo [02](02_validacion_equipo.md). Si no, el paso 1 la detecta y
la persiste. Dejarla vacía también funciona —los scripts la detectan solos— pero fijarla hace el
montaje más previsible: si algún día conectas un adaptador USB-Ethernet, la detección automática
podría elegir el equivocado.

### 4.3 Variables temporales de esta sesión

Ninguna. Todo lo que este capítulo necesita está en `config/servidor.env`.

---

## 5. Procedimiento

### Paso 0 — Prepara la sesión y las dos terminales

```bash
# [servidor] — terminal 1: la que aplica los cambios
cd ~/nomad_server
source scripts/lib/entorno.sh
echo "lan=${LAN_CIDR} ip=${LAN_IP}/${LAN_PREFIJO} gw=${LAN_GATEWAY} ssh=${SSH_PUERTO}"
```

Criterio de aceptación: los cuatro valores aparecen y coinciden con tu red real. Contrástalos:

```bash
# [servidor]
ip -br -4 addr | grep -v '^lo'
ip -4 route show default
```

**Terminal 2 — déjala preparada pero sin conectar.** La usarás en el paso 5 para comprobar que
sigues entrando tras aplicar el cortafuegos, y en el paso 8 para volver con la IP nueva.

**Y ten a mano el plan B:** monitor y teclado conectados al servidor, o alguien que pueda
conectarlos. Este capítulo es el que más veces obliga a bajar físicamente al equipo.

### Paso 1 — Identifica la interfaz

```bash
# [servidor]
ip -br link
ip -br -4 addr
ip -4 route show default
```

Salida de ejemplo:

```
lo               UNKNOWN        00:00:00:00:00:00 <LOOPBACK,UP,LOWER_UP>
enp3s0           UP             a4:bb:6d:11:22:33 <BROADCAST,MULTICAST,UP,LOWER_UP>
default via 192.168.1.1 dev enp3s0 proto dhcp metric 100
```

La interfaz que te interesa es la que aparece en la ruta por defecto: `enp3s0` en el ejemplo.

> Los nombres tipo `eth0` ya no existen en Debian: se usan nombres predecibles derivados de la
> posición física de la tarjeta, para que no cambien al añadir hardware.

**Persiste el valor**, para que no dependa de la detección automática:

```bash
# [servidor]
./scripts/variables.sh --fijar LAN_INTERFAZ="$(ip -o -4 route show to default | awk '{print $5}')"
source scripts/lib/entorno.sh
echo "interfaz=${LAN_INTERFAZ}"
```

Criterio de aceptación: imprime el nombre de la interfaz, no una línea vacía. Ese valor queda
escrito en `config/servidor.env` y sobrevive a reinicios y a cerrar la sesión.

> **Por qué persistirlo y no dejarlo en blanco.** La detección automática funciona bien mientras
> haya una sola interfaz cableada. El día que conectes un adaptador USB-Ethernet o una segunda
> tarjeta, `ip route` puede elegir otra y el archivo `/etc/network/interfaces` quedaría escrito para
> la interfaz equivocada. Un valor fijo es un valor que puedes revisar.

### Paso 2 — Cortafuegos primero, red después

**El orden importa.** Se configura y valida el cortafuegos mientras la red sigue funcionando; y solo
después se cambia la IP. Al revés, un fallo en el cortafuegos te dejaría sin acceso justo cuando
acabas de cambiar la dirección y no sabrías cuál de las dos cosas falló.

```bash
# [servidor]
sudo apt install -y nftables
```

### Paso 3 — Escribe las reglas

Copia previa, siempre:

```bash
# [servidor]
sudo mkdir -p /var/backups/nomad/config$(dirname /etc/nftables.conf)
sudo cp -a /etc/nftables.conf \
    /var/backups/nomad/config/etc/nftables.conf.bak-$(date +%Y%m%d-%H%M%S)
```

**Antes de escribir, mira qué va a cambiar.** Esto renderiza la plantilla con tus valores y la
compara con lo que hay instalado:

```bash
# [servidor]
nomad_diff etc/nftables.conf /etc/nftables.conf
```

**Y este es el comando que la instala:**

```bash
# [servidor]
nomad_plantilla etc/nftables.conf | sudo tee /etc/nftables.conf >/dev/null
sudo chmod 640 /etc/nftables.conf
```

Comprueba que las tres definiciones han quedado con tus valores reales:

```bash
# [servidor]
grep '^define' /etc/nftables.conf
```

Salida esperada, con los valores de ejemplo:

```
define lan_cidr  = 192.168.1.0/24
define ts_cidr   = 100.64.0.0/10
define ssh_port  = 22
define ts_iface  = "tailscale0"
```

Criterio de aceptación: **ninguna definición vacía y ningún `${…}` literal**. Una definición vacía
hace que `nft -c` falle en el paso 4, que es exactamente para lo que sirve ese paso.

El contenido completo está en `templates/etc/nftables.conf`, con los comentarios que explican cada
decisión. En resumen:

```
#!/usr/sbin/nft -f

table inet nomad_filter
delete table inet nomad_filter

define lan_cidr  = 192.168.1.0/24
define ts_cidr   = 100.64.0.0/10
define ssh_port  = 22
define ts_iface  = "tailscale0"

table inet nomad_filter {
    chain entrada {
        type filter hook input priority filter; policy drop;

        ct state established,related accept
        ct state invalid drop
        iif lo accept

        ip protocol icmp icmp type { echo-request, echo-reply,
            destination-unreachable, time-exceeded, parameter-problem } accept
        ip6 nexthdr ipv6-icmp accept

        ip saddr $lan_cidr tcp dport $ssh_port accept
        iifname $ts_iface accept
        ip saddr $ts_cidr accept
        udp dport 41641 accept

        limit rate 5/minute burst 10 packets \
            log prefix "nomad-descartado: " level info
    }

    chain salida {
        type filter hook output priority filter; policy accept;
    }
}
```

> Fíjate en lo que **no** hay: ni `flush ruleset` ni cadena `forward`. Las secciones 3.4 y 3.5
> explican por qué, y no es un detalle menor: son las dos causas más frecuentes de «Docker dejó de
> funcionar tras configurar el cortafuegos».

> **Los `$` de este archivo no son variables tuyas.** `$lan_cidr`, `$ssh_port` y `$ts_iface` son
> variables **internas de nftables**, declaradas con `define` unas líneas más arriba. Por eso la
> sustitución con `envsubst` recibe una lista explícita de nombres en mayúsculas: si no, vaciaría
> también estas y el archivo dejaría de compilar. Ver el anexo
> [98 § 4.4](98_variables_y_entorno.md).

Si prefieres escribirlo a mano en lugar de usar la plantilla, este es el comando equivalente:

```bash
# [servidor]
sudo tee /etc/nftables.conf >/dev/null <<EOF
#!/usr/sbin/nft -f

table inet nomad_filter
delete table inet nomad_filter

define lan_cidr  = ${LAN_CIDR}
define ts_cidr   = ${TS_CIDR}
define ssh_port  = ${SSH_PUERTO}
define ts_iface  = "${TS_INTERFAZ}"

table inet nomad_filter {
    chain entrada {
        type filter hook input priority filter; policy drop;

        ct state established,related accept
        ct state invalid drop
        iif lo accept

        ip protocol icmp icmp type { echo-request, echo-reply,
            destination-unreachable, time-exceeded, parameter-problem } accept
        ip6 nexthdr ipv6-icmp accept

        ip saddr \$lan_cidr tcp dport \$ssh_port accept
        iifname \$ts_iface accept
        ip saddr \$ts_cidr accept
        udp dport 41641 accept

        limit rate 5/minute burst 10 packets log prefix "nomad-descartado: " level info
    }

    chain salida {
        type filter hook output priority filter; policy accept;
    }
}
EOF
```

Dos detalles de este bloque:

- **Las barras invertidas de `\$lan_cidr`.** Sin ellas, tu shell intentaría expandir esas variables
  —que no existen en tu entorno— y las dejaría vacías, produciendo reglas sin origen. Es la misma
  trampa de la nota anterior, vista desde el otro lado.
- **La regla `limit rate` va en una sola línea.** En la plantilla está partida con una barra
  invertida al final, pero dentro de un heredoc sin comillas esa barra la consume el shell como
  continuación de línea. El resultado sería equivalente, pero se lee peor.

**Usar `nomad_plantilla` evita tener que pensar en nada de esto**, y además instala el archivo con
sus comentarios explicativos.

### Paso 4 — Valida las reglas sin aplicarlas

```bash
# [servidor]
sudo nft -c -f /etc/nftables.conf && echo "SINTAXIS CORRECTA"
```

Criterio de aceptación: `SINTAXIS CORRECTA`. **Si da error, corrígelo antes de continuar.**

### Paso 5 — Aplica con red de seguridad

Aquí conviene una precaución que se usa poco y salva mucho: programar la retirada de las reglas
antes de aplicarlas. Si algo va mal y pierdes la conexión, a los cinco minutos el cortafuegos se
desactiva solo.

```bash
# [servidor]
sudo bash -c 'sleep 300 && nft flush ruleset' &
echo "Red de seguridad activa: el cortafuegos se retirará en 5 minutos"
```

Cómo funciona: se lanza en segundo plano (`&`) un proceso que espera cinco minutos y después borra
**todas** las reglas. Si el cortafuegos te expulsa, no puedes cancelarlo, así que a los cinco
minutos se retira solo y recuperas el acceso.

> **Cómo se cancela, y por qué importa el detalle.** El script no la cancela matando un proceso,
> sino borrando un archivo centinela en `/run` que el proceso en segundo plano comprueba antes de
> vaciar nada. La razón es que una cancelación por PID es poco fiable —el PID de `setsid` no es el
> del proceso que duerme— y aquí un fallo no deja un proceso inofensivo: deja **un
> `nft flush ruleset` armado** que se dispara minutos después, cuando ya no lo relacionas con el
> comando que lo lanzó, y que se lleva por delante también las reglas de Docker.
>
> Si lanzas la red de seguridad a mano, cancélala con el mismo criterio y **comprueba que no queda
> nada vivo**:
>
> ```bash
> # [servidor]
> ps -ef | grep -E 'nft flush ruleset' | grep -v grep || echo "  (ninguna armada)"
> ```

Sus tres limitaciones, que conviene tener claras:

| Limitación | Consecuencia |
|---|---|
| **No sobrevive a un reinicio** | Si el servidor se reinicia, desaparece. El rescate es la consola física |
| **Muere si se cierra la sesión que la lanzó** | En algunos sistemas `systemd-logind` mata los procesos del usuario al cerrar sesión. Por eso se trabaja dentro de `tmux` |
| **Borra las reglas de todos**, no solo las nuestras | Con Docker instalado (capítulo 09) eso deja a los contenedores sin red hasta reiniciar Docker. Aquí todavía no hay Docker, así que es inocuo |

Ahora aplica:

```bash
# [servidor]
sudo systemctl enable --now nftables
sudo nft list ruleset
```

**Comprueba desde otra terminal que sigues entrando:**

```bash
# [cliente] — terminal 2, la que dejaste preparada en el paso 0
ssh ${SERVIDOR_HOSTNAME}
```

Si funciona, cancela la red de seguridad:

```bash
# [servidor]
sudo pkill -f 'sleep 300'
jobs
```

Si **no** funciona, no hagas nada: espera cinco minutos y el cortafuegos se retirará solo.

### Paso 6 — Configura la IP estática

Esta parte **sí** corta tu sesión SSH: vas a cambiar la dirección a la que estás conectado.

```bash
# [servidor]
sudo mkdir -p /var/backups/nomad/config$(dirname /etc/network/interfaces)
sudo cp -a /etc/network/interfaces \
    /var/backups/nomad/config/etc/network/interfaces.bak-$(date +%Y%m%d-%H%M%S)
```

**Así queda el archivo** (con los valores de ejemplo):

```
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

auto enp3s0
iface enp3s0 inet static
    address 192.168.1.50/24
    gateway 192.168.1.1
```

**Y este es el comando que lo escribe con tus valores:**

```bash
# [servidor]
nomad_diff etc/interfaces /etc/network/interfaces
nomad_plantilla etc/interfaces | sudo tee /etc/network/interfaces >/dev/null
```

O, sin la plantilla:

```bash
# [servidor]
sudo tee /etc/network/interfaces >/dev/null <<EOF
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

auto ${LAN_INTERFAZ}
iface ${LAN_INTERFAZ} inet static
    address ${LAN_IP}/${LAN_PREFIJO}
    gateway ${LAN_GATEWAY}
EOF
```

**Comprobación obligatoria antes de aplicar.** Un error aquí deja el servidor sin red tras el
reinicio, y eso significa bajar al equipo:

```bash
# [servidor]
cat /etc/network/interfaces
grep -qE '^\s*auto\s+\S+' /etc/network/interfaces \
  && grep -qE '^\s*address\s+[0-9]' /etc/network/interfaces \
  && echo "CORRECTO" || echo "PARA: falta la interfaz o la dirección"
```

Criterio de aceptación: `CORRECTO`, y en la salida de `cat` aparecen el nombre real de la interfaz y
tu IP, sin `${…}` ni huecos.

Se usa `auto` y no `allow-hotplug` para que `networking.service` espere a que la interfaz esté lista
antes de dar el arranque por terminado. Así Docker no arranca con la red a medias.

### Paso 7 — DNS

**Así queda el archivo** (con los valores de ejemplo):

```
# Generado por scripts/06_firewall.sh — capítulo 06
nameserver 192.168.1.1
nameserver 1.1.1.1
search nomad.lan
options timeout:2 attempts:2
```

**Y este es el comando que lo escribe con tus valores.** `LAN_DNS` contiene varios servidores
separados por espacios, así que hay que convertir cada uno en una línea `nameserver`:

```bash
# [servidor]
sudo mkdir -p /var/backups/nomad/config$(dirname /etc/resolv.conf)
sudo cp -a /etc/resolv.conf \
    /var/backups/nomad/config/etc/resolv.conf.bak-$(date +%Y%m%d-%H%M%S) 2>/dev/null || true
{
    echo "# Generado siguiendo docs/06_red_y_firewall.md — $(date +%F)"
    for ns in ${LAN_DNS}; do echo "nameserver ${ns}"; done
    echo "search ${SERVIDOR_HOSTNAME}.${SERVIDOR_DOMINIO_LOCAL}"
    echo "options timeout:2 attempts:2"
} | sudo tee /etc/resolv.conf >/dev/null
cat /etc/resolv.conf
```

Fíjate en que `${LAN_DNS}` va **sin comillas** dentro del `for`: es lo que hace que el shell separe
la cadena `"192.168.1.1 1.1.1.1"` en dos elementos. Con comillas produciría una sola línea
`nameserver` con las dos direcciones juntas, que no es válida.

Criterio de aceptación: aparece una línea `nameserver` por cada servidor DNS, con direcciones
reales.

> Recuerda 3.3: `dns-nameservers` en `/etc/network/interfaces` **no funciona** sin el paquete
> `resolvconf`. Si más adelante instalas algo que traiga `resolvconf` o `systemd-resolved`, ese
> archivo pasará a generarse automáticamente y estas líneas se perderán.

> **La trampa tiene dos caras, y la segunda es peor.**
>
> Mientras la interfaz siga en DHCP, el cliente reescribe `/etc/resolv.conf` en cada renovación del
> arrendamiento: lo que escribas a mano se pierde. Eso es molesto pero evidente.
>
> Lo que no es evidente es lo que ocurre **al quitar el DHCP**. Cuando la interfaz pasa a estática,
> `dhcpcd` deja de gestionar el archivo, y al soltar el arrendamiento **retira las entradas que
> había puesto**, dejándolo así:
>
> ```
> # Generated by dhcpcd
> # /etc/resolv.conf.head can replace this line
> # /etc/resolv.conf.tail can replace this line
> ```
>
> Ni un solo `nameserver`. El servidor se queda sin resolución de nombres, los contenedores que
> hablan con internet entran en bucle de reinicio, y **el síntoma no aparece al hacer el cambio:
> aparece en el siguiente reinicio**, horas después, cuando ya nadie lo relaciona con esto.
>
> Por eso este capítulo desactiva el hook antes de escribir nada:
>
> ```bash
> # [servidor]
> grep -n 'nohook resolv.conf' /etc/dhcpcd.conf || echo "  (sin desactivar)"
> ```
>
> Y por eso la validación del capítulo incluye **comprobar el DNS después de reiniciar**, no solo
> antes.

> **Se reconoce por su primera línea:**
>
> ```
> # Generated by dhcpcd from enp5s0.dhcp
> ```
>
> Escribir el archivo a mano en esa situación da una falsa sensación de control: vuelve a su sitio
> horas después, y el síntoma —«el DNS se me cambia solo»— cuesta atribuir. **El paso 6 es el que
> resuelve esto**: al fijar la dirección estática deja de haber cliente DHCP para esa interfaz, y el
> archivo pasa a ser tuyo. Por eso el orden de este capítulo es cortafuegos, DNS y dirección: los
> dos últimos son en realidad un solo cambio.

### Paso 8 — Aplica el cambio de dirección

Aplicarlo por SSH corta tu propia sesión a mitad. Hay dos formas de hacerlo con seguridad:

**Opción A — reiniciar (la más limpia):**

```bash
# [servidor]
sudo reboot
```

```bash
# [cliente] — al cabo de un minuto, ya con la nueva IP
ssh ${ADMIN_USUARIO}@${LAN_IP}
```

Y al entrar, **el entorno hay que cargarlo otra vez**: el reinicio se llevó la sesión anterior.

```bash
# [servidor]
tmux new -s montaje
cd ~/nomad_server
source scripts/lib/entorno.sh
```

**Opción B — aplicar en caliente**, útil si no quieres reiniciar. Se lanza con `nohup` para que el
comando sobreviva a la desconexión:

```bash
# [servidor]
sudo nohup sh -c 'sleep 2; systemctl restart networking' >/dev/null 2>&1 &
exit
```

Después actualiza `~/.ssh/config` en tu equipo con la nueva dirección. Si lo creaste en el capítulo
05 con la IP antigua, corrígela ahora:

```bash
# [cliente]
cd ~/nomad_server && source scripts/lib/entorno.sh
sed -i "/^Host ${SERVIDOR_HOSTNAME}\$/,/^$/ s/^\( *HostName \).*/\1${LAN_IP}/" ~/.ssh/config
ssh -G ${SERVIDOR_HOSTNAME} | grep '^hostname'
```

Criterio de aceptación: imprime `hostname` seguido de `${LAN_IP}`. Si prefieres no usar `sed`, edita
el archivo y cambia la línea `HostName` del bloque `Host nomad`.

### Paso 9 — Comprueba la red completa

```bash
# [servidor]
ip -br -4 addr
ip -4 route show default
ping -c2 ${LAN_GATEWAY}
ping -c2 1.1.1.1
getent hosts deb.debian.org
```

Criterio de aceptación: la IP es `${LAN_IP}`, hay ruta por defecto, responden el router y una IP de
internet, **y los nombres se resuelven**. Ese último es el que falla cuando el DNS no está bien.

---

## 6. Script asociado

### 6.1 Vía A — con el script

`scripts/06_firewall.sh` automatiza los pasos 2 a 8, con las mismas precauciones.

```bash
# [servidor]
cd ~/nomad_server
./scripts/06_firewall.sh --help
sudo ./scripts/06_firewall.sh --check
sudo ./scripts/06_firewall.sh
```

No hace falta cargar el entorno: el script lee `config/servidor.env` por su cuenta.

**La forma recomendada de ejecutarlo es en dos tandas**, porque separa el riesgo del cortafuegos del
riesgo del cambio de dirección:

```bash
# [servidor] — 1ª tanda: solo el cortafuegos
sudo ./scripts/06_firewall.sh --sin-red
# comprueba desde otra terminal que sigues entrando
```

```bash
# [servidor] — 2ª tanda: ahora sí, la dirección estática y el DNS
sudo ./scripts/06_firewall.sh
```

| Opción | Para qué |
|---|---|
| `--margen <seg>` | Segundos de la red de seguridad (300 por omisión). `0` la desactiva: no lo hagas en remoto |
| `--sin-red` | Solo cortafuegos: no toca la IP ni el DNS |
| `--sin-firewall` | Solo red: no toca el cortafuegos |
| `-n, --check` | Muestra las diferencias y valida `nft -c`, sin aplicar |
| `-y, --si` | No pide confirmación |

Salvaguardas que incorpora:

- Valida las reglas con `nft -c` antes de aplicarlas.
- Activa una **red de seguridad**: antes de aplicar el cortafuegos programa un `nft flush ruleset`
  diferido. Si al terminar puede seguir hablando contigo, la cancela; si no, el cortafuegos se
  retira solo y recuperas el acceso. Se controla con `--margen <segundos>`.
- Detecta la interfaz automáticamente si `LAN_INTERFAZ` está vacía.
- Comprueba que `${LAN_IP}` pertenece a `${LAN_CIDR}` y avisa si no.
- **No cambia la IP sin confirmación explícita**, porque eso corta la sesión.

En modo `--check` muestra las diferencias que aplicaría a `/etc/nftables.conf`,
`/etc/network/interfaces` y `/etc/resolv.conf`, y valida la sintaxis de las reglas sin cargarlas.

### 6.2 Correspondencia entre el script y los pasos manuales

| Paso de la sección 5 | ¿Lo hace el script? | Nota |
|---|---|---|
| 0 — preparar sesión y terminales | No | Es tuyo |
| 1 — identificar la interfaz | Sí, la detecta | **Persistirla con `--fijar` sigue siendo tuyo** |
| 2 — instalar nftables | Sí | |
| 3 — escribir las reglas | Sí | Instala `templates/etc/nftables.conf` |
| 4 — validar con `nft -c` | Sí | Aborta si la sintaxis falla |
| 5 — aplicar con red de seguridad | Sí | Se ajusta con `--margen` |
| 6 — IP estática | Sí | Solo con confirmación explícita |
| 7 — DNS | Sí | |
| 8 — aplicar el cambio de dirección | Parcial | Avisa y explica; **reiniciar y actualizar `~/.ssh/config` es tuyo** |
| 9 — comprobar la red | Sí | |

### 6.3 Si prefieres la vía manual

Lo que asumes:

- [ ] Copia previa de los tres archivos antes de sobrescribirlos.
- [ ] Comprobar que `grep '^define' /etc/nftables.conf` no tiene valores vacíos.
- [ ] `sudo nft -c -f /etc/nftables.conf` **antes** de cargarlo.
- [ ] Lanzar la red de seguridad antes de aplicar, y cancelarla después.
- [ ] Comprobar el acceso desde la segunda terminal.
- [ ] Persistir `LAN_INTERFAZ` con `./scripts/variables.sh --fijar`.

---

## 7. Validación

```bash
# [servidor]
sudo nft list ruleset | head -40
```

Criterio de aceptación: aparece `table inet nomad_filter` con `policy drop` en la cadena de entrada.

```bash
# [servidor]
sudo nft list chain inet nomad_filter entrada | grep -c 'policy drop'
```

Criterio de aceptación: `1`.

```bash
# [servidor]
systemctl is-enabled nftables && systemctl is-active nftables
```

Criterio de aceptación: `enabled` y `active`.

```bash
# [servidor]
ip -br -4 addr show $(ip -o -4 route show to default | awk '{print $5}')
```

Criterio de aceptación: muestra `${LAN_IP}/${LAN_PREFIJO}`.

```bash
# [servidor]
getent hosts deb.debian.org && echo "DNS OK"
```

Criterio de aceptación: `DNS OK`.

```bash
# [servidor] — las reglas cargadas contienen tus valores reales, no huecos
sudo nft list chain inet nomad_filter entrada | grep -E 'saddr|dport|iifname'
```

Criterio de aceptación: aparecen tu `LAN_CIDR`, el puerto SSH y `tailscale0`. Una regla con un
origen vacío o `0.0.0.0/0` donde debería estar tu red indica que el archivo se escribió sin el
entorno cargado.

```bash
# [servidor] — la interfaz quedó persistida
./scripts/variables.sh --ver LAN_INTERFAZ
```

Criterio de aceptación: imprime el nombre real de la interfaz.

**Desde otro equipo de la red**, comprobación de que solo está abierto lo previsto:

```bash
# [cliente]
nmap -Pn -p 1-1000 ${LAN_IP}
```

Criterio de aceptación: **solo el puerto 22 aparece como `open`**. Todos los demás deben salir como
`filtered`, que es lo que produce una política `drop` (a diferencia de `closed`, que indicaría un
rechazo explícito).

Si no tienes `nmap`:

```bash
# [cliente]
for p in 22 80 443 8080; do
    timeout 2 bash -c "</dev/tcp/${LAN_IP}/$p" 2>/dev/null \
      && echo "$p ABIERTO" || echo "$p cerrado"
done
```

Criterio de aceptación: solo el 22 aparece como `ABIERTO`.

```bash
# [servidor] — el registro de descartes debe estar funcionando
sudo journalctl -k --since "10 min ago" | grep -c 'nomad-descartado' || true
```

Criterio de aceptación: cualquier número, incluido 0. Si has hecho el escaneo del paso anterior,
deberías ver entradas.

**Prueba de reinicio:** `sudo reboot` y comprobar que vuelve con la IP correcta, con el cortafuegos
cargado y aceptando SSH. Es la validación definitiva.

```bash
# [servidor] — tras el reinicio, y en este orden
ip -br -4 addr show "${LAN_INTERFAZ}"
grep -c '^nameserver' /etc/resolv.conf
getent hosts deb.debian.org && echo "DNS OK"
sudo nft list tables
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

Criterios: la IP es `${LAN_IP}`, **hay al menos un `nameserver`**, los nombres resuelven, `nomad_filter`
y las tablas de Docker están, y ningún contenedor en `Restarting`.

> **El `grep -c '^nameserver'` no es redundante con la prueba de resolución.** Si el archivo se
> quedó vacío, `getent` puede tardar en fallar y confundirse con un problema de red. Contar las
> líneas dice de inmediato si el archivo es el tuyo o el que dejó `dhcpcd` al retirarse.

---

## 8. Reversión

**Si te has quedado sin acceso**, la red de seguridad del paso 5 debería haber retirado el
cortafuegos a los cinco minutos. Si no la activaste, hace falta consola física:

```bash
# [servidor] — consola física
sudo systemctl stop nftables
sudo nft flush ruleset
```

**Reversión ordenada:**

```bash
# [servidor]
sudo systemctl disable --now nftables
sudo nft flush ruleset

sudo cp /etc/network/interfaces.bak-* /etc/network/interfaces
sudo systemctl restart networking
```

**Volver a DHCP** sin restaurar copias:

```bash
# [servidor]
sudo tee /etc/network/interfaces >/dev/null <<'EOF'
source /etc/network/interfaces.d/*
auto lo
iface lo inet loopback
allow-hotplug enp3s0
iface enp3s0 inet dhcp
EOF
sudo systemctl restart networking
```

---

## 9. Errores frecuentes

| Síntoma | Causa probable | Solución | Documentación |
|---|---|---|---|
| Tras aplicar el cortafuegos pierdo SSH | `${LAN_CIDR}` no coincide con tu red real | Espera a la red de seguridad, o entra por consola. Comprueba tu red con `ip -4 addr` | § 5 paso 5 |
| Los contenedores se quedan sin red al recargar el cortafuegos | `/etc/nftables.conf` tiene `flush ruleset` | Elimínalo y usa el par `table` / `delete table` (§ 3.4). Recupera con `sudo systemctl restart docker` | [nftables — Wiki](https://wiki.nftables.org/) |
| Los contenedores no llegan a internet | Se declaró una cadena `forward` con política `drop` | Elimínala: el reenvío lo gestiona Docker (§ 3.5) | [Docker — Filtrado de paquetes](https://docs.docker.com/engine/network/packet-filtering-firewalls/) |
| Hay IP y hay ping por número, pero ningún nombre resuelve | `dns-nameservers` sin `resolvconf` instalado | Escribe `/etc/resolv.conf` directamente (§ 3.3) | [`resolv.conf(5)`](https://manpages.debian.org/trixie/manpages/resolv.conf.5.en.html) |
| `/etc/resolv.conf` se sobrescribe solo | Algo instaló `resolvconf` o `systemd-resolved` | Configura el DNS en esa herramienta, o desinstálala si no la necesitas | [Debian Wiki — resolv.conf](https://wiki.debian.org/resolv.conf) |
| `/etc/resolv.conf` vuelve a cambiar aunque no haya `resolvconf` instalado | La interfaz sigue en DHCP y lo reescribe el cliente. Se reconoce por la primera línea: `# Generated by dhcpcd…` | Fija la IP estática (§ 5 paso 6): al dejar de haber cliente DHCP, el archivo pasa a estar bajo tu control | § 3.3 |
| **Tras pasar a IP estática y reiniciar, no resuelve ningún nombre** | Al soltar el arrendamiento, `dhcpcd` retiró sus `nameserver` y dejó el archivo solo con comentarios | Añade `nohook resolv.conf` a `/etc/dhcpcd.conf` y vuelve a escribir `/etc/resolv.conf`. Lo hace el script del capítulo | § 3.3 |
| Un contenedor entra en bucle `Restarting` justo después de un reinicio | Casi siempre es DNS: sin resolución, `cloudflared` no alcanza el borde de Cloudflare | `getent hosts deb.debian.org` primero, y `docker restart <contenedor>` cuando vuelva | § 3.3 |
| El servidor no vuelve tras reiniciar | Error tipográfico en `/etc/network/interfaces` | Consola física: restaura la copia `.bak-*` y `systemctl restart networking` | [`interfaces(5)`](https://manpages.debian.org/trixie/ifupdown/interfaces.5.en.html) |
| `nft` no reconoce `iifname "tailscale0"` | La interfaz aún no existe (Tailscale es el capítulo 08) | Es normal: nftables acepta el nombre aunque la interfaz no exista todavía | [nftables — Wiki](https://wiki.nftables.org/) |
| Conflicto de IP: dos equipos con la misma dirección | `${LAN_IP}` está dentro del rango DHCP y el router la entregó a otro | Reserva la IP por MAC en el router, o elige una fuera del rango | § 3.1 |
| `systemctl restart networking` cuelga la sesión | Se ha cambiado la IP a la que estás conectado | Es lo esperado. Usa la opción A (reiniciar) o `nohup` (opción B) | § 5 paso 8 |
| El registro de descartes llena el disco | Falta el limitador en la regla de log | Comprueba que la regla incluye `limit rate 5/minute` | [nftables — Logging](https://wiki.nftables.org/wiki-nftables/index.php/Logging_traffic) |
| `nmap` muestra puertos `closed` en lugar de `filtered` | El cortafuegos no está cargado | `sudo systemctl status nftables` y `sudo nft list ruleset` | § 7 |
| Tailscale conecta pero va lento | Falta la regla `udp dport 41641`: la VPN cae al relé | Añádela y comprueba con `tailscale netcheck` | Capítulo [08](08_tailscale.md) |
| `nft -f` falla con «syntax error, unexpected newline» | Una `define` quedó vacía porque el entorno no estaba cargado | `grep '^define' /etc/nftables.conf`, carga el entorno y reescribe | § 5 paso 3 |
| El archivo de reglas contiene `${LAN_CIDR}` literal | Se usó `<<'EOF'` con comillas, o `envsubst` sin lista | Usa `nomad_plantilla etc/nftables.conf` | Anexo [98](98_variables_y_entorno.md) § 4.3 |
| `envsubst` vació los `$lan_cidr` de nftables | Se ejecutó `envsubst` sin la lista explícita de variables | Usa `nomad_plantilla`, que ya la pasa | Anexo [98](98_variables_y_entorno.md) § 4.4 |
| Tras reiniciar, la red no levanta y `/etc/network/interfaces` tiene la interfaz vacía | El entorno no estaba cargado al escribir el archivo | Consola física: restaura la copia `.bak-*` y repite el paso 6 con el entorno cargado | § 5 paso 6 |
| `/etc/resolv.conf` tiene una sola línea con dos IP juntas | Se entrecomilló `${LAN_DNS}` en el bucle | Repite el paso 7 sin comillas alrededor de la variable | § 5 paso 7 |
| La red de seguridad no me rescató | Se reinició el servidor, o murió al cerrar la sesión que la lanzó | Consola física. Trabaja dentro de `tmux` para que no muera | § 5 paso 5 |
| El cortafuegos se vació solo minutos después, sin motivo aparente | Una red de seguridad de una ejecución anterior que no se canceló bien y se disparó tarde | `ps -ef \| grep 'nft flush ruleset'` para ver si queda alguna armada. Después `sudo systemctl restart nftables` y `sudo systemctl restart docker` | § 5 paso 5 |
| Tras un flush inesperado, los contenedores pierden la red | `nft flush ruleset` borra también las cadenas de Docker | `sudo systemctl restart docker` las recrea | Capítulo [09](09_docker.md) § 3.2 |
| Tras el paso 8, `ssh nomad` va a la dirección antigua | `~/.ssh/config` sigue con la IP anterior | Actualiza `HostName` (§ 5 paso 8) | Capítulo [05](05_usuarios_y_acceso_ssh.md) |

---

## 10. Referencias

- [Debian Wiki — nftables](https://wiki.debian.org/nftables)
- [nftables — Wiki oficial](https://wiki.nftables.org/)
- [nftables — Ejemplos de conjuntos de reglas](https://wiki.nftables.org/wiki-nftables/index.php/Simple_ruleset_for_a_home_router)
- [Docker — Filtrado de paquetes y cortafuegos](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
- [`interfaces(5)`](https://manpages.debian.org/trixie/ifupdown/interfaces.5.en.html)
- [`resolv.conf(5)`](https://manpages.debian.org/trixie/manpages/resolv.conf.5.en.html)
- [Debian Wiki — Nombres predecibles de interfaces](https://wiki.debian.org/NetworkInterfaceNames)
- [Tailscale — Requisitos de red](https://tailscale.com/kb/1082/firewall-ports)
- [templates/README.md](../templates/README.md) — cómo aplicar `nftables.conf` e `interfaces` a mano
- Anexo [98 — Variables, entorno y sesiones](98_variables_y_entorno.md) § 4.4, sobre los `$` que no hay que expandir

---

**Anterior:** [05 — Usuarios y acceso SSH](05_usuarios_y_acceso_ssh.md) · **Siguiente:** [07 — Endurecimiento del sistema](07_endurecimiento_del_sistema.md)
