# 01 — Unidad USB booteable

> Preparar el medio de instalación de Debian y —esto es lo importante— comprobar
> criptográficamente que lo que vas a instalar es realmente lo que Debian publicó.

---

## 1. Objetivo

Al terminar tendrás una memoria USB que arranca el instalador de Debian, cuya imagen ha sido
verificada mediante suma de comprobación **y** firma OpenPGP, y cuya escritura en el dispositivo
has confirmado byte a byte.

---

## 2. Requisitos previos

**Capítulos previos:** [00 — Planificación](00_planificacion.md).

**Necesitas a mano:**

- Una memoria USB de **2 GB o más**. Su contenido se destruirá por completo.
- Un equipo con lector USB y conexión a internet (unos 700 MB de descarga).
- `gpg`, `curl` y `sha256sum` disponibles. En la mayoría de distribuciones Linux ya están; si no:
  - Debian/Ubuntu: `sudo apt install gnupg curl coreutils`
  - Fedora: `sudo dnf install gnupg2 curl coreutils`
  - macOS: `brew install gnupg curl coreutils` (los comandos serán `gsha256sum`)

**Se puede hacer en paralelo con:** [02 — Validación del equipo](02_validacion_equipo.md).

---

## 3. Decisiones y por qué

### 3.1 Imagen netinst, no DVD ni live

**Decisión: la imagen `netinst` (unos 700 MB).**

| Alternativa descartada | Por qué |
|---|---|
| DVD completo (~4 GB) | Contiene miles de paquetes que no se van a instalar. Solo tiene sentido sin conexión a internet durante la instalación. |
| Imagen *live* | Pensada para probar un escritorio antes de instalar. Aquí no hay escritorio. |
| Imagen *cloud* / preinstalada | Para máquinas virtuales, no para hardware físico. |

`netinst` trae lo justo para arrancar el instalador y descarga el resto desde la réplica de Debian.
Ventaja añadida: los paquetes que instala ya vienen actualizados, en lugar de venir congelados en la
fecha de publicación de la imagen.

### 3.2 La verificación criptográfica no es opcional

Comprobar la suma SHA256 demuestra que la descarga no se corrompió. **No demuestra que la imagen sea
auténtica**: si alguien intercepta la descarga, puede servirte una imagen alterada junto con su suma
SHA256 correspondiente, y ambas coincidirían.

Lo que cierra el círculo es la **firma OpenPGP** del archivo `SHA256SUMS`. Solo Debian puede
generarla. La cadena queda así:

```
clave de Debian  →  firma SHA256SUMS  →  suma de la ISO  →  bytes escritos en el USB
```

Este es el primer eslabón de confianza de todo el servidor. Si se salta aquí, todo lo demás —el
cortafuegos, las llaves SSH, los respaldos cifrados— descansa sobre una base que nadie ha
comprobado. Cuesta dos minutos.

### 3.3 Escritura con `dd`

**Decisión: `dd` en Linux/macOS; Rufus en modo imagen en Windows.**

| Alternativa descartada | Por qué |
|---|---|
| Ventoy | Muy cómodo para llevar varias ISO en un USB, pero añade su propio gestor de arranque entre la UEFI y el instalador. Una capa más que puede fallar con Secure Boot. |
| balenaEtcher | Funciona, pero es una aplicación Electron de ~100 MB para una operación que hace `dd` en una línea. Queda como alternativa si `dd` intimida. |
| «Formatear el USB y copiar los archivos» | No funciona: la imagen contiene un gestor de arranque en su sector inicial que se pierde al copiar archivos. |

Las imágenes de Debian son *isohybrid*: se pueden escribir directamente al dispositivo de bloques
sin conversión.

> **`dd` no pide confirmación y no tiene deshacer.** Escribir en el disco equivocado destruye sus
> datos de forma irrecuperable. El paso 4 del procedimiento explica cómo identificar el dispositivo
> correcto con certeza, y el script asociado obliga a confirmar el modelo y el tamaño antes de
> escribir.

