# 02 — Validación del equipo

> Comprobar que el hardware está sano antes de confiarle datos, rescatar lo que hubiera en él, y
> dejar la UEFI configurada para que se comporte como un servidor y no como un ordenador de mesa.

---

## 1. Objetivo

Al terminar tendrás: un inventario escrito del hardware, la certeza de que el disco y la memoria
están sanos, una copia de seguridad de lo que hubiera en el equipo, y la UEFI configurada para
arrancar sola tras un corte de luz y no suspenderse nunca.

---

## 2. Requisitos previos

**Capítulos previos:** [00 — Planificación](00_planificacion.md). Se puede hacer en paralelo con el
[01](01_unidad_usb_booteable.md).

**Necesitas a mano:**

- El equipo candidato, un monitor y un teclado conectados físicamente.
- Un cable de red conectado al router. Nada de Wi-Fi (ver 3.1).
- Un disco externo con espacio suficiente si el equipo tiene datos que rescatar.
- Un USB con un sistema Linux *live* (sirve el propio instalador de Debian en modo rescate) para
  poder inspeccionar el equipo sin depender de su sistema actual.
- Tiempo: la comprobación de memoria completa puede tardar varias horas. Conviene lanzarla por la
  noche.

**Este capítulo no instala nada** en el equipo. Es la última oportunidad de recuperar datos antes
del formateo del capítulo 03.

**Preparar la sesión.** Este capítulo es el único que se ejecuta **delante del equipo candidato**,
normalmente desde un sistema *live*, y ahí no hay repositorio ni configuración. Los bloques de
comandos van marcados como `# [equipo]` para distinguirlos.

Si quieres usar el script del inventario, lleva el repositorio al sistema *live*:

```bash
# [equipo] — con red disponible
sudo apt update && sudo apt install -y git      # en un live de Debian/Ubuntu
git clone <url-del-repositorio> /tmp/nomad_server
cd /tmp/nomad_server
```

Si el *live* no tiene red o el repositorio no está publicado, cópialo desde tu equipo a una segunda
memoria USB y móntala. **No hace falta `config/servidor.env`**: el inventario no usa ninguna
variable del despliegue, solo escribe un archivo con lo que encuentra.

Los resultados de este capítulo —`DISCO_DESTINO` y `LAN_INTERFAZ`— se anotan al final, **en tu
equipo**, dentro de `config/servidor.env`. El paso 9 da los comandos exactos.

---

## 3. Decisiones y por qué

### 3.1 Red por cable, siempre

**Decisión: conexión Ethernet. Si el equipo solo tiene Wi-Fi, se añade un adaptador USB-Ethernet.**

Un servidor con Wi-Fi es una fuente constante de problemas difíciles de diagnosticar:
reconexiones silenciosas que cortan sesiones SSH, latencia variable que hace que un túnel parezca
caído, firmware propietario que a veces falla tras una actualización de kernel, y una IP que cambia
si el punto de acceso se reinicia. Un adaptador USB-Ethernet cuesta poco y elimina toda esa
categoría de fallos.

### 3.2 Comprobar la memoria antes, no después

**Decisión: una pasada completa de memtest86+ antes de instalar.**

La RAM defectuosa es especialmente traicionera en un servidor: no provoca un fallo evidente, sino
corrupción silenciosa. Un bit que cambia al escribir en disco corrompe un volumen de Docker o un
respaldo, y el error se descubre semanas después, cuando ya se ha propagado a todas las copias.

Es el tipo de comprobación que solo cuesta una noche si se hace ahora, y que cuesta un fin de
semana entero de diagnóstico si se hace después.

### 3.3 Secure Boot: se deja activado

**Decisión: mantener Secure Boot habilitado.**

Debian firma su gestor de arranque y su kernel con el `shim` de Microsoft, así que arranca sin
problemas con Secure Boot activo. Muchas guías indican desactivarlo por costumbre heredada de
distribuciones que no lo soportaban; aquí no hace falta y desactivarlo solo resta.

**Cuándo sí desactivarlo:** si necesitas cargar módulos de kernel compilados fuera del árbol
(drivers propietarios de NVIDIA, ZFS, VirtualBox). Ninguno interviene en este montaje.

### 3.4 Modo SATA: AHCI

