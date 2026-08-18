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
- La IP actual del servidor, anotada en el capítulo 03 paso 13.
- El monitor y el teclado del servidor todavía conectados, por si algo sale mal. A partir del
  capítulo 05 ya no harán falta.
- La URL del repositorio, o tu equipo encendido para copiarlo con `rsync`.

**Preparar la sesión.** Este capítulo tiene una particularidad: **es el que instala el entorno de
trabajo**, así que sus dos primeros pasos son distintos de todos los demás. En el paso 2 llega el
repositorio al servidor y se copia `config/servidor.env`; a partir de ahí, y en todos los capítulos
siguientes, la sesión se prepara siempre igual:

```bash
# [servidor] — el ritual que se repite en cada sesión, a partir del paso 2
cd ~/nomad_server
source scripts/lib/entorno.sh
```

Hasta el paso 2 los comandos llevan valores explícitos o marcadores `<entre-ángulos>`, porque
todavía no hay nada que cargar.

**Tiempo estimado:** 30 minutos, casi todos de descarga desatendida.

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

### 4.1 De `config/servidor.env`

| Variable | Uso | Dónde aparece |
|---|---|---|
| `SERVIDOR_HOSTNAME` | Nombre del sistema y entrada en `/etc/hosts` | Pasos 6 |
| `SERVIDOR_DOMINIO_LOCAL` | FQDN en `/etc/hosts` | Paso 6 |
| `SERVIDOR_ZONA_HORARIA` | Zona horaria del sistema | Paso 7 |
| `SERVIDOR_LOCALE` | Configuración regional | Paso 8 |
| `ADMIN_USUARIO` | Usuario que debe estar en el grupo `sudo` | Pasos 2 y 3 |
| `DEBIAN_MIRROR` | Réplica en `debian.sources` | Paso 4 |
| `DEBIAN_SUITE` | Nombre en clave de la versión | Paso 4 |

**Para que estas variables existan en tu terminal**, a partir del paso 2:

```bash
# [servidor]
cd ~/nomad_server
source scripts/lib/entorno.sh
```

Comprobación antes de pegar cualquier comando de este capítulo:

```bash
# [servidor]
echo "${SERVIDOR_HOSTNAME}.${SERVIDOR_DOMINIO_LOCAL} · ${SERVIDOR_ZONA_HORARIA} · ${DEBIAN_SUITE}"
```

Salida esperada, con los valores de ejemplo:

```
nomad.lan · America/Bogota · trixie
```

Si sale ` · · `, el entorno no está cargado y **ningún comando de la sección 5 hará lo que dice**.

> Si usas los scripts (vía A), este paso no hace falta: `04_base.sh` carga `config/servidor.env` por
> su cuenta. Solo es necesario para la vía manual.

### 4.2 Variables temporales de esta sesión

| Variable | Qué contiene | Se usa en |
|---|---|---|
| `<ip-del-servidor>` | La IP anotada en el capítulo 03 paso 13 | Pasos 1 y 2 |

No es una variable de shell: es un marcador que sustituyes al escribir. Se usa así porque en los
pasos 1 y 2 todavía no hay repositorio en el servidor del que cargar nada. A partir del capítulo 06
esa dirección será `${LAN_IP}`, fija y ya cargable.

### 4.3 Variables que este capítulo NO toca

Ninguna se descubre aquí. Si vienes del capítulo 02, `DISCO_DESTINO` y `LAN_INTERFAZ` ya deberían
estar escritas; compruébalo con `./scripts/variables.sh --faltan` después del paso 2.

---

## 5. Procedimiento

### Paso 0 — Conéctate y abre una sesión persistente

En este capítulo el servidor todavía no tiene el repositorio, así que los comandos llevan valores
explícitos entre `<ángulos>` que tienes que sustituir al escribirlos.

```bash
# [cliente] — la IP es la que anotaste en el capítulo 03 paso 13
ssh <usuario>@<ip-del-servidor>
```

Pedirá la contraseña del usuario: es normal, la autenticación por llave se configura en el capítulo
[05](05_usuarios_y_acceso_ssh.md).

Trabaja dentro de `tmux`. No es una comodidad: una desconexión Wi-Fi en mitad de un `apt
full-upgrade` puede dejar el sistema de paquetes a medias, y `tmux` hace que el proceso siga vivo
en el servidor aunque tu terminal desaparezca.

```bash
# [servidor]
tmux new -s montaje
```

