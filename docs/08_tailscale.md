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

**Preparar la sesión.**

```bash
# [servidor]
cd ~/nomad_server
source scripts/lib/entorno.sh
echo "nodo=${TS_HOSTNAME} interfaz=${TS_INTERFAZ} rango=${TS_CIDR} suite=${DEBIAN_SUITE}"
```

Salida esperada, con los valores de ejemplo:

```
nodo=nomad interfaz=tailscale0 rango=100.64.0.0/10 suite=trixie
```

**Este capítulo produce un valor nuevo que hay que persistir**: `TS_IP`, la dirección del servidor
dentro de tu tailnet. Sin ella, los capítulos [10](10_traefik.md) y [13](13_observabilidad.md) no
podrán publicar el panel ni las herramientas de operación en una dirección alcanzable desde tu
móvil. El paso 10 explica cómo escribirla.

> **Trabaja por la LAN, no por Tailscale.** Es lo evidente —la VPN aún no existe— pero conviene
> dejarlo dicho: si más adelante repites este capítulo, hazlo también desde la LAN. `tailscale up`
> y `tailscale down` cortan tu propia sesión si estás conectado a través de la VPN.

**Tiempo estimado:** 30 minutos.

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

### 4.1 De `config/servidor.env`

| Variable | Uso | Dónde |
|---|---|---|
| `TS_HOSTNAME` | Nombre del nodo dentro de la tailnet | Paso 3 |
| `TS_CIDR` | Rango permitido en el cortafuegos (capítulo 06) | Paso 1 |
| `TS_INTERFAZ` | Interfaz permitida en el cortafuegos | Paso 1 |
| `DEBIAN_SUITE` | Suite del repositorio de Tailscale | Paso 2 |
| `ADMIN_USUARIO` | Usuario con el que se entrará por SSH sobre la VPN | Pasos 5 y 8 |

### 4.2 Variables que se DESCUBREN en este capítulo

| Variable | Qué es | Cómo se obtiene | La necesitan |
|---|---|---|---|
| `TS_IP` | Dirección del servidor dentro de tu tailnet (`100.x.y.z`) | `tailscale ip -4` | Capítulos [10](10_traefik.md), [13](13_observabilidad.md) |
| `TRAEFIK_BIND_INTERNA` | Dónde se publica el panel de Traefik. Pasa de `127.0.0.1` a `${TS_IP}` si eliges esa opción | Decisión tuya, en el paso 10 | Capítulos [10](10_traefik.md), [13](13_observabilidad.md) |

Ambas se escriben en el paso 10. **Es un paso de treinta segundos que ahorra confusión dos capítulos
después**: si `TS_IP` se queda vacía, Traefik intentará atarse a una dirección inexistente y Docker
se negará a arrancar el contenedor con un mensaje que no menciona Tailscale por ningún lado.

### 4.3 Valores que no van en `config/servidor.env`

| Valor | Dónde vive | Por qué no |
|---|---|---|
| La clave de autenticación (`tskey-auth-…`) | Se genera y se usa en el momento | Es un secreto de un solo uso; guardarla sería el peor de los dos mundos |
| El nombre completo MagicDNS (`nomad.tuorg.ts.net`) | Lo asigna Tailscale | Se consulta con `tailscale status`; no hace falta fijarlo |
| Las ACL de la tailnet | En la consola web de Tailscale | No hay forma de gestionarlas desde el servidor |

---

## 5. Procedimiento

### Paso 0 — Prepara la sesión

```bash
# [servidor]
cd ~/nomad_server
source scripts/lib/entorno.sh
echo "nodo=${TS_HOSTNAME} interfaz=${TS_INTERFAZ} suite=${DEBIAN_SUITE}"
```

Criterio de aceptación: los tres tienen valor.

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

**Así queda el archivo del repositorio** (con los valores de ejemplo):

```
Types: deb
URIs: https://pkgs.tailscale.com/stable/debian
Suites: trixie
Components: main
Signed-By: /usr/share/keyrings/tailscale-archive-keyring.gpg
```

**Y este es el comando que lo escribe con tu suite:**

```bash
# [servidor]
nomad_plantilla etc/tailscale.sources \
    | sudo tee /etc/apt/sources.list.d/tailscale.sources >/dev/null
```

O sin la plantilla:

