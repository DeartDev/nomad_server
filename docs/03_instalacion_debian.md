# 03 — Instalación de Debian

> El paso irreversible. Al final tendrás un Debian 13 mínimo, sobre LVM, arrancando desde el disco
> y accesible por SSH.

---

## 1. Objetivo

Al terminar tendrás Debian 13 instalado sobre un esquema LVM pensado para crecer, sin entorno
gráfico, con un usuario administrador con `sudo`, con la cuenta de root bloqueada y con el servidor
SSH funcionando.

---

## 2. Requisitos previos

**Capítulos previos:** [01 — Unidad USB booteable](01_unidad_usb_booteable.md) y
[02 — Validación del equipo](02_validacion_equipo.md), **ambos completos**.

**Necesitas a mano:**

- El USB verificado del capítulo 01, conectado al equipo.
- Monitor y teclado conectados al servidor. Esta parte no se puede hacer remotamente.
- Cable de red conectado y con acceso a internet: `netinst` descarga los paquetes durante la
  instalación.
- `config/servidor.env` relleno, en particular `SERVIDOR_HOSTNAME`, `ADMIN_USUARIO`,
  `SERVIDOR_ZONA_HORARIA` y `DISCO_DESTINO`.
- Una contraseña buena para el usuario administrador, generada y guardada en tu gestor de
  contraseñas. La usarás poco —a partir del capítulo 05 se entra con llave— pero es la que
  te salvará si te quedas fuera.

> **Punto de no retorno.** Este capítulo borra el disco entero. Comprueba una última vez que el
> respaldo del capítulo 02, paso 5, está hecho y verificado.

**Tiempo estimado:** 45 minutos, de los cuales unos 15 son de descarga desatendida.

---

## 3. Decisiones y por qué

### 3.1 Contraseña de root vacía

**Decisión: dejar la contraseña de root en blanco durante la instalación.**

Cuando el instalador de Debian recibe una contraseña de root vacía, hace dos cosas: bloquea la
cuenta de root (nadie puede iniciar sesión como root) y añade automáticamente el primer usuario al
grupo `sudo`.

| Alternativa descartada | Por qué |
|---|---|
| Contraseña de root y usuario sin sudo | Obliga a `su -` para todo, y ninguna acción administrativa queda registrada con el nombre de quien la hizo. |
| Contraseña de root **y** usuario con sudo | Dos vías de acceso privilegiado, dos contraseñas que custodiar, y la de root nunca se usa. Superficie extra sin beneficio. |

Con root bloqueada, toda administración pasa por `sudo`, queda en el registro con el nombre del
usuario, y hay una credencial menos que proteger.

**Cómo se recupera el acceso si haces algo mal:** arrancando desde el USB en modo rescate. No queda
nadie fuera del sistema por bloquear root.

### 3.2 Particionado manual con LVM

**Decisión: particionado manual, con `/`, `/var` y `/srv` como volúmenes lógicos separados.**

El particionado guiado de Debian mete todo en un único volumen. Funciona, pero pierde la propiedad
que aquí más interesa: **que llenar una cosa no rompa las demás**.

| Volumen | Qué contiene | Qué pasa si se llena |
|---|---|---|
| `/` | Sistema y paquetes | El sistema deja de funcionar |
| `/var` | Imágenes, volúmenes y logs de Docker | Docker deja de funcionar, pero el sistema sigue en pie y puedes entrar a limpiar |
| `/srv` | Código y datos de los proyectos | Un proyecto deja de escribir, el resto sigue |

`/var` es, con diferencia, lo que más crece: una imagen de Docker ocupa cientos de megabytes y los
logs se acumulan. Sin separarlo, un contenedor mal configurado que escriba logs sin parar puede
llenar el disco raíz y dejar el sistema inutilizable, sin siquiera poder entrar por SSH a
arreglarlo.

**Se deja espacio libre sin asignar en el grupo de volúmenes a propósito.** Ampliar un volumen
lógico con LVM es trivial y se hace en caliente; reducirlo es arriesgado. Es mucho mejor quedarse
corto y crecer que sobredimensionar.