| Si… | Haz |
|---|---|
| Te desconectas y vuelves | `tmux attach -t montaje` |
| Quieres una segunda ventana | `Ctrl+b` y luego `c` |
| Quieres cambiar de ventana | `Ctrl+b` y luego el número |
| Quieres salir dejándolo corriendo | `Ctrl+b` y luego `d` |

> Cada ventana de `tmux` es un shell independiente. Cuando en el paso 2 cargues el entorno, lo harás
> **en esa ventana**: si abres otra, hay que volver a cargarlo allí.

### Paso 1 — Comprueba que hay red y que `sudo` funciona

Antes de descargar nada, dos comprobaciones de diez segundos que ahorran diagnósticos confusos:

```bash
# [servidor]
ping -c2 -W2 deb.debian.org
sudo -v
```

Criterio de aceptación: el ping responde y `sudo` acepta tu contraseña sin errores. Si el ping falla
pero `ping -c2 1.1.1.1` funciona, el problema es de DNS y lo resuelve el capítulo
[06](06_red_y_firewall.md) § 3.3; de momento puedes seguir usando la IP.

### Paso 2 — Lleva el repositorio al servidor

Este es el paso que convierte el servidor en un sitio donde se puede trabajar. Hay dos formas de
traer el repositorio y hay que hacer **una de las dos**, más el `scp` del final, que es obligatorio
en ambos casos.

**Opción A — clonar directamente** (recomendada: hace trivial la reconstrucción del capítulo 16):

```bash
# [servidor]
sudo apt update
sudo apt install -y git
git clone <url-del-repositorio> ~/nomad_server
```

**Opción B — copiar desde tu equipo**, si el repositorio aún no está publicado:

```bash
# [cliente] — desde la raíz del repositorio, ojo a la barra final de './'
rsync -av --exclude='.git' --exclude='config/servidor.env' --exclude='inventario' \
    ./ <usuario>@<ip-del-servidor>:~/nomad_server/
```

`--exclude='config/servidor.env'` está a propósito: ese archivo se copia aparte, en el comando
siguiente, para que quede claro que es un secreto y no parte del repositorio.

**En los dos casos**, copia tu configuración. **Nunca viaja por git**: está en `.gitignore`.

```bash
# [cliente]
scp config/servidor.env <usuario>@<ip-del-servidor>:~/nomad_server/config/
```

```bash
# [servidor]
chmod 600 ~/nomad_server/config/servidor.env
ls -l ~/nomad_server/config/servidor.env
```

Criterio de aceptación: `-rw-------`, es decir, permisos `600`.

**Y ahora, el paso que se repetirá en cada sesión a partir de aquí:**

```bash
# [servidor]
cd ~/nomad_server
source scripts/lib/entorno.sh
```

Salida esperada:

```
[OK]    Entorno cargado desde /home/deart/nomad_server/config/servidor.env
        servidor   : nomad.lan
        usuario    : deart
        LAN        : 192.168.1.50/24 en 192.168.1.0/24
        dominio    : ejemplo.com
        proyectos  : /srv
```

Criterio de aceptación: aparece `[OK] Entorno cargado` y el resumen muestra **los valores de tu
servidor**, no los del ejemplo. Si aparece `[ERROR] Variables OBLIGATORIAS sin valor`, rellénalas
antes de seguir:

```bash
# [servidor]
./scripts/variables.sh --faltan
```

> **A partir de aquí, todos los comandos de este capítulo usan `${VARIABLES}`** y solo funcionan si
> acabas de ejecutar ese `source`. Si reinicias el servidor (paso 11) o abres otra terminal, hay
> que repetirlo. El anexo [98](98_variables_y_entorno.md) explica por qué y qué otras trampas hay.

Si quieres tenerlo más a mano, añade un atajo a tu perfil:

```bash
# [servidor]
cat >> ~/.bashrc <<'PERFIL'

# --- nomad_server ---------------------------------------------------------
nomad() { source "$HOME/nomad_server/scripts/lib/entorno.sh"; }
PERFIL
source ~/.bashrc
```

A partir de entonces basta con escribir `nomad` al empezar cada sesión.

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

> Ojo con este bloque: `su -` abre un shell de **root**, y ese shell **no hereda** las variables que
> cargaste. `${ADMIN_USUARIO}` se expandiría a nada. Como el comando se teclea dentro de la sesión
> de root, hay dos formas de hacerlo bien: escribir el nombre de usuario literalmente, o pasarlo así
> desde tu sesión:
>
> ```bash
> # [servidor] — el valor se sustituye ANTES de que 'su' arranque
> su -c "usermod -aG sudo ${ADMIN_USUARIO}"
> ```
>
> Es el mismo mecanismo que se explica para `sudo` en el anexo
> [98 § 4.2](98_variables_y_entorno.md).