**Decisión: comprobar que la controladora está en modo AHCI, no en RAID ni en IDE.**

Es la causa número uno de «el instalador no encuentra el disco». Muchos equipos de fábrica vienen
con Intel RST (modo RAID) activado, y el kernel de Linux no ve los discos detrás de esa capa.

> Si el equipo tiene actualmente Windows instalado y cambias de RAID a AHCI, **Windows dejará de
> arrancar**. Como aquí se va a formatear el disco, da igual. Pero tenlo presente si pensabas
> conservar el arranque dual.

### 3.5 Comportamiento tras un corte de luz

**Decisión: configurar la UEFI para que encienda automáticamente al restaurarse la corriente.**

Este es el ajuste que separa un servidor de un ordenador de sobremesa. Por omisión, casi todos los
equipos se quedan apagados cuando vuelve la luz. Si el servidor está en casa y tú no, eso significa
servicios caídos hasta que alguien pulse el botón.

El ajuste suele llamarse *AC Power Recovery*, *Restore on AC Power Loss*, *After Power Failure* o
*State After Power Loss*, según el fabricante, y hay que ponerlo en **Power On** / **Last State**.

### 3.6 Nada de suspensión

**Decisión: desactivar todos los estados de suspensión en la UEFI y, más adelante, en el sistema.**

Un servidor suspendido no responde a SSH ni mantiene el túnel abierto. Además, la reanudación desde
S3 es una de las operaciones donde más fallan los controladores de red. Se desactiva en dos sitios:
en la UEFI (aquí) y en systemd (capítulo 04), porque cualquiera de los dos puede dormir el equipo.

### 3.7 Sobre el SAI (UPS)

**Decisión: recomendado, no obligatorio.**

Este montaje no depende de un SAI —el ajuste de 3.5 hace que el servidor vuelva solo—, pero un
corte de luz durante una escritura puede corromper el sistema de archivos. Un SAI pequeño que
aguante cinco minutos evita la mayoría de esos casos. Si lo instalas, el paquete `nut` permite un
apagado ordenado; queda fuera del alcance de este repositorio.

---

## 4. Variables usadas

### 4.1 De `config/servidor.env` (solo para contrastar)

| Variable | Uso en este capítulo |
|---|---|
| `LAN_CIDR` | Se contrasta con la red que se observa realmente en el equipo |
| `LAN_GATEWAY` | Se contrasta con la puerta de enlace real |

Ninguna hace falta cargada en la sesión: se comparan a ojo con lo que muestren los comandos.

### 4.2 Variables que se DESCUBREN en este capítulo

Este es el capítulo que más valores aporta al archivo de configuración. **Anótalos antes de apagar
el equipo**: si no, hay que volver a arrancarlo con el *live* para averiguarlos.

| Variable | Qué es | Cómo se obtiene | La necesita |
|---|---|---|---|
| `DISCO_DESTINO` | Ruta estable del disco donde se instalará Debian | Paso 2, con `ls -l /dev/disk/by-id/` | Capítulo [03](03_instalacion_debian.md) |
| `LAN_INTERFAZ` | Nombre de la interfaz cableada | Paso 2, con `ip -br link` | Capítulo [06](06_red_y_firewall.md) |

`DISCO_DESTINO` usa la ruta por identificador de hardware (`/dev/disk/by-id/ata-Marca_Modelo_Serie`)
y no `/dev/sda`, porque las letras cambian de orden entre arranques según qué disco responda antes.
Instalar en `/dev/sda` creyendo que es el SSD y que resulte ser el disco de datos es un error real y
caro.

`LAN_INTERFAZ` puede quedarse vacía: los scripts la detectan solas y el capítulo 06 la confirma. Se
anota aquí porque ya la tienes delante.

El paso 9 da los comandos exactos para escribir ambas.

### 4.3 Variables temporales de esta sesión

| Variable | Qué contiene | Se declara en |
|---|---|---|
| `DISCO` | Dispositivo que se está inspeccionando (`/dev/sda`) | Paso 3 |

Solo vive en la terminal del sistema *live*. No confundirla con `DISCO_DESTINO`: `DISCO` es la ruta
volátil (`/dev/sda`) que se usa para consultar SMART; `DISCO_DESTINO` es la ruta estable que se
guarda.

---

## 5. Procedimiento

