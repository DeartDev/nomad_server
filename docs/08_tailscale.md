# 08 — Tailscale

> Poder administrar el servidor desde cualquier lugar sin abrir un solo puerto en el router, sin IP
> pública fija y sin DNS dinámico.

---

## 1. Objetivo

Al terminar podrás entrar por SSH al servidor desde cualquier red del mundo usando su nombre dentro
de tu tailnet, la clave del nodo no caducará nunca, y las ACL limitarán qué dispositivos pueden
hablar con él.

---

## 2. Requisitos previos

**Capítulos previos:** [06 — Red y cortafuegos](06_red_y_firewall.md) y
[07 — Endurecimiento](07_endurecimiento_del_sistema.md).

> **El capítulo 06 debe estar aplicado antes que este.** El cortafuegos tiene que permitir
> `${TS_INTERFAZ}` **antes** de levantar la VPN. Si se hiciera al revés y estuvieras administrando
> el servidor remotamente, te cortarías el acceso a ti mismo.

**Necesitas a mano:**

- Cuenta de Tailscale creada, con verificación en dos pasos (capítulo 00, paso 6).
- Un navegador para autorizar el nodo.
- El cliente de Tailscale instalado en tu equipo y en tu móvil.

**Tiempo estimado:** 20 minutos.

---

## 3. Decisiones y por qué

### 3.1 Tailscale para administración, Cloudflare para publicación

**Decisión: dos proveedores distintos para dos funciones distintas.**

Tailscale te lleva a ti al servidor. Cloudflare lleva a tus visitantes a tus webs. Podrían
solaparse —Tailscale tiene *Funnel* para publicar en internet, y Cloudflare tiene *Access* para
administración— pero mantenerlos separados tiene una consecuencia práctica muy concreta:

**Si Cloudflare cae, tus webs dejan de verse pero tú sigues entrando al servidor para arreglarlo.**
Si dependieran del mismo proveedor, una caída te dejaría fuera justo cuando más falta hace entrar.

Además, ambos son gratuitos en el uso que se les da aquí, así que la redundancia no cuesta nada.

### 3.2 Paquete del repositorio oficial

**Decisión: instalar desde `pkgs.tailscale.com`, no desde Debian.**

Debian empaqueta Tailscale, pero congelado en la versión que existía cuando se publicó la
distribución. Tailscale evoluciona rápido y su protocolo depende de estar razonablemente al día con
los servidores de coordinación. Es de los pocos casos donde un repositorio de terceros está
justificado.

El repositorio se declara en formato deb822 con `Signed-By`, igual que los de Debian: así la clave
de Tailscale solo puede firmar paquetes de Tailscale.

### 3.3 OpenSSH, no Tailscale SSH

**Decisión: no usar `tailscale up --ssh`.**

Tailscale SSH permite entrar sin gestionar llaves: la identidad la verifica Tailscale. Es cómodo, y
se descarta por dos razones concretas:

1. **Convierte a Tailscale en el único guardián del acceso.** Si tu cuenta se compromete o el
   servicio tiene una caída, no hay una segunda vía. Con OpenSSH, la llave privada está en tu
   equipo y sigue funcionando por la LAN pase lo que pase.
2. **Dos implementaciones de SSH en la misma máquina** significan dos configuraciones que endurecer
   y dos sitios donde mirar cuando algo falla.

Con esta decisión, Tailscale hace una sola cosa: transportar paquetes. La autenticación es siempre
de OpenSSH, tanto por LAN como por VPN.

### 3.4 La clave del nodo no debe caducar

**Decisión: desactivar la caducidad de clave del nodo del servidor.**

Por omisión, las claves de los nodos de Tailscale caducan a los 180 días y hay que reautorizarlos
desde un navegador. En un portátil es razonable. En un servidor significa que **un día, seis meses
después, dejas de poder entrar** — y el motivo no es evidente, porque nada ha cambiado.

Hay dos formas de evitarlo:

