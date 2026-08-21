# 14 — Respaldos con restic

> Copias cifradas, automáticas y —esto es lo que separa un respaldo de una ilusión— **probadas**.

---

## 1. Objetivo

Al terminar tendrás un respaldo diario, cifrado y con histórico hacia un disco USB, con política de
retención, aviso si falla, y una restauración de prueba **ya realizada** que demuestra que el
respaldo sirve.

---

## 2. Requisitos previos

**Capítulos previos:** [12 — Despliegue de proyectos](12_despliegue_de_proyectos.md). Conviene tener
al menos un proyecto desplegado para que haya algo real que respaldar.

**Necesitas a mano:**

- Un **disco USB** dedicado. Como referencia, al menos el triple de lo que ocupa `${DATOS_RAIZ}`.
  Su contenido se borrará.
- La contraseña del repositorio restic que generaste en el capítulo 00, paso 7, guardada en tu
  gestor de contraseñas.
- Opcionalmente, credenciales de un almacenamiento remoto (Backblaze B2, S3, o cualquiera de los que
  soporta `rclone`).

> **Si no tienes la contraseña del capítulo 00, genérala ahora y guárdala antes de continuar.**
> Sin ella, el repositorio es matemáticamente irrecuperable. No hay recuperación de contraseña, no
> hay puerta trasera, no hay soporte al que llamar.

**Preparar la sesión.**

```bash
# [servidor]
cd ~/nomad_server
source scripts/lib/entorno.sh
echo "montaje=${RESTIC_USB_MOUNT} repo=${RESTIC_REPO_LOCAL} clave=${RESTIC_PASSWORD_FILE}"
echo "uuid=${RESTIC_USB_UUID:-(pendiente, paso 1)} hora=${RESTIC_HORA}"
```

Salida esperada al empezar, con los valores de ejemplo:

```
montaje=/mnt/respaldo repo=/mnt/respaldo/restic/nomad clave=/root/.restic-password
uuid=(pendiente, paso 1) hora=03:30
```

Fíjate en que `RESTIC_REPO_LOCAL` se compone a partir de `RESTIC_USB_MOUNT` y
`SERVIDOR_HOSTNAME`: si alguna de las dos estuviera vacía, la ruta del repositorio saldría
malformada y `restic init` crearía el repositorio en un sitio equivocado.

**Este capítulo produce dos valores que hay que persistir**: `RESTIC_USB_UUID` (paso 1) y
`RESTIC_PUSH_URL` (paso 8). Sin el primero, el disco no se monta al arrancar y el respaldo nocturno
falla en silencio; sin el segundo, nadie te avisa de que ha fallado.

**Tiempo estimado:** 1 hora y media, incluida la prueba de restauración.

---

## 3. Decisiones y por qué

### 3.1 restic

**Decisión: restic hacia un disco USB local, con repositorio remoto opcional.**

| Propiedad | Qué aporta |
|---|---|
| Incremental y deduplicado | Un respaldo diario de 50 GB ocupa unos pocos megabytes cuando casi nada ha cambiado |
| Cifrado de extremo a extremo | El disco USB se puede perder o robar sin que nadie lea su contenido |
| Con instantáneas | Se puede recuperar el estado de hace tres semanas, no solo el de ayer |
| Verificación integrada | `restic check` detecta corrupción antes de que la necesites |
| Un solo binario | Sin demonio, sin base de datos, sin servidor |

| Alternativa descartada | Por qué |
|---|---|
| `rsync` a otro disco | Simple, pero sin histórico ni cifrado. Un borrado accidental se replica en la copia esa misma noche |
| Instantáneas de LVM | Útiles para revertir una actualización, inservibles como respaldo: viven en el mismo disco que se puede morir |
| Borg | Muy similar y igualmente bueno. restic gana en soporte nativo de destinos en la nube, que es lo que hace falta para la copia remota |
| Solo copia en la nube | Restaurar 50 GB por una conexión doméstica tarda horas. El disco local es la copia rápida; la remota es el seguro contra incendio o robo |

### 3.2 Qué se respalda y qué no

**Decisión: respaldar lo irreemplazable; ignorar lo que se descarga otra vez.**

| Se respalda | Por qué |
|---|---|
| `${DATOS_RAIZ}` | Los proyectos completos: compose, `.env` y datos. Es lo que no existe en ningún otro sitio |
| `/etc` | Toda la configuración del sistema: nftables, SSH, Docker, fstab, APT |
| `~/.cloudflared` | Las credenciales del túnel. **Sin ellas hay que rehacer el túnel y todos los registros DNS** |
| `~/.ssh` | Llaves autorizadas |
| `~/nomad_server/config` | `servidor.env`, que no está en git |
| `/var/lib/tailscale` | Estado del nodo: evita tener que reautorizar |
| Manifiesto del sistema | Lista de paquetes, de imágenes y de contenedores. No está en ningún archivo, pero hace falta para reconstruir |

| NO se respalda | Por qué |
|---|---|
| `/var/lib/docker` | Las imágenes se descargan otra vez. Ocupan gigabytes y no contienen nada propio |
| `node_modules`, `vendor`, `.venv` | Se regeneran con un comando |
| Cachés y artefactos de construcción | Ídem |
| `/home` completo | En un servidor no hay documentos personales; lo que importa está enumerado arriba |

**El manifiesto merece una explicación.** Antes de cada respaldo se genera un directorio con la
lista de paquetes instalados, las imágenes de contenedor en uso, los contenedores existentes y el
esquema de discos. Nada de eso vive en un archivo que se pueda respaldar directamente, y es
justamente lo primero que se echa de menos al reconstruir el servidor desde cero (capítulo 16).

### 3.3 Dos modos: con disco local, o solo remoto

**Decisión: el repositorio principal es el disco USB si lo hay, y el remoto si no.**

Lo determina `RESTIC_USB_UUID`: con valor, modo local; vacía, modo remoto. No hay una variable
aparte que elegir, y por tanto no hay forma de que las dos se contradigan.

