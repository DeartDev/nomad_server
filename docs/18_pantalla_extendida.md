# 18 — Pantalla extendida

> El panel del HP como segunda pantalla del portátil Fedora, o como su pantalla principal. Un
> capítulo opcional: ningún otro depende de él, y el servidor sigue siendo un servidor.

---

## 1. Objetivo

Al terminar este capítulo, tienes:

- **En el HP**, un receptor mínimo: `cage` con Moonlight a pantalla completa en `tty7`, bajo un
  usuario de sistema sin privilegios y una unidad de systemd que **no se habilita nunca**. No hay
  escritorio ni gestor de sesión.
- **En el portátil Fedora (KDE)**, Sunshine y una orden, `pantalla-hp`, que abre y cierra la sesión:
  - `pantalla-hp extender`: el HP es un segundo monitor, a la derecha de la pantalla interna.
  - `pantalla-hp principal`: el HP es la pantalla principal y la interna se apaga.
  - `pantalla-hp off`, `pantalla-hp estado` y `pantalla-hp vincular`.
- **Un vínculo** entre los dos, hecho una sola vez, que sobrevive a los reinicios.

Lo que **no** hace:

- No funciona con Windows ni con Ubuntu. Son etapas posteriores, con su propio plan, y este capítulo
  no las cubre.
- No sobrevive a un cambio de red: si se corta el cable, la sesión termina y se vuelve a abrir.
- No es un monitor físico. En modo extensor el texto se lee, pero sin la nitidez de un panel
  conectado por cable de vídeo.
- Por Wi-Fi funciona con menos bitrate: el texto se ve peor que por cable (§ 3.10).

---

## 2. Requisitos previos

**Capítulos previos:** del 04 al 08. Este capítulo necesita el usuario administrador y SSH por llave
(05), el cortafuegos del capítulo 06 sin cambios (el HP solo hace conexiones de salida) y Tailscale
(08) en el HP **y en el portátil**: la sesión viaja por la tailnet. No necesita Docker.

**Ningún capítulo depende de este.** Con `PANTALLA_HABILITADA` en `no`, `18_pantalla.sh` sale sin
tocar el sistema.

**Necesitas a mano:**

- El portátil Fedora 44 con KDE Plasma, en sesión Wayland, con Tailscale conectado.
- Una vez, el teclado del HP (o un SSH con sudo): el vínculo pide la contraseña de `sudo` del HP.
- La contraseña del panel web de Sunshine (usuario `nomad`), que se crea con `sunshine --creds`
  (§ 5 paso 9). No se guarda en el repositorio.
- Teclado y ratón conectados al HP si vas a usar el modo principal.

**Preparar la sesión.** Este capítulo trabaja en **dos máquinas**. Cada bloque dice en cuál va
(`# [servidor]` es el HP, `# [portátil]` es el Fedora).

```bash
# [servidor]
cd ~/nomad_server
source scripts/lib/entorno.sh
```

```bash
# [portátil] — desde la raíz de tu copia del repositorio, esté donde esté
source scripts/lib/entorno.sh
```

El portátil tiene su **propio** `config/servidor.env` (§ 4.1). El repositorio es el mismo en las dos
máquinas; el archivo de configuración no viaja por git. Su copia no tiene por qué estar en
`~/nomad_server`: en el portátil, los bloques de este capítulo se ejecutan desde la raíz de esa copia.

---

## 3. Decisiones y por qué

### 3.1 Un kiosco de Moonlight bajo `cage`, no un escritorio

Del HP solo hace falta el receptor. `cage` es un compositor de Wayland que ejecuta **una** aplicación
a pantalla completa, sin barra, sin menús y sin gestor de sesión.

| Alternativa descartada | Por qué |
|---|---|
| XFCE con LightDM | LightDM se activaría solo con `graphical.target`, y un servidor no debe arrancar un escritorio |
| `krdp` + FreeRDP | Funciona, pero `krdp` no parece enviar audio |

La AppImage de Moonlight solo trae el plugin Qt `xcb`, así que corre sobre Xwayland dentro de `cage`
(`QT_QPA_PLATFORM=xcb`). Por eso `xwayland` va en la lista de paquetes, y no se confía en que llegue
como recomendación de `cage`: se instala con `--no-install-recommends`.

`cage` se lanza **sin `-s`**, la opción que permite cambiar de consola con el teclado. Desde el
kiosco no se sale a una consola. Si el panel se queda colgado, se recupera por SSH. Las unidades
cambian de consola con `chvt`, como root, y eso no pasa por `cage`.

### 3.2 Sunshine y Moonlight, y por Tailscale

Sunshine lleva vídeo, audio y entrada en un solo canal. La sesión la inicia **el HP hacia el
portátil**: el cortafuegos del HP no cambia y no se abre ningún puerto.

Se conecta a la IP de Tailscale del portátil (`PANTALLA_EMISOR_IP`), no a la de la LAN. Así el HP
usa siempre la misma dirección, venga el portátil por cable o por Wi-Fi. Sunshine escucha solo en
esa IP (`bind_address`).

### 3.3 Monitor virtual con `krfb-virtualmonitor`

Ya está en Fedora y Sunshine lo captura con `capture = kwin`. La captura `kms` no ve salidas
virtuales. La salida se llama `Virtual-hp-pantalla`; la interna es `eDP-1`.

### 3.4 El usuario `pantalla`, sin privilegios

Es un usuario de sistema con `nologin` y los grupos `video`, `render` y `audio`, y nada más. El
script se niega a seguir si pertenece a `sudo`, `docker`, `adm` o `input`: este último daría acceso a
todos los dispositivos de entrada del equipo.

**Su directorio personal guarda el vínculo con el portátil** (certificado de Moonlight). Por eso el
script **nunca recrea** el usuario si ya existe: recrearlo obligaría a repetir el vínculo. Solo le
añade `video`, `render` o `audio` si le falta alguno.

### 3.5 La unidad no se habilita, y tampoco se lanza al arrancar

