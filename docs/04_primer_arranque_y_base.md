# 04 — Primer arranque y base del sistema

> Dejar el sistema recién instalado en un estado conocido: repositorios correctos, todo actualizado,
> nombre y hora bien puestos, las herramientas mínimas y la certeza de que nunca se va a dormir.

---

## 1. Objetivo

Al terminar tendrás un Debian actualizado, con los repositorios en el formato moderno, el nombre y
la zona horaria correctos, las utilidades básicas de diagnóstico instaladas, la suspensión
desactivada de forma permanente y el repositorio `nomad_server` clonado en el propio servidor.

---

## 2. Requisitos previos

**Capítulos previos:** [03 — Instalación de Debian](03_instalacion_debian.md), completo y validado.

**Necesitas a mano:**

- Acceso por SSH al servidor con `${ADMIN_USUARIO}` y su contraseña (validado al final del
  capítulo 03).
- La IP actual del servidor.
- El monitor y el teclado del servidor todavía conectados, por si algo sale mal. A partir del
  capítulo 05 ya no harán falta.

**Tiempo estimado:** 20 minutos, casi todos de descarga desatendida.

---

## 3. Decisiones y por qué

### 3.1 Repositorios en formato deb822

**Decisión: usar `/etc/apt/sources.list.d/debian.sources` en formato deb822.**

Debian 13 es la primera versión que adopta este formato por omisión: en lugar de una línea densa por
repositorio, cada uno se declara en un bloque con campos con nombre.

```
Types: deb
URIs: https://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
```

Frente a la línea equivalente del formato antiguo:

```
deb https://deb.debian.org/debian trixie main non-free-firmware
```

La diferencia importa por dos motivos concretos: el campo `Signed-By` ata cada repositorio a una
clave específica —de modo que un repositorio de terceros no puede firmar paquetes que suplanten a
los de Debian—, y los bloques con nombre se pueden generar y comparar desde un script sin analizar
sintaxis posicional.

Si vienes de una instalación anterior, `sudo apt modernize-sources` convierte el formato antiguo al
nuevo automáticamente.

### 3.2 Componentes: `main` y `non-free-firmware`, nada más

**Decisión: no habilitar `contrib` ni `non-free`.**

`non-free-firmware` sí, porque es donde vive el firmware de tarjetas de red y controladoras, y sin él
puedes quedarte sin red tras una actualización de kernel. Es un componente separado precisamente
desde Debian 12 para poder incluirlo sin arrastrar el resto.

`contrib` y `non-free` contienen software que no forma parte del sistema y que aquí no se necesita:
todo lo que no sea Debian base irá en contenedores. Cuanto menos haya disponible para instalar por
descuido, mejor.

### 3.3 HTTPS hacia las réplicas

**Decisión: `https://deb.debian.org` en lugar de `http://`.**

APT verifica la firma de todos los paquetes, así que HTTP no permitiría a nadie inyectar código.
Lo que sí permite es **observar qué paquetes instalas**, lo que revela qué versiones corres y, por
tanto, a qué vulnerabilidades eres susceptible. HTTPS lo evita, y desde APT 1.5 no requiere ningún
paquete adicional.

### 3.4 `systemd-timesyncd` en lugar de `chrony`

**Decisión: mantener `systemd-timesyncd`, que ya viene instalado.**

La hora correcta no es un detalle estético: los certificados TLS, los registros y las llaves de
Tailscale dependen de ella. Un reloj desviado provoca fallos de conexión difíciles de diagnosticar.

`chrony` es más preciso y maneja mejor las redes con latencia variable, pero `timesyncd` mantiene el
reloj dentro de unos pocos milisegundos, que es más que suficiente, y **no hay que instalar nada**.
Coherente con la idea de mantener el host mínimo.

### 3.5 Suspensión desactivada en el sistema, no solo en la UEFI

**Decisión: enmascarar los objetivos de suspensión de systemd.**