| | Con disco USB | Solo remoto |
|---|---|---|
| Dónde se respalda | Disco local, y `restic copy` replica al remoto | Directamente al remoto |
| Qué viaja por la red | Solo las instantáneas nuevas, ya cifradas | Todo, cada noche |
| Restaurar | Desde el disco, a velocidad de USB | A velocidad de tu bajada |
| Copias | Dos | Una |
| Protege de | Fallo de disco, error humano, incendio y robo | Fallo de disco, error humano, incendio y robo |

**El modo remoto es una configuración legítima**, y desde luego mejor que no tener respaldos. Pero
conviene ser consciente de a qué se renuncia: con una sola copia, un problema con el proveedor —una
cuenta suspendida, unas credenciales perdidas, un error de facturación— te deja sin nada. Y una
restauración completa de 50 GB por una conexión doméstica no se mide en minutos.

Si empiezas sin disco y añades uno después, basta con rellenar `RESTIC_USB_UUID` y volver a ejecutar
`scripts/14_restic.sh`: el modo cambia solo, y a partir de ahí el remoto pasa a recibir copias en
lugar de respaldos directos.

**Las credenciales del remoto van en `/etc/nomad/restic-remoto.env`**, con permisos 600, y **no** en
`config/servidor.env`. El servicio de systemd las carga con `EnvironmentFile`. Ese detalle no es
cosmético: sin esa línea en la unidad, `restic copy` falla cada noche bajo el temporizador y
funciona solo cuando lanzas el script a mano, porque a mano sí tienes las variables cargadas. Es un
fallo que se descubre el día que hace falta el respaldo remoto.

### 3.4 El disco se monta por UUID

**Decisión: `/etc/fstab` con `UUID=` y `nofail`.**

Las letras de dispositivo (`/dev/sdb1`) cambian según el orden en que respondan los discos al
arrancar. Un día tu respaldo se escribiría en otro disco, o no se escribiría.

`nofail` es igual de importante: sin esa opción, **si el disco USB no está conectado el sistema no
termina de arrancar** y se queda esperando en una consola de emergencia a la que no puedes llegar
por SSH. Con `nofail`, el arranque continúa y el respaldo falla ruidosamente, que es exactamente el
comportamiento correcto.

### 3.5 Retención escalonada

**Decisión: 7 diarios, 4 semanales, 6 mensuales.**

```
hoy ──── 7 días ──────── 4 semanas ─────────── 6 meses
 │         │                  │                    │
 └ diario  └ semanal          └ mensual            └ se borra
```

Cubre los tres escenarios reales:

| Escenario | Qué salva |
|---|---|
| «Borré un archivo esta mañana» | Los diarios |
| «Esto se rompió hace dos semanas y no me di cuenta» | Los semanales |
| «Necesito recuperar cómo estaba esto en marzo» | Los mensuales |

Gracias a la deduplicación, guardar 17 instantáneas ocupa poco más que guardar una.

### 3.6 El script vive fuera del repositorio

**Decisión: `/usr/local/bin/nomad-respaldo.sh`, no `~/nomad_server/scripts/…`.**

El respaldo tiene que funcionar aunque el repositorio no esté clonado, se haya movido, esté a medio
actualizar o tenga un conflicto de git a medio resolver. Es precisamente en los momentos de
desorden cuando más falta hace que la copia de esa noche se haga.

El script se **genera** desde la plantilla con los valores de `config/servidor.env` ya sustituidos,
de modo que sigue siendo reproducible sin depender del repositorio en tiempo de ejecución.

### 3.7 El fallo se detecta por ausencia de aviso

**Decisión: avisar a Uptime Kuma solo cuando el respaldo termina bien.**

Parece al revés, y es deliberado. Si el script avisara «he fallado», ese aviso no llegaría en el
peor caso de todos: el servidor apagado, sin red o con el disco muerto. Un respaldo que falla en
silencio es peor que no tener respaldo, porque crees que estás cubierto.

Con un monitor de tipo *Push*, Uptime Kuma espera un aviso cada 24 horas. **Si no llega, salta.** Da
igual el motivo: fallo del respaldo, servidor apagado, red caída o disco desconectado.

### 3.8 La prueba de restauración es obligatoria

**Decisión: no se da el capítulo por terminado sin haber restaurado.**

Es la regla que más se incumple en la práctica. Los motivos por los que un respaldo aparentemente
correcto no sirve son numerosos y silenciosos: exclusiones demasiado amplias, permisos que no se
conservan, la contraseña anotada mal, el archivo de credenciales que nunca entró en la lista de
rutas.

**Todos ellos se descubren en la primera restauración.** La cuestión es si esa primera restauración
ocurre hoy, con calma, o el día que el disco se muera.

### 3.9 La contraseña, en dos sitios

**Decisión: `/root/.restic-password` en el servidor **y** en tu gestor de contraseñas.**

El archivo del servidor es el que usa el respaldo automático. La copia del gestor es la que te
permitirá restaurar cuando el servidor ya no exista, que es justamente el escenario para el que
existen los respaldos.

Guardar la contraseña **solo** en el servidor sería como dejar la única llave dentro de la caja
fuerte.

---

## 4. Variables usadas

### 4.1 De `config/servidor.env`

| Variable | Uso | Dónde acaba |
|---|---|---|
| `RESTIC_USB_MOUNT` | Punto de montaje del disco | `/etc/fstab`, el script y la unidad de systemd |
| `RESTIC_REPO_LOCAL` | Ruta del repositorio dentro del disco | El script de respaldo |
| `RESTIC_REPO_REMOTO` | Repositorio remoto opcional | El script de respaldo |
| `RESTIC_PASSWORD_FILE` | Archivo con la contraseña, en el servidor | El script de respaldo |
| `RESTIC_RETENCION_DIARIOS`, `_SEMANALES`, `_MENSUALES` | Política de retención | El script de respaldo |
| `RESTIC_HORA` | Hora del respaldo diario | `nomad-respaldo.timer` |
| `DATOS_RAIZ`, `ADMIN_USUARIO`, `SERVIDOR_HOSTNAME` | Qué se respalda y con qué etiqueta | El script de respaldo |

### 4.2 Variables que se DESCUBREN en este capítulo

