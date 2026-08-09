# 05 — Usuarios y acceso SSH

> Cambiar el acceso de «contraseña» a «llave criptográfica», sin quedarte fuera de tu propio
> servidor en el intento.

---

## 1. Objetivo

Al terminar entrarás al servidor con una llave ed25519 protegida por frase de paso, la
autenticación por contraseña estará rechazada, root no podrá iniciar sesión por SSH y `fail2ban`
bloqueará a quien insista.

---

## 2. Requisitos previos

**Capítulos previos:** [04 — Primer arranque y base](04_primer_arranque_y_base.md).

**Necesitas a mano:**

- Sesión SSH abierta con `${ADMIN_USUARIO}`.
- **Una segunda terminal disponible.** No es opcional: es el mecanismo de seguridad de este
  capítulo.
- El monitor y el teclado del servidor todavía conectados. Es el último capítulo en el que hacen
  falta.
- Un gestor de contraseñas donde guardar la frase de paso de la llave.

> **La regla de oro de este capítulo:** nunca cierres la sesión que tienes abierta hasta haber
> comprobado, **desde otra terminal**, que la nueva configuración te deja entrar. Si algo sale mal,
> la sesión abierta es lo que te permite deshacerlo. Esta regla se repite en cada paso porque es
> el error que más veces obliga a bajar físicamente al servidor.

**Tiempo estimado:** 30 minutos.

---

## 3. Decisiones y por qué

### 3.1 Llaves ed25519 con frase de paso

**Decisión: `ssh-keygen -t ed25519`, protegida con frase de paso.**

| Alternativa descartada | Por qué |
|---|---|
| RSA 4096 | Sigue siendo seguro, pero las llaves son mucho más largas, la firma más lenta y no aporta nada frente a ed25519. Solo tiene sentido con sistemas antiguos que no soporten ed25519. |
| ECDSA | Basada en curvas NIST, cuya generación de parámetros ha sido cuestionada. Ed25519 es la recomendación actual de OpenSSH. |
| Llave sin frase de paso | Cómodo hasta el día que alguien accede a tu portátil: en ese momento tiene tu servidor. La frase de paso convierte el robo del archivo en algo inútil. |

La frase de paso **no** significa escribirla en cada conexión: el agente SSH la recuerda durante la
sesión de escritorio. Se teclea una vez al día como mucho.

### 3.2 `ssh.service` en lugar de `ssh.socket`

**Decisión: desactivar la activación por socket que Debian 13 trae por omisión.**

Debian 13 es la primera versión que activa `ssh.socket`: en lugar de un demonio permanente,
`systemd` escucha en el puerto 22 y lanza un `sshd` por cada conexión.

El problema es concreto y molesto: con `ssh.socket` activo, **`systemctl reload ssh` falla** con
`fatal: Cannot bind any address`, porque el proceso intenta reabrir un puerto que ya tiene systemd.
Y quien no se dé cuenta puede creer que aplicó un cambio de configuración que en realidad no se
aplicó, o dejar el servicio caído.

Además, las directivas `ListenAddress` y `Port` de `sshd_config` dejan de gobernar dónde se escucha:
eso pasa a definirse en la unidad de socket.

Para un servidor con un puñado de conexiones al día, el ahorro de memoria de la activación por
socket es irrelevante frente a tener un comportamiento previsible y una configuración que hace lo
que dice.

```bash
sudo systemctl disable --now ssh.socket
sudo systemctl enable --now ssh.service
```

### 3.3 Configuración en `sshd_config.d/`, no en `sshd_config`

**Decisión: escribir un archivo propio en `/etc/ssh/sshd_config.d/`.**

Debian incluye `Include /etc/ssh/sshd_config.d/*.conf` al principio de `sshd_config`. Poner ahí
nuestros ajustes tiene dos ventajas: una actualización de OpenSSH nunca los pisará, y toda la
configuración propia queda en un único archivo fácil de leer, revertir o comparar.

> **Detalle importante de OpenSSH**: en un archivo de configuración, **gana la primera aparición de
> cada directiva**, no la última. Como el `Include` está al principio, lo que escribamos en el
> *drop-in* tiene prioridad sobre lo que venga después en `sshd_config`.