En el capítulo 02 se desactivó la suspensión en la UEFI. Eso no basta: systemd puede suspender el
equipo por su cuenta —por inactividad, o si alguien pulsa el botón de encendido—. Enmascarar los
objetivos `sleep.target`, `suspend.target`, `hibernate.target` y `hybrid-sleep.target` hace que
esas peticiones simplemente no existan.

Es una de esas configuraciones que solo se echa de menos el día que el servidor deja de responder
sin motivo aparente.

### 3.6 Paquetes base: pocos y de diagnóstico

**Decisión: instalar solo herramientas que sirvan para entender qué está pasando.**

| Paquete | Para qué |
|---|---|
| `git` | Clonar este repositorio y los proyectos |
| `curl`, `ca-certificates`, `gnupg` | Descargar y verificar repositorios de terceros (Docker, Tailscale) |
| `vim`, `less` | Editar configuración y leer registros |
| `btop` | Ver CPU, memoria, disco y red de un vistazo |
| `ncdu` | Encontrar qué está llenando el disco, que siempre acaba pasando |
| `rsync` | Copias y respaldos manuales |
| `tmux` | Que un `apt upgrade` largo sobreviva a una desconexión SSH |
| `jq` | Leer la salida JSON de Docker, Tailscale y cloudflared |
| `smartmontools`, `lm-sensors` | Salud de discos y temperaturas |
| `dnsutils`, `net-tools` | Diagnóstico de red |
| `unattended-upgrades` | Se configura en el capítulo 07 |

No se instalan `nginx`, `python3-pip`, `nodejs` ni bases de datos. Todo eso va en contenedores.

### 3.7 El repositorio se clona en el servidor

**Decisión: clonar `nomad_server` en el directorio personal de `${ADMIN_USUARIO}`.**

A partir de aquí los scripts se ejecutan en el servidor, así que el repositorio tiene que estar
allí. Va en `~/nomad_server` y no en `/opt` porque pertenece al administrador, se edita como
administrador y solo se eleva a root al ejecutar un script concreto.

`config/servidor.env` **no se clona** (está en `.gitignore`): hay que copiarlo aparte, con `scp`,
como se explica en el paso 2.

---

## 4. Variables usadas

| Variable | Uso |
|---|---|
| `SERVIDOR_HOSTNAME` | Nombre del sistema y entrada en `/etc/hosts` |
| `SERVIDOR_DOMINIO_LOCAL` | FQDN en `/etc/hosts` |
| `SERVIDOR_ZONA_HORARIA` | Zona horaria del sistema |
| `SERVIDOR_LOCALE` | Configuración regional |
| `ADMIN_USUARIO` | Usuario que debe estar en el grupo `sudo` |
| `DEBIAN_MIRROR` | Réplica en `debian.sources` |
| `DEBIAN_SUITE` | Nombre en clave de la versión |

---

## 5. Procedimiento

### Paso 1 — Conéctate por SSH

```bash
# [cliente]
ssh ${ADMIN_USUARIO}@<ip-del-servidor>
```

Trabaja dentro de `tmux` para que una desconexión no interrumpa una actualización a medias:

```bash
# [servidor]
tmux new -s montaje
```

Si te desconectas, vuelve con `tmux attach -t montaje`.

### Paso 2 — Lleva el repositorio al servidor

```bash
# [servidor]
sudo apt update
sudo apt install -y git
git clone <url-del-repositorio> ~/nomad_server
```

Si el repositorio aún no está publicado, cópialo desde tu equipo:

```bash
# [cliente]
rsync -av --exclude='.git' --exclude='config/servidor.env' \
    ./ ${ADMIN_USUARIO}@<ip-del-servidor>:~/nomad_server/
```

Y en cualquiera de los dos casos, copia tu configuración, que nunca viaja por git:

```bash
# [cliente]
scp config/servidor.env ${ADMIN_USUARIO}@<ip-del-servidor>:~/nomad_server/config/
```

```bash
# [servidor]
chmod 600 ~/nomad_server/config/servidor.env
cd ~/nomad_server
```

### Paso 3 — Comprueba el estado de partida

Antes de cambiar nada, confirma lo que dejó el instalador:

```bash
# [servidor]
cat /etc/os-release | grep VERSION_CODENAME
sudo passwd -S root        # debe decir 'L' (bloqueada)
groups                     # debe incluir 'sudo'
ls /etc/apt/sources.list.d/
```

Si `passwd -S root` dice `P`, root tiene contraseña. Bloquéala:

```bash
# [servidor]
sudo passwd -l root
```

Si tu usuario no está en `sudo`, y solo en ese caso, necesitas la contraseña de root:

```bash
# [servidor]
su -
usermod -aG sudo ${ADMIN_USUARIO}
exit
```

Después cierra la sesión y vuelve a entrar para que el grupo tenga efecto.

### Paso 4 — Configura los repositorios

```bash
# [servidor]
sudo cp /etc/apt/sources.list.d/debian.sources \
        /etc/apt/sources.list.d/debian.sources.bak-$(date +%F)
sudo vim /etc/apt/sources.list.d/debian.sources
```

El contenido debe quedar así:

```
Types: deb
URIs: https://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://security.debian.org/debian-security
Suites: trixie-security
Components: main non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
```

Las tres suites cumplen funciones distintas y las tres hacen falta:

| Suite | Qué contiene |
|---|---|
| `trixie` | La versión estable, congelada |
| `trixie-updates` | Correcciones importantes que no son de seguridad, entre versiones puntuales |
| `trixie-security` | Parches de seguridad. **Es la que no puede faltar** |

Si existe todavía el archivo antiguo, elimínalo para que no haya dos definiciones:

```bash
# [servidor]
[ -f /etc/apt/sources.list ] && sudo mv /etc/apt/sources.list /etc/apt/sources.list.desactivado
```

### Paso 5 — Actualiza el sistema

```bash
# [servidor]
sudo apt update
sudo apt full-upgrade -y
sudo apt autoremove --purge -y
```

`full-upgrade` en lugar de `upgrade` porque permite instalar y eliminar paquetes cuando una
dependencia lo requiere. En un sistema recién instalado es lo correcto.

Si se actualizó el kernel, hará falta reiniciar. Se hace al final del capítulo.

### Paso 6 — Nombre de la máquina

```bash
# [servidor]
sudo hostnamectl set-hostname ${SERVIDOR_HOSTNAME}
```

Y ajusta `/etc/hosts` para que el nombre resuelva localmente:

```bash
# [servidor]
sudo vim /etc/hosts
```

```
127.0.0.1       localhost
127.0.1.1       nomad.lan nomad

::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
```

La línea `127.0.1.1` con el FQDN y el nombre corto es una convención de Debian. Sin ella, muchos
programas tardan en arrancar porque intentan resolver su propio nombre y esperan a que el DNS
agote el tiempo de espera.

### Paso 7 — Zona horaria y sincronización

```bash
# [servidor]
sudo timedatectl set-timezone ${SERVIDOR_ZONA_HORARIA}
sudo timedatectl set-ntp true
timedatectl status
```

Salida esperada:

```
           Time zone: America/Bogota (-05, -0500)
System clock synchronized: yes
              NTP service: active
```

Si `System clock synchronized` dice `no`, espera un minuto y repite: la primera sincronización tarda.

### Paso 8 — Configuración regional

```bash
# [servidor]
sudo sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen
sudo locale-gen
sudo update-locale LANG=${SERVIDOR_LOCALE}
```

### Paso 9 — Paquetes base

```bash
# [servidor]
sudo apt install -y --no-install-recommends \
    git curl wget ca-certificates gnupg \
    vim less tmux rsync jq unzip tree \
    btop ncdu \
    smartmontools lm-sensors \
    dnsutils iproute2 \
    unattended-upgrades
```

`--no-install-recommends` evita arrastrar decenas de paquetes «recomendados» que no se van a usar.

### Paso 10 — Desactiva la suspensión

```bash
# [servidor]
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

Salida esperada: cuatro líneas `Created symlink … → /dev/null`.

Y que el botón de encendido no apague el equipo por accidente:

```bash
# [servidor]
sudo mkdir -p /etc/systemd/logind.conf.d
printf '[Login]\nHandlePowerKey=ignore\nHandleLidSwitch=ignore\nHandleSuspendKey=ignore\n' \
    | sudo tee /etc/systemd/logind.conf.d/50-nomad-servidor.conf