| Variable | Qué es | Cómo se obtiene | Sin ella |
|---|---|---|---|
| `RESTIC_USB_UUID` | UUID del sistema de archivos del disco de respaldo | `sudo blkid /dev/sdX1`, paso 1 | El disco no se monta al arrancar y el respaldo falla cada noche |
| `RESTIC_PUSH_URL` | URL del monitor *Push* de Uptime Kuma | Al crear el monitor, paso 8 | Un respaldo que falle no avisa a nadie |

Los comandos exactos para persistirlas están en sus pasos. Comprobación en cualquier momento:

```bash
# [servidor]
./scripts/variables.sh --faltan
```

> **Es el UUID de la partición, no el del disco.** `blkid /dev/sdb` (el disco) y
> `blkid /dev/sdb1` (la partición formateada) devuelven UUID distintos, y `/etc/fstab` necesita el
> segundo. Poner el del disco produce un sistema que no arranca del todo si falta `nofail`, y un
> respaldo que nunca encuentra su destino si lo lleva.

### 4.3 Variables temporales de esta sesión

| Variable | Qué contiene | Se declara en | Riesgo |
|---|---|---|---|
| `DISCO` | Dispositivo del disco USB de respaldo (`/dev/sdb`) | Paso 1 | **Máximo**: el paso 1 lo formatea |

`DISCO` es, junto con `USB` del capítulo [01](01_unidad_usb_booteable.md), la variable más peligrosa
del repositorio. El paso 1 incluye una comprobación previa obligatoria.

### 4.4 Secretos que NO van en `config/servidor.env`

| Secreto | Dónde vive | Copia obligatoria |
|---|---|---|
| La contraseña del repositorio restic | `${RESTIC_PASSWORD_FILE}`, permisos 600 | **En tu gestor de contraseñas, fuera del servidor** |
| Credenciales del repositorio remoto | `/etc/nomad/restic-remoto.env`, permisos 600 | En tu gestor de contraseñas |

`config/servidor.env` guarda la **ruta** del archivo de contraseña, nunca la contraseña. Guardar la
única copia en el propio servidor sería dejar la llave dentro de la caja fuerte: el escenario para
el que existen los respaldos es precisamente que ese servidor ya no esté.

---

## 5. Procedimiento

### Paso 0 — Prepara la sesión

```bash
# [servidor]
cd ~/nomad_server
source scripts/lib/entorno.sh
echo "montaje=${RESTIC_USB_MOUNT} repo=${RESTIC_REPO_LOCAL} clave=${RESTIC_PASSWORD_FILE}"
```

Criterio de aceptación: las tres rutas están completas. Una `RESTIC_REPO_LOCAL` del tipo
`/restic/` significa que `RESTIC_USB_MOUNT` o `SERVIDOR_HOSTNAME` están vacías.

Y ten la contraseña del repositorio delante, en tu gestor de contraseñas. La necesitas en el paso 3
y sin ella no tiene sentido empezar.

### Paso 1 — Prepara el disco USB

> **Si vas a respaldar solo a un destino remoto, sáltate los pasos 1 y 2** y ve directo al paso 3.
> Deja `RESTIC_USB_UUID` vacía y asegúrate de haber hecho antes el paso 12, que en ese caso deja de
> ser opcional: es tu repositorio principal (§ 3.3).

Conecta el disco e identifícalo:

```bash
# [servidor]
lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,FSTYPE,MOUNTPOINTS
```

Localiza el disco USB por tamaño, modelo y `TRAN=usb`. **Comprueba tres veces que es el correcto**:
el paso siguiente lo borra sin preguntar y sin posibilidad de deshacer.

```bash
# [servidor]
DISCO=/dev/sdb        # ← el tuyo
```

**Comprobación obligatoria antes de formatear.** Es el mismo tipo de comprobación del capítulo
[01](01_unidad_usb_booteable.md) paso 10, y por el mismo motivo:

```bash
# [servidor]
[ -n "${DISCO}" ] && [ -b "${DISCO}" ] \
  && lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS "${DISCO}" \
  || echo "PARA: la variable DISCO está vacía o no es un dispositivo de bloques"
```

Criterio de aceptación: muestra **tu disco USB**, con `TRAN` igual a `usb`, el tamaño esperado, y
**ningún punto de montaje del sistema** (`/`, `/var`, `/srv`, `/boot`). Si aparece alguno de esos,
has elegido el disco equivocado.

```bash
# [servidor] — a partir de aquí el contenido del disco se pierde
sudo wipefs -a ${DISCO}
sudo parted ${DISCO} --script mklabel gpt
sudo parted ${DISCO} --script mkpart primary ext4 1MiB 100%
sudo mkfs.ext4 -L RESPALDO ${DISCO}1
```

Se usa ext4 y no exFAT ni NTFS porque restic necesita permisos y enlaces de un sistema de archivos
POSIX. Un disco exFAT provoca fallos difíciles de interpretar.

```bash
# [servidor]
sudo blkid ${DISCO}1
```

Salida de ejemplo:

```
/dev/sdb1: LABEL="RESPALDO" UUID="a1b2c3d4-e5f6-7890-abcd-ef1234567890" TYPE="ext4"
```

**Persiste el UUID ahora**, sin copiarlo a mano —es largo y un carácter mal copiado produce un
sistema que no monta el disco y un respaldo que falla cada noche—:

```bash
# [servidor]
./scripts/variables.sh --fijar RESTIC_USB_UUID="$(sudo blkid -s UUID -o value ${DISCO}1)"
source scripts/lib/entorno.sh
echo "RESTIC_USB_UUID=${RESTIC_USB_UUID}"
```

Criterio de aceptación: imprime un UUID de cinco grupos separados por guiones. Si sale vacío, es que
`${DISCO}1` no existe: comprueba con `lsblk` cómo se llama la partición (en discos NVMe sería
`${DISCO}p1`).

### Paso 2 — Monta el disco de forma permanente

```bash
# [servidor]
sudo mkdir -p ${RESTIC_USB_MOUNT}
sudo cp -a /etc/fstab /etc/fstab.bak-$(date +%Y%m%d-%H%M%S)
```

**Así queda la línea** (con el UUID de ejemplo):

```
UUID=a1b2c3d4-e5f6-7890-abcd-ef1234567890  /mnt/respaldo  ext4  defaults,nofail,noatime,x-systemd.device-timeout=10  0  2
```