### 3.4 El control de acceso lo hace el cortafuegos, no `ListenAddress`

**Decisión: `sshd` escucha en todas las interfaces; quien decide desde dónde se puede llegar es
nftables (capítulo 06).**

La alternativa —`ListenAddress ${LAN_IP}` y `ListenAddress <ip-de-tailscale>`— parece más segura,
pero introduce un problema de arranque real: si `sshd` arranca antes de que la interfaz exista o
tenga dirección, falla y el servicio queda caído. Es exactamente lo que ocurre con `tailscale0`,
que se crea tarde en el arranque.

Un servicio SSH caído en un servidor sin monitor es un viaje hasta donde esté el equipo. El
cortafuegos consigue el mismo resultado sin depender del orden de arranque.

### 3.5 Puerto 22

**Decisión: no cambiar el puerto.**

Cambiar SSH a un puerto alto reduce el ruido en los registros, y nada más. Como el servicio nunca
se expone a internet, ese ruido no existe: solo pueden llegar equipos de tu LAN o de tu tailnet.

A cambio, un puerto no estándar hay que recordarlo en cada cliente, en cada script y en cada regla
del cortafuegos, y es una causa recurrente de «no me conecto y no sé por qué». La variable
`SSH_PUERTO` existe por si tu caso es distinto, y toda la documentación la usa.

### 3.6 `sudo` sigue pidiendo contraseña

**Decisión: no configurar `NOPASSWD` en sudoers.**

Con la llave SSH, entrar al servidor no requiere teclear nada. Si además `sudo` no pidiera
contraseña, cualquiera que se sentara ante tu portátil desbloqueado tendría root en el servidor sin
un solo obstáculo.

La contraseña de `sudo` es la última barrera, y se teclea pocas veces por sesión porque `sudo` la
recuerda durante 15 minutos.

### 3.7 fail2ban con backend systemd y acción nftables

**Decisión: instalar `fail2ban` configurado explícitamente para journald y para nftables.**

Con SSH cerrado a contraseñas y accesible solo desde la LAN, fail2ban no es la defensa principal:
es defensa en profundidad, para el escenario de un equipo comprometido dentro de tu propia red.

Dos ajustes son imprescindibles en Debian 13 y suelen olvidarse:

- **`backend = systemd`**: una instalación mínima de Debian 13 no lleva `rsyslog`, así que
  `/var/log/auth.log` no existe. Con la configuración por defecto, fail2ban no encuentra nada que
  leer y no bloquea a nadie, en silencio.
- **`banaction = nftables-multiport`**: por omisión usa `iptables`, que en un sistema con nftables
  funciona por la capa de compatibilidad pero deja las reglas en un sitio donde no las verás al
  inspeccionar el cortafuegos.

Se añade además `ignoreip` con la LAN y el rango de Tailscale: bloquearte a ti mismo por escribir
mal la contraseña de `sudo` tres veces sería un final absurdo para este capítulo.

---

## 4. Variables usadas

| Variable | Uso |
|---|---|
| `ADMIN_USUARIO` | Único usuario autorizado en `AllowUsers` |
| `ADMIN_SSH_CLAVE_PUBLICA` | Ruta a la llave pública en el equipo cliente |
| `SSH_PUERTO` | Puerto de escucha |
| `LAN_CIDR` | Red excluida de los bloqueos de fail2ban |
| `TS_CIDR` | Rango de Tailscale, también excluido |

---

## 5. Procedimiento

### Paso 1 — Genera la llave en tu equipo

**En el cliente**, no en el servidor. La llave privada no debe salir nunca de tu equipo.

```bash
# [cliente]
ssh-keygen -t ed25519 -C "${ADMIN_USUARIO}@nomad" -f ~/.ssh/id_ed25519_nomad
```

Cuando pida la frase de paso, escribe una larga y guárdala en tu gestor de contraseñas.
**Dejarla vacía anula buena parte del beneficio** (ver 3.1).

Se generan dos archivos:

| Archivo | Qué es | Dónde va |
|---|---|---|
| `~/.ssh/id_ed25519_nomad` | Llave **privada** | Solo en tu equipo. Nunca se copia, nunca se envía |
| `~/.ssh/id_ed25519_nomad.pub` | Llave **pública** | Se copia al servidor |

```bash
# [cliente]
chmod 600 ~/.ssh/id_ed25519_nomad
chmod 644 ~/.ssh/id_ed25519_nomad.pub
ssh-keygen -l -f ~/.ssh/id_ed25519_nomad.pub
```

La última orden muestra la huella de la llave. Anótala: sirve para comprobar en el servidor que la
que está instalada es la tuya.

### Paso 2 — Copia la llave pública al servidor

```bash
# [cliente]
ssh-copy-id -i ~/.ssh/id_ed25519_nomad.pub ${ADMIN_USUARIO}@<ip-del-servidor>
```

Pedirá la contraseña del usuario: es la última vez que la usas para entrar.

Si `ssh-copy-id` no está disponible (macOS antiguo, Windows), hazlo a mano:

```bash
# [cliente]
cat ~/.ssh/id_ed25519_nomad.pub | ssh ${ADMIN_USUARIO}@<ip-del-servidor> \
  "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

### Paso 3 — Comprueba que la llave funciona ANTES de tocar nada

Este paso es el que evita el desastre. **No sigas si falla.**

```bash
# [cliente] — en una terminal NUEVA
ssh -i ~/.ssh/id_ed25519_nomad ${ADMIN_USUARIO}@<ip-del-servidor>
```

Criterio de aceptación: entra pidiendo **la frase de paso de la llave**, no la contraseña del
usuario. Si te pide la contraseña del usuario, la llave no se instaló bien: revisa el paso 2 y no
continúes.

Para ver exactamente qué está pasando:

```bash
# [cliente]
ssh -vv -i ~/.ssh/id_ed25519_nomad ${ADMIN_USUARIO}@<ip-del-servidor> 2>&1 | grep -E 'Offering|Authenticat|Server accepts'
```

### Paso 4 — Configura el cliente para no repetir la ruta

```bash
# [cliente]
vim ~/.ssh/config
```

```
Host nomad
    HostName 192.168.1.50
    User deart
    Port 22
    IdentityFile ~/.ssh/id_ed25519_nomad
    IdentitiesOnly yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
```

```bash
# [cliente]
chmod 600 ~/.ssh/config
ssh nomad
```

Sustituye los valores por los tuyos (`${LAN_IP}`, `${ADMIN_USUARIO}`, `${SSH_PUERTO}`).

Qué aporta cada opción:

| Opción | Para qué |
|---|---|
| `IdentitiesOnly yes` | Ofrece solo esta llave. Sin esto, el cliente prueba todas las que tenga cargadas y puede agotar `MaxAuthTries` antes de llegar a la correcta |
| `ServerAliveInterval 60` | Envía una señal cada minuto para que un router intermedio no corte una sesión inactiva |
| `ServerAliveCountMax 3` | Da la conexión por perdida tras tres fallos seguidos |

### Paso 5 — Endurece el servidor

**Deja abierta la sesión actual.** Todo lo que sigue se hace desde ella.

```bash
# [servidor]
sudo vim /etc/ssh/sshd_config.d/50-nomad.conf
```

```
# Autenticación: solo llaves
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitEmptyPasswords no
UsePAM yes

# Acceso
PermitRootLogin no
AllowUsers deart
MaxAuthTries 3
MaxSessions 5
LoginGraceTime 30

# Funciones que no se usan
X11Forwarding no
AllowAgentForwarding no
PermitTunnel no
PrintMotd no

# Sesiones colgadas
ClientAliveInterval 300
ClientAliveCountMax 2

