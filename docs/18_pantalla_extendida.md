# 18 — Pantalla extendida

> El panel del HP como segunda pantalla del portátil, desde Fedora o desde Windows 11, o como su
> pantalla principal. Un capítulo opcional: ningún otro depende de él, y el servidor sigue siendo un
> servidor.

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
- **En Windows 11**, en el mismo portátil, Apollo y la misma orden `pantalla-hp`, en PowerShell, con
  los mismos modos (§ 10).
- **Un vínculo** con cada sistema, hecho una sola vez, que sobrevive a los reinicios.

Lo que **no** hace:

- No funciona con Ubuntu. Es una etapa posterior, con su propio plan, y este capítulo no la cubre.
- No abre dos sesiones a la vez: el portátil es uno solo, y cada `pantalla-hp` cierra antes la del otro
  sistema, si quedó alguna.
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

- El portátil Fedora 44 con KDE Plasma, en sesión Wayland, con Tailscale conectado. Para Windows, lo
  que pide el § 10.2.
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

La unidad tiene una instancia por emisor: `nomad-pantalla@fedora.service` y
`nomad-pantalla@windows.service`. El nombre de la instancia llega a `lanzar.sh`, que lo traduce a una IP
con `/opt/nomad-pantalla/emisor.sh`: `fedora` es `PANTALLA_EMISOR_IP` y `windows`,
`PANTALLA_EMISOR_WINDOWS_IP`. Es el único sitio del HP que guarda esas IP. Un nombre desconocido, o un
emisor sin IP, termina con un mensaje claro y sin arrancar Moonlight. Ubuntu será una instancia más.

`nomad-pantalla@.service` no tiene sección `[Install]`: no se puede habilitar por error. Arranca solo
cuando el portátil lo pide y nunca vuelve sola tras un reinicio.

**Límites:** `MemoryMax=2G` impide que el receptor agote la memoria del servidor. `CPUWeight=50` solo pesa frente a otros usuarios: Docker vive en `system.slice`, así que **no le da prioridad sobre el receptor**. En las pruebas Moonlight usó un 11–12 % de CPU, de modo que hoy no hace falta más.
Van en la porción del usuario (`user-<uid>.slice`), con un añadido que instala el script, y no en la
unidad: `PAMName=login` abre una sesión, y eso mueve el cliente a `session-N.scope`, dentro de esa
porción y fuera de la unidad. La unidad conserva las dos líneas porque no estorban,
pero no son ellas las que limitan a Moonlight. Esto sale de cómo funciona `PAMName`, no de una
medición; se comprueba en el servidor.

**Parada:** por la misma razón, parar la unidad no alcanza lo que está en la sesión. `ExecStopPost`
cierra primero la sesión del usuario `pantalla` (`loginctl terminate-user`; `pkill -KILL` dejaba `user@<uid>.service` fallida) y después devuelve el panel a
`tty1`. Las órdenes de `ExecStopPost` van una tras otra, así que `chvt` no compite con `pkill`, y
se ejecutan al terminar **por cualquier causa**. Al arrancar, el panel cambia a `tty7`.

`Restart=no`: si algo falla se mira el registro y se vuelve a pedir. Una unidad fallida se descarga
sola (`CollectMode=inactive-or-failed`): `systemctl status` no la encontrará. Lo que hizo la unidad
está en `journalctl -u nomad-pantalla@fedora.service` (o `@windows`); la salida de Moonlight, que corre
en la sesión del usuario, en `sudo journalctl _UID=$(id -u pantalla)`.

Pedir una sesión es siempre `stop` y `start` en la misma llamada: `start` sobre una unidad activa no
hace nada, y seguiría el Moonlight de la sesión anterior. `pantalla-hp` para **las dos** instancias
antes de arrancar la suya, porque puede quedar una huérfana del otro sistema: las instancias no se
excluyen entre sí (`Conflicts=` sobre la propia plantilla pararía también la que entra). La unidad de
vínculo, `nomad-pantalla-vincular@<emisor>-<PIN>.service`, sí excluye a las dos (`Conflicts=`), porque
usan el mismo `tty7` y el mismo usuario, y no arranca hasta que han parado del todo: si no, su
`loginctl terminate-user` cerraría la que entra.

La unidad pone `Master` y `Speaker` al 100 %. Esos controles se suman: al 80 % atenúan unos 25,5 dB.
Si uno de ellos falta, la sesión arranca igual: mejor imagen sin sonido que nada.

### 3.6 Una excepción limitada a `NOPASSWD`

El portátil arranca y para la unidad por SSH, y no hay nadie que teclee una contraseña. Se concede
una regla de `sudoers` que permite **exactamente cuatro órdenes**:

```
systemctl start nomad-pantalla@fedora.service
systemctl stop  nomad-pantalla@fedora.service
systemctl start nomad-pantalla@windows.service
systemctl stop  nomad-pantalla@windows.service
```

No se usa un comodín (`nomad-pantalla@*`): en `sudoers` casaría también con argumentos añadidos.

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
lo deja en segundo plano y lo cierra por dos vías. En los dos casos la unidad termina y devuelve el
panel a `tty1`.

- **Su propia salida.** `lanzar.sh` copia todo lo que escribe Moonlight al journal y lo cierra en cuanto
  escribe `Connection terminated`. Cubre el corte con el portátil aún accesible, por ejemplo al quitar
  el cable con el Wi-Fi activo: el emisor sigue respondiendo, pero la sesión ya ha muerto. Sin esto el
  HP se quedó en el diálogo de error hasta que alguien lo aceptó con su ratón (Windows, 2026-11-07).
  En las pruebas cerró todos los cortes: cable, corte total y portátil suspendido.