`nomad-pantalla.service` no tiene sección `[Install]`: no se puede habilitar por error. Arranca solo
cuando el portátil lo pide y nunca vuelve sola tras un reinicio.

**Límites:** `MemoryMax=2G` impide que el receptor agote la memoria del servidor. `CPUWeight=50` solo pesa frente a otros usuarios: Docker vive en `system.slice`, así que **no le da prioridad sobre el receptor**. En las pruebas Moonlight usó un 11–12 % de CPU, de modo que hoy no hace falta más.
Van en la porción del usuario (`user-<uid>.slice`), con un añadido que instala el script, y no en la
unidad: `PAMName=login` abre una sesión, y eso mueve el cliente a `session-N.scope`, dentro de esa
porción y fuera de `nomad-pantalla.service`. La unidad conserva las dos líneas porque no estorban,
pero no son ellas las que limitan a Moonlight. Esto sale de cómo funciona `PAMName`, no de una
medición; se comprueba en el servidor.

**Parada:** por la misma razón, parar la unidad no alcanza lo que está en la sesión. `ExecStopPost`
cierra primero la sesión del usuario `pantalla` (`loginctl terminate-user`; `pkill -KILL` dejaba `user@<uid>.service` fallida) y después devuelve el panel a
`tty1`. Las órdenes de `ExecStopPost` van una tras otra, así que `chvt` no compite con `pkill`, y
se ejecutan al terminar **por cualquier causa**. Al arrancar, el panel cambia a `tty7`.

`Restart=no`: si algo falla se mira el registro y se vuelve a pedir. Una unidad fallida se descarga
sola (`CollectMode=inactive-or-failed`): `systemctl status` no la encontrará, y lo que pasó está en
`journalctl -u nomad-pantalla.service`.

Pedir una sesión es siempre `stop` y `start` en la misma llamada: `start` sobre una unidad activa no
hace nada, y seguiría el Moonlight de la sesión anterior. La unidad de vínculo y esta usan el mismo
`tty7` y el mismo usuario, así que se excluyen (`Conflicts=`), y una no arranca hasta que la otra ha
parado del todo: si no, su `loginctl terminate-user` cerraría la que entra.

La unidad pone `Master` y `Speaker` al 100 %. Esos controles se suman: al 80 % atenúan unos 25,5 dB.
Si uno de ellos falta, la sesión arranca igual: mejor imagen sin sonido que nada.

### 3.6 Una excepción limitada a `NOPASSWD`

El portátil arranca y para la unidad por SSH, y no hay nadie que teclee una contraseña. Se concede
una regla de `sudoers` que permite **exactamente dos órdenes**:

```
systemctl start nomad-pantalla.service
systemctl stop  nomad-pantalla.service
```

Es la única excepción a la decisión del capítulo [05](05_usuarios_y_acceso_ssh.md) § 3.6, y está
documentada allí. La frase de la clave SSH se sigue pidiendo una vez por sesión del portátil:
`pantalla-hp` la deja en el agente (`AddKeysToAgent`), porque después ya no puede preguntar.

### 3.7 Lo que protege `pantalla-hp`: un fallo no deja el portátil a oscuras

Una restauración descuidada ya dejó la pantalla interna sin imagen 20 minutos. Las reglas que lo
evitan están escritas en la cabecera de `scripts/emisor/pantalla-hp.sh`:

- **Nada se toca** hasta comprobar la red, que no hay otra sesión y que el HP responde por SSH.
  Se prueba además, antes de mover nada, el mismo camino que se usará con las pantallas movidas: un
  `ssh` que no pregunta y un `sudo -n -l`. Sin la clave en el agente o sin la regla de `sudo`, se
  aborta ahí.
- **Restauración programada antes de crear el monitor.** `systemd-run --user` deja un temporizador
  de 600 segundos que devuelve las pantallas a su sitio. Se arma *antes* de crear la pantalla
  virtual, porque crearla ya mueve las pantallas: KDE puede reaplicar una disposición guardada en
  cuanto aparece. Con cliente conectado, el vigilante la aplaza cada 60 segundos. No depende de
  este repositorio ni del proceso que la armó.
- **Disposición explícita en cada arranque:**

  | Modo | Pantalla virtual | Pantalla interna |
  |---|---|---|
  | `extender` | `1920,0`, prioridad 2 | encendida, `0,0`, prioridad 1 |
  | `principal` | `0,0`, prioridad 1 | apagada, prioridad 2 |

  KDE guarda la disposición de cada pareja de pantallas. Por eso se fija siempre.
- **`kscreen-doctor` devuelve 0 aunque no haya hecho nada**: si la salida que nombra no existe, no
  aplica *ninguna* de las órdenes de esa llamada. Su código de salida no vale; el resultado se
  comprueba leyendo `kscreen-doctor -o`.
- **El modo se aplica antes de arrancar Sunshine.** Al revés, Sunshine calcula el ratón con la
  geometría antigua y este solo alcanza media pantalla.
- **La interna se mueve en el orden correcto:** la virtual a `1920,0` *antes* de encender la interna,
  o las dos coinciden en `0,0` y la interna se queda sin imagen.
- **`off` restaura primero:** la interna vuelve antes de hablar con el HP y con la virtual aún
  viva. Después para la unidad del HP, Sunshine y el monitor, y comprueba otra vez la interna.
- **`off` nunca aborta a medias:** un paso que falla no impide el siguiente, y las señales se
  ignoran mientras restaura.
- **Tras tocar las pantallas, el `ssh` no pregunta nada** y tiene tiempo límite: con la interna
  apagada nadie ve la terminal.

### 3.8 Fin de sesión sin `off`

Cada arranque deja en el portátil un **vigilante** local. Cierra la sesión (restaura la interna y
retira el monitor virtual y Sunshine) cuando:

| Situación | Plazo |
|---|---|
| El HP no llega a conectar tras arrancar | **120 segundos** |
| Había cliente y ya no lo hay | **60 segundos** |
| Sunshine o el monitor virtual terminan | de inmediato |
| Falla todo lo anterior | los 10 minutos de la restauración programada |