**Y este es el comando que la añade con tus valores**, solo si no estaba ya (para poder repetirlo
sin duplicar la entrada):

```bash
# [servidor]
grep -q "${RESTIC_USB_UUID}" /etc/fstab || printf '%s\n' \
  "UUID=${RESTIC_USB_UUID}  ${RESTIC_USB_MOUNT}  ext4  defaults,nofail,noatime,x-systemd.device-timeout=10  0  2" \
  | sudo tee -a /etc/fstab >/dev/null
tail -2 /etc/fstab
```

**Comprobación crítica antes de reiniciar nunca más este servidor:**

```bash
# [servidor]
grep "${RESTIC_USB_UUID}" /etc/fstab | grep -c nofail
```

Criterio de aceptación: `1`. **Sin `nofail`, el día que el disco USB no esté conectado el servidor
no terminará de arrancar** y se quedará en una consola de emergencia a la que no puedes llegar por
SSH. Es el error más caro de este capítulo, porque obliga a bajar físicamente al equipo con un
teclado.

Qué hace cada opción:

| Opción | Para qué |
|---|---|
| `UUID=` | Identifica el disco aunque cambie de letra (§ 3.3) |
| `nofail` | **El sistema arranca aunque el disco no esté conectado.** Sin esto te quedas en una consola de emergencia |
| `noatime` | No escribe la fecha de último acceso: menos desgaste |
| `x-systemd.device-timeout=10` | Espera 10 segundos como mucho, en lugar de 90 |

```bash
# [servidor]
sudo systemctl daemon-reload
sudo mount -a
mountpoint ${RESTIC_USB_MOUNT} && df -h ${RESTIC_USB_MOUNT}
```

Criterio de aceptación: el punto de montaje está activo y muestra el tamaño del disco.

### Paso 3 — Instala restic y la contraseña

```bash
# [servidor]
sudo apt install -y restic
restic version
```

```bash
# [servidor] — la contraseña que guardaste en el capítulo 00
sudo touch ${RESTIC_PASSWORD_FILE}
sudo chmod 600 ${RESTIC_PASSWORD_FILE}
sudo vim ${RESTIC_PASSWORD_FILE}
```

Escribe **solo** la contraseña, en una línea, sin comillas ni espacios finales.

Si no la generaste antes:

```bash
# [servidor]
openssl rand -base64 48 | sudo tee ${RESTIC_PASSWORD_FILE}
sudo chmod 600 ${RESTIC_PASSWORD_FILE}
```

> **Cópiala ahora mismo a tu gestor de contraseñas.** No sigas sin hacerlo (§ 3.8).

### Paso 4 — Inicializa el repositorio

```bash
# [servidor]
sudo mkdir -p ${RESTIC_REPO_LOCAL}
sudo restic init \
    --repo ${RESTIC_REPO_LOCAL} \
    --password-file ${RESTIC_PASSWORD_FILE}
```

Salida esperada:

```
created restic repository a1b2c3d4 at /mnt/respaldo/restic/nomad

Please note that knowledge of your password is required to access
the repository. Losing your password means that your data is
irrecoverably lost.
```

### Paso 5 — Exclusiones

```bash
# [servidor]
sudo mkdir -p /etc/nomad
nomad_plantilla etc/restic-excluir.txt | sudo tee /etc/nomad/restic-excluir.txt >/dev/null
wc -l /etc/nomad/restic-excluir.txt
```

El contenido está en `templates/etc/restic-excluir.txt`, con un comentario por bloque explicando qué
se descarta y por qué.

> Revisa la sección de artefactos de construcción antes de darla por buena: si algún proyecto
> **sirve** su directorio `dist/` sin reconstruirlo al desplegar, excluirlo dejaría el sitio vacío
> tras restaurar.

### Paso 6 — Script de respaldo

```bash
# [servidor]
nomad_plantilla etc/nomad-respaldo.sh | sudo tee /usr/local/bin/nomad-respaldo.sh >/dev/null
sudo chmod 700 /usr/local/bin/nomad-respaldo.sh
```

El contenido está en `templates/etc/nomad-respaldo.sh`. **Es la plantilla más delicada del
repositorio**, porque es un script que primero se sustituye con `envsubst` y después se ejecuta:

| En la plantilla | Qué le pasa al instalar | Ejemplo |
|---|---|---|
| Está en `config/servidor.env.example` | **Se sustituye** por tu valor | `${RESTIC_REPO_LOCAL}`, `${DATOS_RAIZ}` |
| Variable interna en minúscula | Llega intacta; la resuelve bash al ejecutarse | `${punto_montaje}`, `${rutas[@]}` |
| Variable en mayúscula que no está en la configuración | Llega intacta también | `${RESTIC_REPOSITORY}`, `${VERSION_CODENAME}` |

Lo que decide qué se sustituye no es el nombre, sino **estar en la lista** que se le pasa a
`envsubst`. La convención de minúsculas existe para que esa frontera se vea de un vistazo (anexo
[98 § 4.4](98_variables_y_entorno.md)).

**Comprueba las tres cosas antes de ejecutarlo:**

```bash
# [servidor]
sudo bash -n /usr/local/bin/nomad-respaldo.sh && echo "1. SINTAXIS CORRECTA"
sudo grep -E '^RESTIC_REPOSITORY=|^punto_montaje=|^datos_raiz=' /usr/local/bin/nomad-respaldo.sh
```

Salida esperada, con los valores de ejemplo:

```
1. SINTAXIS CORRECTA
RESTIC_REPOSITORY="/mnt/respaldo/restic/nomad"
punto_montaje="/mnt/respaldo"
datos_raiz="/srv"
```

Criterio de aceptación: sintaxis correcta y las asignaciones con **tus rutas reales** entre
comillas, no con `${…}` ni con cadenas vacías. Que más abajo el script siga usando
`${RESTIC_REPOSITORY}` y `${punto_montaje}` es correcto: son sus propias variables, ya asignadas
aquí arriba.

### Paso 7 — Primer respaldo, a mano

```bash
# [servidor]
sudo /usr/local/bin/nomad-respaldo.sh
```

El primero tarda: hay que leer y cifrar todo. Los siguientes son cuestión de segundos.

Criterio de aceptación: termina con `=== Respaldo terminado correctamente ===`.