# Registro suficiente para que fail2ban vea los intentos
LogLevel VERBOSE
```

Sustituye `deart` por `${ADMIN_USUARIO}`.

Sobre dos opciones que conviene entender antes de copiarlas:

- **`AllowAgentForwarding no`**: impide reenviar tu agente SSH al servidor. El reenvío de agente
  permite que quien controle el servidor use tus llaves para conectarse a otros sitios. Como aquí no
  se salta desde el servidor a ningún otro equipo, se desactiva.
- **`AllowTcpForwarding`** se deja en su valor por omisión (`yes`) a propósito: es lo que permite
  `ssh -L` para acceder a un servicio interno desde tu equipo, algo que se usa en los capítulos 10
  y 13.

### Paso 6 — Cambia a `ssh.service`

```bash
# [servidor]
systemctl is-active ssh.socket && echo "socket activo: hay que cambiarlo"
sudo systemctl disable --now ssh.socket
sudo systemctl enable --now ssh.service
```

### Paso 7 — Valida la configuración ANTES de reiniciar el servicio

```bash
# [servidor]
sudo sshd -t && echo "CONFIGURACION VALIDA"
```

Criterio de aceptación: imprime `CONFIGURACION VALIDA`. **Si da error, corrígelo antes de seguir**:
reiniciar `sshd` con una configuración inválida deja el servicio caído y a ti fuera.

Comprueba también cómo queda la configuración efectiva, ya combinada:

```bash
# [servidor]
sudo sshd -T | grep -E '^(passwordauthentication|permitrootlogin|pubkeyauthentication|allowusers|port|maxauthtries)'
```

Salida esperada:

```
port 22
permitrootlogin no
pubkeyauthentication yes
passwordauthentication no
maxauthtries 3
allowusers deart
```

### Paso 8 — Aplica y verifica desde otra terminal

```bash
# [servidor]
sudo systemctl restart ssh
systemctl status ssh --no-pager
```

Reiniciar `sshd` **no corta las sesiones ya establecidas**: cada una la atiende un proceso hijo
independiente. Tu sesión actual sigue viva.

Ahora, **sin cerrar esa sesión**:

```bash
# [cliente] — en una terminal NUEVA
ssh nomad
```

Criterio de aceptación: entra con la llave.

Y comprueba que la contraseña está realmente rechazada:

```bash
# [cliente]
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password nomad
```

Criterio de aceptación: `Permission denied (publickey)`. Si te pide contraseña, la configuración no
se aplicó: repite el paso 7.

**Solo cuando ambas comprobaciones pasen**, cierra la sesión antigua.

### Paso 9 — fail2ban

```bash
# [servidor]
sudo apt install -y fail2ban
sudo vim /etc/fail2ban/jail.d/nomad.local
```

```
[DEFAULT]
# Nunca bloquear a los equipos de la red local ni a los de la tailnet
ignoreip = 127.0.0.1/8 ::1 192.168.1.0/24 100.64.0.0/10

bantime  = 1h
findtime = 10m
maxretry = 5

# Debian 13 mínimo no instala rsyslog: los registros están solo en journald
backend = systemd

# El cortafuegos de este servidor es nftables (capítulo 06)
banaction = nftables-multiport
banaction_allports = nftables-allports

[sshd]
enabled = true
port    = 22
```

Sustituye la red por `${LAN_CIDR}` y el puerto por `${SSH_PUERTO}`.

```bash
# [servidor]
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

Salida esperada:

```
Status for the jail: sshd
|- Filter
|  |- Currently failed: 0
|  |- Total failed:     0
|  `- Journal matches:  _SYSTEMD_UNIT=ssh.service + _COMM=sshd
`- Actions
   |- Currently banned: 0
```

La línea `Journal matches` es la que confirma que el backend systemd funciona. Si en su lugar
aparece `File list: /var/log/auth.log`, el backend no se aplicó y fail2ban no está viendo nada.

### Paso 10 — Retira el monitor y el teclado

Ya no hacen falta. A partir de aquí todo es remoto.

Antes de desconectarlos, una última prueba de fuego:

```bash
# [servidor]
sudo reboot
```

```bash
# [cliente] — espera un minuto
ssh nomad
```

Si entras, el servidor es autónomo.

---

## 6. Script asociado

`scripts/05_ssh.sh` automatiza los pasos 5 a 9.

```bash
# [servidor]
cd ~/nomad_server
./scripts/05_ssh.sh --help
sudo ./scripts/05_ssh.sh --check
sudo ./scripts/05_ssh.sh
```

El script incorpora las salvaguardas del capítulo:

- **Se niega a continuar si no encuentra ninguna llave** en `~${ADMIN_USUARIO}/.ssh/authorized_keys`.
  Es la comprobación que impide que se cierre el acceso por contraseña sin tener otra vía de entrada.
- Valida la configuración con `sshd -t` **antes** de reiniciar el servicio, y si no es válida
  restaura la copia de seguridad y aborta.
- Usa `restart`, no `stop`+`start`, para no cortar las sesiones abiertas.
- Al terminar recuerda comprobar el acceso desde otra terminal antes de cerrar la actual.

En modo `--check` muestra el contenido exacto que escribiría en
`/etc/ssh/sshd_config.d/50-nomad.conf` y en la configuración de fail2ban, y las diferencias respecto
a lo que hay.

Lo que **no** hace: generar la llave ni copiarla (pasos 1 y 2). Eso ocurre en tu equipo, no en el
servidor.

---

## 7. Validación

```bash
# [servidor]
sudo sshd -T | grep -E '^(passwordauthentication|permitrootlogin|kbdinteractiveauthentication)'
```

Criterio de aceptación:

```
permitrootlogin no
passwordauthentication no
kbdinteractiveauthentication no
```

```bash
# [servidor]
systemctl is-enabled ssh.socket 2>/dev/null || echo "ssh.socket desactivado (correcto)"
systemctl is-active ssh.service
```

Criterio de aceptación: el socket está desactivado y `ssh.service` está `active`.

```bash
# [servidor]
sudo systemctl reload ssh && echo "RECARGA CORRECTA"
```

Criterio de aceptación: `RECARGA CORRECTA`. Si falla con `Cannot bind any address`, `ssh.socket`
sigue activo: repite el paso 6.

```bash
# [cliente] — la contraseña debe ser rechazada
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password nomad 2>&1 | tail -1
```

Criterio de aceptación: `Permission denied (publickey)`.

```bash
# [cliente] — root no debe poder entrar
ssh -i ~/.ssh/id_ed25519_nomad root@<ip-del-servidor> 2>&1 | tail -1
```

Criterio de aceptación: `Permission denied`.

```bash
# [servidor]
sudo fail2ban-client status sshd | grep -E 'Journal matches|Currently banned'
```

Criterio de aceptación: aparece `Journal matches` (no `File list`).

```bash
# [servidor] — permisos correctos en el directorio de llaves
ls -ld ~/.ssh && ls -l ~/.ssh/authorized_keys
```

Criterio de aceptación: `drwx------` en `~/.ssh` y `-rw-------` en `authorized_keys`. OpenSSH
**ignora** las llaves si los permisos son más laxos, y no siempre lo dice claramente.

```bash
# [servidor] — la huella instalada debe ser la tuya
ssh-keygen -lf ~/.ssh/authorized_keys
```

Criterio de aceptación: coincide con la huella anotada en el paso 1.

**Prueba final:** reinicia el servidor y comprueba que puedes entrar con la llave sin intervención
manual.

---

## 8. Reversión

**Si te has quedado fuera**, el rescate es por consola física:

1. Conecta monitor y teclado, entra con `${ADMIN_USUARIO}` y su contraseña.
2. Restaura la configuración anterior:

```bash
# [servidor] — en la consola física
sudo mv /etc/ssh/sshd_config.d/50-nomad.conf /root/50-nomad.conf.roto
sudo sshd -t && sudo systemctl restart ssh
```

3. Si el problema es que fail2ban te bloqueó:

```bash
# [servidor]
sudo fail2ban-client set sshd unbanip <tu-ip>
sudo fail2ban-client status sshd
```

**Reversión ordenada del capítulo completo:**

```bash
# [servidor]
sudo rm /etc/ssh/sshd_config.d/50-nomad.conf
sudo rm /etc/fail2ban/jail.d/nomad.local
sudo systemctl disable --now fail2ban
sudo sshd -t && sudo systemctl restart ssh
```

Para volver a la activación por socket de Debian 13:

```bash
# [servidor]
sudo systemctl disable --now ssh.service
sudo systemctl enable --now ssh.socket
```

---

## 9. Errores frecuentes