- **El sondeo**, de respaldo, para un portátil que desaparece sin que Moonlight llegue a enterarse:
  sondea por TCP el puerto `47989` del emisor cada 5 segundos, con un límite de 3 segundos por conexión.
  Tras 3 sondeos fallidos seguidos cierra Moonlight. Empieza 10 segundos después de arrancar, porque el
  emisor puede estar arrancando todavía. Los sondeos salen del HP, como la sesión: el cortafuegos no
  cambia.

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

### 3.10 Wi-Fi: menos bitrate, y automático en Fedora

El cable es la ruta recomendada, pero el Wi-Fi funciona. Una sesión de más de 5 minutos, con el cable
fuera todo el tiempo, fue fluida y con buen sonido a unos 11 Mbit/s. Una prueba anterior a 40 Mbit/s
salió entrecortada, y en ella el cable volvió a mitad, así que no sirve para comparar.

El HP pide siempre `PANTALLA_BITRATE`. Para no tocarlo al cambiar de ruta, `pantalla-hp` mira por dónde
sale el portátil a la red: si es Wi-Fi, arranca Sunshine con `max_bitrate=15000`, y si es cable, sin
tope. Se limita en el portátil y no hace falta `sudo`. La ruta se decide al abrir la sesión: si cambias
de cable a Wi-Fi, la sesión se corta y se vuelve a abrir.

En Windows el tope es fijo, también con cable (§ 10.1).

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
pruebas manuales anteriores. Todo es de Fedora; lo medido con Windows está en el § 10.5.

---

## 4. Variables usadas

### 4.1 De `config/servidor.env`

Las mismas variables, **en cada máquina**:

| Variable | Para qué | Ejemplo | HP | Portátil |
|---|---|---|---|---|
| `PANTALLA_HABILITADA` | `si`/`no`. Con `no`, el script no toca nada | `no` | sí | sí |
| `PANTALLA_USUARIO` | Usuario de sistema que ejecuta el receptor | `pantalla` | sí | |
| `PANTALLA_EMISOR_IP` | IP de Tailscale del portátil en Fedora | `100.x.y.z` | sí | sí |
| `PANTALLA_EMISOR_WINDOWS_IP` | IP de Tailscale del portátil en Windows. Opcional: vacía, solo funciona Fedora | `100.x.y.z` | sí | Windows (§ 10) |
| `PANTALLA_BITRATE` | Tasa de vídeo, en kbps | `40000` | sí | |
| `PANTALLA_HP_SSH` | Alias SSH con el que el portátil llega al HP | `nomadservernw` | | sí |
| `MOONLIGHT_VERSION` | Versión del cliente | `6.2.0` | sí | |
| `MOONLIGHT_SHA256` | Huella de esa AppImage | (64 hex) | sí | |
| `TS_IP` | IP de Tailscale del HP. La usa `vincular` para reconocer su petición | `100.x.y.z` | | sí |
| `ADMIN_USUARIO` | Quién recibe el permiso de `sudo` y cuyo repositorio documenta las unidades | `deart` | sí | |

### 4.2 Las variables que se DESCUBREN aquí

| Variable | De dónde sale |
|---|---|
| `PANTALLA_EMISOR_IP` | `tailscale ip -4` **en el portátil**, en Fedora |
| `PANTALLA_EMISOR_WINDOWS_IP` | `tailscale ip -4` en Windows: Tailscale da a cada sistema su propia IP |
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
nomad_diff etc/nomad-pantalla-emisor.sh /opt/nomad-pantalla/emisor.sh
nomad_diff systemd/nomad-pantalla@.service /etc/systemd/system/nomad-pantalla@.service
nomad_diff systemd/nomad-pantalla-vincular@.service /etc/systemd/system/nomad-pantalla-vincular@.service
nomad_diff systemd/nomad-pantalla-usuario.conf \
    "/etc/systemd/system/user-$(id -u ${PANTALLA_USUARIO}).slice.d/50-nomad-pantalla.conf"
```

```bash
# [servidor]
for f in lanzar emisor; do
    nomad_plantilla "etc/nomad-pantalla-${f}.sh" | sudo tee "/opt/nomad-pantalla/${f}.sh" >/dev/null
    sudo chmod 755 "/opt/nomad-pantalla/${f}.sh"
done
for u in nomad-pantalla@.service nomad-pantalla-vincular@.service; do
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
# [servidor] — solo si vienes de la versión con una sola unidad, sin instancias
sudo systemctl stop nomad-pantalla.service
sudo rm -f /etc/systemd/system/nomad-pantalla.service
sudo systemctl daemon-reload
```

Es lo que hace el script, que no la retira si está en marcha. A la vez hay que poner el `sudoers` nuevo
(paso 6): el antiguo solo conoce la unidad sin instancia, y `pantalla-hp` lo detecta y lo dice.

```bash
# [servidor] — comprobación obligatoria: ninguna variable sin sustituir
sudo grep -nE '\$\{(PANTALLA|MOONLIGHT_V|ADMIN)[A-Z_]*\}' /opt/nomad-pantalla/lanzar.sh \
    /opt/nomad-pantalla/emisor.sh /etc/systemd/system/nomad-pantalla@.service || echo "CORRECTO"