### Paso 1 — Arranca el equipo con un Linux *live*

Si el equipo tiene ya un Linux funcionando, puedes usarlo directamente. Si tiene Windows, o si no
tiene nada, arranca desde el USB del capítulo 01 y elige **Advanced options → Rescue mode**, y
dentro **Execute a shell in the installer environment**.

Otra opción cómoda para esta fase es un *live* con entorno gráfico y navegador
(Debian Live, Ubuntu, GParted Live), porque permite consultar la documentación en el mismo equipo.

### Paso 2 — Inventario del hardware

Ejecuta cada bloque y **guarda la salida**. La necesitarás en el capítulo 03 y, sobre todo, el día
que algo falle y quieras saber qué llevaba dentro esta máquina.

```bash
# [equipo] — identificación de la máquina
sudo dmidecode -s system-manufacturer
sudo dmidecode -s system-product-name
sudo dmidecode -s baseboard-product-name
sudo dmidecode -s bios-version
sudo dmidecode -s bios-release-date
```

```bash
# [equipo] — procesador
lscpu | grep -E 'Model name|^CPU\(s\)|Thread|Core|Architecture|Virtualization'
```

Criterio de aceptación: arquitectura `x86_64`, al menos 2 núcleos. Con menos de 2 núcleos, Docker
con varios contenedores irá justo.

```bash
# [equipo] — memoria
free -h
sudo dmidecode -t memory | grep -E 'Size|Speed|Type:|Locator' | grep -v 'No Module'
```

Criterio de aceptación: 4 GB como mínimo, 8 GB recomendados. Anota también cuántos zócalos hay
libres, por si más adelante quieres ampliar.

```bash
# [equipo] — discos
lsblk -o NAME,SIZE,TYPE,MODEL,SERIAL,ROTA,TRAN
ls -l /dev/disk/by-id/ | grep -v part
```

`ROTA=1` significa disco mecánico; `ROTA=0`, SSD. **Instala el sistema en un SSD**: la diferencia en
arranque de contenedores y en operaciones de Docker es enorme.

De la salida de `/dev/disk/by-id/` sale el valor de `DISCO_DESTINO`. Elige la entrada que empiece
por `ata-`, `nvme-` o `scsi-` seguida de marca, modelo y número de serie, e ignora las que
contengan `-part`:

```
lrwxrwxrwx 1 root root 9 ago  9 10:15 ata-Samsung_SSD_870_EVO_500GB_S6PENL0T123456 -> ../../sda
```

```bash
# [equipo] — red
ip -br link
lspci | grep -iE 'ethernet|network'
```

Anota el nombre de la interfaz cableada (`enp3s0`, `eno1`…) para `LAN_INTERFAZ`.

```bash
# [equipo] — resto del hardware
lspci
lsusb
```

### Paso 3 — Salud de los discos

Declara primero qué disco vas a inspeccionar. Es una variable **temporal de esta sesión** (§ 4.3):
si cierras la terminal, hay que volver a declararla.

```bash
# [equipo]
DISCO=/dev/sda                        # ← el tuyo, según la salida del paso 2
echo "Inspeccionando: ${DISCO}"
```

Criterio de aceptación: imprime el dispositivo. Si sale vacío, los comandos siguientes fallarán con
mensajes confusos sobre dispositivos inexistentes.

```bash
# [equipo]
sudo apt install -y smartmontools     # o: sudo dnf install smartmontools
sudo smartctl -i "${DISCO}"
sudo smartctl -H "${DISCO}"
```

Criterio de aceptación:

```
SMART overall-health self-assessment test result: PASSED
```

Si dice `FAILED`, **no uses ese disco**. Está avisando de un fallo inminente.

Los atributos concretos importan tanto como el veredicto global:

```bash
# [equipo] — disco mecánico
sudo smartctl -A "${DISCO}" | grep -E 'Reallocated_Sector|Current_Pending|Offline_Uncorrectable|Power_On_Hours'
```

```bash
# [equipo] — SSD
sudo smartctl -A "${DISCO}" | grep -E 'Wear_Leveling|Percent_Lifetime|Media_Wearout|Total_LBAs_Written|Power_On_Hours'
```

Cómo leerlo:

| Atributo | Qué significa | Cuándo preocuparse |
|---|---|---|
| `Reallocated_Sector_Ct` | Sectores que el disco ha dado por muertos y sustituido | Cualquier valor > 0 en un disco que vas a usar como servidor es motivo para descartarlo |
| `Current_Pending_Sector` | Sectores dudosos aún sin reasignar | > 0 indica un disco en proceso de degradación |
| `Power_On_Hours` | Horas encendido | > 40 000 h (unos 4,5 años continuos) en un disco mecánico: contempla sustituirlo |
| `Wear_Leveling_Count` / `Percent_Lifetime_Remain` | Desgaste del SSD | Por debajo del 20 % restante, sustitúyelo |

Lanza además una prueba corta:

```bash
# [equipo]
sudo smartctl -t short "${DISCO}"
sleep 120
sudo smartctl -l selftest "${DISCO}"
```

Criterio de aceptación: `Completed without error`.

Si el disco tiene alguna sospecha, lanza la prueba larga (`-t long`, varias horas) y déjala correr
mientras haces la comprobación de memoria.

### Paso 4 — Comprobación de memoria

memtest86+ se ejecuta fuera del sistema operativo, así que necesita su propio medio de arranque.

**Opción recomendada:** descarga la imagen desde <https://www.memtest.org> y escríbela en otro USB
con el mismo procedimiento del capítulo [01](01_unidad_usb_booteable.md), paso 10. Arranca desde
ella y déjala trabajar.

**Alternativa:** si prefieres no preparar otro USB, instala Debian primero (capítulo 03) y luego
`sudo apt install memtest86+`, que añade una entrada al menú de GRUB. El inconveniente es evidente:
si la memoria está mal, ya habrás instalado sobre ella.

Criterio de aceptación: **una pasada completa (`Pass 1`) con `Errors: 0`**. Una pasada de 8 GB tarda
entre 40 minutos y 2 horas según la velocidad de la RAM. Si tienes tiempo, dos o tres pasadas dan
mucha más confianza: los fallos térmicos aparecen cuando los módulos llevan un rato calientes.

Si aparece **un solo error**, esa memoria no sirve. Con varios módulos, pruébalos de uno en uno para
identificar el defectuoso.

### Paso 5 — Rescata los datos existentes

**Este es el punto de no retorno.** A partir del capítulo 03 el disco se borra entero.

Primero, mira qué hay:

```bash
# [equipo]
lsblk -f
sudo mkdir -p /mnt/antiguo
sudo mount /dev/sda2 /mnt/antiguo      # ajusta la partición
ls -la /mnt/antiguo
```

**Si es un Linux**, lo que suele importar:

```bash
# [equipo]
sudo rsync -aAXv --info=progress2 \
    /mnt/antiguo/home/ /mnt/externo/respaldo-antiguo/home/
sudo rsync -aAXv /mnt/antiguo/etc/ /mnt/externo/respaldo-antiguo/etc/
sudo cp /mnt/antiguo/var/lib/dpkg/status /mnt/externo/respaldo-antiguo/   # lista de paquetes
```

**Si es Windows**, monta la partición NTFS y copia `Users`:

```bash
# [equipo]
sudo mount -t ntfs3 -o ro /dev/sda3 /mnt/antiguo
sudo rsync -av --info=progress2 /mnt/antiguo/Users/ /mnt/externo/respaldo-windows/
```

**Si no estás seguro de qué hay o quieres poder volver atrás**, haz una imagen completa del disco.
Necesitas un destino con al menos tanto espacio como el disco origen (comprimido suele ocupar
bastante menos):

```bash
# [equipo]
sudo dd if=/dev/sda bs=4M status=progress | gzip -c > /mnt/externo/imagen-disco-completo.img.gz
```

Y para verificar que la imagen es legible:

```bash
# [equipo]
gzip -t /mnt/externo/imagen-disco-completo.img.gz && echo "IMAGEN INTEGRA"
```

> **Comprueba el respaldo antes de continuar.** Abre algún archivo copiado, verifica que el tamaño
> total cuadra, y desconecta el disco externo. Un respaldo que no se ha comprobado no cuenta:
> exactamente el mismo principio que rige el capítulo 14.

### Paso 6 — Actualiza el firmware de la UEFI

Una UEFI antigua puede tener errores de gestión de energía, de arranque USB o de ACPI que después
son muy difíciles de diagnosticar. Es mucho más fácil actualizarla ahora, con el disco vacío, que
más adelante.