| Síntoma | Causa probable | Solución | Documentación |
|---|---|---|---|
| `Permission denied (publickey)` tras endurecer | La llave no llegó a `authorized_keys`, o los permisos son demasiado abiertos | Entra por consola física y revisa `~/.ssh` (700) y `authorized_keys` (600). Diagnostica con `sudo journalctl -u ssh -n 50` | [Debian Wiki — SSH](https://wiki.debian.org/SSH) |
| `systemctl reload ssh` da `Cannot bind any address` | `ssh.socket` sigue activo | `sudo systemctl disable --now ssh.socket` (§ 3.2) | [Notas de publicación de Trixie](https://www.debian.org/releases/trixie/releasenotes) |
| Sigue pidiendo contraseña tras `PasswordAuthentication no` | Otro archivo en `sshd_config.d/` la habilita antes, o no se reinició el servicio | `sudo sshd -T \| grep passwordauth` muestra el valor efectivo. Recuerda: **gana la primera aparición** | [sshd_config(5)](https://manpages.debian.org/trixie/openssh-server/sshd_config.5.en.html) |
| `Too many authentication failures` | El cliente ofrece todas tus llaves y agota `MaxAuthTries` | Añade `IdentitiesOnly yes` en `~/.ssh/config` (paso 4) | [ssh_config(5)](https://manpages.debian.org/trixie/openssh-client/ssh_config.5.en.html) |
| fail2ban no bloquea nada | Backend por defecto buscando `/var/log/auth.log`, que no existe | `backend = systemd` en `jail.d/nomad.local` (§ 3.7) | [fail2ban — Jails](https://github.com/fail2ban/fail2ban/wiki) |
| fail2ban falla al arrancar | `banaction` de iptables en un sistema con nftables sin capa de compatibilidad | Usa `banaction = nftables-multiport` | [fail2ban — Actions](https://github.com/fail2ban/fail2ban/wiki) |
| Me he bloqueado a mí mismo con fail2ban | Falta tu red en `ignoreip` | Desde consola física: `sudo fail2ban-client set sshd unbanip <ip>` y añade `${LAN_CIDR}` a `ignoreip` | § 3.7 |
| `ssh-copy-id: command not found` | No está instalado en el cliente | Usa la vía manual del paso 2 | — |
| La sesión se corta sola tras unos minutos | Un router intermedio cierra conexiones inactivas | `ServerAliveInterval 60` en `~/.ssh/config` (paso 4) | [ssh_config(5)](https://manpages.debian.org/trixie/openssh-client/ssh_config.5.en.html) |
| `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED` | Se reinstaló el servidor y cambiaron sus claves de host | Si el cambio es esperado: `ssh-keygen -R <ip>`. **Si no lo esperabas, investígalo** | [OpenSSH — known_hosts](https://man.openbsd.org/ssh#SSH_KNOWN_HOSTS_FILE_FORMAT) |
| Al reiniciar, `ssh` no arranca | `ListenAddress` apunta a una interfaz que aún no existe | No uses `ListenAddress`: el control de acceso lo hace el cortafuegos (§ 3.4) | Capítulo [06](06_red_y_firewall.md) |
| Olvidé la frase de paso de la llave | No hay forma de recuperarla | Genera una llave nueva y vuelve a los pasos 1–3 desde una sesión abierta | — |

---

## 10. Referencias

- [Debian Wiki — SSH](https://wiki.debian.org/SSH)
- [`sshd_config(5)`](https://manpages.debian.org/trixie/openssh-server/sshd_config.5.en.html)
- [`ssh_config(5)`](https://manpages.debian.org/trixie/openssh-client/ssh_config.5.en.html)
- [OpenSSH — Página oficial](https://www.openssh.com/)
- [fail2ban — Wiki](https://github.com/fail2ban/fail2ban/wiki)
- [Debian — Notas de publicación de Trixie](https://www.debian.org/releases/trixie/releasenotes)
- [Mozilla — Guía de configuración de OpenSSH](https://infosec.mozilla.org/guidelines/openssh)

---

**Anterior:** [04 — Primer arranque y base](04_primer_arranque_y_base.md) · **Siguiente:** [06 — Red y cortafuegos](06_red_y_firewall.md)