### 3.4 Firmware incluido

Desde Debian 12, las imágenes oficiales del instalador **ya incluyen el firmware no libre**
necesario para la mayoría de tarjetas de red y controladoras. Con Debian 11 y anteriores había que
buscar una imagen «unofficial non-free firmware»; eso ya no hace falta.

Esto importa porque el instalador `netinst` necesita red desde el primer momento: si la tarjeta no
tuviera firmware, la instalación se detendría.

---

## 4. Variables usadas

| Variable | Uso en este capítulo |
|---|---|
| `DEBIAN_SUITE` | Nombre en clave de la versión a descargar (`trixie`) |
| `DEBIAN_MIRROR` | Réplica desde la que se descarga |

No se usa `DISCO_DESTINO`: esa variable se refiere al disco **interno del servidor**, no a la
memoria USB. El dispositivo USB se identifica en el momento, porque su nombre cambia según dónde se
conecte.

---

## 5. Procedimiento

### Paso 1 — Crea un directorio de trabajo

```bash
# [cliente]
mkdir -p ~/debian-iso && cd ~/debian-iso
```

### Paso 2 — Averigua el nombre exacto de la imagen actual

El número de versión menor cambia con cada actualización de Debian (13.0, 13.1, 13.6…). En lugar de
fijarlo, se consulta:

```bash
# [cliente]
curl -sL https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA256SUMS \
  | grep -E 'debian-[0-9.]+-amd64-netinst\.iso$'
```

Salida de ejemplo:

```
65273beed27b2df543b68b65630ba525cfbad8df2b12035732b2dff87d6664e7  debian-13.6.0-amd64-netinst.iso
```

Guarda ese nombre en una variable para el resto del capítulo:

```bash
# [cliente]
ISO=$(curl -sL https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA256SUMS \
      | grep -oE 'debian-[0-9.]+-amd64-netinst\.iso$' | head -1)
echo "Imagen: ${ISO}"
```

> Fíjate en que hay tres imágenes netinst en ese listado: `debian-*`, `debian-edu-*` y
> `debian-mac-*`. La que necesitas es la primera. El filtro anterior ya la selecciona.

### Paso 3 — Descarga la imagen, las sumas y la firma

```bash
# [cliente]
BASE=https://cdimage.debian.org/debian-cd/current/amd64/iso-cd
curl -fLO "${BASE}/${ISO}"
curl -fLO "${BASE}/SHA256SUMS"
curl -fLO "${BASE}/SHA256SUMS.sign"
ls -lh
```

Salida esperada: los tres archivos, con la ISO en torno a 700 MB.

### Paso 4 — Verifica la suma de comprobación

```bash
# [cliente]
sha256sum -c SHA256SUMS --ignore-missing
```

Salida esperada (criterio de aceptación):

```
debian-13.6.0-amd64-netinst.iso: La suma coincide
```

Si dice `LA SUMA NO COINCIDE`, la descarga está corrupta o alterada. **Bórrala y vuelve a
descargar**; no continúes.

### Paso 5 — Importa las claves de firma de Debian

```bash
# [cliente]
gpg --keyserver keyring.debian.org --recv-keys \
  6294BE9B 09EA8AC3 64E6EA7D
```

Si el servidor de claves no responde (ocurre a veces), usa una alternativa:

```bash
# [cliente]
gpg --keyserver hkps://keys.openpgp.org --recv-keys \
  DF9B9C49EAA9298432589D76DA87E80D6294BE9B
```

### Paso 6 — Comprueba las huellas contra la fuente oficial

Este paso es el que da sentido a todo lo anterior: hay que confirmar que las claves importadas son
las de Debian y no las de quien te haya interceptado.

```bash
# [cliente]
gpg --fingerprint 6294BE9B 09EA8AC3 64E6EA7D 2>/dev/null | grep -A1 '^pub'
```

Compara las huellas mostradas, carácter a carácter, con las publicadas en
**<https://www.debian.org/CD/verify>**. En el momento de escribir esto son:

| Clave | Huella |
|---|---|
| Debian CD signing key (2009) | `1046 0DAD 7616 5AD8 1FBC  0CE9 9880 21A9 64E6 EA7D` |
| Debian CD signing key (2011) | `DF9B 9C49 EAA9 2984 3258  9D76 DA87 E80D 6294 BE9B` |
| Debian CD signing key (2014) | `F41D 3034 2F35 4669 5F65  C669 4246 8F40 09EA 8AC3` |

> No confíes en esta tabla: confía en la página oficial. Debian puede rotar sus claves, y una tabla
> copiada en un repositorio de terceros es exactamente el tipo de dato que conviene contrastar con
> el origen. Esta tabla está aquí para que sepas qué esperar, no para sustituir la comprobación.

### Paso 7 — Verifica la firma

```bash
# [cliente]
gpg --verify SHA256SUMS.sign SHA256SUMS
```

Salida esperada (criterio de aceptación): una línea `Good signature from "Debian CD signing key …"`.

```
gpg: Signature made ...
gpg:                using RSA key DF9B9C49EAA9298432589D76DA87E80D6294BE9B
gpg: Good signature from "Debian CD signing key <debian-cd@lists.debian.org>" [unknown]
gpg: WARNING: This key is not certified with a trusted signature!
```

El aviso `This key is not certified with a trusted signature` es **normal y esperado**: significa
que no has firmado personalmente la clave de Debian dentro de tu red de confianza. Lo que importa
es `Good signature` y que la huella coincida con la del paso 6.

Si aparece `BAD signature`, detente. El archivo de sumas ha sido manipulado.

### Paso 8 — Identifica la memoria USB

Con el USB **desconectado**:

```bash
# [cliente]
lsblk -d -o NAME,SIZE,MODEL,TRAN
```

Conecta el USB, espera unos segundos y repite el mismo comando. El dispositivo **nuevo** es el tuyo.

```
NAME  SIZE MODEL             TRAN
sda   477G Samsung SSD 870   sata
sdb    29G Ultra Fit         usb     ← este es el USB
```

Tres señales que lo confirman: `TRAN` es `usb`, el tamaño coincide con el de tu memoria, y el modelo
es reconocible. Si alguna de las tres no cuadra, no continúes.

```bash
# [cliente]
USB=/dev/sdb        # ← sustitúyelo por el tuyo
```

> Verifica una vez más:
> ```bash
> lsblk -o NAME,SIZE,MODEL,MOUNTPOINTS "${USB}"
> ```
> Si en la salida aparece cualquier punto de montaje de tu sistema (`/`, `/home`, `/boot`),
> **has elegido el disco equivocado**.

### Paso 9 — Desmonta las particiones del USB

Muchos escritorios montan el USB automáticamente. Escribir sobre un dispositivo montado corrompe el
resultado.

```bash
# [cliente]
lsblk -no MOUNTPOINTS "${USB}" | grep -v '^$' | while read -r m; do
    sudo umount "$m"
done
lsblk -o NAME,MOUNTPOINTS "${USB}"
```

Criterio de aceptación: ninguna partición tiene punto de montaje.

### Paso 10 — Escribe la imagen

```bash
# [cliente]
sudo dd if="${ISO}" of="${USB}" bs=4M status=progress oflag=sync
```

Salida esperada: el progreso y, al final, algo como

```
735051776 bytes (735 MB, 701 MiB) copied, 62 s, 11.9 MB/s
```

`oflag=sync` fuerza la escritura real en el dispositivo en lugar de dejarla en la caché del sistema.
Sin él, `dd` puede terminar en dos segundos y dejar los datos a medio escribir.

```bash
# [cliente]
sync
```

### Paso 11 — Verifica lo escrito

Aquí se cierra la cadena: se lee del USB exactamente el mismo número de bytes que ocupa la ISO y se
comprueba que su suma coincide.