Busca en la web de soporte del fabricante el modelo exacto que anotaste en el paso 2. La mayoría de
las UEFI modernas actualizan desde una memoria USB en formato FAT32, sin sistema operativo.

**No interrumpas la actualización ni apagues el equipo durante el proceso.**

### Paso 7 — Configura la UEFI

Entra en la configuración pulsando `F2`, `Supr`, `F10` o `Esc` durante el arranque, según el
fabricante.

Recorre esta tabla completa. Los nombres varían entre fabricantes; se indican las variantes más
habituales.

| Ajuste | Valor | Dónde suele estar | Por qué |
|---|---|---|---|
| **Restore on AC Power Loss** / *AC Power Recovery* / *State After Power Loss* | **Power On** | Power / Advanced / ACPI | Que el servidor vuelva solo tras un corte de luz. **El ajuste más importante de esta tabla.** |
| **SATA Mode** / *SATA Operation* | **AHCI** | Advanced / Storage | Si está en RAID o Intel RST, Linux no verá el disco |
| **Secure Boot** | **Enabled** | Security / Boot | Debian lo soporta; no hay motivo para desactivarlo |
| **Boot Mode** / *CSM* / *Legacy Support* | **UEFI only**, CSM **Disabled** | Boot | Arranque en modo UEFI puro. Mezclarlo con legacy produce instalaciones que no arrancan |
| **Fast Boot** | **Disabled** | Boot | Impide entrar en la UEFI y arrancar desde USB |
| **Boot Order** | USB primero durante la instalación; disco interno después | Boot | Para arrancar el instalador |
| **Suspend / Sleep States** / *ACPI S3* | **Disabled** | Power / ACPI | Un servidor no duerme |
| **Deep Sleep Control** | **Disabled** | Power | Impide el encendido por red y ralentiza el arranque |
| **Wake on LAN** / *Power On By PCIe* | **Enabled** | Power | Permite encender el servidor remotamente. Útil como rescate |
| **Virtualization** (VT-x / AMD-V) | **Enabled** | Advanced / CPU | No lo necesita Docker, pero sí cualquier VM futura, y activarlo no cuesta nada |
| **Intel VT-d / AMD IOMMU** | **Enabled** | Advanced | Igual que el anterior: útil más adelante, inocuo ahora |
| **Fan Control** / *Fan Profile* | **Silent** o *Standard* | Hardware Monitor | Un servidor doméstico suele estar en una habitación. Vigila las temperaturas después |
| **Numlock on boot** | Indiferente | Boot | — |
| **Audio Controller** | **Disabled** | Advanced / Onboard Devices | Hardware que no se usa: menos consumo y menos módulos cargados |
| **Wi-Fi / Bluetooth** (si es integrado y usas cable) | **Disabled** | Advanced | Ídem |
| **Serial Port / Parallel Port** | **Disabled** | Advanced | Ídem |
| **Supervisor Password** | Opcional | Security | Impide que alguien con acceso físico cambie el orden de arranque. Si la pones, **guárdala en tu gestor de contraseñas**: sin ella no se puede modificar la UEFI |

Guarda y sal (normalmente `F10`).

> **Anota los cambios que hiciste.** Si algún día el equipo se comporta de forma extraña tras
> resetear la UEFI, esta lista es tu punto de restauración. El script del capítulo la incluye en el
> inventario generado.

### Paso 8 — Comprobación física

Con el equipo apagado y desenchufado:

- [ ] Limpia el polvo de disipadores y ventiladores. Un servidor encendido todo el día acumula
      mucho más que un equipo de uso ocasional.
- [ ] Comprueba que todos los ventiladores giran libremente.
- [ ] Revisa los condensadores de la placa: si alguno está hinchado o con restos, no uses ese equipo.
- [ ] Asegura los cables SATA y de alimentación.
- [ ] Coloca el equipo donde vaya a quedarse: ventilado, sin alfombra debajo, sin tapar las rejillas.
- [ ] Conecta el cable de red al router.

### Paso 9 — Anota los resultados

**Este es el paso que no se puede saltar.** Todo lo averiguado hasta aquí vive solo en la pantalla
del sistema *live*, que va a desaparecer en cuanto apagues el equipo.