| Forma | Cómo | Cuándo |
|---|---|---|
| Desactivar la caducidad del nodo | Un interruptor en la consola de administración | Lo más sencillo. Suficiente para un tailnet personal |
| Etiquetar el nodo (`tag:servidor`) | Requiere definir `tagOwners` en las ACL | Más ordenado si vas a tener varios servidores: los nodos etiquetados nunca caducan y se les aplican reglas por etiqueta |

Se documentan las dos. La segunda es mejor a medio plazo y es la que se recomienda en cuanto tengas
más de un nodo servidor.

### 3.5 ACL restrictivas desde el principio

**Decisión: definir una política que limite qué puede alcanzar qué.**

Por omisión, un tailnet nuevo permite que **todos** los dispositivos hablen con todos por cualquier
puerto. Para una persona con tres dispositivos suyos es aceptable; deja de serlo en cuanto
compartes un nodo con alguien, o en cuanto un dispositivo se pierde.

La política que se propone limita el acceso al servidor a los dispositivos de tu propio usuario y,
dentro de él, solo a los puertos que se usan.

### 3.6 Actualizaciones automáticas del cliente

**Decisión: activar `tailscale set --auto-update`.**

Tailscale sabe actualizarse solo. En un servidor cuyo acceso remoto depende de este cliente, tener
la última versión importa: los problemas de conectividad entre versiones muy separadas son reales.
Se combina bien con las actualizaciones desatendidas del capítulo 07.

### 3.7 Lo que no se activa

| Función | Por qué no |
|---|---|
| **Exit node** (`--advertise-exit-node`) | Haría que tu tráfico de internet saliera por casa. Útil en redes públicas, pero consume ancho de banda de subida y no es el objetivo aquí. Se puede activar después sin rehacer nada |
| **Subnet router** (`--advertise-routes`) | Daría acceso a toda tu LAN desde la tailnet. Amplía mucho el alcance de un dispositivo comprometido. Solo si realmente necesitas llegar a otros equipos de casa |
| **Tailscale Funnel** | Publicar en internet por Tailscale. Ese trabajo lo hace Cloudflare (§ 3.1) |
| **`--accept-routes`** | Solo tiene sentido si otro nodo anuncia rutas. Aquí no las hay |

---

## 4. Variables usadas

| Variable | Uso |
|---|---|
| `TS_HOSTNAME` | Nombre del nodo dentro de la tailnet |
| `TS_CIDR` | Rango permitido en el cortafuegos (capítulo 06) |
| `TS_INTERFAZ` | Interfaz permitida en el cortafuegos |
| `DEBIAN_SUITE` | Suite del repositorio de Tailscale |
| `ADMIN_USUARIO` | Usuario con el que se entrará por SSH sobre la VPN |

---

## 5. Procedimiento

### Paso 1 — Comprueba que el cortafuegos ya permite la VPN

Antes de instalar nada:

```bash
# [servidor]
sudo nft list chain inet nomad_filter entrada | grep -E 'tailscale|41641'
```

Criterio de aceptación: aparecen las reglas de `${TS_INTERFAZ}`, de `${TS_CIDR}` y del puerto UDP
41641. Si no están, vuelve al capítulo [06](06_red_y_firewall.md).

### Paso 2 — Añade el repositorio

```bash
# [servidor]
curl -fsSL https://pkgs.tailscale.com/stable/debian/${DEBIAN_SUITE}.noarmor.gpg \
    | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
sudo chmod 644 /usr/share/keyrings/tailscale-archive-keyring.gpg
```

```bash
# [servidor]
sudo vim /etc/apt/sources.list.d/tailscale.sources
```

```
Types: deb
URIs: https://pkgs.tailscale.com/stable/debian
Suites: trixie
Components: main
Signed-By: /usr/share/keyrings/tailscale-archive-keyring.gpg
```

```bash
# [servidor]
sudo apt update
sudo apt install -y tailscale
```

### Paso 3 — Conecta el nodo

```bash
# [servidor]
sudo tailscale up --hostname=${TS_HOSTNAME}
```