### 3.3 Sistema de archivos: ext4

**Decisión: ext4 en todos los volúmenes.**

| Alternativa descartada | Por qué |
|---|---|
| XFS | Más rápido con archivos grandes, y es lo que usa Red Hat por omisión. Pero **no se puede reducir**, lo que anula parte de la flexibilidad de LVM. |
| Btrfs | Instantáneas y sumas de comprobación integradas, muy atractivo. Su integración con Docker ha dado problemas históricamente y añade complejidad de mantenimiento. |
| ZFS | Excelente, pero no está en el núcleo de Linux y exige módulos externos, que además chocan con Secure Boot. |

ext4 es lo que Debian prueba más, lo que mejor documentado está y lo que menos sorpresas da. Para
este servidor, la fiabilidad y la previsibilidad valen más que las prestaciones extra.

### 3.4 `/boot` fuera de LVM

**Decisión: una partición `/boot` independiente de 1 GB.**

GRUB moderno puede arrancar desde LVM, pero mantener `/boot` fuera simplifica el rescate: desde
cualquier live se monta directamente, sin activar el grupo de volúmenes. En un arranque roto a las
dos de la mañana, esa diferencia importa.

1 GB parece mucho para unos pocos kernels, pero Debian conserva versiones anteriores y un `/boot`
lleno hace fallar la actualización del kernel. Es un fallo clásico y molesto de resolver.

### 3.5 Swap pequeña, no ausente

**Decisión: 4 GB de swap en un volumen lógico.**

Con 8 GB o más de RAM la swap casi no se usará. Se incluye igualmente porque el kernel de Linux la
aprovecha para expulsar páginas realmente inactivas y dejar más memoria para caché de disco, y
porque sin swap el *OOM killer* mata procesos de golpe, en lugar de degradar el rendimiento
gradualmente y darte tiempo a intervenir.

Se pone en un volumen lógico, no en una partición: así se puede cambiar de tamaño después.

### 3.6 Red por DHCP durante la instalación

**Decisión: DHCP durante la instalación; IP estática en el capítulo 06.**

Configurar la IP estática en el instalador es posible, pero si te equivocas en la máscara o en la
puerta de enlace lo descubres al final, cuando ya no hay red para descargar paquetes.

Como en el capítulo 00 ya reservaste `${LAN_IP}` en el router para la MAC del servidor, el DHCP le
entregará justamente esa dirección. En el capítulo 06 se fija de forma estática en el propio
sistema, con la reserva del router como red de seguridad.

### 3.7 Sin entorno de escritorio

**Decisión: en la selección de programas, solo «SSH server» y «standard system utilities».**

Todo lo demás se desmarca, incluido el servidor web y las bases de datos que ofrece `tasksel`.
Cualquier servicio que haga falta irá en un contenedor. Esto no es minimalismo por gusto: cada
paquete instalado en el host es una actualización más que aplicar y una vulnerabilidad potencial
más que vigilar.

---

## 4. Variables usadas

| Variable | Dónde se introduce en el instalador |
|---|---|
| `SERVIDOR_HOSTNAME` | Pantalla «Configurar la red → Nombre de la máquina» |
| `SERVIDOR_DOMINIO_LOCAL` | Pantalla «Nombre de dominio» |
| `SERVIDOR_ZONA_HORARIA` | Pantalla «Configurar el reloj» |
| `SERVIDOR_LOCALE` | Pantallas de idioma y localización |
| `ADMIN_USUARIO` | Pantalla «Configurar usuarios y contraseñas» |
| `DISCO_DESTINO` | Pantalla «Particionado de discos» |
| `DEBIAN_MIRROR` | Pantalla «Configurar el gestor de paquetes» |

Ten `config/servidor.env` abierto en otro equipo mientras instalas: el instalador no puede leerlo.

---

## 5. Procedimiento

### Paso 1 — Arranca desde el USB