Después cierra la sesión y vuelve a entrar para que el grupo tenga efecto. **Y vuelve a cargar el
entorno**, porque la sesión nueva no lo tiene:

```bash
# [servidor]
cd ~/nomad_server && source scripts/lib/entorno.sh
```

### Paso 4 — Configura los repositorios

Primero, la copia de seguridad. Es lo que hacen los scripts por ti y lo que permite volver atrás:

```bash
# [servidor]
sudo cp -a /etc/apt/sources.list.d/debian.sources \
        /etc/apt/sources.list.d/debian.sources.bak-$(date +%Y%m%d-%H%M%S)
```

**Así queda el archivo** (con los valores de ejemplo, para poder leerlo):

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

**Y este es el comando que lo escribe con tus valores**, sin teclear nada:

```bash
# [servidor]
sudo tee /etc/apt/sources.list.d/debian.sources >/dev/null <<EOF
Types: deb
URIs: https://${DEBIAN_MIRROR}/debian
Suites: ${DEBIAN_SUITE} ${DEBIAN_SUITE}-updates
Components: main non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://security.debian.org/debian-security
Suites: ${DEBIAN_SUITE}-security
Components: main non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
```

Fíjate en que el heredoc va **sin comillas** (`<<EOF`, no `<<'EOF'`): es lo que permite que tu shell
sustituya `${DEBIAN_MIRROR}` y `${DEBIAN_SUITE}`. Con comillas, el archivo quedaría con esas cadenas
literales y `apt` fallaría (anexo [98 § 4.1](98_variables_y_entorno.md)).

Tercera opción, la que usa el script por dentro: aplicar la plantilla del repositorio, que además
lleva los comentarios explicativos:

```bash
# [servidor]
nomad_diff etc/debian.sources /etc/apt/sources.list.d/debian.sources
nomad_plantilla etc/debian.sources | sudo tee /etc/apt/sources.list.d/debian.sources >/dev/null
```

Comprueba el resultado antes de seguir:

```bash
# [servidor]
cat /etc/apt/sources.list.d/debian.sources
```

Criterio de aceptación: aparecen tus valores reales (`trixie`, `deb.debian.org`), **ninguna cadena
`${…}` sin sustituir**, y están los tres bloques de suites.

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
hostnamectl --static
```

Criterio de aceptación: imprime el nombre que tienes en `SERVIDOR_HOSTNAME`. Si imprime una línea
vacía, el entorno no estaba cargado y acabas de dejar el sistema sin nombre: vuelve a cargarlo y
repite.

Y ajusta `/etc/hosts` para que el nombre resuelva localmente.

**Así queda el archivo** (con los valores de ejemplo):

```
127.0.0.1       localhost
127.0.1.1       nomad.lan nomad

::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
```

**Y este es el comando que lo escribe con tus valores:**

```bash
# [servidor]
sudo cp -a /etc/hosts /etc/hosts.bak-$(date +%Y%m%d-%H%M%S)
sudo tee /etc/hosts >/dev/null <<EOF
127.0.0.1       localhost
127.0.1.1       ${SERVIDOR_HOSTNAME}.${SERVIDOR_DOMINIO_LOCAL} ${SERVIDOR_HOSTNAME}

::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF
cat /etc/hosts
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

El primer comando descomenta tu locale en `/etc/locale.gen`; el segundo la genera; el tercero la
declara como la del sistema. Los tres usan el valor de `SERVIDOR_LOCALE`, así que funcionan igual si
elegiste `es_ES.UTF-8`:

```bash
# [servidor]
sudo sed -i "s/^# *\(${SERVIDOR_LOCALE}\)/\1/" /etc/locale.gen
sudo locale-gen
sudo update-locale LANG=${SERVIDOR_LOCALE}
```

Comprobación:

```bash
# [servidor]
grep -c "^${SERVIDOR_LOCALE}" /etc/locale.gen
cat /etc/default/locale
```

