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

**Tiempo estimado:** 30 minutos.

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

| Variable | Uso |
|---|---|
| `LAN_INTERFAZ` | Interfaz a configurar (si está vacía, se detecta) |
| `LAN_IP`, `LAN_PREFIJO`, `LAN_GATEWAY` | Dirección estática |
| `LAN_DNS` | Servidores DNS en `/etc/resolv.conf` |
| `LAN_CIDR` | Red autorizada a conectar por SSH |
| `SSH_PUERTO` | Puerto permitido |
| `TS_CIDR`, `TS_INTERFAZ` | Tráfico de Tailscale permitido |
| `SERVIDOR_HOSTNAME`, `SERVIDOR_DOMINIO_LOCAL` | Dominio de búsqueda en `resolv.conf` |

---

## 5. Procedimiento

### Paso 1 — Identifica la interfaz

```bash
# [servidor]
ip -br link
ip -br -4 addr
ip -4 route show default
```

Anota el nombre de la interfaz cableada (`enp3s0`, `eno1`…) en `LAN_INTERFAZ`, dentro de
`config/servidor.env`.

> Los nombres tipo `eth0` ya no existen en Debian: se usan nombres predecibles derivados de la
> posición física de la tarjeta, para que no cambien al añadir hardware.

### Paso 2 — Cortafuegos primero, red después

**El orden importa.** Se configura y valida el cortafuegos mientras la red sigue funcionando; y solo
después se cambia la IP. Al revés, un fallo en el cortafuegos te dejaría sin acceso justo cuando
acabas de cambiar la dirección y no sabrías cuál de las dos cosas falló.

```bash
# [servidor]
sudo apt install -y nftables
```

### Paso 3 — Escribe las reglas

```bash
# [servidor]
sudo cp /etc/nftables.conf /etc/nftables.conf.bak-$(date +%F)
sudo vim /etc/nftables.conf
```

El contenido completo está en `templates/etc/nftables.conf`. En resumen:

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

Sustituye los valores por los tuyos.

> Fíjate en lo que **no** hay: ni `flush ruleset` ni cadena `forward`. Las secciones 3.4 y 3.5
> explican por qué, y no es un detalle menor: son las dos causas más frecuentes de «Docker dejó de
> funcionar tras configurar el cortafuegos».

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

Ahora aplica:

```bash
# [servidor]
sudo systemctl enable --now nftables
sudo nft list ruleset
```

**Comprueba desde otra terminal que sigues entrando:**

```bash
# [cliente] — terminal NUEVA
ssh nomad
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
sudo cp /etc/network/interfaces /etc/network/interfaces.bak-$(date +%F)
sudo vim /etc/network/interfaces
```

```
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

auto enp3s0
iface enp3s0 inet static
    address 192.168.1.50/24
    gateway 192.168.1.1
```

Sustituye por `${LAN_INTERFAZ}`, `${LAN_IP}/${LAN_PREFIJO}` y `${LAN_GATEWAY}`.

Se usa `auto` y no `allow-hotplug` para que `networking.service` espere a que la interfaz esté lista
antes de dar el arranque por terminado. Así Docker no arranca con la red a medias.

### Paso 7 — DNS

```bash
# [servidor]
sudo vim /etc/resolv.conf
```

```
# Generado por scripts/06_firewall.sh — capítulo 06
nameserver 192.168.1.1
nameserver 1.1.1.1
search nomad.lan
options timeout:2 attempts:2
```

Sustituye por los valores de `${LAN_DNS}` y `${SERVIDOR_DOMINIO_LOCAL}`.

> Recuerda 3.3: `dns-nameservers` en `/etc/network/interfaces` **no funciona** sin el paquete
> `resolvconf`. Si más adelante instalas algo que traiga `resolvconf` o `systemd-resolved`, ese
> archivo pasará a generarse automáticamente y estas líneas se perderán.

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

**Opción B — aplicar en caliente**, útil si no quieres reiniciar. Se lanza con `nohup` para que el
comando sobreviva a la desconexión:

```bash
# [servidor]
sudo nohup sh -c 'sleep 2; systemctl restart networking' >/dev/null 2>&1 &
exit
```

Después actualiza `~/.ssh/config` en tu equipo con la nueva dirección.

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

`scripts/06_firewall.sh` automatiza los pasos 2 a 8, con las mismas precauciones.

```bash
# [servidor]
cd ~/nomad_server
./scripts/06_firewall.sh --help
sudo ./scripts/06_firewall.sh --check
sudo ./scripts/06_firewall.sh
```

Salvaguardas que incorpora:

- Valida las reglas con `nft -c` antes de aplicarlas.
- Activa una **red de seguridad**: antes de aplicar el cortafuegos programa un `nft flush ruleset`
  diferido. Si al terminar puede seguir hablando contigo, la cancela; si no, el cortafuegos se
  retira solo y recuperas el acceso. Se controla con `--margen <segundos>`.
- Detecta la interfaz automáticamente si `LAN_INTERFAZ` está vacía.
- Comprueba que `${LAN_IP}` pertenece a `${LAN_CIDR}` y avisa si no.
- **No cambia la IP sin confirmación explícita**, porque eso corta la sesión.

```bash
# [servidor] — cortafuegos sí, dirección no (para hacerlo en dos tandas)
sudo ./scripts/06_firewall.sh --sin-red
```

En modo `--check` muestra las diferencias que aplicaría a `/etc/nftables.conf`,
`/etc/network/interfaces` y `/etc/resolv.conf`, y valida la sintaxis de las reglas sin cargarlas.

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
| El servidor no vuelve tras reiniciar | Error tipográfico en `/etc/network/interfaces` | Consola física: restaura la copia `.bak-*` y `systemctl restart networking` | [`interfaces(5)`](https://manpages.debian.org/trixie/ifupdown/interfaces.5.en.html) |
| `nft` no reconoce `iifname "tailscale0"` | La interfaz aún no existe (Tailscale es el capítulo 08) | Es normal: nftables acepta el nombre aunque la interfaz no exista todavía | [nftables — Wiki](https://wiki.nftables.org/) |
| Conflicto de IP: dos equipos con la misma dirección | `${LAN_IP}` está dentro del rango DHCP y el router la entregó a otro | Reserva la IP por MAC en el router, o elige una fuera del rango | § 3.1 |
| `systemctl restart networking` cuelga la sesión | Se ha cambiado la IP a la que estás conectado | Es lo esperado. Usa la opción A (reiniciar) o `nohup` (opción B) | § 5 paso 8 |
| El registro de descartes llena el disco | Falta el limitador en la regla de log | Comprueba que la regla incluye `limit rate 5/minute` | [nftables — Logging](https://wiki.nftables.org/wiki-nftables/index.php/Logging_traffic) |
| `nmap` muestra puertos `closed` en lugar de `filtered` | El cortafuegos no está cargado | `sudo systemctl status nftables` y `sudo nft list ruleset` | § 7 |
| Tailscale conecta pero va lento | Falta la regla `udp dport 41641`: la VPN cae al relé | Añádela y comprueba con `tailscale netcheck` | Capítulo [08](08_tailscale.md) |

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

---

**Anterior:** [05 — Usuarios y acceso SSH](05_usuarios_y_acceso_ssh.md) · **Siguiente:** [07 — Endurecimiento del sistema](07_endurecimiento_del_sistema.md)