```

Las IP se escriben en `emisor.sh` al renderizar: tras cambiarlas en `servidor.env`, repite este paso.
Con una IP vacía, la instancia de ese emisor termina con `El emisor '...' no tiene IP` en su registro.
El script exige `PANTALLA_EMISOR_IP`; `PANTALLA_EMISOR_WINDOWS_IP` es opcional, y sin ella solo avisa.

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

Si ya había un `sunshine.conf`, haz copia antes. `vaapi_rc = vbr` se dejó por la franja inferior, que resultó ser un fallo del panel (§ 9).

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
2. En el HP lanza `nomad-pantalla-vincular@fedora-<PIN>.service`: `moonlight pair` con un PIN aleatorio
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
| 5 — lanzador, unidades y límites | `18_pantalla.sh`, con diff en `--check`; recarga systemd solo si algo cambió. Retira `nomad-pantalla.service` si existe y está parada |
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
[OK]    nomad-pantalla@fedora.service no se habilita al arranque.
[OK]    nomad-pantalla@windows.service no se habilita al arranque.
[OK]    No hay gestor de pantalla.
[OK]    sudoers con las cuatro reglas exactas (start y stop de fedora y windows).
[OK]    VA-API: decodificación por hardware disponible.
```

Sin `sudo` en la sesión, las dos últimas y la de `AppRun` salen como **aviso**, no como fallo: el
`sudoers` es `440` de root, y tanto `vainfo` como `AppRun` hay que probarlos como el usuario
`pantalla`. Eso es «no puedo mirar», no «está mal». El `sudoers` debe tener esa regla y ninguna más:
una línea de más también es un fallo.

Las dos instancias figuran como `static` en `systemctl is-enabled`, porque la plantilla no tiene
`[Install]`: es lo esperado.

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
sudo systemctl stop nomad-pantalla@fedora.service nomad-pantalla@windows.service
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
sudo systemctl stop nomad-pantalla@fedora.service nomad-pantalla@windows.service
./scripts/variables.sh --fijar PANTALLA_HABILITADA=no
```

```bash
# [servidor] — quitarlo del todo
sudo systemctl stop nomad-pantalla@fedora.service nomad-pantalla@windows.service
sudo rm -f /etc/systemd/system/nomad-pantalla@.service
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
otra cosa. Lo de Windows se deshace como dice el § 10.6. El servidor vuelve exactamente al estado anterior; **ningún otro capítulo depende de
este**.

---

## 9. Errores frecuentes

| Síntoma | Causa | Solución |
|---|---|---|
| Tras `pantalla-hp vincular` exitoso, `journalctl -u nomad-pantalla-vincular@fedora-<PIN>` dice `Failed with result 'timeout'` | **No es un error.** `moonlight pair` no termina solo tras vincular: la unidad tiene `RuntimeMaxSec=90`, y es ese límite el que la cierra | Nada. Comprueba que el vínculo funciona con `pantalla-hp extender` |
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
| El HP muestra un error y vuelve a `tty1` enseguida | Falló `cage` o Moonlight | `sudo journalctl -u nomad-pantalla@fedora.service -n 50` y la salida de Moonlight: `sudo journalctl _UID=$(id -u pantalla) -n 50` (con `-u` no sale) |
| `El sudo de ... no permite arrancar nomad-pantalla@...` o `sudoers ... de la versión anterior` | El HP tiene la regla de `sudo` antigua, de la unidad sin instancia | En el HP: `sudo ./scripts/18_pantalla.sh`. No se ha tocado nada |
| La sesión termina en cuanto arranca y el registro dice `El emisor '...' no tiene IP` | Falta la IP de ese emisor en `servidor.env` del HP | `./scripts/variables.sh --fijar PANTALLA_EMISOR_WINDOWS_IP=<ip>` (o `PANTALLA_EMISOR_IP`) y `sudo ./scripts/18_pantalla.sh` |
| La sesión del HP termina sola, y el registro dice `Moonlight ha anunciado el fin de la conexión` | Moonlight perdió la sesión: corte de red, cambio de ruta o portátil suspendido | Es lo previsto (§ 3.8). Vuelve a abrir la sesión desde el portátil |
| La sesión del HP termina sola, y el registro dice `Sin respuesta de ...:47989` | El HP perdió de vista al emisor durante 3 sondeos seguidos: el portátil cayó, o se cortó la red | Es lo previsto (§ 3.8). Vuelve a abrir la sesión desde el portátil |
| `18_pantalla.sh`: «PANTALLA_EMISOR_IP está vacía» | El lanzador quedaría sin anfitrión | `./scripts/variables.sh --fijar PANTALLA_EMISOR_IP=<ip>` |
| `18_pantalla.sh`: «El SHA-256 de Moonlight no coincide» | Descarga corrupta o `MOONLIGHT_SHA256` no es de esa versión | No se instala. Revisa la versión y la huella; no relajes la comprobación |
| `El usuario 'pantalla' pertenece al grupo ...` | Alguien lo metió en un grupo con privilegios | `sudo gpasswd -d ${PANTALLA_USUARIO} <grupo>` |
| `libfuse2t64 está instalado` (aviso) | Resto de una prueba manual | No hace falta. Si quieres quitarlo: `sudo apt-get remove libfuse2t64`. El script **no** lo hace |
| Hay un `segfault` de Moonlight en el registro al parar | Un cierre por tiempo deja el hilo de audio a medias (Moonlight 6.2.0) | No afecta al servidor. La unidad termina y el panel vuelve a `tty1` |
| Sesión entrecortada por Wi-Fi | Red saturada o señal débil, aun con el tope de 15 Mbit/s | Acércate al router o usa el cable. Para bajar el tope, cambia `BITRATE_WIFI` en `pantalla-hp.sh` |
| Tras apagar la red del portátil, `Este equipo no tiene la IP` | `nmcli networking off` le quita la dirección a `tailscale0` y Tailscale no la repone | `sudo systemctl restart tailscaled` |
| Unas veces 60 FPS, otras 27–45 | Aceptado. Hay `Atomic commit failed` en `eDP-1`, unos 6 por minuto, con y sin V-Sync. Causa sin confirmar | Ninguna conocida. `--no-vsync` se mantiene porque fue la última configuración probada |
| El vídeo de Disney+, Prime Video o Netflix se ve **en negro** en el HP, con sonido | Protección anticopia (DRM) del servicio, sobre todo en Edge o en apps de Windows | Usa Chrome sin aceleración por hardware o el navegador de Fedora. Ver más abajo |
| Una **franja inferior** del panel (unos 150–200 px, y otra más fina arriba) se estropea cada 2 segundos, con rayas verticales | **Fallo de hardware del panel del HP**: aparece hasta en la BIOS | Ninguna por software; ver más abajo |