```bash
# [servidor]
sudo restic snapshots \
    --repo ${RESTIC_REPO_LOCAL} \
    --password-file ${RESTIC_PASSWORD_FILE}
```

Criterio de aceptación: aparece una instantánea con las rutas esperadas.

### Paso 8 — Monitor de respaldo en Uptime Kuma

En Uptime Kuma, **Añadir nuevo monitor**:

| Campo | Valor |
|---|---|
| Tipo | Push |
| Nombre | `Respaldo nocturno` |
| Intervalo | `90000` segundos (25 horas) |
| Reintentos | 0 |

Uptime Kuma muestra entonces una **Push URL** con este aspecto:

```
http://estado.nomad.lan:8080/api/push/f7G8h9J0k1
```

**Persístela ahora**, con la dirección que el **host** pueda alcanzar (no el nombre interno del
contenedor, porque el script de respaldo corre fuera de Docker):

```bash
# [servidor]
PUSH_ID=f7G8h9J0k1        # ← el identificador que te ha dado Uptime Kuma
./scripts/variables.sh --fijar \
    RESTIC_PUSH_URL="http://${UPTIME_KUMA_HOST}:${TRAEFIK_PUERTO_INTERNA}/api/push/${PUSH_ID}"
source scripts/lib/entorno.sh
echo "${RESTIC_PUSH_URL}"
```

> **Tiene que ser el NOMBRE de Kuma, no una IP.** Una petición sin nombre de host no casa con
> ningún router por `Host(…)`, y se la queda el router del panel de Traefik, cuya regla incluye
> `PathPrefix(/api)`: el aviso muere en un 404 y el monitor se queda esperando para siempre. Para
> que el servidor resuelva ese nombre hace falta la entrada en `/etc/hosts` del capítulo
> [13](13_observabilidad.md) § 5 paso 8.

Y **pruébala antes de darla por buena**. El monitor debe pasar a verde en segundos:

```bash
# [servidor]
curl -fsS "${RESTIC_PUSH_URL}?status=up&msg=prueba" && echo "  ← aviso entregado"
```

Criterio de aceptación: `curl` devuelve una respuesta correcta y el monitor se pone en verde. Si
falla, prueba con otra dirección (`127.0.0.1`, la IP de Tailscale) hasta dar con la que responde
desde el host, y vuelve a fijar la variable.

> **Vuelve a instalar el script después de fijar esta variable**, porque el valor se sustituye al
> generarlo: `nomad_plantilla etc/nomad-respaldo.sh | sudo tee /usr/local/bin/nomad-respaldo.sh`.
> Si no, el respaldo funcionará pero no avisará a nadie, que es justo el fallo que este monitor
> existe para detectar.

El intervalo de 25 horas da margen: el respaldo es diario y `RandomizedDelaySec` puede retrasarlo
unos minutos. Si pasan 25 horas sin aviso, algo va mal (§ 3.6).

### Paso 9 — Automatiza

```bash
# [servidor]
nomad_plantilla systemd/nomad-respaldo.service \
    | sudo tee /etc/systemd/system/nomad-respaldo.service >/dev/null
nomad_plantilla systemd/nomad-respaldo.timer \
    | sudo tee /etc/systemd/system/nomad-respaldo.timer >/dev/null
```

El contenido está en `templates/systemd/`. Comprueba que las rutas y la hora han quedado escritas:

```bash
# [servidor]
grep -E 'RequiresMountsFor|ReadWritePaths' /etc/systemd/system/nomad-respaldo.service
grep 'OnCalendar' /etc/systemd/system/nomad-respaldo.timer
```

Salida esperada, con los valores de ejemplo:

```
RequiresMountsFor=/mnt/respaldo
ReadWritePaths=/mnt/respaldo /var/backups/nomad /var/cache/restic
OnCalendar=*-*-* 03:30:00
```

Criterio de aceptación: rutas reales y una hora válida. Un `OnCalendar=*-*-* :00` con la hora vacía
hace que systemd rechace la unidad, lo cual al menos es ruidoso; un `ReadWritePaths` vacío hace que
el respaldo falle **solo desde systemd** y funcione a mano, que es mucho más confuso.

```bash
# [servidor]
sudo systemctl daemon-reload
sudo systemctl enable --now nomad-respaldo.timer
systemctl list-timers nomad-respaldo --no-pager
```

Criterio de aceptación: aparece con próxima ejecución programada a las `${RESTIC_HORA}`.

```bash
# [servidor] — probar el servicio completo tal como lo ejecutará systemd
sudo systemctl start nomad-respaldo.service
sudo journalctl -u nomad-respaldo -n 40 --no-pager
```

Ejecutarlo a través de systemd, y no solo a mano, es importante: el servicio corre con
`ProtectSystem=strict` y un aislamiento que el script no tiene al lanzarlo desde tu sesión. Un
respaldo que funciona a mano y falla desde systemd es un caso habitual.

### Paso 10 — LA PRUEBA DE RESTAURACIÓN

**Este es el paso que da sentido a todo el capítulo.**

```bash
# [servidor]
sudo mkdir -p /tmp/prueba-restauracion
sudo restic restore latest \
    --repo ${RESTIC_REPO_LOCAL} \
    --password-file ${RESTIC_PASSWORD_FILE} \
    --target /tmp/prueba-restauracion \
    --include ${DATOS_RAIZ}
```

Comprueba que lo restaurado coincide con el original:

```bash
# [servidor]
sudo diff -r ${DATOS_RAIZ} /tmp/prueba-restauracion${DATOS_RAIZ} && echo "IDENTICO"
```

Criterio de aceptación: `IDENTICO`, o solo diferencias en archivos que cambian constantemente
(bases de datos en uso, registros).

Comprueba también lo que más importa y menos se mira:

```bash
# [servidor] — los archivos .env deben estar, y con sus permisos
sudo find /tmp/prueba-restauracion${DATOS_RAIZ} -name '.env' -exec stat -c '%n %a' {} \;
```

Criterio de aceptación: aparecen todos, con permisos `600`.

```bash
# [servidor] — las credenciales del túnel deben estar
sudo restic ls latest \
    --repo ${RESTIC_REPO_LOCAL} \
    --password-file ${RESTIC_PASSWORD_FILE} \
    | grep cloudflared
```