Conecta el USB, enciende el equipo y pulsa la tecla del menú de arranque (`F12`, `F11`, `F8` o
`Esc`, según el fabricante). Elige la entrada **UEFI** correspondiente al USB.

> Si aparecen dos entradas para el mismo USB, una con el prefijo `UEFI:` y otra sin él, elige
> **siempre la de `UEFI:`**. La otra arranca en modo legacy y produce un sistema que no arrancará
> después.

En el menú del instalador elige **Install** (modo texto) o **Graphical install**. Son idénticos en
contenido; el modo texto responde mejor por consola serie o con teclados raros.

**Cómo moverse por el instalador en modo texto:** flechas para navegar, `Espacio` para marcar y
desmarcar casillas, `Tab` para saltar a los botones, `Enter` para aceptar. `Alt+F4` muestra el
registro de errores y `Alt+F1` vuelve al instalador: útil si algo falla.

### Paso 2 — Idioma, ubicación y teclado

| Pantalla | Qué elegir |
|---|---|
| Select a language | **English** |
| Select your location | Tu país |
| Configure locales | `${SERVIDOR_LOCALE}` (`en_US.UTF-8`) |
| Configure the keyboard | La distribución **física** de tu teclado (`Spanish`, `Latin American`…) |

> **Por qué el sistema en inglés.** Los mensajes de error en inglés se pueden pegar en un buscador y
> encontrar respuesta; los mismos mensajes traducidos, casi nunca. Es una decisión práctica, no de
> preferencia. La distribución del **teclado** sí debe ser la real, o no acertarás al escribir la
> contraseña.

Si prefieres el sistema en español, elige `es_ES.UTF-8`: nada de lo que sigue cambia.

### Paso 3 — Red

El instalador intentará configurar la red por DHCP automáticamente.

| Pantalla | Qué introducir |
|---|---|
| Hostname | `${SERVIDOR_HOSTNAME}` — solo el nombre corto, sin puntos |
| Domain name | `${SERVIDOR_DOMINIO_LOCAL}` (por ejemplo `lan`) |

Si el DHCP falla, el instalador ofrece configurar la red a mano: introduce `${LAN_IP}`, la máscara
correspondiente a `${LAN_PREFIJO}`, `${LAN_GATEWAY}` y `${LAN_DNS}`.

Si te pide elegir entre varias interfaces, elige la cableada (`enp…` o `eno…`), no la inalámbrica.

### Paso 4 — Usuarios y contraseñas

Aquí se aplica la decisión 3.1:

| Pantalla | Qué introducir |
|---|---|
| Root password | **Déjalo vacío** y pulsa Continue |
| Re-enter password to verify | **Déjalo vacío** |
| Full name for the new user | Tu nombre completo |
| Username for your account | `${ADMIN_USUARIO}` |
| Choose a password | La contraseña de tu gestor de contraseñas |

El instalador no avisa de nada al dejar root en blanco: simplemente bloquea la cuenta y añade tu
usuario a `sudo`. Se verifica en el capítulo 04.

### Paso 5 — Reloj

Elige la zona correspondiente a `${SERVIDOR_ZONA_HORARIA}`. Si tu país tiene varias, el instalador
te dará a elegir.

### Paso 6 — Particionado

Esta es la parte delicada. **Elige `Manual`**, no ninguna de las opciones guiadas.

#### 6.1 — Identifica el disco correcto

El instalador muestra los discos como `/dev/sda`, `/dev/nvme0n1`… Contrasta el **tamaño y el
modelo** con el inventario del capítulo 02 y con `DISCO_DESTINO`. Si hay más de un disco, esta es la
pantalla donde un descuido cuesta caro.

#### 6.2 — Borra la tabla de particiones existente

Selecciona el disco (la línea con el nombre del modelo, no las particiones) y pulsa `Enter`.
Responde **Yes** a «Create new empty partition table on this device?» y elige **gpt**.

> GPT es obligatorio para el arranque UEFI. Si el instalador solo ofrece `msdos`, es que arrancaste
> en modo legacy: vuelve al paso 1.

#### 6.3 — Partición EFI (512 MB)