```bash
# [cliente]
BYTES=$(stat -c %s "${ISO}")
sudo head -c "${BYTES}" "${USB}" | sha256sum
sha256sum "${ISO}"
```

Criterio de aceptación: **las dos sumas son idénticas**.

Si difieren, el USB puede estar defectuoso o la escritura no terminó. Repite el paso 10; si vuelve a
fallar, cambia de memoria.

### Paso 12 — Alternativas en otros sistemas

**Windows** — [Rufus](https://rufus.ie):

1. Selecciona el dispositivo USB en «Dispositivo».
2. Selecciona la ISO en «Elección de arranque».
3. Esquema de partición: **GPT**. Sistema de destino: **UEFI (no CSM)**.
4. Al pulsar «Empezar», Rufus preguntará si escribir en «modo Imagen ISO» o «modo Imagen DD»:
   elige **modo Imagen DD**. El modo ISO reescribe el gestor de arranque y puede fallar.

Para verificar la firma en Windows, instala [Gpg4win](https://gpg4win.org) y ejecuta los mismos
comandos `gpg` de los pasos 5 a 7 desde PowerShell.

**macOS** — igual que en Linux, con dos diferencias:

```bash
# [cliente macOS]
diskutil list                                   # identifica el disco: /dev/diskN
diskutil unmountDisk /dev/diskN
sudo dd if="${ISO}" of=/dev/rdiskN bs=4m        # ojo: rdiskN (raw), mucho más rápido
diskutil eject /dev/diskN
```

Las utilidades de GNU se instalan con `brew install coreutils` y llevan prefijo `g`
(`gsha256sum`, `gstat`).

---

## 6. Script asociado

`scripts/01_crear_usb.sh` automatiza los pasos 1 a 11: descarga, verifica la suma, verifica la firma
OpenPGP, muestra el dispositivo elegido para que lo confirmes, escribe y comprueba el resultado.

```bash
# [cliente]
./scripts/01_crear_usb.sh --help          # qué hace y qué opciones admite
./scripts/01_crear_usb.sh --check         # simula: descarga y verifica, no escribe nada
sudo ./scripts/01_crear_usb.sh --usb /dev/sdb
```

Qué hace en modo `--check`: descarga la imagen y los archivos de firma en `~/debian-iso`, verifica
suma y firma, e informa del dispositivo que **usaría**, sin escribir un solo byte en él.

Qué no hace: **no elige el dispositivo por ti**. Hay que pasarlo con `--usb`, y el script muestra
modelo, tamaño y transporte y exige confirmación explícita antes de escribir. Rechaza cualquier
dispositivo que no sea extraíble o que tenga particiones montadas en rutas del sistema.

---

## 7. Validación

```bash
# [cliente]
gpg --verify SHA256SUMS.sign SHA256SUMS 2>&1 | grep -q 'Good signature' && echo VALIDO
```

Criterio de aceptación: imprime `VALIDO`.

```bash
# [cliente]
BYTES=$(stat -c %s "${ISO}")
[ "$(sudo head -c "${BYTES}" "${USB}" | sha256sum | cut -d' ' -f1)" \
  = "$(sha256sum "${ISO}" | cut -d' ' -f1)" ] && echo "USB CORRECTO"
```

Criterio de aceptación: imprime `USB CORRECTO`.

```bash
# [cliente] — el USB debe tener tabla de particiones y una partición EFI
lsblk -o NAME,SIZE,FSTYPE,LABEL "${USB}"
```

Criterio de aceptación: aparecen particiones con etiqueta similar a `Debian 13.x amd64 n` y una
partición pequeña de tipo `vfat` (la ESP para el arranque UEFI).

**Validación final, en el hardware real:** conecta el USB al servidor, arráncalo y comprueba que
aparece el menú del instalador de Debian. Si el menú muestra las entradas «Graphical install» /
«Install», el medio funciona. **No inicies la instalación todavía**: primero hay que completar el
capítulo [02](02_validacion_equipo.md).

---

## 8. Reversión

El USB queda con la tabla de particiones de la imagen y no se puede usar como memoria normal hasta
reformatearlo:

```bash
# [cliente]
sudo wipefs -a "${USB}"                                    # borra las firmas de sistema de archivos
sudo parted "${USB}" --script mklabel gpt
sudo parted "${USB}" --script mkpart primary fat32 1MiB 100%
sudo mkfs.vfat -F32 -n DATOS "${USB}1"
```

Para liberar espacio en tu equipo:

```bash
# [cliente]
rm -rf ~/debian-iso
```

Conviene **conservar la ISO verificada** hasta terminar el capítulo 03: si la instalación falla y
hay que repetirla, te ahorras la descarga y la verificación.

---

## 9. Errores frecuentes

| Síntoma | Causa probable | Solución | Documentación |
|---|---|---|---|
| `sha256sum: LA SUMA NO COINCIDE` | Descarga incompleta o corrupta | Borra la ISO y vuelve a descargar. Si se repite, prueba otra réplica | [Verificación de imágenes](https://www.debian.org/CD/verify) |
| `gpg: Can't check signature: No public key` | No se importaron las claves de Debian | Repite el paso 5. Si el servidor de claves falla, usa `hkps://keys.openpgp.org` | [Claves de firma](https://www.debian.org/CD/verify) |
| `gpg: WARNING: This key is not certified…` | Normal: no has firmado la clave de Debian personalmente | No es un error. Lo relevante es `Good signature` y que la huella coincida | Paso 7 |
| `gpg: BAD signature` | El archivo `SHA256SUMS` está alterado o corrupto | Bórralo y vuelve a descargarlo. Si persiste, no uses esa réplica | [Verificación de imágenes](https://www.debian.org/CD/verify) |
| `dd: failed to open '/dev/sdb': Device or resource busy` | El USB está montado | Ejecuta el paso 9 antes de escribir | — |
| `dd` termina en 2 segundos | La escritura quedó en la caché del sistema | Falta `oflag=sync`. Ejecuta `sync` y repite la verificación del paso 11 | — |
| El USB no aparece en el menú de arranque | Secure Boot activo, arranque legacy, o el USB no se escribió bien | Revisa la configuración UEFI en el capítulo [02](02_validacion_equipo.md); repite el paso 11 | Capítulo 02 |
| Arranca pero muestra «No bootable device» | Se escribió en la partición (`/dev/sdb1`) en vez de en el dispositivo (`/dev/sdb`) | Vuelve al paso 10 usando el dispositivo completo, sin número | — |
| El instalador no detecta la tarjeta de red | Hardware muy reciente cuyo firmware no está ni en la imagen oficial | Conecta un adaptador USB-Ethernet, o descarga la imagen del kernel *backports* | [Debian Wiki — Firmware](https://wiki.debian.org/Firmware) |
| Rufus deja un USB que no arranca | Se eligió «modo Imagen ISO» en lugar de «modo Imagen DD» | Repite eligiendo **modo DD** | [Rufus FAQ](https://github.com/pbatard/rufus/wiki/FAQ) |
| En macOS `dd` va lentísimo | Se está usando `/dev/diskN` en vez de `/dev/rdiskN` | Usa el dispositivo *raw* (`rdiskN`) | — |

---

## 10. Referencias

- [Debian — Instalación por red (netinst)](https://www.debian.org/distrib/netinst)
- [Debian — Verificación de imágenes y claves de firma](https://www.debian.org/CD/verify)
- [Debian — Índice de imágenes actuales (amd64)](https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/)
- [Debian Wiki — Firmware](https://wiki.debian.org/Firmware)
- [Guía de instalación de Debian 13](https://www.debian.org/releases/trixie/amd64/)
- [Rufus — Preguntas frecuentes](https://github.com/pbatard/rufus/wiki/FAQ)

---

**Anterior:** [00 — Planificación](00_planificacion.md) · **Siguiente:** [02 — Validación del equipo](02_validacion_equipo.md)