Primero, en el propio equipo, imprime los dos valores en un formato que puedas copiar:

```bash
# [equipo]
echo "DISCO_DESTINO=$(ls -l /dev/disk/by-id/ | grep -v part | grep -E 'ata-|nvme-|scsi-' | awk '{print "/dev/disk/by-id/" $9}' | head -5)"
echo "LAN_INTERFAZ=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}')"
```

Salida de ejemplo:

```
DISCO_DESTINO=/dev/disk/by-id/ata-Samsung_SSD_870_EVO_500GB_S6PENL0T123456
LAN_INTERFAZ=enp3s0
```

> Si aparecen varias rutas `by-id`, elige la del disco **donde vas a instalar**: la que lleva el
> modelo y el número de serie que anotaste en el paso 2. Ignora las que contengan `-part`, que son
> particiones, y las `wwn-…`, que son válidas pero menos legibles.

Después, **en tu equipo**, escríbelos en la configuración:

```bash
# [cliente]
cd ~/nomad_server
./scripts/variables.sh --fijar DISCO_DESTINO=/dev/disk/by-id/ata-Samsung_SSD_870_EVO_500GB_S6PENL0T123456
./scripts/variables.sh --fijar LAN_INTERFAZ=enp3s0
```

Comprueba que han quedado escritos:

```bash
# [cliente]
./scripts/variables.sh --ver DISCO_DESTINO
./scripts/variables.sh --ver LAN_INTERFAZ
make faltan
```

Criterio de aceptación: los dos valores se imprimen, y `make faltan` ya no los menciona.

Si prefieres editar el archivo a mano:

```bash
# [cliente]
$EDITOR config/servidor.env
chmod 600 config/servidor.env
```

- `DISCO_DESTINO` → la ruta `/dev/disk/by-id/…` del paso 2
- `LAN_INTERFAZ` → el nombre de la interfaz cableada (o déjalo vacío para autodetección)

Y guarda también el archivo del inventario en un sitio que no sea este equipo: contiene los números
de serie y te hará falta el día que haya que pedir una garantía o comparar el desgaste de un disco.

---

## 6. Script asociado

### 6.1 Vía A — con el script

`scripts/02_inventario_equipo.sh` automatiza los pasos 2 y 3 completos: recoge todo el inventario,
la salud de los discos y las características de la red, y lo guarda en un archivo Markdown con
fecha.

```bash
# [equipo] — desde el sistema live o el sistema actual del equipo
cd /tmp/nomad_server                            # o donde lo hayas copiado
./scripts/02_inventario_equipo.sh --help
sudo ./scripts/02_inventario_equipo.sh --check  # lo muestra por pantalla, no escribe nada
sudo ./scripts/02_inventario_equipo.sh
```

Conviene ejecutarlo con `sudo`: sin privilegios no se puede leer la información de DMI (fabricante,
modelo, módulos de memoria) ni consultar SMART, y el inventario queda a medias sin decirlo
claramente.

Para dejar el archivo directamente en el disco externo, que es lo más práctico si el equipo se va a
formatear:

```bash
# [equipo]
sudo ./scripts/02_inventario_equipo.sh --salida /mnt/externo/inventario-servidor.md
```

Por omisión va a `inventario/<hostname>-<fecha>.md`, dentro del repositorio. Ese directorio está en
`.gitignore` porque el archivo contiene números de serie del hardware.

**Este script no necesita `config/servidor.env`**: no usa ninguna variable del despliegue, solo
recoge lo que encuentra. Es el único del repositorio del que se puede decir eso.

### 6.2 Correspondencia entre el script y los pasos manuales

| Paso de la sección 5 | ¿Lo hace el script? | Nota |
|---|---|---|
| 1 — arrancar con un *live* | No | Es una operación física |
| 2 — inventario del hardware | **Sí**, completo | Incluye DMI, CPU, memoria, discos, red y PCI/USB |
| 3 — salud de los discos | **Sí** | SMART de todos los discos detectados |
| 4 — memoria (memtest86+) | No | Se ejecuta fuera del sistema operativo |
| 5 — rescate de datos | No | Solo tú sabes qué conservar |
| 6 — actualizar el firmware UEFI | No | Depende del fabricante |
| 7 — configurar la UEFI | No | No es accesible desde el sistema operativo |
| 8 — comprobación física | No | Hay que abrir la caja |
| 9 — anotar los resultados | Parcial: los imprime; escribirlos es tuyo | Usa `scripts/variables.sh --fijar` |