sudo systemctl restart systemd-logind
```

`HandleLidSwitch=ignore` solo importa si el servidor es un portátil, pero no molesta en un equipo de
sobremesa y ahorra un problema si algún día cambia el hardware.

### Paso 11 — Reinicia y comprueba

```bash
# [servidor]
sudo reboot
```

Espera un minuto y vuelve a conectarte. Si el equipo no vuelve, el monitor y el teclado siguen
conectados: es la razón por la que aún no los hemos retirado.

---

## 6. Script asociado

`scripts/04_base.sh` automatiza los pasos 4 a 10.

```bash
# [servidor]
cd ~/nomad_server
./scripts/04_base.sh --help
sudo ./scripts/04_base.sh --check      # muestra qué cambiaría, sin tocar nada
sudo ./scripts/04_base.sh
```

En modo `--check` muestra las diferencias exactas que aplicaría a `debian.sources`, `/etc/hosts` y
la configuración de `logind`, la lista de paquetes que instalaría y los objetivos de systemd que
enmascararía. No ejecuta `apt` ni modifica ningún archivo.

Es idempotente: en una segunda ejecución informa con `[=]` de todo lo que ya estaba en su sitio.

Lo que **no** hace y hay que hacer a mano:

- El paso 2 (clonar el repositorio y copiar `servidor.env`), que ocurre antes de que el script
  exista en el servidor.
- El reinicio final: el script avisa si hace falta, pero no reinicia por su cuenta.

---

## 7. Validación

```bash
# [servidor]
hostnamectl | grep -E 'Static hostname|Operating System|Kernel'
```

Criterio de aceptación: el nombre es `${SERVIDOR_HOSTNAME}` y el sistema es Debian 13.

```bash
# [servidor]
timedatectl status | grep -E 'Time zone|synchronized|NTP service'
```

Criterio de aceptación: zona correcta, `synchronized: yes`, `NTP service: active`.

```bash
# [servidor]
apt-get -s upgrade 2>/dev/null | grep -c '^Inst'
```

Criterio de aceptación: `0` — no queda nada por actualizar.

```bash
# [servidor]
grep -c 'trixie-security' /etc/apt/sources.list.d/debian.sources
```

Criterio de aceptación: `1` o más. **Si es 0, el servidor no recibe parches de seguridad.**

```bash
# [servidor]
systemctl is-enabled sleep.target suspend.target hibernate.target hybrid-sleep.target
```

Criterio de aceptación: `masked` cuatro veces.

```bash
# [servidor]
sudo passwd -S root | awk '{print $2}'
```

Criterio de aceptación: `L`.

```bash
# [servidor]
getent group sudo | grep -q "${ADMIN_USUARIO}" && echo "SUDO OK"
```

Criterio de aceptación: `SUDO OK`.

```bash
# [servidor]
ping -c2 -W2 deb.debian.org && getent hosts $(hostname)
```

Criterio de aceptación: responde el ping y el nombre propio resuelve sin retraso perceptible.

```bash
# [servidor]
ls -l ~/nomad_server/config/servidor.env
```

Criterio de aceptación: existe y tiene permisos `-rw-------`.

```bash
# [servidor] — no debe haber quedado ningún reinicio pendiente
[ -f /var/run/reboot-required ] && echo "REINICIO PENDIENTE" || echo "SIN REINICIOS PENDIENTES"
```

Criterio de aceptación: `SIN REINICIOS PENDIENTES` (tras el reinicio del paso 11).

---

## 8. Reversión

Todos los archivos modificados tienen copia en `<archivo>.bak-<fecha>`.

```bash
# [servidor] — repositorios
sudo cp /etc/apt/sources.list.d/debian.sources.bak-* /etc/apt/sources.list.d/debian.sources
sudo apt update
```

```bash
# [servidor] — volver a permitir la suspensión
sudo systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
sudo rm /etc/systemd/logind.conf.d/50-nomad-servidor.conf
sudo systemctl restart systemd-logind
```

```bash
# [servidor] — desinstalar los paquetes base añadidos
sudo apt autoremove --purge -y btop ncdu tmux jq tree ncdu
```

La actualización del sistema (paso 5) **no se revierte**. Debian no admite volver a versiones
anteriores de los paquetes de forma segura. Si una actualización rompiera algo, la vía es el
capítulo [16](16_recuperacion_ante_desastres.md).

---

## 9. Errores frecuentes

| Síntoma | Causa probable | Solución | Documentación |
|---|---|---|---|
| `apt update` da `NO_PUBKEY` | Falta el llavero de Debian o `Signed-By` apunta a un archivo inexistente | `sudo apt install --reinstall debian-archive-keyring` y revisa la ruta de `Signed-By` | [Debian Wiki — SecureApt](https://wiki.debian.org/SecureApt) |
| `apt update` no ve `trixie-security` | El archivo `debian.sources` no incluye ese bloque | Repite el paso 4. Es el error más grave de este capítulo: sin él no llegan los parches | [Debian — Seguridad](https://www.debian.org/security/) |
| `E: Could not get lock /var/lib/dpkg/lock-frontend` | Hay otro `apt` en marcha, a menudo la actualización automática del arranque | Espera un minuto. Si persiste: `sudo lsof /var/lib/dpkg/lock-frontend` para ver quién lo tiene | — |
| `sudo: unable to resolve host` | Falta la entrada `127.0.1.1` en `/etc/hosts` tras cambiar el nombre | Repite el paso 6 | [Debian Wiki — Hostname](https://wiki.debian.org/Hostname) |
| `timedatectl` dice `synchronized: no` | La primera sincronización tarda, o el puerto UDP 123 está bloqueado | Espera un minuto. Comprueba con `systemctl status systemd-timesyncd` | [systemd-timesyncd](https://www.freedesktop.org/software/systemd/man/systemd-timesyncd.html) |
| `locale-gen` avisa de configuración regional no soportada | La locale no está descomentada en `/etc/locale.gen` | Repite el paso 8, o `sudo dpkg-reconfigure locales` | [Debian Wiki — Locale](https://wiki.debian.org/Locale) |
| El servidor se apagó solo por la noche | Suspensión activa por systemd o por la UEFI | Verifica el paso 10 y la configuración de UEFI del capítulo [02](02_validacion_equipo.md) | — |
| Tras el reinicio no responde a SSH | El sistema no arrancó, o cambió la IP | Conecta el monitor. Comprueba la IP con `ip -br addr` en la consola física | Capítulo [06](06_red_y_firewall.md) |
| `apt full-upgrade` quiere eliminar muchos paquetes | Los repositorios apuntan a una suite equivocada (`testing`, `sid`) | Revisa `Suites:` en `debian.sources`: debe decir `trixie` | [Debian — Releases](https://www.debian.org/releases/) |
| `git clone` falla con «Permission denied (publickey)» | El repositorio es privado y el servidor no tiene llave | Usa la vía de `rsync` del paso 2, o genera una llave de despliegue | Capítulo [05](05_usuarios_y_acceso_ssh.md) |

---

## 10. Referencias

- [Debian — Notas de publicación de Trixie](https://www.debian.org/releases/trixie/releasenotes)
- [Debian Wiki — SourcesList](https://wiki.debian.org/SourcesList)
- [Manual de `sources.list` en formato deb822](https://manpages.debian.org/trixie/apt/sources.list.5.en.html)
- [Debian Wiki — SecureApt](https://wiki.debian.org/SecureApt)
- [Debian — Información de seguridad](https://www.debian.org/security/)
- [Debian Wiki — Hostname](https://wiki.debian.org/Hostname)
- [systemd — `logind.conf`](https://www.freedesktop.org/software/systemd/man/logind.conf.html)

---

**Anterior:** [03 — Instalación de Debian](03_instalacion_debian.md) · **Siguiente:** [05 — Usuarios y acceso SSH](05_usuarios_y_acceso_ssh.md)