El vigilante lee el registro de Sunshine. Cuenta como fin de sesión tanto `CLIENT DISCONNECTED`
como `Ping Timeout`: en los cortes de cable medidos, el primero llegó unos 5 segundos después, pero
no se depende de ello.

**No mantiene ninguna sesión SSH abierta en el HP**, porque `who` la contaría y bloquearía el
reinicio automático de `unattended-upgrades`. Con una sesión abierta, `who` sí muestra a `pantalla`
y el reinicio se aplaza a la noche siguiente, igual que con una sesión SSH.

**El HP se cuida solo.** Si el portátil cae, nadie puede pedir el `stop` por SSH, y Moonlight se
quedaría en su diálogo de error con el panel ocupado. Por eso `lanzar.sh` no hace `exec` de Moonlight:
lo deja en segundo plano y sondea por TCP el puerto `47989` de Sunshine cada 5 segundos, con un límite
de 3 segundos por conexión. Tras 3 sondeos fallidos seguidos cierra Moonlight, y la unidad termina y
devuelve el panel a `tty1`. Empieza 10 segundos después de arrancar, porque Sunshine puede estar
arrancando todavía. Los sondeos salen del HP, como la sesión: el cortafuegos no cambia.

Al reconectar tras un corte hay que relanzar el modo.

### 3.9 Riesgo aceptado: quien está frente al HP controla el portátil

**Durante una sesión, quien se siente ante el HP controla el escritorio del portátil**, y desde
ahí podría llegar a `compass` (el servidor) si la clave SSH está cargada en el agente. Es un riesgo
que el usuario aceptó: la sesión solo se abre con él presente, y se cierra con `off` o por el
vigilante.

Lo que sí se garantiza es lo contrario: desde `cage` no se llega a una consola ni a la cuenta
`compass` del propio HP (`cage` va sin `-s`, § 3.1). Se verifica en la validación (§ 7).

Pero lleva una consecuencia práctica: **no dejes una sesión abierta con el HP a la vista de
terceros** y no cargues la clave SSH del servidor en un portátil que va a estar en un sitio público.

### 3.10 Wi-Fi: menos bitrate, y automático

El cable es la ruta recomendada, pero el Wi-Fi funciona. Una sesión de más de 5 minutos, con el cable
fuera todo el tiempo, fue fluida y con buen sonido a unos 11 Mbit/s. Una prueba anterior a 40 Mbit/s
salió entrecortada, y en ella el cable volvió a mitad, así que no sirve para comparar.

El HP pide siempre `PANTALLA_BITRATE`. Para no tocarlo al cambiar de ruta, `pantalla-hp` mira por dónde
sale el portátil a la red: si es Wi-Fi, arranca Sunshine con `max_bitrate=15000`, y si es cable, sin
tope. Se limita en el portátil y no hace falta `sudo`. La ruta se decide al abrir la sesión: si cambias
de cable a Wi-Fi, la sesión se corta y se vuelve a abrir.

La reserva de DHCP del router para el portátil (`192.168.1.4`) no cubre el Wi-Fi, aunque da igual: la
sesión usa la IP de Tailscale.

### 3.11 Lo que se mide y lo que no

Medido en el HP con Moonlight 6.2.0 (el HP All-in-One 22-dd2xxx; panel `eDP-1` de 1920×1080):

| Dato | Valor |
|---|---|
| Decodificación | `VAAPI`, HEVC, unos 0,6–1,1 ms por fotograma |
| Red durante la sesión (cable) | 0 % de fotogramas perdidos, 1 ms |
| CPU del HP | 71–74 % libre de mediana; Moonlight 11–12 % de media |
| Memoria de Moonlight | 179 MB como máximo |
| FPS | 27–45 en extensor, 60 en principal, con 60 solicitados. Aceptable para el usuario |
| Tapa cerrada | Casi 3 minutos sin suspender, con `systemd-inhibit` |
| Corte de cable en modo principal | Pantalla interna de vuelta a los 62 segundos |
| Portátil sin red en plena sesión | El HP cierra solo: `tty1` a los 29 segundos |
| Wi-Fi | Fluido a unos 11 Mbit/s negociados; por cable, 31 Mbit/s |
| Sesión larga con respaldo | 69 minutos por cable sin reinicios, cortes ni avisos de Uptime Kuma: 17/17 contenedores sanos en las 66 muestras, CPU libre media del 69 % (mínimo 39 %, durante los 25 s del respaldo), memoria del receptor entre 246 y 276 MB, sin crecimiento sostenido |
| Con sesión abierta | `who` muestra a `pantalla`; el reinicio automático se aplaza |

Las cifras de cortes y de Wi-Fi son del servidor real con `pantalla-hp`; las de CPU y FPS, de las
pruebas manuales anteriores.

---

## 4. Variables usadas

### 4.1 De `config/servidor.env`

Las mismas variables, **en cada máquina**:

| Variable | Para qué | Ejemplo | HP | Portátil |
|---|---|---|---|---|
| `PANTALLA_HABILITADA` | `si`/`no`. Con `no`, el script no toca nada | `no` | sí | sí |
| `PANTALLA_USUARIO` | Usuario de sistema que ejecuta el receptor | `pantalla` | sí | |
| `PANTALLA_EMISOR_IP` | IP de Tailscale del portátil | `100.x.y.z` | sí | sí |
| `PANTALLA_BITRATE` | Tasa de vídeo, en kbps | `40000` | sí | |
| `PANTALLA_HP_SSH` | Alias SSH con el que el portátil llega al HP | `nomadservernw` | | sí |
| `MOONLIGHT_VERSION` | Versión del cliente | `6.2.0` | sí | |
| `MOONLIGHT_SHA256` | Huella de esa AppImage | (64 hex) | sí | |
| `TS_IP` | IP de Tailscale del HP. La usa `vincular` para reconocer su petición | `100.x.y.z` | | sí |
| `ADMIN_USUARIO` | Quién recibe el permiso de `sudo` y cuyo repositorio documenta las unidades | `deart` | sí | |

### 4.2 Las variables que se DESCUBREN aquí