Criterio de aceptación: aparece el archivo `<UUID>.json`.

```bash
# [servidor] — limpia
sudo rm -rf /tmp/prueba-restauracion
```

**Prueba avanzada, muy recomendable:** restaura un proyecto completo en otra ruta, cambia el
subdominio en su compose y levántalo. Si arranca y funciona, tu respaldo sirve de verdad.

### Paso 11 — Verificación de integridad

```bash
# [servidor] — comprobación de estructura (rápida)
sudo restic check \
    --repo ${RESTIC_REPO_LOCAL} \
    --password-file ${RESTIC_PASSWORD_FILE}
```

```bash
# [servidor] — comprobación de datos sobre una muestra (lenta)
sudo restic check --read-data-subset=5% \
    --repo ${RESTIC_REPO_LOCAL} \
    --password-file ${RESTIC_PASSWORD_FILE}
```

`check` a secas verifica que la estructura del repositorio es coherente. `--read-data-subset`
además **lee y descifra** una muestra de los datos, que es lo único que detecta un disco que se está
degradando en silencio. Se incluye en la rutina mensual del capítulo 15.

### Paso 12 — Repositorio remoto

> **Opcional solo si tienes disco local.** Sin disco, este paso es obligatorio y va **antes** del
> paso 4: el remoto es el repositorio principal y no hay nada que inicializar hasta tenerlo (§ 3.3).

El disco local protege contra el fallo del disco del servidor. No protege contra un incendio, una
inundación o un robo: ambos discos están en la misma habitación.

Con Backblaze B2, que es de los más baratos:

```bash
# [servidor]
sudo vim /etc/nomad/restic-remoto.env
```

```
B2_ACCOUNT_ID=xxxxx
B2_ACCOUNT_KEY=xxxxx
```

```bash
# [servidor]
sudo chmod 600 /etc/nomad/restic-remoto.env
```

Ese archivo lo carga el servicio de systemd con `EnvironmentFile=-/etc/nomad/restic-remoto.env`. El
guion inicial hace que el servicio arranque igual si el archivo no existe, que es el caso cuando no
hay remoto. **Comprueba que esa línea está en tu unidad**, porque sin ella el respaldo funciona a
mano y falla cada noche:

```bash
# [servidor]
grep -n EnvironmentFile /etc/systemd/system/nomad-respaldo.service
```

Criterio de aceptación: aparece la línea.

Y en `config/servidor.env`:

```
RESTIC_REPO_REMOTO="b2:mi-bucket:nomad"
```

Inicializa el repositorio remoto una vez:

```bash
# [servidor]
set -a; . /etc/nomad/restic-remoto.env; set +a
sudo -E restic init --repo ${RESTIC_REPO_REMOTO} --password-file ${RESTIC_PASSWORD_FILE}
```

El script de respaldo usa `restic copy` para replicar las instantáneas locales al remoto. Copiar en
lugar de respaldar dos veces evita leer y cifrar todo otra vez.

---

## 6. Script asociado

### 6.1 Vía A — con el script

`scripts/14_restic.sh` automatiza los pasos 2 a 9 y proporciona las operaciones del día a día.

```bash
# [servidor] — CON sudo: toca /etc/fstab, /root y unidades de systemd
cd ~/nomad_server
sudo ./scripts/14_restic.sh --help
sudo ./scripts/14_restic.sh --check
sudo ./scripts/14_restic.sh --instalar
```

**Antes de ejecutarlo** hay que haber hecho a mano el paso 1 (formatear el disco) y haber
persistido `RESTIC_USB_UUID`. El script comprueba que ese UUID corresponde a un dispositivo
presente y aborta si no.

Operaciones habituales:

```bash
sudo ./scripts/14_restic.sh --ahora            # respaldo inmediato
sudo ./scripts/14_restic.sh --listar           # instantáneas del repositorio
sudo ./scripts/14_restic.sh --verificar        # restic check
sudo ./scripts/14_restic.sh --verificar-datos  # check con lectura de datos (lento)
sudo ./scripts/14_restic.sh --probar           # prueba de restauración automatizada
sudo ./scripts/14_restic.sh --estado           # resumen: temporizador, tamaño, última copia
```

Comportamiento destacable:

- **No formatea el disco**: ese paso es destructivo y se hace a mano, a propósito.
- Comprueba que `RESTIC_USB_UUID` corresponde a un dispositivo presente.
- Se niega a continuar si el archivo de contraseña no existe o no tiene permisos `600`.
- Inicializa el repositorio solo si no existe.
- `--probar` restaura la última instantánea a un directorio temporal, compara con el original,
  verifica los permisos de los `.env` y comprueba que las credenciales del túnel están dentro.

En modo `--check` muestra las diferencias de `fstab`, del script y de las unidades de systemd, y
comprueba el estado del disco, sin escribir nada.

### 6.2 Correspondencia entre el script y los pasos manuales

| Paso de la sección 5 | ¿Lo hace el script? | Nota |
|---|---|---|
| 0 — preparar la sesión | Sí | Carga la configuración por su cuenta |
| 1 — formatear el disco | **No, a propósito** | Es destructivo. También es tuyo persistir el UUID |
| 2 — montaje permanente por UUID | Sí | Con `nofail`, siempre |
| 3 — instalar restic y la contraseña | Parcial | Instala el paquete; **la contraseña la escribes tú** |
| 4 — inicializar el repositorio | Sí | Solo si no existe ya |
| 5 — exclusiones | Sí | Desde `templates/etc/restic-excluir.txt` |
| 6 — script de respaldo | Sí | Desde `templates/etc/nomad-respaldo.sh`, con las variables sustituidas |
| 7 — primer respaldo | Sí, con `--ahora` | |
| 8 — monitor de Uptime Kuma | **No** | Interfaz web; y persistir `RESTIC_PUSH_URL` es tuyo |
| 9 — servicio y temporizador | Sí | Desde `templates/systemd/` |
| 10 — **prueba de restauración** | Sí, con `--probar` | **Interpretar el resultado es tuyo** |
| 11 — verificación de integridad | Sí, con `--verificar` y `--verificar-datos` | |
| 12 — repositorio remoto | Parcial | El script lo usa si está configurado; inicializarlo es tuyo |