Criterio de aceptación: el primer comando devuelve `1` o más, y el segundo muestra
`LANG=` con tu locale. El cambio se aplica del todo al abrir una sesión nueva.

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
sudo tee /etc/systemd/logind.conf.d/50-nomad-servidor.conf >/dev/null <<'EOF'
[Login]
HandlePowerKey=ignore
HandleLidSwitch=ignore
HandleSuspendKey=ignore
EOF
sudo systemctl restart systemd-logind
cat /etc/systemd/logind.conf.d/50-nomad-servidor.conf
```

Aquí el heredoc va **con comillas** (`<<'EOF'`) a propósito: este archivo no lleva ninguna variable
del despliegue, y las comillas garantizan que se escriba tal cual aunque tu shell tuviera definida
alguna variable con esos nombres. Es la otra mitad de la regla del anexo
[98 § 4.1](98_variables_y_entorno.md).

`HandleLidSwitch=ignore` solo importa si el servidor es un portátil, pero no molesta en un equipo de
sobremesa y ahorra un problema si algún día cambia el hardware.

### Paso 11 — Reinicia y comprueba

```bash
# [servidor]
sudo reboot
```

Espera un minuto y vuelve a conectarte. Si el equipo no vuelve, el monitor y el teclado siguen
conectados: es la razón por la que aún no los hemos retirado.

**Al volver, la sesión está en blanco.** El sistema conserva todo lo que has escrito en `/etc`, pero
tu terminal no conserva nada: ni las variables cargadas, ni la sesión de `tmux`, ni el directorio de
trabajo. El ritual completo es:

```bash
# [cliente]
ssh <usuario>@<ip-del-servidor>
```

```bash
# [servidor]
tmux new -s montaje
cd ~/nomad_server
source scripts/lib/entorno.sh
```

Es exactamente el mismo ritual que abre cada uno de los capítulos siguientes, y está resumido en
[checklists/reanudar_sesion.md](../checklists/reanudar_sesion.md).

---

## 6. Script asociado

### 6.1 Vía A — con el script

`scripts/04_base.sh` automatiza los pasos 4 a 10.

```bash
# [servidor]
cd ~/nomad_server
./scripts/04_base.sh --help
sudo ./scripts/04_base.sh --check      # muestra qué cambiaría, sin tocar nada
sudo ./scripts/04_base.sh
```

**No hace falta cargar el entorno** para esto: el script lee `config/servidor.env` por su cuenta y
aborta con un mensaje claro si falta alguna variable obligatoria. Es la diferencia principal con la
vía manual.

Opciones:

| Opción | Para qué |
|---|---|
| `--sin-actualizar` | Omite el paso 5 (`apt full-upgrade`). Útil para reejecutarlo sin esperar la descarga |
| `-n, --check` | Muestra las diferencias exactas, sin modificar nada |
| `-y, --si` | No pide confirmación |

En modo `--check` muestra las diferencias exactas que aplicaría a `debian.sources`, `/etc/hosts` y
la configuración de `logind`, la lista de paquetes que instalaría y los objetivos de systemd que
enmascararía. No ejecuta `apt` ni modifica ningún archivo.

Es idempotente: en una segunda ejecución informa con `[=]` de todo lo que ya estaba en su sitio. Eso
lo hace útil **después** de haber hecho los pasos a mano, como verificador.

### 6.2 Correspondencia entre el script y los pasos manuales

| Paso de la sección 5 | ¿Lo hace el script? | Nota |
|---|---|---|
| 0 — conectar y `tmux` | No | Ocurre en tu equipo |
| 1 — comprobar red y `sudo` | Sí | Aborta si no hay salida a internet |
| 2 — traer el repositorio y `servidor.env` | **No** | Ocurre antes de que el script exista en el servidor |
| 3 — estado de partida | Sí | Avisa si root tiene contraseña o si falta `sudo` |
| 4 — repositorios deb822 | Sí | Instala `templates/etc/debian.sources` |
| 5 — actualizar el sistema | Sí | Se omite con `--sin-actualizar` |
| 6 — nombre y `/etc/hosts` | Sí | |
| 7 — zona horaria y NTP | Sí | |
| 8 — configuración regional | Sí | |
| 9 — paquetes base | Sí | Solo instala los que falten |
| 10 — suspensión y botón de encendido | Sí | |
| 11 — reinicio | **No** | Avisa si hace falta, pero no reinicia por su cuenta |

### 6.3 Si prefieres la vía manual

Los pasos 4 a 10 de la sección 5 producen exactamente lo mismo. Lo que asumes:

- [ ] Cargar el entorno al principio de cada sesión (paso 2).
- [ ] Hacer la copia previa de cada archivo antes de sobrescribirlo.
- [ ] Comprobar, tras cada `tee`, que el archivo escrito no tiene `${…}` sin sustituir.
- [ ] Recorrer entera la sección 7 al terminar.

Y una comprobación que conviene hacer siempre, sea cual sea la vía:

```bash
# [servidor] — ¿ha quedado alguna variable sin sustituir en lo que acabas de escribir?
sudo grep -rl '\${' /etc/apt/sources.list.d/ /etc/hosts /etc/systemd/logind.conf.d/ 2>/dev/null \
    && echo "REVISAR: hay variables sin sustituir" || echo "CORRECTO"