Selecciona `FREE SPACE` bajo el disco → `Create a new partition`:

| Campo | Valor |
|---|---|
| New partition size | `512 MB` |
| Location | `Beginning` |
| Use as | **EFI System Partition** |

`Done setting up the partition`.

#### 6.4 — Partición `/boot` (1 GB)

`FREE SPACE` → `Create a new partition`:

| Campo | Valor |
|---|---|
| New partition size | `1 GB` |
| Location | `Beginning` |
| Use as | `Ext4 journaling file system` |
| Mount point | `/boot` |

`Done setting up the partition`.

#### 6.5 — Partición para LVM (todo el resto)

`FREE SPACE` → `Create a new partition`:

| Campo | Valor |
|---|---|
| New partition size | `max` (escribe literalmente `max`) |
| Use as | **physical volume for LVM** |

`Done setting up the partition`.

#### 6.6 — Crea el grupo de volúmenes

Vuelve al menú principal del particionador y elige
**Configure the Logical Volume Manager**. Confirma escribir los cambios en disco (**Yes**).

1. `Create volume group`
   - Volume group name: `vg0`
   - Selecciona la partición LVM que acabas de crear (la tercera: `/dev/sda3` o similar)

2. `Create logical volume`, una vez por cada volumen de esta tabla:

| Nombre | Tamaño | Notas |
|---|---|---|
| `raiz` | `40 GB` | Sistema y paquetes |
| `var` | `30 GB` | Docker: imágenes, volúmenes y logs |
| `swap` | `4 GB` | 2 GB si tienes 16 GB o más de RAM |
| `srv` | `100 GB` | Proyectos. Ajusta según tu disco |

> **Deja libre entre el 20 % y el 30 % del grupo de volúmenes.** En un disco de 500 GB, los tamaños
> anteriores suman 174 GB y dejan unos 290 GB sin asignar. Eso es correcto y deliberado: cuando un
> volumen se quede corto lo amplías en caliente con `lvextend` (capítulo 15). Es la única razón por
> la que se usa LVM.

3. `Finish` para salir del gestor de LVM.

#### 6.7 — Formatea los volúmenes lógicos

De vuelta en el particionador, ahora aparecen los volúmenes bajo `LVM VG vg0`. Selecciona cada uno y
configúralo:

| Volumen | Use as | Mount point |
|---|---|---|
| `raiz` | `Ext4 journaling file system` | `/` |
| `var` | `Ext4 journaling file system` | `/var` |
| `srv` | `Ext4 journaling file system` | `/srv` |
| `swap` | **swap area** | — |

#### 6.8 — Revisa y confirma

La pantalla final debería parecerse a esto:

```
LVM VG vg0, LV raiz    -  42.9 GB  Linux device-mapper (linear)
        #1  42.9 GB   f  ext4       /
LVM VG vg0, LV srv     - 107.4 GB  Linux device-mapper (linear)
        #1 107.4 GB   f  ext4       /srv
LVM VG vg0, LV swap    -   4.2 GB  Linux device-mapper (linear)
        #1   4.2 GB   f  swap       swap
LVM VG vg0, LV var     -  32.2 GB  Linux device-mapper (linear)
        #1  32.2 GB   f  ext4       /var

SCSI1 (0,0,0) (sda) - 500.1 GB ATA Samsung SSD 870
        #1  537.9 MB  B  K  ESP
        #2    1.0 GB  F  K  ext4     /boot
        #3  498.5 GB     K  lvm
```

Comprueba antes de continuar:

- [ ] Hay una partición **ESP**.
- [ ] `/boot` es una partición **fuera** de LVM.
- [ ] `/`, `/var` y `/srv` son volúmenes lógicos **dentro** de `vg0`.
- [ ] Hay un área de **swap**.
- [ ] Queda espacio sin asignar en `vg0`.

`Finish partitioning and write changes to disk` → **Yes**.

**A partir de aquí el disco está borrado.**

### Paso 7 — Instalación del sistema base

Desatendido, unos 5 minutos.