```bash
# [servidor]
sudo tee /etc/apt/sources.list.d/tailscale.sources >/dev/null <<EOF
Types: deb
URIs: https://pkgs.tailscale.com/stable/debian
Suites: ${DEBIAN_SUITE}
Components: main
Signed-By: /usr/share/keyrings/tailscale-archive-keyring.gpg
EOF
```

Comprueba que la suite ha quedado escrita, porque una línea `Suites:` vacía hace que `apt update`
falle con un error que no menciona el motivo:

```bash
# [servidor]
grep '^Suites:' /etc/apt/sources.list.d/tailscale.sources
```

Criterio de aceptación: `Suites: trixie` (o tu suite real).

```bash
# [servidor]
sudo apt update
sudo apt install -y tailscale
```

> **Sobre la clave del repositorio.** Se descarga en formato binario (`.noarmor.gpg`), no ASCII. Es
> el error más frecuente al añadir este repositorio a mano: con el archivo `.asc`, `apt update`
> avisa de firma no válida.

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

Esa IP `100.x.y.z` es la dirección del servidor **dentro de tu tailnet**, y es fija mientras no
cierres sesión y vuelvas a registrar el nodo. **No la anotes en un papel: persístela** en el paso
10, que es donde se hace junto con el resto.

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

### Paso 10 — Persiste la dirección de la tailnet

**Este es el paso que evita un atasco dos capítulos más adelante.** La IP de Tailscale existe ahora
mismo en la salida de un comando y en ningún archivo: si cierras la sesión sin escribirla, el
capítulo 10 no sabrá dónde publicar el panel.

```bash
# [servidor]
./scripts/variables.sh --fijar TS_IP="$(tailscale ip -4)"
source scripts/lib/entorno.sh
echo "TS_IP=${TS_IP}"
```

Criterio de aceptación: imprime una dirección `100.x.y.z`. Si imprime `TS_IP=`, `tailscale ip -4`
no devolvió nada: comprueba `tailscale status` antes de seguir.

**Y decide ahora dónde quieres el panel de Traefik y las herramientas de operación.** Es una
decisión del capítulo [10](10_traefik.md), pero el momento de tomarla es este, con la VPN recién
levantada:

| Opción | `TRAEFIK_BIND_INTERNA` | Cómo se accede |
|---|---|---|
| **Por túnel SSH** (lo más cerrado) | `127.0.0.1` | `ssh -L 8080:127.0.0.1:8080 nomad` y luego `http://localhost:8080/dashboard/` |
| **Por la tailnet** (lo más cómodo) | `${TS_IP}` | `http://100.x.y.z:8080/dashboard/` desde cualquier dispositivo tuyo, incluido el móvil |

Las dos son privadas: `100.64.0.0/10` no se enruta por internet. La segunda es la que casi todo el
mundo acaba usando.

```bash
# [servidor] — si eliges la tailnet
./scripts/variables.sh --fijar TRAEFIK_BIND_INTERNA="$(tailscale ip -4)"
source scripts/lib/entorno.sh
```

```bash
# [servidor] — comprobación final de lo persistido
./scripts/variables.sh --faltan
```

Criterio de aceptación: `TS_IP` ya no aparece en la lista de pendientes.

> **Si repites el capítulo o reinstalas el nodo**, la IP puede cambiar. Vuelve a ejecutar este paso:
> es idempotente y tarda dos segundos. Y recuerda que Traefik se niega a arrancar si intenta atarse
> a una dirección que no existe en el sistema (capítulo 10 § 9).

---

## 6. Script asociado

### 6.1 Vía A — con el script

`scripts/08_tailscale.sh` automatiza los pasos 1, 2, 3, 6 y 9, y guía los que necesitan navegador.

```bash
# [servidor]
cd ~/nomad_server
./scripts/08_tailscale.sh --help
sudo ./scripts/08_tailscale.sh --check
sudo ./scripts/08_tailscale.sh
```

| Opción | Para qué |
|---|---|
| `--authkey <clave>` | Registra el nodo sin navegador. Usa siempre claves de un solo uso y caducidad corta |
| `--etiqueta <tag>` | Registra el nodo con una etiqueta (`tag:servidor`). Los nodos etiquetados **no caducan nunca** |
| `-n, --check` | Muestra qué cambiaría, sin instalar ni conectar |
| `-y, --si` | No pide confirmación |

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