| Variable | De dónde sale |
|---|---|
| `PANTALLA_EMISOR_IP` | `tailscale ip -4` **en el portátil** |
| `TS_IP` (en el portátil) | `tailscale ip -4` **en el HP**, o `tailscale status` |

```bash
# [portátil] — su propia IP de Tailscale
tailscale ip -4
```

```bash
# [servidor] y [portátil] — la misma, en cada archivo de configuración
./scripts/variables.sh --fijar PANTALLA_EMISOR_IP=<ip-del-portátil>
```

### 4.3 Variables temporales de esta sesión

Ninguna. El PIN del vínculo lo genera `pantalla-hp vincular` y la contraseña de Sunshine se pide en
el momento: no se guardan.

---

## 5. Procedimiento

### Paso 0 — Prepara las dos sesiones

```bash
# [servidor]
cd ~/nomad_server
source scripts/lib/entorno.sh
```

```bash
# [portátil] — desde la raíz de tu copia del repositorio
source scripts/lib/entorno.sh
```

Comprueba que el portátil llega al HP por SSH con el alias que vas a usar, y que el HP tiene
Tailscale:

```bash
# [portátil]
ssh ${PANTALLA_HP_SSH} true && echo "CORRECTO"
```

### Paso 1 — Decide y activa

**Las dos máquinas necesitan las variables**, cada una en su `config/servidor.env` (§ 4.1). Si tu
archivo es anterior a este capítulo, copia antes en cada una el bloque 10 de
`config/servidor.env.example`: con `PANTALLA_HABILITADA=si`, `18_pantalla.sh` se niega a seguir si
falta alguna.

```bash
# [servidor]
./scripts/variables.sh --fijar PANTALLA_HABILITADA=si
./scripts/variables.sh --fijar PANTALLA_EMISOR_IP=<ip-de-tailscale-del-portátil>
source scripts/lib/entorno.sh      # recarga: variables.sh escribe el archivo, no tu sesión
```

```bash
# [portátil] — su archivo de configuración es propio: copia o escribe las PANTALLA_*
./scripts/variables.sh --fijar PANTALLA_HABILITADA=si
./scripts/variables.sh --fijar PANTALLA_EMISOR_IP=<su-propia-ip-de-tailscale>
./scripts/variables.sh --fijar PANTALLA_HP_SSH=<alias-ssh-del-HP>
./scripts/variables.sh --fijar TS_IP=<ip-de-tailscale-del-HP>
source scripts/lib/entorno.sh
```

`PANTALLA_BITRATE`, `PANTALLA_USUARIO`, `MOONLIGHT_VERSION` y `MOONLIGHT_SHA256` vienen con valor en
la plantilla.

### Paso 2 — HP: paquetes

```bash
# [servidor]
sudo apt-get install -y --no-install-recommends cage xwayland kbd intel-media-va-driver \
    mesa-va-drivers vainfo libgl1-mesa-dri libegl-mesa0 alsa-utils libopengl0 libfontconfig1 \
    libva-x11-2
```

`--no-install-recommends` es deliberado: evita arrastrar un escritorio. Por eso `xwayland` se nombra
aquí, y `kbd` también: de él sale `chvt`, y las unidades lo llaman. `libfuse2t64` **no** está en la
lista, porque la AppImage se extrae y no usa FUSE.

> Si hiciste la prueba manual y `libfuse2t64` quedó instalado, **el script no lo retira**: solo lo
> avisa. Quítalo a mano, si quieres: `sudo apt-get remove libfuse2t64`. Nada depende de él.

### Paso 3 — HP: el usuario

```bash
# [servidor] — si no existe. Si existe, NO lo recrees: guarda el vínculo
id -u ${PANTALLA_USUARIO} || sudo useradd --system --create-home --shell /usr/sbin/nologin \
     --groups video,render,audio \
     --comment "Cliente de pantalla extendida (capitulo 18)" \
     ${PANTALLA_USUARIO}
```

```bash
# [servidor] — si ya existía: le añade los que le falten y no le quita nada
sudo usermod -aG video,render,audio ${PANTALLA_USUARIO}
```

```bash
# [servidor] — comprobación: ni sudo, ni docker, ni adm, ni input
id -nG ${PANTALLA_USUARIO}
```

Salida esperada: el grupo propio más `video`, `render` y `audio`.

### Paso 4 — HP: Moonlight

```bash
# [servidor]
URL="https://github.com/moonlight-stream/moonlight-qt/releases/download/v${MOONLIGHT_VERSION}/Moonlight-${MOONLIGHT_VERSION}-x86_64.AppImage"
TMP="$(mktemp -d)"
curl -fsSL --retry 3 -o "${TMP}/moonlight.AppImage" "${URL}"
echo "${MOONLIGHT_SHA256}  ${TMP}/moonlight.AppImage" | sha256sum -c -
```

**Si `sha256sum` no dice `OK`, para y no sigas.** El binario se ejecuta en el HP con acceso al panel.

```bash
# [servidor]
chmod +x "${TMP}/moonlight.AppImage"
( cd "${TMP}" && ./moonlight.AppImage --appimage-extract >/dev/null )
sudo install -d -m 755 -o root -g root /opt/nomad-pantalla
sudo rm -rf /opt/nomad-pantalla/moonlight
sudo mv "${TMP}/squashfs-root" /opt/nomad-pantalla/moonlight
sudo chown -R root:root /opt/nomad-pantalla/moonlight
sudo chmod -R u=rwX,go=rX /opt/nomad-pantalla/moonlight
echo "${MOONLIGHT_VERSION}" | sudo tee /opt/nomad-pantalla/moonlight/.version >/dev/null
rm -rf "${TMP}"
```

Los dos últimos `chown`/`chmod` no son decoración: la extracción hereda `700` del squashfs, y el
usuario `pantalla` no podría ejecutarla.

### Paso 5 — HP: el lanzador y las unidades