### Paso 8 — Gestor de paquetes

| Pantalla | Qué elegir |
|---|---|
| Scan extra installation media? | **No** |
| Debian archive mirror country | Tu país, o `deb.debian.org` si aparece |
| Debian archive mirror | `${DEBIAN_MIRROR}` (`deb.debian.org` sirve en todo el mundo) |
| HTTP proxy information | Vacío, salvo que tu red use proxy |

`deb.debian.org` es un servicio con reparto geográfico: te dirige automáticamente a una réplica
cercana. Es la opción correcta salvo que sepas que tu proveedor tiene una réplica local más rápida.

### Paso 9 — Encuesta de popularidad

`Participate in the package usage survey?` → **No**.

Es inocua (envía qué paquetes usas, de forma anónima) pero significa tráfico saliente periódico
desde un servidor donde queremos saber exactamente qué habla con el exterior.

### Paso 10 — Selección de programas

**Esta pantalla es la que decide si acabas con un servidor o con un escritorio.** Usa `Espacio` para
marcar y desmarcar.

| Opción | Marcar |
|---|---|
| Debian desktop environment | **NO** |
| ... GNOME / KDE / Xfce / etc. | **NO** |
| Web server | **NO** |
| SSH server | **SÍ** |
| standard system utilities | **SÍ** |

Solo dos opciones marcadas. Si dudas, desmarca: todo lo que falte se instala después con `apt`.

Descarga e instalación: entre 5 y 15 minutos según tu conexión.

### Paso 11 — GRUB

| Pantalla | Qué elegir |
|---|---|
| Install the GRUB boot loader to your primary drive? | **Yes** |
| Device for boot loader installation | El disco completo (`/dev/sda`), **no** una partición |

En modo UEFI, GRUB se instala en la partición ESP; el instalador lo gestiona solo.

### Paso 12 — Primer arranque

`Installation complete` → **Continue**. El equipo se reinicia.

**Retira el USB** mientras reinicia, o volverá a arrancar el instalador.

Debería aparecer el menú de GRUB y, tras unos segundos, la consola de acceso:

```
Debian GNU/Linux 13 nomad tty1

nomad login:
```

Entra con `${ADMIN_USUARIO}` y tu contraseña.

### Paso 13 — Comprobación inmediata

Antes de desconectar el monitor, comprueba lo esencial:

```bash
# [servidor] — en la consola física
ip -br -4 addr                 # ¿tiene IP?
ping -c2 deb.debian.org        # ¿hay internet?
sudo -v                        # ¿funciona sudo?
systemctl is-active ssh        # ¿está el servidor SSH?
```

Criterio de aceptación: hay IP, hay internet, `sudo` acepta tu contraseña y `ssh` responde
`active`.

Anota la IP: es la que usarás para conectarte en el capítulo 04.

---

## 6. Script asociado

**Este capítulo no tiene script ejecutable**: el instalador de Debian es interactivo y se ejecuta
antes de que exista ningún sistema donde correr nada.

### Alternativa avanzada: instalación automatizada (preseed)

Debian permite responder de antemano a todas las preguntas del instalador mediante un archivo
*preseed*. `templates/preseed.cfg` contiene una plantilla comentada que reproduce exactamente las
decisiones de este capítulo.

```bash
# [cliente] — genera tu preseed a partir de la plantilla y tu configuración
set -a; . config/servidor.env; set +a
envsubst "$(grep -oE '^[A-Z][A-Z0-9_]*=' config/servidor.env.example \
            | tr -d '=' | sed 's/^/${/; s/$/}/' | tr '\n' ' ')" \
    < templates/preseed.cfg > /tmp/preseed.cfg
```

Hay que pasarle a `envsubst` la lista explícita de variables. Sin ella destrozaría la sintaxis del
particionador, que también usa `$` para lo suyo (`$primary{ }`, `$lvmok{ }`).

Después, sirve el archivo por HTTP desde tu equipo:

```bash
# [cliente]
python3 -m http.server 8000 --directory /tmp
```