### La franja inferior: fallo de hardware del panel del HP

Una franja de unos 150–200 píxeles abajo, y otra más fina arriba, se estropea con un ritmo fijo de unos
2 segundos: **rayas verticales de colores**, como si una fila se repitiera hacia abajo. **Es un fallo
de hardware del panel del HP o de su cable interno**, demostrado el 2026-11-08. La pantalla extendida
no la causa y ningún ajuste de software la corrige. El vídeo y el sonido llegan estables.

La prueba que lo zanja: **aparece también en la configuración de la BIOS**, donde no interviene nada de
Linux. Antes, cambiando una sola cosa cada vez, se vio que aparece igual:

| Prueba | Resultado |
|---|---|
| Emisores Fedora (Sunshine) y Windows (Apollo), HEVC y H.264, codificador Intel y por software | Sigue |
| Decodificación en el HP con `iHD`, con `i965` y por software, que además cambia el dibujo | Sigue |
| `cage` con `WLR_DRM_NO_MODIFIERS=1` y con `WLR_DRM_NO_ATOMIC=1`; FBC apagado; `--vsync` | Sigue |
| Patrón de prueba generado en el HP con `ffplay`, sin red ni Moonlight | Sigue |
| Pantalla negra con solo el cursor de `cage` | Sigue |
| Consola de texto (`tty1`) con `htop`, sin `cage` | Sigue |
| BIOS del equipo | Sigue |

El controlador `i915` funciona de forma estable: 1920×1080 a 60 Hz, sin PSR ni DRRS, sin entradas en
estados de ahorro DC (contador `DC3 -> DC5` a 0) y sin errores del kernel.

**Qué hacer:** si molesta, la vía es física. Se puede reasentar el conector del cable del panel en la
placa, con el equipo apagado y desenchufado, o reparar el panel. `vaapi_rc = vbr` se mantiene porque
en Sunshine parecía reducirla, pero con un fallo de hardware esa mejora no está demostrada.

### Servicios de streaming con DRM (Disney+, Prime Video, Netflix…)

**Sin probar en este equipo:** es el comportamiento habitual de estos servicios, no una medición. Para
ellos, Sunshine y Apollo son programas que capturan la pantalla. El vídeo puede verse en negro, bajar
de calidad o no reproducirse; el sonido suele llegar igual.

| Emisor y navegador | Lo esperable |
|---|---|
| Fedora, cualquier navegador | Se ve, porque en Linux no se usa la vía protegida por hardware. La calidad ya viene limitada por el servicio, normalmente a 720p en Linux |
| Windows, Edge o la app de Netflix | Vídeo **en negro**, con sonido: usan la protección por hardware (PlayReady) |
| Windows, Chrome o Firefox | Suele verse. Si sale en negro, desactiva la **aceleración por hardware** del navegador |
| Windows, cualquiera | La pantalla virtual de Apollo no tiene HDCP: algunos servicios bajan la resolución en Full HD |

La opción más fiable es el navegador de Fedora, o Chrome en Windows sin aceleración por hardware. Para
salir de dudas basta una prueba de un minuto por servicio con `pantalla-hp extender`. Cuando se pruebe,
esta tabla se sustituye por el resultado real.

### Otros riesgos abiertos

- **Corte del cable:** el enlace del portátil cayó 15 segundos una vez (2026-11-05, 21:39) sin causa
  conocida. Si se repite con el cable sin tocar, revisa el cable y el puerto del router.
- **`/var` con 11 GB libres:** las imágenes de Docker comparten ese espacio. Este capítulo no lo usa.

---

## 10. Windows 11 como emisor

El mismo portátil, arrancado en Windows 11, usa el HP igual que Fedora: el receptor es el mismo, con su
instancia `nomad-pantalla@windows.service`, y la orden se llama igual. Probado el 2026-11-07 en el
ThinkPad E14 con Windows 11 Pro 26H2, gráfica Iris Xe, Apollo 0.4.6 y PowerShell 5.1.

```powershell
pantalla-hp extender     # el HP es un segundo escritorio
pantalla-hp principal    # el HP es la única pantalla: la interna se apaga
pantalla-hp estado
pantalla-hp off          # deja la interna activa y como principal
pantalla-hp vincular     # una vez
```

En este capítulo, `# [windows]` es una consola de PowerShell en el portátil. Los bloques que dicen
**como administrador** necesitan una consola abierta con «Ejecutar como administrador».

### 10.1 Decisiones y por qué