```bash
# [servidor] — mira antes qué va a cambiar
nomad_diff etc/nomad-pantalla-lanzar.sh /opt/nomad-pantalla/lanzar.sh
nomad_diff systemd/nomad-pantalla.service /etc/systemd/system/nomad-pantalla.service
nomad_diff systemd/nomad-pantalla-vincular@.service /etc/systemd/system/nomad-pantalla-vincular@.service
nomad_diff systemd/nomad-pantalla-usuario.conf \
    "/etc/systemd/system/user-$(id -u ${PANTALLA_USUARIO}).slice.d/50-nomad-pantalla.conf"
```

```bash
# [servidor]
nomad_plantilla etc/nomad-pantalla-lanzar.sh | sudo tee /opt/nomad-pantalla/lanzar.sh >/dev/null
sudo chmod 755 /opt/nomad-pantalla/lanzar.sh
for u in nomad-pantalla.service nomad-pantalla-vincular@.service; do
    nomad_plantilla "systemd/${u}" | sudo tee "/etc/systemd/system/${u}" >/dev/null
    sudo chmod 644 "/etc/systemd/system/${u}"
done
limites="/etc/systemd/system/user-$(id -u ${PANTALLA_USUARIO}).slice.d"
sudo install -d -m 755 "${limites}"
nomad_plantilla systemd/nomad-pantalla-usuario.conf | sudo tee "${limites}/50-nomad-pantalla.conf" >/dev/null
sudo systemctl daemon-reload
```

El último archivo son los límites de recursos del usuario, y lleva su `uid` en la ruta (§ 3.5).

```bash
# [servidor] — comprobación obligatoria: ninguna variable sin sustituir
sudo grep -nE '\$\{(PANTALLA|MOONLIGHT_V|ADMIN)[A-Z_]*\}' /opt/nomad-pantalla/lanzar.sh \
    /etc/systemd/system/nomad-pantalla.service || echo "CORRECTO"
```

El lanzador, con `PANTALLA_EMISOR_IP` vacía, no da error claro: Moonlight interpreta `Desktop` como
el anfitrión y no conecta. Por eso el script exige la variable.

### Paso 6 — HP: el permiso de `sudo`

```bash
# [servidor] — SIEMPRE se valida antes de instalar: un sudoers roto deja sin sudo
nomad_plantilla etc/sudoers-nomad-pantalla | sudo tee /etc/sudoers.d/nomad-pantalla.nuevo >/dev/null
sudo visudo -cf /etc/sudoers.d/nomad-pantalla.nuevo
```

Solo si `visudo` dice `parsed OK`:

```bash
# [servidor]
sudo install -m 440 /etc/sudoers.d/nomad-pantalla.nuevo /etc/sudoers.d/nomad-pantalla
sudo rm /etc/sudoers.d/nomad-pantalla.nuevo
```

### Paso 7 — HP: salvaguarda

```bash
# [servidor] — no debe existir un gestor de pantalla
systemctl cat display-manager.service >/dev/null 2>&1 && echo "HAY UN GESTOR: retíralo" || echo "CORRECTO"
```

Un gestor de pantalla competiría con `cage` por la GPU. La unidad **no se habilita**, ni ahora ni
después: no ejecutes `systemctl enable` sobre ella.

### Paso 8 — Portátil: Sunshine, el cortafuegos y la orden

```bash
# [portátil]
sudo dnf -y copr enable lizardbyte/stable
sudo dnf -y install Sunshine intel-media-driver libva-utils
```

El `intel-media-driver` es de RPM Fusion: el driver de Fedora no trae H.264 ni HEVC, y sin él la
codificación iría por CPU.

```bash
# [portátil] — la configuración de Sunshine (sustituye la IP por PANTALLA_EMISOR_IP)
mkdir -p ~/.config/sunshine
printf '%s\n' \
    "capture = kwin" \
    "encoder = vaapi" \
    "output_name = Virtual-hp-pantalla" \
    "bind_address = ${PANTALLA_EMISOR_IP}" \
    "upnp = disabled" \
    "vaapi_rc = vbr" \
    "vaapi_strict_rc_buffer = disabled" \
    > ~/.config/sunshine/sunshine.conf
```

Si ya había un `sunshine.conf`, haz copia antes. `vaapi_rc = vbr` reduce la franja inferior (§ 9).

```bash
# [portátil] — krfb-virtualmonitor escucha en TODAS las interfaces y no permite limitarlo
zona="$(firewall-cmd --get-default-zone)"
sudo firewall-cmd --zone="${zona}" --permanent --add-rich-rule='rule port port="15905" protocol="tcp" reject'
sudo firewall-cmd --zone="${zona}" --add-rich-rule='rule port port="15905" protocol="tcp" reject'
```

```bash
# [portátil] — la orden en el PATH, desde la raíz de tu copia del repositorio
mkdir -p ~/.local/bin
ln -sfn "$(pwd)/scripts/emisor/pantalla-hp.sh" ~/.local/bin/pantalla-hp
```

```bash
# [portátil] — comprobación: el portátil debe ofrecer HEVC por hardware
vainfo 2>&1 | grep -E 'VAProfileHEVCMain.*VAEntrypointEncSlice'
```

Si no sale ninguna línea, la codificación iría por CPU: revisa `intel-media-driver`.

No hace falta añadir tu usuario al grupo `input`: `/dev/uinput` ya es accesible por `uaccess`, y
ese grupo daría acceso a todos los dispositivos de entrada.

### Paso 9 — Vincular el HP con el portátil

Es un paso **único** y **manual a propósito**. Hay que repetirlo tras reconstruir el HP o el
portátil, o si borras el directorio personal del usuario `pantalla`.

Antes, crea el usuario `nomad` del panel de Sunshine. El panel no se puede abrir ahora: solo funciona
con Sunshine en marcha, y Sunshine solo arranca dentro de una sesión. Por eso se crea desde la línea
de órdenes, una vez:

```bash
# [portátil] — sin eco y sin que la contraseña quede en el historial
sunshine --creds nomad "$(systemd-ask-password 'Contraseña del panel de Sunshine:')"
```

```bash
# [portátil]
pantalla-hp vincular
```