Y en el menú del instalador pulsa `Tab` sobre «Install», añade al final de la línea de arranque
`auto=true priority=critical url=http://<ip-de-tu-equipo>:8000/preseed.cfg` y pulsa `Enter`.

> **Valídalo antes en una máquina virtual.** Un preseed mal escrito no se detiene a preguntar: borra
> el disco que le digas sin pedir confirmación. La vía manual de la sección 5 es la ruta
> recomendada y la que está probada. El preseed es útil cuando ya has hecho la instalación manual
> al menos una vez y quieres repetirla de forma idéntica.

---

## 7. Validación

Todo lo siguiente se ejecuta en la consola física del servidor.

```bash
# [servidor] — versión de Debian
cat /etc/os-release | grep -E 'PRETTY_NAME|VERSION_CODENAME'
```

Criterio de aceptación: `Debian GNU/Linux 13 (trixie)`.

```bash
# [servidor] — arranque en modo UEFI
[ -d /sys/firmware/efi ] && echo "UEFI CORRECTO" || echo "ARRANQUE LEGACY - PROBLEMA"
```

Criterio de aceptación: `UEFI CORRECTO`. Si dice legacy, hay que reinstalar: el modo de arranque no
se puede cambiar después.

```bash
# [servidor] — esquema de volúmenes
lsblk
df -h /  /var  /srv  /boot
sudo vgs
sudo lvs
```

Criterio de aceptación: `/`, `/var` y `/srv` son sistemas de archivos distintos; `vgs` muestra
`vg0` con espacio libre (`VFree` mayor que cero).

```bash
# [servidor] — root debe estar bloqueada
sudo passwd -S root
```

Criterio de aceptación: la segunda columna es `L` (locked). Si es `P`, root tiene contraseña: se
corrige en el capítulo 04.

```bash
# [servidor] — el usuario debe tener sudo
groups | grep -q sudo && echo "SUDO OK"
```

Criterio de aceptación: `SUDO OK`.

```bash
# [servidor] — no debe haber entorno gráfico
dpkg -l | grep -cE '^ii\s+(xserver-xorg|gnome-shell|plasma-desktop)'
```

Criterio de aceptación: `0`.

```bash
# [servidor] — swap activa
swapon --show
free -h | grep Swap
```

Criterio de aceptación: aparece el dispositivo `/dev/mapper/vg0-swap`.

```bash
# [servidor] — SSH escuchando
systemctl is-enabled ssh && systemctl is-active ssh
ss -tlnp | grep :22
```

Criterio de aceptación: `enabled`, `active`, y el puerto 22 en escucha.

**Prueba final desde tu equipo**, que además valida que la red funciona de extremo a extremo:

```bash
# [cliente]
ssh ${ADMIN_USUARIO}@<ip-del-servidor>
```

Criterio de aceptación: pide contraseña y entra. **A partir de aquí ya no necesitas el monitor ni el
teclado del servidor**, aunque conviene dejarlos conectados hasta terminar el capítulo 05.

---

## 8. Reversión

No hay reversión parcial: si la instalación salió mal, se repite entera. Es rápido —45 minutos— y
no hay nada que perder porque aún no hay datos.

**Motivos por los que merece la pena reinstalar en lugar de arreglar:**

- Arrancó en modo legacy en vez de UEFI.
- El particionado quedó sin separar `/var` o sin espacio libre en `vg0`.
- Se instaló un entorno de escritorio por error.

**Motivos por los que NO hace falta reinstalar** (se arreglan en el capítulo 04):

- Zona horaria, `locale` o nombre de la máquina equivocados.
- Root quedó con contraseña.
- Falta algún paquete.

**Para volver al estado anterior del equipo**, restaura la imagen del disco que hiciste en el
capítulo 02, paso 5:

```bash
# [equipo] — desde un live, con el disco externo conectado
gunzip -c /mnt/externo/imagen-disco-completo.img.gz | sudo dd of=/dev/sda bs=4M status=progress
```

---

## 9. Errores frecuentes