**Apollo, no Sunshine.** Apollo es una variante de Sunshine con pantalla virtual propia (SudoVDA): la
crea cuando el HP conecta y la retira cuando se va. Es la limpieza que en Fedora hizo falta programar
(§ 3.7 y § 3.8). Cumplió los cuatro criterios de elección (pantalla virtual a 1920×1080 que se retira
sola, sonido en el HP y silencio en el portátil, modo principal y HEVC por QuickSync), así que Sunshine
no se probó.

**Apollo transmite la pantalla principal.** En «Extender» con la interna como principal, el HP mostraría
la interna. Por eso `extender` deja la pantalla virtual como **principal** en `0,0` y la interna a su
izquierda, en `−1920,0`: hay dos escritorios, las ventanas pasan de uno a otro, y la barra de tareas
queda en el HP. `principal` es `DisplaySwitch /external` («Solo segunda pantalla»), y `off`,
`DisplaySwitch /internal`. Windows, como KDE, recuerda disposiciones antiguas, así que el modo se aplica
siempre y se comprueba leyendo las pantallas, no el código de salida.

**Los ajustes que Apollo necesita**, y que `preparar_windows.ps1` fija:

| Archivo (en `C:\Program Files\Apollo\config`) | Ajuste | Sin él |
|---|---|---|
| `sunshine.conf` | `encoder = quicksync` | Apollo elige solo y puede caer en el codificador por software |
| `sunshine.conf` | `max_bitrate = 15000` | Por Wi-Fi, a los 40000 kbps que pide el HP, se nota lentitud pasados unos minutos |
| `apps.json`, aplicación `Desktop` | `"virtual-display": true` | Apollo transmite la pantalla física y Windows queda en «Duplicar» |
| `apps.json`, aplicación `Desktop` | `"terminate-on-pause": true` | Al parar, la pantalla virtual sigue siendo la principal sin que nadie la vea: el portátil se queda sin barra de tareas |

El tope de bitrate es **fijo, también con cable**. En Fedora solo se pone con Wi-Fi, al arrancar Sunshine
(§ 3.10), pero Apollo es un servicio, y cambiarlo en cada sesión exigiría administrador. Con el tope, la
imagen por cable se sigue viendo bien.

**Cortafuegos: hacen falta reglas de bloqueo.** El instalador crea dos reglas `Apollo` abiertas a todo,
y Tailscale instala `Tailscale-In`, que permite **toda** entrada por su interfaz. Permitir solo al HP no
basta: desde el HP seguía abierta la web de Apollo (47990). En Windows, una regla de bloqueo gana a una
de permitir, así que las reglas de `Apollo` se desactivan (sin borrarlas) y se crean cinco:

| Regla | Acción | Puertos | Desde |
|---|---|---|---|
| `Nomad Apollo TCP` | Permitir (`sunshine.exe`) | TCP 47984, 47989, 48010 | solo el HP (`TS_IP`) |
| `Nomad Apollo UDP` | Permitir (`sunshine.exe`) | UDP 47998-48000 | solo el HP |
| `Nomad Apollo bloquear web` | Bloquear | TCP 47990 | todo menos `127.0.0.0/8` |
| `Nomad Apollo solo HP TCP` | Bloquear | TCP 47984, 47989, 48010 | todo menos el HP y `127.0.0.0/8` |
| `Nomad Apollo solo HP UDP` | Bloquear | UDP 47998-48000 | todo menos el HP y `127.0.0.0/8` |

Medido desde el HP: 47984, 47989 y 48010 abiertos, y 47990 cerrado. La web sigue en
`https://localhost:47990`. No se probó desde otro equipo de la tailnet. Apollo no tiene opción de
dirección de escucha (escucha en `0.0.0.0`, solo IPv4): la protección es el cortafuegos. Si una
actualización de Apollo vuelve a activar sus reglas, `preparar_windows.ps1 -Check` lo cuenta como
cambio.

**Sin vigilante ni restauración programada.** Cuando el HP deja de verse, Apollo da la sesión por
perdida a los 10 segundos (`Ping Timeout`), retira la pantalla virtual, y Windows vuelve solo a la
interna. Se comprobó en modo principal con el corte total (cable fuera y modo avión): la interna volvió
sin hacer nada. `off` pide al HP que pare, espera hasta 20 segundos a que la virtual desaparezca, aplica
`DisplaySwitch /internal` y comprueba que la interna es la principal.

**La tapa no se toca.** Con la tapa cerrada la sesión sigue: cinco minutos, 36 muestras desde el HP, sin
cortes, con la acción de tapa predeterminada («suspender»). No hay ajuste de energía que restaurar. En
modo principal, al cerrar la tapa Windows entra un instante en espera moderna y **se bloquea**: se
desbloquea desde el HP y sigue funcionando. Al abrirla, la interna sigue apagada hasta el `off`.

**Teclado.** La pantalla de bloqueo y las ventanas de UAC se ven y se controlan desde el HP. La tecla
Win funciona porque `lanzar.sh` lleva `--capture-system-keys fullscreen`. `Win+L` no llega, porque
Windows no lo acepta desde un teclado simulado: para bloquear, usa Inicio.

**Salidas fantasma.** El controlador de Apollo deja diez salidas (`DISPLAY5`…`DISPLAY14`) aunque no
haya sesión. `pantalla-hp` solo cuenta las que tienen monitor: si no, creía que había una sesión.