Muestra una URL. Ábrela en tu navegador, inicia sesión y autoriza el dispositivo.

```
To authenticate, visit:

    https://login.tailscale.com/a/xxxxxxxxxxxx
```

Al autorizar, el comando termina solo.

```bash
# [servidor]
tailscale status
tailscale ip -4
```

Salida esperada:

```
100.101.102.103  nomad    tu@correo    linux   -
```

Anota esa IP `100.x.y.z`: es la dirección del servidor **dentro de tu tailnet**, y es fija.

### Paso 4 — Desactiva la caducidad de la clave

Este paso se hace en el navegador y es el que evita quedarte fuera dentro de seis meses.

1. Entra en <https://login.tailscale.com/admin/machines>.
2. Busca `${TS_HOSTNAME}` en la lista.
3. Menú `⋯` → **Disable key expiry**.
4. Confirma. La columna de caducidad debe pasar a mostrar **Disabled**.

**Alternativa con etiquetas** (recomendada si vas a tener varios servidores). En
<https://login.tailscale.com/admin/acls>, añade a la política:

```json
{
  "tagOwners": {
    "tag:servidor": ["autogroup:admin"]
  }
}
```

Y en el servidor:

```bash
# [servidor]
sudo tailscale up --hostname=${TS_HOSTNAME} --advertise-tags=tag:servidor
```

Los nodos etiquetados **no caducan nunca** y además permiten escribir reglas por etiqueta en lugar
de por nombre de máquina.

### Paso 5 — Activa MagicDNS

En <https://login.tailscale.com/admin/dns>, activa **MagicDNS**.

A partir de ese momento el servidor es alcanzable por nombre desde cualquier dispositivo de la
tailnet:

```bash
# [cliente]
ssh ${ADMIN_USUARIO}@${TS_HOSTNAME}
```

Tailscale asigna además un nombre completo del tipo `nomad.tuorganizacion.ts.net`.

### Paso 6 — Actualizaciones automáticas del cliente

```bash
# [servidor]
sudo tailscale set --auto-update
tailscale version
```

### Paso 7 — Configura las ACL

En <https://login.tailscale.com/admin/acls>, sustituye la política por omisión.

Política mínima razonable para un tailnet personal:

```json
{
  "tagOwners": {
    "tag:servidor": ["autogroup:admin"]
  },

  "acls": [
    {
      "action": "accept",
      "src":    ["autogroup:member"],
      "dst":    ["tag:servidor:22,80,443,3000-9000"]
    },
    {
      "action": "accept",
      "src":    ["autogroup:member"],
      "dst":    ["autogroup:self:*"]
    }
  ],

  "ssh": []
}
```

Qué hace cada bloque:

| Bloque | Efecto |
|---|---|
| `tagOwners` | Define quién puede asignar la etiqueta `tag:servidor` |
| Primer `acls` | Los miembros del tailnet llegan al servidor **solo** por SSH, HTTP, HTTPS y el rango donde viven las herramientas internas |
| Segundo `acls` | Cada persona sigue alcanzando sus propios dispositivos |
| `ssh: []` | Tailscale SSH desactivado explícitamente (§ 3.3) |

> Guarda la política con cuidado: **una ACL mal escrita puede dejarte sin acceso por la VPN**. La
> consola avisa antes de aplicar cambios que te desconectarían, pero conviene tener la sesión de LAN
> abierta mientras experimentas.

### Paso 8 — Prueba desde fuera de casa

La prueba real: **desconecta el móvil del Wi-Fi**, deja solo datos móviles, activa Tailscale y
conéctate.

```bash
# [cliente desde datos móviles]
ssh ${ADMIN_USUARIO}@${TS_HOSTNAME}
```

Si entra, el objetivo del capítulo está cumplido: administras el servidor desde cualquier lugar sin
un solo puerto abierto en el router.

### Paso 9 — Diagnóstico de conectividad

```bash
# [servidor]
tailscale netcheck
```

Fíjate en dos cosas de la salida:

| Campo | Qué significa |
|---|---|
| `UDP: true` | Hay conectividad UDP directa. Es lo deseable |
| `Nearest DERP` | El relé más cercano. Solo se usa si falla la conexión directa |

```bash
# [servidor] — cómo está conectado cada par
tailscale status --json | jq -r '.Peer[] | "\(.HostName)\t\(.CurAddr // "relé DERP")"'
```

Si todo pasa por relé, revisa que la regla `udp dport 41641` del capítulo 06 está aplicada.

---

## 6. Script asociado

`scripts/08_tailscale.sh` automatiza los pasos 1, 2, 6 y 9, y guía los que necesitan navegador.

```bash
# [servidor]
cd ~/nomad_server
./scripts/08_tailscale.sh --help
sudo ./scripts/08_tailscale.sh --check
sudo ./scripts/08_tailscale.sh
```

Comportamiento destacable:

- **Comprueba primero que el cortafuegos permite `${TS_INTERFAZ}`** y aborta si no, para no
  levantar una VPN a la que después no se pueda llegar.
- Si el nodo ya está conectado, no vuelve a ejecutar `tailscale up`: informa del estado.
- Al terminar **recuerda explícitamente el paso manual de desactivar la caducidad de la clave**, con
  el enlace directo, porque es el que se olvida y el que causa el fallo a seis meses vista.
- Admite `--authkey` para automatizar el registro sin navegador:

```bash
# [servidor]
sudo ./scripts/08_tailscale.sh --authkey tskey-auth-XXXXX
```

Las claves de autenticación se generan en <https://login.tailscale.com/admin/settings/keys>.
Genera siempre claves **de un solo uso y con caducidad corta**: una clave reutilizable filtrada
permite a cualquiera meter un nodo en tu red privada. El script no la guarda en ningún archivo ni
la muestra en el registro.

Lo que **no** hace: los pasos 4, 5 y 7 (caducidad, MagicDNS y ACL) se hacen en la consola web y no
tienen equivalente local.

---

## 7. Validación

```bash
# [servidor]
tailscale status
```

Criterio de aceptación: el nodo aparece y los demás dispositivos figuran en la lista.

```bash
# [servidor]
systemctl is-enabled tailscaled && systemctl is-active tailscaled
```

Criterio de aceptación: `enabled` y `active`.

```bash
# [servidor]
ip -br addr show ${TS_INTERFAZ}
```

Criterio de aceptación: la interfaz existe y tiene una dirección `100.x.y.z`.

```bash
# [servidor]
tailscale netcheck 2>&1 | grep -E 'UDP|IPv4'
```

Criterio de aceptación: `UDP: true`.

```bash
# [cliente] — desde una red distinta a la de casa
ssh ${ADMIN_USUARIO}@${TS_HOSTNAME}
```

Criterio de aceptación: entra con la llave SSH.

```bash
# [servidor] — la caducidad de clave debe estar desactivada
tailscale status --json | jq -r '.Self.KeyExpiry // "sin caducidad"'
```

Criterio de aceptación: `sin caducidad` o `null`. **Si muestra una fecha, vuelve al paso 4**: ese
día perderás el acceso remoto.

```bash
# [servidor] — el cortafuegos sigue en pie con la VPN levantada
sudo nft list chain inet nomad_filter entrada | grep -c 'policy drop'
```

Criterio de aceptación: `1`.

**Prueba de reinicio:** `sudo reboot` y comprobar que la VPN vuelve sola, sin autorizar nada.

---

## 8. Reversión

```bash
# [servidor] — desconectar sin desinstalar
sudo tailscale down
```

```bash
# [servidor] — cerrar sesión y olvidar las credenciales del nodo
sudo tailscale logout
```

```bash
# [servidor] — desinstalar por completo
sudo systemctl disable --now tailscaled
sudo apt purge -y tailscale
sudo rm -f /etc/apt/sources.list.d/tailscale.sources
sudo rm -f /usr/share/keyrings/tailscale-archive-keyring.gpg
sudo rm -rf /var/lib/tailscale
sudo apt update
```