```

Criterio de aceptación: `CORRECTO`.

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
# [servidor] — el entorno se puede cargar y las variables obligatorias tienen valor
cd ~/nomad_server && source scripts/lib/entorno.sh
```

Criterio de aceptación: `[OK] Entorno cargado`, sin ninguna línea `[ERROR]`.

```bash
# [servidor] — ningún archivo escrito ha quedado con variables sin sustituir
sudo grep -rl '\${' /etc/apt/sources.list.d/ /etc/hosts 2>/dev/null \
    && echo "REVISAR" || echo "CORRECTO"
```

Criterio de aceptación: `CORRECTO`. Es el error típico de haber usado `<<'EOF'` con comillas donde
no tocaba, o de haber pegado los comandos sin el entorno cargado.

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
| `git clone` falla con «Permission denied (publickey)» | El repositorio es privado y el servidor no tiene llave | Usa la opción B (`rsync`) del paso 2, o genera una llave de despliegue | Capítulo [05](05_usuarios_y_acceso_ssh.md) |
| `hostnamectl set-hostname` deja el nombre vacío | El entorno no estaba cargado: `${SERVIDOR_HOSTNAME}` se expandió a nada | `source scripts/lib/entorno.sh` y repite el paso 6 | Anexo [98](98_variables_y_entorno.md) § 3 |
| `apt update` falla y `debian.sources` contiene `${DEBIAN_SUITE}` literal | Se usó `<<'EOF'` con comillas, o no había entorno cargado | Reescribe el archivo con `<<EOF` sin comillas, o con `nomad_plantilla` | § 5 paso 4 |
| Tras clonar, no existe `config/servidor.env` | Está en `.gitignore` a propósito: nunca viaja por git | Cópialo con `scp` (paso 2) | § 3.7 |
| `source scripts/lib/entorno.sh` dice que no encuentra el archivo | Se ejecutó desde otro directorio, o el `scp` no llegó | `ls -l ~/nomad_server/config/servidor.env` y repite el `scp` | § 5 paso 2 |
| Tras reiniciar, los comandos vuelven a fallar con valores vacíos | Es lo normal: el entorno vive en el shell y murió con el reinicio | Repite el ritual del paso 11 | Anexo [98](98_variables_y_entorno.md) § 5 |
| `su -` no reconoce `${ADMIN_USUARIO}` | El shell de root no hereda tu entorno | Usa `su -c "usermod -aG sudo ${ADMIN_USUARIO}"` | § 5 paso 3 |
| Abrí una segunda ventana de tmux y no hay variables | Cada ventana es un shell independiente | Carga el entorno también allí | § 5 paso 0 |

---

## 10. Referencias

- [Debian — Notas de publicación de Trixie](https://www.debian.org/releases/trixie/releasenotes)
- [Debian Wiki — SourcesList](https://wiki.debian.org/SourcesList)
- [Manual de `sources.list` en formato deb822](https://manpages.debian.org/trixie/apt/sources.list.5.en.html)
- [Debian Wiki — SecureApt](https://wiki.debian.org/SecureApt)
- [Debian — Información de seguridad](https://www.debian.org/security/)
- [Debian Wiki — Hostname](https://wiki.debian.org/Hostname)
- [systemd — `logind.conf`](https://www.freedesktop.org/software/systemd/man/logind.conf.html)
- [`tmux(1)`](https://manpages.debian.org/trixie/tmux/tmux.1.en.html)
- Anexo [98 — Variables, entorno y sesiones](98_variables_y_entorno.md) — el ritual de cada sesión
- Anexo [97 — Las dos vías de montaje](97_vias_de_montaje.md) § 3.2, sobre llevar el repositorio al servidor

---

**Anterior:** [03 — Instalación de Debian](03_instalacion_debian.md) · **Siguiente:** [05 — Usuarios y acceso SSH](05_usuarios_y_acceso_ssh.md)