**SSH de Windows, no de WSL.** La orden usa `ssh.exe`, el cliente OpenSSH de Windows, con su propio
`%USERPROFILE%\.ssh\config` y el servicio `ssh-agent`. WSL no hace falta para usarla, solo para el
repositorio si lo tienes ahí. Las órdenes al HP van con `BatchMode` y tiempo límite, como en Fedora. La
primera de cada sesión puede pedir la frase de la clave, y la deja en el agente (`AddKeysToAgent`).

El riesgo aceptado del § 3.9 es el mismo: quien está frente al HP controla el portátil.

### 10.2 Requisitos

- **En el HP**, el § 5 hecho, y además la IP de Windows en su `servidor.env`. Tailscale da a cada
  sistema del portátil su propia IP:

  ```powershell
  # [windows]
  tailscale ip -4
  ```

  ```bash
  # [servidor]
  ./scripts/variables.sh --fijar PANTALLA_EMISOR_WINDOWS_IP=<ip-de-windows>
  source scripts/lib/entorno.sh
  sudo ./scripts/18_pantalla.sh
  sudo ./scripts/18_pantalla.sh --check     # debe decir: Cambios que se aplicarían: 0
  ```

- **En Windows:** Tailscale conectado; el Cliente OpenSSH (*Configuración › Sistema › Características
  opcionales*); la clave del HP en `%USERPROFILE%\.ssh` con un alias en `%USERPROFILE%\.ssh\config`, el
  mismo que `PANTALLA_HP_SSH`. Comprueba que entra:

  ```powershell
  # [windows]
  ssh nomadservernw true; if ($?) { 'CORRECTO' }
  ```

- **Una copia del repositorio** que Windows pueda leer, con su `config/servidor.env`.
  `preparar_windows.ps1` lee de él `TS_IP`, `PANTALLA_HP_SSH` y `PANTALLA_EMISOR_WINDOWS_IP`. Puede
  estar en WSL: Windows la ve en `\\wsl.localhost\<distribución>\home\<usuario>\nomad_server`.
- La contraseña de `sudo` del HP, una vez, para vincular.

### 10.3 Vía A — con los scripts

Apollo se instala a mano (§ 10.4, pasos W1 y W2): es un instalador que se descarga, se comprueba y se
ejecuta como administrador, y su usuario web lo creas tú. Después:

```powershell
# [windows] como administrador — desde la raíz de la copia del repositorio
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\emisor\preparar_windows.ps1 -Check
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\emisor\preparar_windows.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\emisor\preparar_windows.ps1 -Check
```

La última debe decir `Cambios que se aplicarían: 0`. Es idempotente y no pide elevación por su cuenta:
en una consola normal hace lo que no necesita administrador (instalar la orden), deja el resto como
**pendiente** y termina con código 1. Al final comprueba, solo leyendo, que el HP acepta la sesión de
Windows sin contraseña.

Abre una consola **nueva**, para que tome el `PATH`, y vincula:

```powershell
# [windows]
pantalla-hp vincular
```

| Paso manual (§ 10.4) | Lo hace el script |
|---|---|
| W1 — instalar Apollo | **No.** Lo comprueba y para si falta |
| W2 — usuario de la web | **No.** Es una contraseña tuya |
| W3 — ajustes de Apollo | `preparar_windows.ps1`, y reinicia `ApolloService` si cambió algo |
| W4 — cortafuegos | `preparar_windows.ps1`, calculando los rangos a partir de `TS_IP` |
| W5 — agente de SSH | `preparar_windows.ps1` |
| W6 — instalar la orden | `preparar_windows.ps1`: copia comparando SHA-256, para que el BOM llegue intacto |
| W7 — vincular | `pantalla-hp vincular` |

Las pruebas de la orden, con dobles de todo lo que toca el sistema:

```powershell
# [windows]
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\emisor\probar_pantalla_hp.ps1
```

### 10.4 La vía manual

**W1 — Instalar Apollo.** Descarga `Apollo-0.4.6.exe` de las *releases* de `ClassicOldSong/Apollo` en
GitHub y comprueba su huella:

```powershell
# [windows]
(Get-FileHash .\Apollo-0.4.6.exe -Algorithm SHA256).Hash
```

Debe ser `42B2AEFAACB3474511517A56B96EE9F0517F30AC38B5DD2FDA9FD5B478F5021A`. **Si no coincide, no lo
ejecutes.** Si coincide, instálalo como administrador.

**W2 — El usuario de la web.** Abre `https://localhost:47990`, acepta el certificado propio de Apollo y
crea el usuario y la contraseña. No se guardan en el repositorio. Comprueba que en *Applications* existe
`Desktop`.

**W3 — Ajustes de Apollo.**

```powershell
# [windows] como administrador
$dir = 'C:\Program Files\Apollo\config'
Copy-Item "$dir\sunshine.conf" "$dir\sunshine.conf.antes"
Copy-Item "$dir\apps.json" "$dir\apps.json.antes"
notepad "$dir\sunshine.conf"
```

Añade, quitando antes cualquier línea anterior con esos nombres:

```
encoder = quicksync
max_bitrate = 15000
```

```powershell
# [windows] como administrador — la aplicación Desktop
notepad "$dir\apps.json"
```

En el objeto con `"name": "Desktop"`, pon `"virtual-display": true` y `"terminate-on-pause": true`.
Después:

```powershell
# [windows] como administrador
Set-Service ApolloService -StartupType Automatic
Restart-Service ApolloService
```

**W4 — Cortafuegos.** Sustituye las direcciones por las de tu HP: `$hp` es `TS_IP`, y los dos rangos
`$antes` y `$despues` son los vecinos de esa IP, la dirección anterior y la siguiente.