Elimina también el nodo desde <https://login.tailscale.com/admin/machines>, o quedará en la lista
como un dispositivo fantasma.

> **Antes de revertir, asegúrate de que sigues teniendo acceso por la LAN.** Si estás conectado a
> través de Tailscale, `tailscale down` corta tu propia sesión.

---

## 9. Errores frecuentes

| Síntoma | Causa probable | Solución | Documentación |
|---|---|---|---|
| Un día deja de conectar sin haber tocado nada | La clave del nodo caducó a los 180 días | Reautoriza y **desactiva la caducidad** (§ 3.4, paso 4) | [Tailscale — Key expiry](https://tailscale.com/kb/1028/key-expiry) |
| `tailscale up` se queda esperando | No hay salida a internet o el DNS falla | Comprueba con `ping 1.1.1.1` y `getent hosts login.tailscale.com` | Capítulo [06](06_red_y_firewall.md) |
| Conecta pero va lento | Todo el tráfico pasa por relé DERP | Añade `udp dport 41641 accept` al cortafuegos y comprueba con `tailscale netcheck` | Capítulo [06](06_red_y_firewall.md) § 3.6 |
| SSH por la VPN no responde | El cortafuegos no permite `${TS_INTERFAZ}` | Revisa el capítulo 06. La regla debe existir **antes** de levantar la VPN | Capítulo [06](06_red_y_firewall.md) |
| `ssh nomad` no resuelve | MagicDNS desactivado, o el cliente no lo usa | Actívalo en la consola y comprueba en el cliente con `tailscale status` | [Tailscale — MagicDNS](https://tailscale.com/kb/1081/magicdns) |
| Tras aplicar las ACL pierdo el acceso | La política es más restrictiva de lo previsto | Entra por la LAN y corrige en la consola. Ten siempre esa vía abierta al experimentar | [Tailscale — ACLs](https://tailscale.com/kb/1018/acls) |
| `tailscaled` no arranca tras reiniciar | El servicio no quedó habilitado | `sudo systemctl enable --now tailscaled` | [Tailscale — Linux](https://tailscale.com/kb/1031/install-linux) |
| Dos nodos con el mismo nombre | Se reinstaló el servidor sin eliminar el nodo anterior | Elimina el antiguo en la consola. Tailscale renombra a `nomad-1`, `nomad-2`… | [Tailscale — Machines](https://tailscale.com/kb/1131/machine-names) |
| La IP `100.x` cambia | Se cerró sesión y se volvió a registrar como nodo nuevo | Usa el nombre MagicDNS en lugar de la IP en tus configuraciones | [Tailscale — MagicDNS](https://tailscale.com/kb/1081/magicdns) |
| `apt update` avisa de firma no válida en el repositorio de Tailscale | La clave se descargó en formato ASCII y no binario | Usa el archivo `.noarmor.gpg`, no el `.asc` | [Tailscale — Debian](https://tailscale.com/kb/1187/install-debian-trixie) |

---

## 10. Referencias

- [Tailscale — Instalación en Debian](https://tailscale.com/kb/1187/install-debian-trixie)
- [Tailscale — Caducidad de claves](https://tailscale.com/kb/1028/key-expiry)
- [Tailscale — ACLs](https://tailscale.com/kb/1018/acls)
- [Tailscale — MagicDNS](https://tailscale.com/kb/1081/magicdns)
- [Tailscale — Etiquetas de servidor](https://tailscale.com/kb/1068/tags)
- [Tailscale — Claves de autenticación](https://tailscale.com/kb/1085/auth-keys)
- [Tailscale — Puertos y cortafuegos](https://tailscale.com/kb/1082/firewall-ports)
- [Tailscale — Solución de problemas](https://tailscale.com/kb/1023/troubleshooting)

---

**Anterior:** [07 — Endurecimiento del sistema](07_endurecimiento_del_sistema.md) · **Siguiente:** [09 — Docker](09_docker.md)