Te pide dos contraseñas: la del panel de Sunshine (al principio) y la de `sudo` del HP (por SSH).
Lo que hace por dentro:

1. Crea el monitor virtual y arranca Sunshine, igual que `extender`.
2. En el HP lanza `nomad-pantalla-vincular@<PIN>.service`: `moonlight pair` con un PIN aleatorio
   bajo `cage`, con un límite de 90 segundos.
3. Sunshine 2026.914 exige un `pairing_id`: se busca con `GET /api/pin`, comprobando que la
   petición viene de `TS_IP` (el HP), y se confirma con `POST /api/pin`.
4. Cierra la sesión (`detener`).

> La unidad de vínculo del HP sigue viva hasta 90 segundos, ocupando `tty7`. No hace falta esperar:
> abrir una sesión la para antes de arrancar (`Conflicts=`, § 3.5).

### Paso 10 — Abrir y cerrar una sesión

```bash
# [portátil] — te pide la frase de tu clave SSH, una vez, y nada más
pantalla-hp extender
pantalla-hp estado
pantalla-hp off
```

También `pantalla-hp principal`. `--check` muestra lo que haría sin tocar nada.

### Paso 11 — Una barra en el HP en modo extensor

En modo extensor el panel del HP sale **sin barra de tareas**: Plasma tiene el panel en la pantalla
interna. Añade uno en la pantalla virtual (clic derecho en el escritorio, *Añadir panel*). En modo
principal la barra pasa sola al HP.

---

## 6. Script asociado

### 6.1 Vía A — con los scripts

```bash
# [servidor]
sudo ./scripts/18_pantalla.sh --check     # qué haría
sudo ./scripts/18_pantalla.sh             # aplicar
sudo ./scripts/18_pantalla.sh --check     # debe decir: Cambios que se aplicarían: 0
```

```bash
# [portátil]
./scripts/emisor/preparar_fedora.sh --check
./scripts/emisor/preparar_fedora.sh
./scripts/emisor/preparar_fedora.sh --check     # debe decir: Cambios que se aplicarían: 0
pantalla-hp vincular
```

`preparar_fedora.sh` corre con tu usuario y llama a `sudo` solo en los pasos que lo necesitan. Con
`--check` no llama a `sudo`.

`scripts/emisor/probar_pantalla_hp.sh` ejecuta las pruebas de `pantalla-hp` con dobles de todo lo
que toca el sistema: no se conecta a nada ni toca las pantallas reales.

```bash
# [portátil]
bash scripts/emisor/probar_pantalla_hp.sh
```

### 6.2 Correspondencia entre los scripts y los pasos manuales

| Paso manual | Lo hace el script |
|---|---|
| 1 — activar y fijar variables | No. Es una decisión tuya. `18_pantalla.sh` exige `PANTALLA_EMISOR_IP` |
| 2 — paquetes | `18_pantalla.sh`. Avisa de `libfuse2t64`, no lo retira |
| 3 — usuario | `18_pantalla.sh`. Si existe, no lo recrea: comprueba sus grupos y añade los que falten |
| 4 — Moonlight | `18_pantalla.sh`: versión fijada, SHA-256 comprobado, permisos corregidos |
| 5 — lanzador, unidades y límites | `18_pantalla.sh`, con diff en `--check`; recarga systemd solo si algo cambió |
| 6 — `sudoers` | `18_pantalla.sh`, validando una copia con `visudo -cf` antes de instalar |
| 7 — salvaguarda | `18_pantalla.sh`: se niega a seguir si hay `display-manager` |
| 8 — Sunshine, cortafuegos, enlace | `preparar_fedora.sh`: además comprueba que `vainfo` ofrece HEVC |
| 9 — vincular | `pantalla-hp vincular`. Los scripts de montaje **no** lo hacen |
| 10 — sesiones | `pantalla-hp` |
| 11 — barra del HP | **No.** Es interfaz de Plasma |

### 6.3 Si prefieres la vía manual

Los pasos 2 a 9 de § 5 son la equivalencia completa. Los scripts no hacen nada que no esté ahí
escrito.

---

## 7. Validación

```bash
# [servidor]
./scripts/verificar_sistema.sh --seccion pantalla
```

Se omite si `PANTALLA_HABILITADA` no es `si`. Comprueba:

```
==> Pantalla extendida
[OK]    Paquetes de la pantalla instalados.
[OK]    Moonlight instalado en /opt/nomad-pantalla/moonlight, ejecutable por pantalla.
[OK]    Moonlight 6.2.0, la versión fijada.
[OK]    pantalla sin grupos sudo, docker, adm ni input.
[OK]    nomad-pantalla.service no se habilita al arranque.
[OK]    No hay gestor de pantalla.
[OK]    sudoers con las dos reglas exactas (start y stop).
[OK]    VA-API: decodificación por hardware disponible.
```

Sin `sudo` en la sesión, las dos últimas y la de `AppRun` salen como **aviso**, no como fallo: el
`sudoers` es `440` de root, y tanto `vainfo` como `AppRun` hay que probarlos como el usuario
`pantalla`. Eso es «no puedo mirar», no «está mal». El `sudoers` debe tener esa regla y ninguna más:
una línea de más también es un fallo.

`nomad-pantalla.service` figura como `static` en `systemctl is-enabled`, porque no tiene `[Install]`:
es lo esperado.

```bash
# [servidor] — el receptor no aparece como sesión
who
```

Con una sesión abierta, `pantalla` no debe aparecer.

```bash
# [servidor] — tras 'pantalla-hp off', el panel vuelve a tty1
sudo fgconsole
```

Esperado: `1`. Y, con los periféricos del HP, `tty1` debe pedir usuario y contraseña.

Con una sesión abierta y los periféricos del HP, `Ctrl+Alt+F1` **no** debe cambiar de consola: `cage`
va sin `-s`. Si el panel se queda colgado, la recuperación es por SSH, no desde su teclado:

```bash
# [servidor] — por SSH, si el panel no responde
sudo systemctl stop nomad-pantalla.service
```

```bash
# [portátil]
pantalla-hp estado
```