```powershell
# [windows] como administrador
$hp = '100.75.40.17'
$antes = '0.0.0.0-100.75.40.16'
$despues = '100.75.40.18-126.255.255.255'
$exe = 'C:\Program Files\Apollo\sunshine.exe'
$tcp = '47984', '47989', '48010'
$udp = '47998-48000'
$noLocal = '0.0.0.0-126.255.255.255', '128.0.0.0-255.255.255.255'
$noHP = $antes, $despues, '128.0.0.0-255.255.255.255'

Disable-NetFirewallRule -DisplayName 'Apollo'
New-NetFirewallRule -DisplayName 'Nomad Apollo TCP' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $tcp -RemoteAddress $hp -Program $exe
New-NetFirewallRule -DisplayName 'Nomad Apollo UDP' -Direction Inbound -Action Allow -Protocol UDP -LocalPort $udp -RemoteAddress $hp -Program $exe
New-NetFirewallRule -DisplayName 'Nomad Apollo bloquear web' -Direction Inbound -Action Block -Protocol TCP -LocalPort 47990 -RemoteAddress $noLocal
New-NetFirewallRule -DisplayName 'Nomad Apollo solo HP TCP' -Direction Inbound -Action Block -Protocol TCP -LocalPort $tcp -RemoteAddress $noHP
New-NetFirewallRule -DisplayName 'Nomad Apollo solo HP UDP' -Direction Inbound -Action Block -Protocol UDP -LocalPort $udp -RemoteAddress $noHP
```

Los rangos dejan fuera `127.0.0.0/8`, para que la web siga funcionando en `localhost`. Comprueba desde el
HP que la web no responde:

```bash
# [servidor]
timeout 3 bash -c 'exec 3<>/dev/tcp/<ip-de-windows>/47990' && echo "ABIERTO: revisa" || echo "CORRECTO"
```

**W5 — El agente de SSH.** Viene desactivado en Windows:

```powershell
# [windows] como administrador
Set-Service ssh-agent -StartupType Automatic
Start-Service ssh-agent
```

**W6 — Instalar la orden.** Desde la raíz de la copia del repositorio, en una consola normal:

```powershell
# [windows]
$destino = "$env:LOCALAPPDATA\nomad-pantalla"
New-Item -ItemType Directory -Force $destino | Out-Null
Copy-Item .\scripts\emisor\pantalla-hp.ps1 $destino
Set-Content -Encoding ASCII "$destino\pantalla-hp.conf" @(
    'HP_SSH="nomadservernw"'          # PANTALLA_HP_SSH
    'EMISOR_IP="<ip-de-windows>"'     # PANTALLA_EMISOR_WINDOWS_IP
)
Set-Content -Encoding ASCII "$destino\pantalla-hp.cmd" @(
    '@echo off'
    'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0pantalla-hp.ps1" %*'
    'exit /b %ERRORLEVEL%'
)
$ruta = [Environment]::GetEnvironmentVariable('Path', 'User')
[Environment]::SetEnvironmentVariable('Path', "$ruta;$destino", 'User')
```

`pantalla-hp.ps1` se copia tal cual: lleva BOM, y sin él PowerShell 5.1 lee mal los acentos. Abre una
consola nueva.

**W7 — Vincular.** Una vez, y otra si reconstruyes el HP o reinstalas Apollo:

```powershell
# [windows]
pantalla-hp vincular
```

Pide la contraseña de `sudo` del HP, lanza allí `nomad-pantalla-vincular@windows-<PIN>.service` y abre
`https://localhost:47990/pin`. En la pestaña *PIN Pairing* escribe el PIN que muestra y pulsa *Send*:
tienes 90 segundos. El HP guarda los dos vínculos en su `Moonlight.conf`, el de Fedora y el de Windows,
porque las IP son distintas.

**W8 — Sesiones.**

```powershell
# [windows]
pantalla-hp extender
pantalla-hp estado
pantalla-hp off
```

### 10.5 Validación y lo medido

```powershell
# [windows]
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\emisor\preparar_windows.ps1 -Check
pantalla-hp estado
```

Esperado: `Cambios que se aplicarían: 0` y, sin sesión, la interna como única pantalla, `activa=True
principal=True`, y las dos instancias del HP `inactive`.

Medido en el HP real el 2026-11-07:

| Prueba | Resultado |
|---|---|
| `extender` | Dos escritorios, ventanas de uno a otro, buen sonido en el HP y silencio en el portátil |
| `principal` | Interna apagada; con la tapa cerrada no se suspende y los periféricos del HP lo controlan |
| `off` | Interna activa y principal, sin pantalla virtual; el HP en `tty1` |
| Quitar el cable con el Wi-Fi activo | Windows recupera la interna en segundos; el HP vuelve a `tty1` solo |
| Corte total: cable fuera y modo avión | El HP para casi al instante; Windows recupera la interna sin intervenir |
| Suspender el portátil en plena sesión | El HP vuelve a `tty1` a los ~20 s; al despertar, la interna está bien sin `off` |
| Wi-Fi | Fluido durante más de 5 minutos con el tope de 15000 kbps |
| Sesión de 30 minutos con vídeo | 17/17 contenedores sanos en las 29 muestras, sin avisos de Uptime Kuma; CPU libre del HP entre 63 y 82 %; memoria usada estable, entre 2176 y 2235 MB |

### 10.6 Reversión en Windows

```powershell
# [windows]
pantalla-hp off
Remove-Item -Recurse "$env:LOCALAPPDATA\nomad-pantalla"
```