### 6.3 Lo que ninguna vía hace por ti

- [ ] **Formatear el disco** (paso 1). Destructivo por definición.
- [ ] **Escribir la contraseña del repositorio** y, sobre todo, **guardarla fuera del servidor**.
- [ ] **Crear el monitor** de Uptime Kuma y persistir `RESTIC_PUSH_URL`.
- [ ] **Leer el resultado de la prueba de restauración.** El script dice si los archivos coinciden;
      que eso signifique que tu servidor es recuperable es un juicio tuyo.

### 6.4 Orden recomendado, mezclando las dos vías

Es el capítulo donde más sentido tiene combinarlas:

```bash
# [servidor] — 1. a mano, porque es destructivo
DISCO=/dev/sdb
# … pasos 1 de la sección 5 …
./scripts/variables.sh --fijar RESTIC_USB_UUID="$(sudo blkid -s UUID -o value ${DISCO}1)"
```

```bash
# [servidor] — 2. a mano, porque es un secreto
sudo touch /root/.restic-password && sudo chmod 600 /root/.restic-password
sudo ${EDITOR:-vim} /root/.restic-password
```

```bash
# [servidor] — 3. el resto, con el script
sudo ./scripts/14_restic.sh --check
sudo ./scripts/14_restic.sh --instalar
sudo ./scripts/14_restic.sh --ahora
sudo ./scripts/14_restic.sh --probar
```

---

## 7. Validación

```bash
# [servidor]
mountpoint ${RESTIC_USB_MOUNT} && df -h ${RESTIC_USB_MOUNT}
```

Criterio de aceptación: montado y con espacio libre.

```bash
# [servidor]
grep -c "${RESTIC_USB_UUID}" /etc/fstab
grep "${RESTIC_USB_UUID}" /etc/fstab | grep -c nofail
```

Criterio de aceptación: `1` en ambos. **Sin `nofail`, el servidor no arrancará si el disco falla.**

```bash
# [servidor]
sudo stat -c '%a' ${RESTIC_PASSWORD_FILE}
```

Criterio de aceptación: `600`.

```bash
# [servidor]
sudo restic snapshots --repo ${RESTIC_REPO_LOCAL} --password-file ${RESTIC_PASSWORD_FILE} | tail -5
```

Criterio de aceptación: al menos una instantánea.

```bash
# [servidor]
systemctl is-enabled nomad-respaldo.timer && systemctl is-active nomad-respaldo.timer
systemctl list-timers nomad-respaldo --no-pager
```

Criterio de aceptación: `enabled`, `active` y con próxima ejecución programada.

```bash
# [servidor]
sudo systemctl start nomad-respaldo.service && \
  systemctl show nomad-respaldo.service -p Result --value
```

Criterio de aceptación: `success`.

```bash
# [servidor]
sudo restic check --repo ${RESTIC_REPO_LOCAL} --password-file ${RESTIC_PASSWORD_FILE}
```

Criterio de aceptación: `no errors were found`.

```bash
# [servidor] — el manifiesto del sistema está dentro
sudo restic ls latest --repo ${RESTIC_REPO_LOCAL} --password-file ${RESTIC_PASSWORD_FILE} \
    | grep -E 'paquetes.txt|imagenes.txt'
```

Criterio de aceptación: aparecen ambos.

```bash
# [servidor] — el script instalado no tiene variables sin sustituir
sudo grep -n '\${[A-Z]' /usr/local/bin/nomad-respaldo.sh && echo "REVISAR" || echo "CORRECTO"
```

Criterio de aceptación: `CORRECTO`. Las variables en minúscula (`${punto_montaje}`, `${rutas[@]}`)
**sí deben estar**: son del propio script.

```bash
# [servidor] — el aviso al monitor está configurado y funciona
source ~/nomad_server/scripts/lib/entorno.sh
[ -n "${RESTIC_PUSH_URL}" ] && curl -fsS "${RESTIC_PUSH_URL}?status=up&msg=validacion" \
  && echo "  ← aviso entregado" || echo "REVISAR: RESTIC_PUSH_URL vacía o inalcanzable"
```

Criterio de aceptación: el aviso se entrega y el monitor de Uptime Kuma se pone en verde.

```bash
# [servidor] — la entrada de fstab lleva nofail
grep "${RESTIC_USB_UUID}" /etc/fstab | grep -c nofail
```

Criterio de aceptación: `1`.

**Comprobaciones que no son comandos, y son las que importan:**

- [ ] La contraseña del repositorio está en tu gestor de contraseñas, **fuera del servidor**.
- [ ] **Has hecho la prueba de restauración del paso 10** y el resultado fue idéntico.
- [ ] Los `.env` restaurados conservan permisos `600`.
- [ ] Las credenciales del túnel están dentro del respaldo.
- [ ] El monitor de Uptime Kuma pasó a verde tras el primer respaldo.

**Prueba del sistema de aviso:** desmonta el disco y lanza el respaldo. Debe fallar. Al día
siguiente, el monitor de Uptime Kuma debe estar en rojo por no recibir el aviso.

```bash
# [servidor]
sudo umount ${RESTIC_USB_MOUNT}
sudo /usr/local/bin/nomad-respaldo.sh    # debe fallar con un mensaje claro
sudo mount -a
```

---

## 8. Reversión

```bash
# [servidor] — detener los respaldos automáticos
sudo systemctl disable --now nomad-respaldo.timer
```

```bash
# [servidor] — eliminar la automatización, conservando los respaldos
sudo systemctl disable --now nomad-respaldo.timer
sudo rm /etc/systemd/system/nomad-respaldo.{service,timer}
sudo rm /usr/local/bin/nomad-respaldo.sh
sudo systemctl daemon-reload
```

```bash
# [servidor] — desmontar el disco definitivamente
sudo umount ${RESTIC_USB_MOUNT}
sudo sed -i "/${RESTIC_USB_UUID}/d" /etc/fstab
sudo systemctl daemon-reload
```