### 6.3 Si prefieres la vía manual

Los pasos 2 y 3 de la sección 5 recogen la misma información, comando a comando. Merece la pena
hacerlo así al menos una vez: son los comandos que usarás para diagnosticar el hardware dentro de
tres años, cuando algo empiece a fallar.

Lo que asumes al hacerlo a mano:

- [ ] Guardar la salida de cada bloque en algún sitio, no solo mirarla.
- [ ] Interpretar los atributos SMART según la tabla del paso 3.
- [ ] Ejecutar el mismo bloque para **cada** disco del equipo, no solo el primero.

---

## 7. Validación

```bash
# [equipo] — repítelo para cada disco que vayas a usar
for DISCO in $(lsblk -dno PATH,TYPE | awk '$2=="disk"{print $1}'); do
    printf '%-12s ' "${DISCO}"
    sudo smartctl -H "${DISCO}" 2>/dev/null | grep -q 'PASSED' \
        && echo "DISCO SANO" || echo "REVISAR"
done
```

Criterio de aceptación: `DISCO SANO` en todos los discos que vayas a usar. Un `REVISAR` puede
significar que el disco falla o que no expone SMART (habitual en adaptadores USB); mira la salida
completa de `sudo smartctl -a` antes de decidir.

```bash
# [equipo] — la controladora debe estar en AHCI, no en RAID
lspci -k | grep -A2 -iE 'sata|nvme'
```

Criterio de aceptación: aparece el controlador con el módulo `ahci` o `nvme` en uso. Si aparece
`Intel RST` o el disco no se lista en `lsblk`, vuelve al paso 7 y cambia el modo SATA.

```bash
# [equipo] — el sistema debe haber arrancado en modo UEFI
[ -d /sys/firmware/efi ] && echo "ARRANQUE UEFI" || echo "ARRANQUE LEGACY"
```

Criterio de aceptación: imprime `ARRANQUE UEFI`. Si dice `LEGACY`, revisa Boot Mode y CSM en el
paso 7 antes de instalar; cambiarlo después implica reinstalar.

```bash
# [equipo] — la interfaz cableada debe tener enlace
ip -br link | grep -v lo
```

Criterio de aceptación: la interfaz cableada aparece en estado `UP` con el cable conectado.

**Comprobaciones manuales:**

- [ ] memtest86+ completó al menos una pasada con 0 errores.
- [ ] Los datos anteriores están respaldados **y verificados** en un disco externo desconectado.
- [ ] La UEFI está configurada según la tabla del paso 7, con *Restore on AC Power Loss* en
      **Power On**.
- [ ] `DISCO_DESTINO` y `LAN_INTERFAZ` están anotados en `config/servidor.env`.
- [ ] El equipo está en su ubicación definitiva, ventilado y conectado por cable.

**Prueba final del corte de luz.** Merece la pena hacerla ahora, que no hay nada que perder:
enciende el equipo, y con él encendido, desconecta el cable de alimentación de la pared. Espera diez
segundos y vuelve a conectarlo. El equipo debe encenderse solo. Si no lo hace, el ajuste de 3.5 no
está bien puesto.

---

## 8. Reversión

Este capítulo no modifica el sistema operativo del equipo, así que no hay nada que revertir por
software.

**Para deshacer los cambios de la UEFI:** entra en la configuración y usa *Load Setup Defaults* /
*Restore Defaults*. Perderás también los ajustes correctos, así que tendrás que repetir el paso 7.

**Si actualizaste el firmware y el equipo empeoró:** algunos fabricantes permiten volver a una
versión anterior; otros no. Es un riesgo real pero pequeño, y menor que el de arrastrar errores de
firmware conocidos.

---

## 9. Errores frecuentes