Quita también esa carpeta del `PATH` del usuario (*Variables de entorno*).

```powershell
# [windows] como administrador
'Nomad Apollo TCP', 'Nomad Apollo UDP', 'Nomad Apollo bloquear web',
'Nomad Apollo solo HP TCP', 'Nomad Apollo solo HP UDP' |
    ForEach-Object { Remove-NetFirewallRule -DisplayName $_ }
```

Si vas a dejar Apollo instalado, **no** vuelvas a activar sus reglas `Apollo`: están abiertas a todo.
Desinstálalo desde *Aplicaciones instaladas* si no lo quieres. `ssh-agent` puede quedarse como está.

```bash
# [servidor] — el HP olvida a Windows
./scripts/variables.sh --fijar PANTALLA_EMISOR_WINDOWS_IP=""
source scripts/lib/entorno.sh
sudo ./scripts/18_pantalla.sh
```

El vínculo queda en `Moonlight.conf` del HP, pero sin IP la instancia `windows` no arranca. Fedora no se
ve afectado.

### 10.7 Errores frecuentes en Windows

| Síntoma | Causa | Solución |
|---|---|---|
| `No existe ...\pantalla-hp.conf` | La orden no está instalada | `preparar_windows.ps1` (§ 10.3) o el paso W6 |
| `pantalla-hp` no se reconoce como orden | La consola se abrió antes de cambiar el `PATH` | Abre una consola nueva |
| `Este equipo no tiene la IP ...: ¿Tailscale está conectado?` | Tailscale caído, o la IP de Windows cambió | `tailscale ip -4` y corrige `PANTALLA_EMISOR_WINDOWS_IP` en las dos máquinas |
| `Apollo no está en marcha (servicio ApolloService)` | El servicio está parado | `Start-Service ApolloService` como administrador, o `preparar_windows.ps1` |
| `Ya hay una sesión activa: la pantalla virtual de Apollo existe` | Quedó la pantalla virtual de una sesión anterior | `pantalla-hp off` |
| `... no responde sin preguntas: comprueba con 'ssh-add -l'` | La clave no está en el agente de Windows, o `ssh-agent` está parado | `ssh-add -l`; si falla, `preparar_windows.ps1` (W5) y `ssh-add $HOME\.ssh\nomadservernw` |
| `El sudo de ... no permite arrancar nomad-pantalla@windows.service` | El HP tiene la regla de `sudo` antigua | En el HP: `sudo ./scripts/18_pantalla.sh` |
| `Apollo no ha creado la pantalla virtual en 30 s` | Falta `virtual-display` en `Desktop`, el HP no está vinculado con Windows, o falta su IP en el HP | `preparar_windows.ps1 -Check`; en el HP, `sudo journalctl _UID=$(id -u pantalla) -n 30` |
| En el HP se ve lo mismo que en el portátil | Windows está en «Duplicar», o la interna es la principal | `pantalla-hp off` y `pantalla-hp extender`: la orden fija la disposición |
| Tras parar, el portátil se queda sin barra de tareas | Falta `terminate-on-pause` en `Desktop`: la virtual sigue como principal | Para la aplicación en la web de Apollo, `preparar_windows.ps1` y `pantalla-hp off` |
| `La pantalla interna no ha vuelto` | Windows no aplicó `DisplaySwitch /internal` | `Win+P` y *Solo pantalla de PC* |
| Al cerrar la tapa en modo principal, el HP muestra la pantalla de bloqueo | Windows entra un instante en espera moderna | Es lo previsto: desbloquea desde el HP |
| `Win+L` no bloquea desde el HP | Windows no acepta ese atajo de un teclado simulado | Bloquea desde Inicio |
| La web de Apollo responde desde otro equipo | Falta una regla de bloqueo, o una actualización reactivó las reglas `Apollo` | `preparar_windows.ps1 -Check` lo cuenta como cambio; aplícalo como administrador |
| Un script `.ps1` editado muestra acentos rotos o falla al cargar | Se guardó sin BOM | Guárdalo en UTF-8 **con BOM**. `make check` lo comprueba |

---

## 11. Referencias

- [Sunshine](https://docs.lizardbyte.dev/projects/sunshine/) — emisor, `sunshine.conf` y la API del PIN
- [Apollo](https://github.com/ClassicOldSong/Apollo) — el emisor de Windows, con su pantalla virtual
- [Moonlight Qt](https://github.com/moonlight-stream/moonlight-qt) — el receptor
- [cage](https://github.com/cage-kiosk/cage) — el compositor de una sola aplicación
- [`kscreen-doctor`](https://userbase.kde.org/KScreen) — la disposición de pantallas de KDE
- [`systemd.service(5)`](https://www.freedesktop.org/software/systemd/man/systemd.service.html) — `RuntimeMaxSec`, `ExecStopPost`, `PAMName`
- [`systemd-run(1)`](https://www.freedesktop.org/software/systemd/man/systemd-run.html) — las unidades temporales de `pantalla-hp`
- [05 — Usuarios y acceso SSH](05_usuarios_y_acceso_ssh.md) — la excepción a `NOPASSWD`
- [08 — Tailscale](08_tailscale.md) — la red por la que viaja la sesión
- [16 — Recuperación ante desastres](16_recuperacion_ante_desastres.md) — revincular tras reconstruir
- `docs/superpowers/specs/2026-11-05-pantalla-extendida-design.md` — el diseño y sus mediciones
- `docs/superpowers/specs/2026-11-07-pantalla-windows-design.md` — el diseño de Windows y sus pruebas