| Síntoma | Causa probable | Solución | Documentación |
|---|---|---|---|
| El instalador no encuentra ningún disco | Controladora SATA en modo RAID / Intel RST | Reinicia, entra en la UEFI y pon SATA Mode en **AHCI** | Capítulo [02](02_validacion_equipo.md) § 3.4 |
| «No common CD-ROM drive was detected» | El instalador no reconoce el USB, o el medio se escribió mal | Prueba otro puerto USB (preferiblemente 2.0) y verifica el medio | Capítulo [01](01_unidad_usb_booteable.md) § 5 paso 11 |
| El particionador solo ofrece `msdos`, no `gpt` | Arrancaste en modo legacy | Reinicia, elige la entrada `UEFI:` del menú de arranque | § 5 paso 1 |
| «No network interfaces detected» | Falta firmware de la tarjeta de red | Las imágenes de Debian 13 ya lo incluyen. Si persiste, usa un adaptador USB-Ethernet | [Debian Wiki — Firmware](https://wiki.debian.org/Firmware) |
| La instalación falla al descargar paquetes | Réplica caída, DNS mal, o sin salida a internet | Vuelve atrás y elige `deb.debian.org`. Comprueba con `Alt+F2` y `ping 1.1.1.1` | [Réplicas de Debian](https://www.debian.org/mirror/list) |
| Tras reiniciar aparece «No bootable device» | GRUB se instaló en una partición, o el orden de arranque no incluye el disco | Arranca en modo rescate desde el USB y reinstala GRUB (ver abajo) | [Debian Wiki — GRUB](https://wiki.debian.org/GRUB) |
| Vuelve a arrancar el instalador | El USB sigue conectado y va primero en el orden de arranque | Retira el USB, o cambia el orden en la UEFI | — |
| `sudo` responde «user is not in the sudoers file» | Se puso contraseña de root, así que el instalador no añadió el usuario a `sudo` | Entra como root con `su -` y ejecuta `usermod -aG sudo ${ADMIN_USUARIO}`, luego reinicia sesión | § 3.1 |
| GRUB no aparece: arranca directamente | Comportamiento normal cuando solo hay un sistema | Mantén pulsada `Shift` (BIOS) o `Esc` (UEFI) durante el arranque | [Debian Wiki — GRUB](https://wiki.debian.org/GRUB) |
| El sistema arranca pero sin red | La interfaz cambió de nombre respecto al instalador | Comprueba con `ip -br link` y ajusta en el capítulo [06](06_red_y_firewall.md) | Capítulo 06 |
| `/boot` se llena al actualizar el kernel | Se creó demasiado pequeño | `sudo apt autoremove --purge` elimina kernels antiguos. Con 1 GB no debería ocurrir | Capítulo [15](15_mantenimiento_y_actualizaciones.md) |

### Reinstalar GRUB desde el modo rescate

```bash
# [servidor] — arranca desde el USB → Advanced options → Rescue mode
# Elige /dev/mapper/vg0-raiz como sistema de archivos raíz
# y responde "Sí" a montar /boot y la partición EFI
chroot /target
grub-install /dev/sda
update-grub
exit
reboot
```

---

## 10. Referencias

- [Guía de instalación de Debian 13 (amd64)](https://www.debian.org/releases/trixie/amd64/)
- [Debian — Particionado durante la instalación](https://www.debian.org/releases/trixie/amd64/ch06s03)
- [Debian Wiki — LVM](https://wiki.debian.org/LVM)
- [Debian Wiki — GRUB](https://wiki.debian.org/GRUB)
- [Debian Wiki — Secure Boot](https://wiki.debian.org/SecureBoot)
- [Debian — Instalación automatizada con preseed](https://www.debian.org/releases/trixie/amd64/apb)
- [Debian — Notas de publicación de Trixie](https://www.debian.org/releases/trixie/releasenotes)

---

**Anterior:** [02 — Validación del equipo](02_validacion_equipo.md) · **Siguiente:** [04 — Primer arranque y base](04_primer_arranque_y_base.md)