Tras `off`, la interna (`eDP-1`) debe decir `enabled 0,0`, y las demás unidades `inactive`.

**Criterio de aceptación:**

1. `pantalla-hp extender` y `pantalla-hp principal` abren la sesión sin pedir más que la frase de la
   clave SSH, y `off` la cierra y deja el panel en `tty1`.
2. Con la sesión cerrada, la pantalla interna está encendida en `0,0`.
3. `./scripts/verificar_sistema.sh --seccion pantalla` pasa.
4. `sudo ./scripts/18_pantalla.sh --check` informa de `Cambios que se aplicarían: 0`.
5. `make check` pasa.

Tras cambiar de ruta o reiniciar el HP, repite una sesión corta: el sonido debe salir por el HP y
`pantalla-hp estado` debe mostrar `cliente conectado`.

---

## 8. Reversión

```bash
# [portátil] — cerrar cualquier sesión
pantalla-hp off
```

```bash
# [servidor] — desactivar sin borrar nada
sudo systemctl stop nomad-pantalla.service
./scripts/variables.sh --fijar PANTALLA_HABILITADA=no
```

```bash
# [servidor] — quitarlo del todo
sudo systemctl stop nomad-pantalla.service
sudo rm -f /etc/systemd/system/nomad-pantalla.service
sudo rm -f /etc/systemd/system/nomad-pantalla-vincular@.service
sudo rm -f "/etc/systemd/system/user-$(id -u ${PANTALLA_USUARIO}).slice.d/50-nomad-pantalla.conf"
sudo rmdir --ignore-fail-on-non-empty "/etc/systemd/system/user-$(id -u ${PANTALLA_USUARIO}).slice.d"
sudo rm -f /etc/sudoers.d/nomad-pantalla
sudo rm -rf /opt/nomad-pantalla
sudo systemctl daemon-reload
```

```bash
# [servidor] — y el usuario, si tampoco lo quieres
# COMPROBACIÓN OBLIGATORIA antes de borrar con una variable dentro:
echo "Se borraría el usuario: ${PANTALLA_USUARIO}"
```

```bash
# [servidor] — solo si la línea anterior mostró el nombre correcto
sudo userdel -r ${PANTALLA_USUARIO}
```

`-r` borra su directorio personal, **con el vínculo**: si más adelante lo reinstalas, hay que repetir
`pantalla-hp vincular`.

Los paquetes (`cage`, `xwayland`, `kbd`, `vainfo`, controladores) no se quitan: son inocuos y otros programas los usan.
`libfuse2t64`, si lo instalaste en una prueba, se quita a mano con `sudo apt-get remove libfuse2t64`.

```bash
# [portátil]
rm -f ~/.local/bin/pantalla-hp
sudo firewall-cmd --zone="$(firewall-cmd --get-default-zone)" --permanent --remove-rich-rule='rule port port="15905" protocol="tcp" reject'
sudo firewall-cmd --reload
```

`~/.config/sunshine/sunshine.conf` y el paquete `Sunshine` los quitas tú, si no los quieres para
otra cosa. El servidor vuelve exactamente al estado anterior; **ningún otro capítulo depende de
este**.

---

## 9. Errores frecuentes

| Síntoma | Causa | Solución |
|---|---|---|
| Tras `pantalla-hp vincular` exitoso, `journalctl -u nomad-pantalla-vincular@<PIN>` dice `Failed with result 'timeout'` | **No es un error.** `moonlight pair` no termina solo tras vincular: la unidad tiene `RuntimeMaxSec=90`, y es ese límite el que la cierra | Nada. Comprueba que el vínculo funciona con `pantalla-hp extender` |
| Conecta pero no se oye nada por el HP | Un audio USB, por ejemplo en un hub con teclado, ocupa `card 0` y el sonido va allí | El lanzador fija `ALSA_CARD=PCH` y la unidad usa `amixer -c PCH`. Comprueba con `cat /proc/asound/cards` que el nombre de la tarjeta sigue siendo `PCH` |
| `pantalla-hp vincular` falla justo después de otro intento | La instancia anterior sigue viva hasta 90 s, y al terminar devuelve el panel a `tty1` y mata lo que corra como `pantalla` | Espera 90 segundos entre intentos |
| El ratón del HP solo alcanza media pantalla | Sunshine arrancó antes que el modo, y calculó el ratón con la geometría antigua | `pantalla-hp off` y abre de nuevo. `pantalla-hp` aplica el modo antes de Sunshine; si lo has hecho a mano, invierte el orden |
| La pantalla interna queda **negra** al abrir o cerrar | KDE reaplicó una disposición guardada: las dos pantallas coinciden en `0,0` | Espera, la restauración programada actúa en 10 minutos como mucho. A mano: `kscreen-doctor output.Virtual-hp-pantalla.position.1920,0 output.eDP-1.enable output.eDP-1.position.0,0 output.eDP-1.priority.1` |
| `kscreen-doctor` devuelve 0 pero no cambia nada | La salida que nombra no existe (la virtual murió): no aplica ninguna orden de esa llamada | Repite la llamada **sin** nombrar la virtual. Comprueba el resultado con `kscreen-doctor -o`, nunca con el código de salida |
| En modo extensor, el panel del HP no tiene barra | Plasma tiene su panel en la pantalla interna | § 5 paso 11: añade un panel en la pantalla virtual |
| `No se llega a ... por ssh. No se ha tocado nada.` | El alias de `PANTALLA_HP_SSH` no resuelve o el HP está apagado | `ssh ${PANTALLA_HP_SSH} true`. No se ha cambiado nada |
| `... no responde sin preguntas: revisa 'ssh-add -l' ...` | El `ssh` entra preguntando, pero la clave no quedó en el agente, o falta la regla de `sudo` del HP | `ssh-add -l` y, si sale vacío, comprueba que el portátil tiene un agente en marcha. En el HP, `sudo ./scripts/18_pantalla.sh`. No se ha cambiado nada |
| `Este equipo no tiene la IP ...: ¿Tailscale está conectado?` | `PANTALLA_EMISOR_IP` no es la del portátil, o Tailscale está caído | `tailscale ip -4` en el portátil y compáralo con la variable |
| `Ya hay una sesión activa` | Quedó Sunshine o el monitor de una sesión anterior | `pantalla-hp off` |
| El HP muestra un error y vuelve a `tty1` enseguida | Falló `cage` o Moonlight | `sudo journalctl -u nomad-pantalla.service -n 50` |
| La sesión del HP termina sola, y el registro dice `Sin respuesta de ...:47989` | El HP perdió de vista a Sunshine durante 3 sondeos seguidos: el portátil cayó, o se cortó la red | Es lo previsto (§ 3.8). Vuelve a abrir la sesión desde el portátil |
| `18_pantalla.sh`: «PANTALLA_EMISOR_IP está vacía» | El lanzador quedaría sin anfitrión | `./scripts/variables.sh --fijar PANTALLA_EMISOR_IP=<ip>` |
| `18_pantalla.sh`: «El SHA-256 de Moonlight no coincide» | Descarga corrupta o `MOONLIGHT_SHA256` no es de esa versión | No se instala. Revisa la versión y la huella; no relajes la comprobación |
| `El usuario 'pantalla' pertenece al grupo ...` | Alguien lo metió en un grupo con privilegios | `sudo gpasswd -d ${PANTALLA_USUARIO} <grupo>` |
| `libfuse2t64 está instalado` (aviso) | Resto de una prueba manual | No hace falta. Si quieres quitarlo: `sudo apt-get remove libfuse2t64`. El script **no** lo hace |
| Hay un `segfault` de Moonlight en el registro al parar | Un cierre por tiempo deja el hilo de audio a medias (Moonlight 6.2.0) | No afecta al servidor. La unidad termina y el panel vuelve a `tty1` |
| Sesión entrecortada por Wi-Fi | Red saturada o señal débil, aun con el tope de 15 Mbit/s | Acércate al router o usa el cable. Para bajar el tope, cambia `BITRATE_WIFI` en `pantalla-hp.sh` |
| Tras apagar la red del portátil, `Este equipo no tiene la IP` | `nmcli networking off` le quita la dirección a `tailscale0` y Tailscale no la repone | `sudo systemctl restart tailscaled` |
| Unas veces 60 FPS, otras 27–45 | Aceptado. Hay `Atomic commit failed` en `eDP-1`, unos 6 por minuto, con y sin V-Sync. Causa sin confirmar | Ninguna conocida. `--no-vsync` se mantiene porque fue la última configuración probada |
| Una **franja inferior** del panel (unos 150–200 px, y otra más fina arriba) se pixela cada 2 segundos | **Causa desconocida**, limitación aceptada | Ver más abajo |