> **Los datos del repositorio no se borran con nada de lo anterior**, y así debe ser. Para eliminar
> el repositorio hay que hacerlo explícitamente:
>
> ```bash
> sudo rm -rf ${RESTIC_REPO_LOCAL}
> ```
>
> Piénsalo dos veces: eso borra todo el histórico de copias.

---

## 9. Errores frecuentes

| Síntoma | Causa probable | Solución | Documentación |
|---|---|---|---|
| El servidor no arranca tras conectar el disco | Falta `nofail` en `/etc/fstab` | Consola física: arranca en modo emergencia, edita `/etc/fstab` y añade `nofail` | § 3.3 |
| «repository master key and config already initialized» | El repositorio ya existía | No es un error: sáltate `restic init` | [restic — Repositorios](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html) |
| «wrong password or no key found» | La contraseña del archivo no coincide | Comprueba que no tiene espacios ni salto de línea extra. **Si la perdiste, el repositorio es irrecuperable** | § 3.8 |
| El respaldo funciona a mano pero falla desde systemd | El aislamiento de la unidad impide escribir en alguna ruta | Añádela a `ReadWritePaths` en el `.service`. Diagnostica con `journalctl -u nomad-respaldo` | [systemd.exec(5)](https://www.freedesktop.org/software/systemd/man/systemd.exec.html) |
| «Fatal: unable to open config file» | El disco no está montado | `mountpoint /mnt/respaldo` y `sudo mount -a`. El script ya lo comprueba antes de empezar | § 5 paso 2 |
| El repositorio crece sin parar | La política de retención no se aplica | Comprueba que `restic forget --prune` se ejecuta. Lánzalo a mano y observa | § 3.4 |
| El respaldo tarda horas cada noche | Se están respaldando `node_modules` o volúmenes de Docker | Revisa el archivo de exclusiones y las rutas incluidas | § 3.2 |
| «Fatal: unable to save snapshot: no space left» | El disco de respaldo está lleno | Ejecuta `restic forget --prune`. Si persiste, hace falta un disco mayor | [restic — Eliminar](https://restic.readthedocs.io/en/stable/060_forget.html) |
| Restauré y faltan los `.env` | No estaban en las rutas respaldadas, o los excluyó un patrón | Comprueba con `restic ls latest \| grep env`. Es justo lo que detecta la prueba del paso 10 | § 3.7 |
| Los permisos no se conservan al restaurar | Se restauró sin `sudo`, o el destino es exFAT/NTFS | Restaura con `sudo` y sobre un sistema de archivos POSIX | § 5 paso 1 |
| `restic check` da errores de integridad | El disco USB se está degradando | Sustituye el disco. Comprueba su salud con `sudo smartctl -H` | Capítulo [02](02_validacion_equipo.md) |
| El monitor de Uptime Kuma está rojo sin motivo aparente | El respaldo no se ejecutó: servidor apagado, disco desconectado o fallo | Eso es exactamente lo que debe detectar. Mira `journalctl -u nomad-respaldo` | § 3.6 |
| La copia remota falla y la local no | Credenciales del remoto mal, o sin red | `set -a; . /etc/nomad/restic-remoto.env; set +a` y prueba `restic -r <remoto> snapshots` | [restic — B2](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html#backblaze-b2) |
| El servidor se queda en consola de emergencia al arrancar | Falta `nofail` en la línea de `/etc/fstab` | Consola física: edita `/etc/fstab` y añádelo. Es el error más caro del capítulo | § 5 paso 2 |
| El respaldo falla cada noche con «no está montado» | `RESTIC_USB_UUID` mal copiado o del disco en vez de la partición | `sudo blkid ${DISCO}1` y vuelve a fijarlo con `--fijar` | § 4.2 |
| El repositorio se creó en `/restic/` o en una ruta rara | `RESTIC_USB_MOUNT` o `SERVIDOR_HOSTNAME` vacías al ejecutar `restic init` | Borra esa ruta, carga el entorno y repite el paso 4 | § 5 paso 0 |
| El script de respaldo falla con rutas vacías | Se instaló sin el entorno cargado | `nomad_plantilla etc/nomad-respaldo.sh \| sudo tee …` y comprueba | § 5 paso 6 |
| El respaldo funciona pero el monitor sigue rojo | `RESTIC_PUSH_URL` se fijó **después** de instalar el script | Vuelve a instalar el script tras fijar la variable | § 5 paso 8 |
| `curl` a la URL de push no responde desde el servidor | La URL usa un nombre de contenedor que el host no resuelve | Usa `${UPTIME_KUMA_HOST}:${TRAEFIK_PUERTO_INTERNA}` con la entrada en `/etc/hosts` | § 5 paso 8 |
| La URL de push devuelve `404 page not found` | La llamas por IP: sin nombre de host se la queda el router del panel de Traefik, que incluye `PathPrefix(/api)` | Llámala por `${UPTIME_KUMA_HOST}`, nunca por IP | Capítulo [10](10_traefik.md) § 3.4 |
| Formateé el disco equivocado | La variable `DISCO` apuntaba a otro dispositivo | No hay recuperación por software. La comprobación del paso 1 existe para esto | § 4.3 |

---

## 10. Referencias

- [restic — Documentación](https://restic.readthedocs.io/)
- [restic — Preparar un repositorio](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html)
- [restic — Respaldar](https://restic.readthedocs.io/en/stable/040_backup.html)
- [restic — Restaurar](https://restic.readthedocs.io/en/stable/050_restore.html)
- [restic — Eliminar instantáneas](https://restic.readthedocs.io/en/stable/060_forget.html)
- [restic — Comprobar la integridad](https://restic.readthedocs.io/en/stable/045_working_with_repos.html)
- [systemd — Temporizadores](https://www.freedesktop.org/software/systemd/man/systemd.timer.html)
- [`fstab(5)`](https://manpages.debian.org/trixie/mount/fstab.5.en.html)
- [templates/README.md](../templates/README.md) — el script de respaldo y las unidades de systemd
- Anexo [98 — Variables, entorno y sesiones](98_variables_y_entorno.md) § 4.4, sobre mayúsculas y minúsculas en la plantilla

---

**Anterior:** [13 — Observabilidad](13_observabilidad.md) · **Siguiente:** [15 — Mantenimiento y actualizaciones](15_mantenimiento_y_actualizaciones.md)