| Síntoma | Causa probable | Solución | Documentación |
|---|---|---|---|
| El instalador no ve ningún disco | Controladora en modo RAID / Intel RST | Cambia SATA Mode a **AHCI** en la UEFI (paso 7) | [Debian Wiki — SATA](https://wiki.debian.org/SATA) |
| No consigo entrar en la UEFI | Fast Boot activo: el equipo no espera a la tecla | Desactiva Fast Boot desde el sistema operativo actual, o desconecta el disco para forzar la entrada | Manual del fabricante |
| El USB no aparece en el menú de arranque | CSM/Legacy activo, o el USB se escribió mal | Pon Boot Mode en **UEFI only** y verifica el USB (capítulo [01](01_unidad_usb_booteable.md), paso 11) | Capítulo 01 |
| `smartctl` dice `Unavailable - device lacks SMART capability` | Disco tras una capa RAID, o adaptador USB que no transmite SMART | Cambia a AHCI; si el disco es externo, prueba `-d sat` | [smartmontools](https://www.smartmontools.org/wiki/Supported_USB-Devices) |
| memtest86+ no arranca en modo UEFI | Versiones antiguas de memtest solo funcionaban en BIOS | Descarga la versión actual (v6 o superior) de [memtest.org](https://www.memtest.org) | [memtest.org](https://www.memtest.org) |
| memtest da errores solo tras horas | Fallo térmico de los módulos | Confirma probando módulo a módulo. Es un fallo real: sustituye la memoria | — |
| El equipo no enciende solo tras el corte | *Restore on AC Power Loss* mal configurado, o el ajuste está en la regleta | Revísalo en la UEFI. Comprueba también que la regleta no tenga interruptor | Manual del fabricante |
| `ip -br link` no muestra la interfaz cableada | Falta el firmware de la tarjeta en el sistema live | Prueba con la imagen del instalador de Debian 13, que ya incluye firmware. Si persiste, usa un adaptador USB-Ethernet | [Debian Wiki — Firmware](https://wiki.debian.org/Firmware) |
| El disco tiene `Reallocated_Sector_Ct` > 0 | El disco está degradándose | No lo uses para el sistema. Si es el único que tienes, refuerza la política de respaldos del capítulo 14 | [Atributos SMART](https://www.smartmontools.org/wiki/FAQ) |
| El equipo se apaga solo a los pocos minutos | Sobrecalentamiento por polvo o pasta térmica seca | Limpia, y si persiste sustituye la pasta térmica del procesador | — |
| Monté la partición NTFS y está en solo lectura | Windows la dejó en modo hibernación / fast startup | Arranca Windows, apágalo con `shutdown /s /f /t 0`, y vuelve a montarla | [Debian Wiki — NTFS](https://wiki.debian.org/NTFS) |
| `smartctl` falla diciendo que no encuentra el dispositivo | La variable `DISCO` está vacía: se perdió al cerrar la terminal del *live* | Vuelve a declararla (paso 3) | § 4.3 |
| Apagué el equipo y no anoté el disco ni la interfaz | Se saltó el paso 9 | Hay que volver a arrancar con el *live*. Es exactamente lo que ese paso evita | § 5 paso 9 |
| El instalador del capítulo 03 no reconoce `DISCO_DESTINO` | Se anotó una ruta `-part` (una partición) en lugar del disco | Vuelve a mirar `/dev/disk/by-id/` e ignora las entradas con `-part` | § 4.2 |
| El script del inventario dice que faltan variables | Se está ejecutando una versión del repositorio que sí las exige | Este script no las necesita; comprueba que estás en `scripts/02_inventario_equipo.sh` | § 6.1 |

---

## 10. Referencias

- [Debian Wiki — Hardware soportado](https://wiki.debian.org/Hardware)
- [Debian Wiki — Firmware](https://wiki.debian.org/Firmware)
- [smartmontools — Preguntas frecuentes](https://www.smartmontools.org/wiki/FAQ)
- [memtest86+](https://www.memtest.org)
- [Debian Wiki — Secure Boot](https://wiki.debian.org/SecureBoot)
- [Debian Wiki — Nombres predecibles de interfaces](https://wiki.debian.org/NetworkInterfaceNames)
- [Guía de instalación de Debian 13 — Requisitos de hardware](https://www.debian.org/releases/trixie/amd64/ch02s05)
- Anexo [98 — Variables, entorno y sesiones](98_variables_y_entorno.md) § 6, sobre cómo persistir lo descubierto

---

**Anterior:** [01 — Unidad USB booteable](01_unidad_usb_booteable.md) · **Siguiente:** [03 — Instalación de Debian](03_instalacion_debian.md)