### La franja inferior: limitación aceptada

Una franja de unos 150–200 píxeles abajo, y otra más fina arriba, se pixelan con un ritmo fijo de unos
2 segundos, incluso con el escritorio quieto. **Se desconoce la causa.** El vídeo y el sonido llegan
estables, y el usuario aceptó dejarla así (2026-11-07). Lo descartado, probando un cambio cada vez:

- **El códec:** ocurre igual con HEVC y con H.264.
- **El codificador Intel:** sigue con `encoder = software` (`libx264`), y además el vídeo fluctúa. Por
  eso se mantiene `vaapi`.
- **El control de tasa `cqp`:** ocurre también con él. `vaapi_rc = vbr` la **redujo**, pero no la
  eliminó, y por eso es el valor de la configuración de Sunshine.
- **Un fotograma pesado periódico:** el tráfico que recibe el HP, medido cada 50 ms, no late a 2
  segundos.
- **La compresión del panel (FBC):** sigue igual apagándola en caliente.
- **La sincronización vertical:** sigue igual con `--vsync`, y sin mejora apreciable, así que se
  mantiene `--no-vsync`.
- **`Atomic commit failed`:** `cage` lo anota unas 23 veces por minuto, pero a intervalos irregulares,
  y la franja late con ritmo fijo. No se ha visto que afecte a la sesión.
- **El ahorro de energía del panel (PSR):** el estado de PSR da `No such device`, señal de que este
  panel no lo usa.

Sin probar: la decodificación por software en el HP, porque un Celeron de 2 núcleos a 1080p60 pondría
en riesgo el servidor, y la captura de la salida virtual en el portátil. Si se retoma, el siguiente
paso es ver la misma sesión con un cliente Moonlight en otro equipo.

### Otros riesgos abiertos

- **Corte del cable:** el enlace del portátil cayó 15 segundos una vez (2026-11-05, 21:39) sin causa
  conocida. Si se repite con el cable sin tocar, revisa el cable y el puerto del router.
- **`/var` con 11 GB libres:** las imágenes de Docker comparten ese espacio. Este capítulo no lo usa.

---

## 10. Referencias

- [Sunshine](https://docs.lizardbyte.dev/projects/sunshine/) — emisor, `sunshine.conf` y la API del PIN
- [Moonlight Qt](https://github.com/moonlight-stream/moonlight-qt) — el receptor
- [cage](https://github.com/cage-kiosk/cage) — el compositor de una sola aplicación
- [`kscreen-doctor`](https://userbase.kde.org/KScreen) — la disposición de pantallas de KDE
- [`systemd.service(5)`](https://www.freedesktop.org/software/systemd/man/systemd.service.html) — `RuntimeMaxSec`, `ExecStopPost`, `PAMName`
- [`systemd-run(1)`](https://www.freedesktop.org/software/systemd/man/systemd-run.html) — las unidades temporales de `pantalla-hp`
- [05 — Usuarios y acceso SSH](05_usuarios_y_acceso_ssh.md) — la excepción a `NOPASSWD`
- [08 — Tailscale](08_tailscale.md) — la red por la que viaja la sesión
- [16 — Recuperación ante desastres](16_recuperacion_ante_desastres.md) — revincular tras reconstruir
- `docs/superpowers/specs/2026-11-05-pantalla-extendida-design.md` — el diseño y sus mediciones