### 6.2 Correspondencia entre el script y los pasos manuales

| Paso de la sección 5 | ¿Lo hace el script? | Nota |
|---|---|---|
| 0 — preparar la sesión | Sí | Carga la configuración por su cuenta |
| 1 — comprobar el cortafuegos | Sí | **Aborta si no permite `${TS_INTERFAZ}`** |
| 2 — repositorio y clave | Sí | Instala `templates/etc/tailscale.sources` |
| 3 — conectar el nodo | Sí | Imprime la URL, o usa `--authkey` |
| 4 — desactivar la caducidad de clave | **No** | Consola web. Es el paso que más se olvida |
| 5 — MagicDNS | **No** | Consola web |
| 6 — actualizaciones automáticas | Sí | |
| 7 — ACL | **No** | Consola web |
| 8 — probar desde fuera de casa | **No** | Requiere datos móviles |
| 9 — diagnóstico | Sí | |
| 10 — persistir `TS_IP` | **No** | `./scripts/variables.sh --fijar TS_IP="$(tailscale ip -4)"` |

### 6.3 Lo que ninguna vía hace por ti

Cuatro cosas, y las cuatro tienen consecuencias que aparecen tarde:

- [ ] **Desactivar la caducidad de clave** (paso 4). Si se olvida, a los 180 días pierdes el acceso
      remoto sin ningún aviso previo.
- [ ] **Activar MagicDNS** (paso 5). Sin ella, hay que usar direcciones `100.x.y.z` en todas partes.
- [ ] **Definir las ACL** (paso 7). Por omisión, todos tus dispositivos se alcanzan entre sí por
      cualquier puerto.
- [ ] **Persistir `TS_IP`** (paso 10). Sin ella, el capítulo 10 no puede publicar el panel.

Las tres primeras se hacen en <https://login.tailscale.com/admin>; la cuarta, con un comando.

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

```bash
# [servidor] — la IP de la tailnet quedó persistida y coincide con la real
./scripts/variables.sh --ver TS_IP
tailscale ip -4
```

Criterio de aceptación: las dos líneas son iguales. Si difieren, el nodo se volvió a registrar:
repite el paso 10.

```bash
# [servidor] — si elegiste publicar el panel en la tailnet, la dirección existe en el sistema
source scripts/lib/entorno.sh
ip -br addr | grep -q "${TRAEFIK_BIND_INTERNA}" \
  && echo "DIRECCION VALIDA" \
  || echo "REVISAR: ${TRAEFIK_BIND_INTERNA} no existe en este servidor"
```

Criterio de aceptación: `DIRECCION VALIDA`, o bien el valor es `127.0.0.1` (que siempre existe).
Esta comprobación evita el fallo del capítulo 10 en el que Docker se niega a arrancar Traefik con un
«cannot assign requested address».

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
| `apt update` falla y `tailscale.sources` tiene `Suites:` vacío | El entorno no estaba cargado al escribir el archivo | `source scripts/lib/entorno.sh` y repite el paso 2 | § 5 paso 2 |
| En el capítulo 10, Traefik no arranca: «cannot assign requested address» | `TRAEFIK_BIND_INTERNA` apunta a una IP de Tailscale que ya no existe o quedó vacía | Repite el paso 10 y comprueba con `ip -br addr` | § 5 paso 10 |
| El capítulo 13 no encuentra a dónde apuntar los registros DNS internos | `TS_IP` no se persistió | `./scripts/variables.sh --fijar TS_IP="$(tailscale ip -4)"` | § 5 paso 10 |
| Reinstalé el nodo y `TS_IP` ya no coincide | Al volver a registrarse, Tailscale puede asignar otra dirección | Repite el paso 10; usa el nombre MagicDNS donde puedas | § 4.2 |
| `tailscale up` corta mi sesión SSH | Estabas conectado a través de la propia VPN | Trabaja desde la LAN mientras configuras Tailscale | § 2 |

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
- Anexo [98 — Variables, entorno y sesiones](98_variables_y_entorno.md) § 6, sobre persistir lo descubierto

---

**Anterior:** [07 — Endurecimiento del sistema](07_endurecimiento_del_sistema.md) · **Siguiente:** [09 — Docker](09_docker.md)
