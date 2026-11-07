# Pantalla extendida en nomadservernw — especificación de diseño

> **Estado: CONSTRUIDO para Fedora, en validación final.** Aplicado en el HP y probado con
> `pantalla-hp` en noviembre de 2026; Windows y Ubuntu no se han probado. Sustituye a la propuesta técnica de
> `docs/new_specs/nomad-server-mw-display-extension-spec.md`, que queda como antecedente.
>
> **Convención de este documento:** las variables que todavía no existen en
> `config/servidor.env.example` se escriben sin llaves (`PANTALLA_HABILITADA`) para que
> `verificar_repositorio.sh` no las marque como huérfanas.

## 1. Intención

El panel integrado del HP (`nomadservernw`) se usa de forma **ocasional** como segunda pantalla del
ThinkPad E14: cuando hacen falta dos pantallas o una más grande para ver vídeo. La función principal
del equipo sigue siendo la de servidor, encendido las 24 horas.

Hay dos modos, y el usuario elige cuál arrancar:

- **Modo extensor:** el HP es un segundo monitor, a la derecha de la pantalla interna. Se trabaja con
  el teclado y el ratón del ThinkPad, o con periféricos conectados al HP.
- **Modo principal:** el HP es la pantalla principal y el portátil solo la «CPU». La pantalla interna
  se apaga o se baja la tapa, y se trabaja con los periféricos del HP.

## 2. Objetivos, no objetivos y antiobjetivos

**Objetivos**

- Escritorio extendido real a 1920×1080, no una copia de la pantalla principal.
- Sonido por los altavoces del HP.
- Arrancar y parar con una sola orden desde el portátil.
- Emisores por orden: Fedora 44 KDE, Windows 11, Ubuntu 24.04.
- Conexión por Tailscale, para que el HP use siempre la misma dirección del portátil, venga este por
  cable o por Wi-Fi. El cable es la ruta recomendada; por Wi-Fi el bitrate se limita solo.

**No objetivos**

- XFCE, LightDM o cualquier escritorio en el HP.
- Inicio automático del receptor con el arranque del HP.
- Que una sesión sobreviva a un cambio de red: al desconectar el cable se corta y se relanza.
- Capturadora HDMI (se reconsiderará en el futuro; el HP tiene USB 3).
- En modo extensor, que el ratón del HP cruce a la pantalla del portátil. Medido: queda limitado a la
  pantalla virtual.
- Juegos con requisitos de latencia.

**Antiobjetivos: esto sería un fracaso aunque la imagen funcione**

- Que abrir o cerrar la pantalla afecte a Docker, SSH, Tailscale o Cloudflare Tunnel.
- Que el reposo del HP bloquee los reinicios de seguridad de `unattended-upgrades`. Con una sesión
  abierta se aplazan, igual que con una sesión SSH: `who` muestra a `pantalla` (decisión del usuario).
- Abrir puertos en el HP o publicar nada hacia internet.
- Que el kiosco dé acceso al HP: desde `cage` no se llega a una consola ni a la cuenta `compass`.
- Dejar al usuario sin imagen: ningún fallo puede mantener la pantalla interna apagada sin una
  restauración automática.

**Riesgo aceptado por el usuario:** durante una sesión, quien esté frente al HP controla el escritorio
del portátil, y desde él podría llegar a `compass` si la clave SSH está cargada. La sesión solo se abre
con el usuario presente.

## 3. Hechos medidos

| Dato | Valor |
|---|---|
| Equipo | HP All-in-One 22-dd2xxx, SKU `693D0LA#ABM` (el spec original decía 22-df) |
| Panel | `eDP-1`, 1920×1080. `HDMI-A-1` es una salida de la GPU, no una entrada |
| Red | HP y ThinkPad a 1 Gbit/s; 1,2 ms entre ambos |
| ThinkPad | `192.168.1.4` reservada en el router para `e8:80:88:26:52:88`; la reserva no cubre Wi-Fi |
| Tailscale | Fedora `100.113.63.57`, Windows `100.100.15.46`. Directo por la LAN, unos 4 ms; MTU 1280 |
| Coste de Tailscale en el HP | `tailscaled` 8 % de media, 13 % máximo; 69,5 % de CPU libre de mediana |
| Modo principal | 60 FPS de decodificación, barra de Plasma en el HP, ratón en toda la pantalla |
| Tapa cerrada | Casi 3 minutos sin suspender, con `systemd-inhibit` |
| Espacio libre | `/` 33 GB, `/var` 11 GB, `/srv` 85 GB |
| Decodificación | `Renderer 'EGL/GLES' with 'VAAPI'`, HEVC, unos 0,6–1,1 ms por fotograma |
| Red durante la sesión | 0 % de fotogramas perdidos, 1 ms |
| CPU del HP | 71–74 % libre de mediana; 31 % en el peor momento. Moonlight: 11–12 % de media, 27 % máximo |
| Memoria de Moonlight | 179 MB como máximo |
| Servidor | 17 de 17 contenedores sanos antes, durante y después |
| FPS | 27–45 en modo extensor y 60 en modo principal, con 60 solicitados; aceptable para el usuario |
| Texto | Legible, mejor con 31 Mbit/s negociados que con 15, pero sin la nitidez de un monitor físico |

## 4. Decisiones y alternativas descartadas

| Decisión | Por qué | Descartado |
|---|---|---|
| Kiosco con `cage` y Moonlight | Solo hace falta el receptor. Evita escritorio y gestor de sesión | XFCE y LightDM: LightDM se activaría solo con `graphical.target` |
| Sunshine + Moonlight | Lleva vídeo, audio y entrada en un solo canal, y sirve también para Windows | `krdp` + FreeRDP: funciona, pero `krdp` no parece enviar audio |
| Monitor virtual con `krfb-virtualmonitor` | Ya está en Fedora y Sunshine lo captura con `capture = kwin` | Captura `kms`: no ve salidas virtuales |
| El HP es cliente | No se toca `nftables`: `verificar_sistema.sh` sigue pasando | Publicar un servicio en el HP |
| El HP conecta por Tailscale | Dirección fija por emisor, idea del usuario, y coste medido bajo | Elegir la IP de LAN según la conexión |
| Dos órdenes de modo | Son usos distintos y el principal apaga una pantalla | Sin selector, descartado por el usuario |
| Usuario `pantalla` sin privilegios | Sin `sudo`, sin `docker`, shell `nologin` | Sesión de `compass` |
| Unidad systemd bajo demanda | Límites de recursos y parada limpia sin tocar el arranque | Inicio automático |
| AppImage extraída en `/opt/nomad-pantalla` | No hay Moonlight en Debian, y Flatpak gastaría `/var` | Flatpak; ejecutar la AppImage con FUSE |

## 5. Arquitectura

```text
ThinkPad 100.113.63.57 (Tailscale)         HP nomadservernw 100.75.40.17
┌───────────────────────────────┐          ┌────────────────────────────────────┐
│ krfb-virtualmonitor           │          │ nomad-pantalla.service             │
│   salida Virtual-hp-pantalla  │          │   usuario pantalla, tty7           │
│ Sunshine (kwin, vaapi, HEVC)  │◀─cliente─│   cage → Xwayland → Moonlight      │
│   solo en su IP de Tailscale  │─vídeo───▶│   VA-API, audio por ALSA           │
└───────────────────────────────┘          └────────────────────────────────────┘
```

La sesión la inicia el HP hacia el portátil, así que el cortafuegos del HP no cambia.

## 6. Componentes

### 6.1 Lado del HP: capítulo 18

Capítulo `docs/18_pantalla_extendida.md` con las 10 secciones obligatorias y las dos vías de montaje,
y script `scripts/18_pantalla.sh`, idempotente y con `--check`. Hace lo siguiente:

- **Paquetes**, con `--no-install-recommends`: `cage`, `xwayland`, `kbd` (trae `chvt`),
  `intel-media-va-driver`, `mesa-va-drivers`, `vainfo`, `libgl1-mesa-dri`, `libegl-mesa0`,
  `alsa-utils`, `libopengl0`, `libfontconfig1`, `libva-x11-2`. Se quita `libfuse2t64`, que deja de
  hacer falta al usar la AppImage extraída.
- **Usuario** `pantalla`, de sistema, con grupos `video`, `render` y `audio`. Si ya existe se le
  añaden los que falten, y se rechaza si pertenece a `sudo`, `docker`, `adm` o `input`.
- **Moonlight**: versión fijada y huella SHA-256 comprobada antes de extraer. Permisos de lectura y
  ejecución para todos: la extracción hereda `700` y `pantalla` no podría ejecutarla.
- **Unidad** `nomad-pantalla.service`, instalada y **sin habilitar**, con esta base probada:
  `User=pantalla`, `PAMName=login`, `TTYPath=/dev/tty7`, `TTYReset=yes`, `TTYVHangup=yes`,
  `StandardInput=tty-fail`, `CollectMode=inactive-or-failed`. Sin `UtmpMode`. `cage` va sin `-s`: el
  antiobjetivo de la § 2 no admite cambiar de consola desde el kiosco, y la recuperación es por SSH.
- **Límites**: `CPUWeight=50` y `MemoryMax=2G` en un añadido de `user-<uid>.slice`
  (`50-nomad-pantalla.conf`), no en la unidad: `PAMName` mueve el cliente a `session-N.scope`, fuera de
  ella. La unidad conserva las dos líneas, que no estorban pero no limitan a Moonlight. Se comprueba
  en la Tarea 7.
- **Panel**: cambia a `tty7` al arrancar y vuelve a `tty1` al terminar por cualquier causa. Antes de
  volver, `ExecStopPost` hace `loginctl terminate-user` de lo que quede del usuario: la parada no alcanza lo que
  está en `session-N.scope`.
- **Unidad de vínculo**: `Conflicts=` y `After=` con `nomad-pantalla.service`, porque comparten
  `tty7` y usuario, y el `terminate-user` de la que para no debe alcanzar a la que arranca.
- **Volumen**: `Master` y `Speaker` al 100 %. Esos controles se suman: al 80 % atenúan unos 25,5 dB.
  Si un control falta, la sesión arranca igual.
- **Lanzador**: `stream <emisor> Desktop --1080 --fps 60 --bitrate 40000 --no-vsync --packet-size 1024
  --display-mode fullscreen --video-decoder hardware --video-codec HEVC --audio-config stereo --absolute-mouse`,
  con `QT_QPA_PLATFORM=xcb`, `SDL_AUDIODRIVER=alsa` y `LIBVA_DRIVER_NAME=iHD`. Sin `--performance-overlay`.
  No hace `exec`: deja Moonlight en segundo plano y lo cierra tras 3 sondeos TCP fallidos seguidos, con
  5 segundos entre ellos, al puerto `47989` del emisor (§ 6.3.1). Termina cuando termina Moonlight.

La AppImage solo trae el plugin Qt `xcb`, por lo que Moonlight corre sobre Xwayland dentro de `cage`.
`moonlight pair` no se llama desde el lanzador: tras vincular se queda abierto esperando un clic.

**Variables nuevas** en `config/servidor.env.example`: `PANTALLA_HABILITADA`, `PANTALLA_USUARIO`,
`PANTALLA_EMISOR_IP`, `PANTALLA_BITRATE`, `PANTALLA_HP_SSH` (el alias con el que el portátil llega al HP
por SSH, que se lee en el `servidor.env` del portátil), `MOONLIGHT_VERSION` y `MOONLIGHT_SHA256`.

**Versión probada:** Moonlight `6.2.0`, `Moonlight-6.2.0-x86_64.AppImage`, SHA-256
`787b0dcbd42ae90620e76fb8d77d7c441ba6473a91c2d7fc3a0fc2466f992437`. Las mediciones de la § 3 y el
`segfault` de la § 9 corresponden a esa versión.

**Identidad del cliente:** Moonlight guarda su certificado y el vínculo en
`/home/pantalla/.config/Moonlight Game Streaming Project/`. El script conserva el usuario y su
directorio personal: recrearlos rompería el vínculo.

### 6.2 Arranque y parada desde el portátil

Una orden `pantalla-hp extender|principal|off|estado|vincular`, en `scripts/emisor/`:

- `extender` y `principal`: crean el monitor virtual, fijan la disposición, arrancan Sunshine y piden
  al HP que arranque la unidad por SSH.
- `off`: restaura la pantalla interna, que es local y aún tiene viva la virtual, y después para la
  unidad del HP, Sunshine y el monitor virtual, y comprueba otra vez que la interna sigue encendida.

**Antes de tocar nada**, `extender`, `principal` y `vincular` cargan la clave en el agente
(`AddKeysToAgent`) y prueban el mismo camino que usarán con las pantallas movidas: `ssh` con `BatchMode`
y `sudo -n -l`. **Pedir una sesión** es `stop` y `start` en una sola llamada, porque `start` sobre una
unidad activa no hace nada.

**Orden obligatorio:** el modo se aplica **antes** de arrancar Sunshine. Al revés, Sunshine calcula el
ratón con la geometría antigua y este solo alcanza media pantalla.

**Disposición explícita:** cada arranque fija ambas pantallas con `kscreen-doctor`. KDE guarda la
disposición de cada pareja de pantallas y la reaplica al reaparecer la virtual; una restauración
descuidada dejó las dos en `0,0` y la pantalla interna sin imagen 20 minutos.

| Modo | Pantalla virtual | Pantalla interna |
|---|---|---|
| `extender` | `1920,0`, prioridad 2 | encendida, `0,0`, prioridad 1 |
| `principal` | `0,0`, prioridad 1 | apagada, prioridad 2 |

**Restauración:** en ambos modos se programa una restauración con `systemd-run --user` antes de crear
el monitor virtual, porque crearlo ya mueve las pantallas, y `extender` aborta si la interna no queda encendida. La restauración mueve la virtual
a `1920,0` antes de encender la interna.

**Tapa:** la sesión mantiene `systemd-inhibit --what=handle-lid-switch:sleep:idle`, que se libera al
terminar, para que el portátil no quede encendido en una mochila. La tapa cerrada se validó en Fedora;
si falla en otro emisor, se documenta usar la tapa abierta sin invalidar el proyecto.

`compass` necesita arrancar y parar la unidad sin contraseña. Se concede con una regla de `sudoers`
limitada a `systemctl start nomad-pantalla.service` y `systemctl stop nomad-pantalla.service`, como
excepción aprobada a la regla «sin `NOPASSWD`» y documentada en el capítulo 05. La frase de la clave
SSH se sigue pidiendo una vez por sesión del portátil.

### 6.3 Lado de Fedora

Documentado en el capítulo 18 y automatizado en `scripts/emisor/`:

- Sunshine del COPR `lizardbyte/stable` e `intel-media-driver` de RPM Fusion. El driver de Fedora no
  trae H.264 ni HEVC, y sin él la codificación iría por CPU.
- `~/.config/sunshine/sunshine.conf`: `capture = kwin`, `encoder = vaapi`,
  `output_name = Virtual-hp-pantalla`, `bind_address = 100.113.63.57`, `upnp = disabled`,
  `vaapi_rc = vbr`, `vaapi_strict_rc_buffer = disabled`.
- Regla de `firewalld` que rechaza el puerto `15905`: `krfb-virtualmonitor` escucha en todas las
  interfaces y no permite limitarlo.
- `/dev/uinput` ya es accesible por `uaccess`: no se añade el usuario al grupo `input`.

El vínculo es un paso único y **documentado, no automático** (decisión del diseñador), con una orden
`pantalla-hp vincular`, que se repite tras una reconstrucción y se recoge en el capítulo 16:

1. El HP lanza `moonlight pair` en una unidad temporal con límite de tiempo, porque tras vincular se
   queda abierto esperando un clic y no debe depender de un ratón en el panel.
2. Sunshine 2026.914 exige `pairing_id`: se obtiene con `GET /api/pin` y se confirma con
   `POST /api/pin`, comprobando que la petición viene del HP.
3. La contraseña del panel de Sunshine se pide en ese momento y no se guarda en el repositorio. El
   usuario del panel se crea antes con `sunshine --creds`: fuera de una sesión Sunshine no corre.

### 6.3.1 Fin de sesión sin `off`

Cada arranque deja en el portátil un vigilante local (decisión del diseñador). Si no hay cliente
conectado durante 60 segundos, o durante 120 en la primera conexión tras arrancar, restaura la pantalla interna y retira el monitor virtual y Sunshine,
para que las ventanas vuelvan a ella. No mantiene ninguna sesión SSH abierta en el HP, porque `who`
la contaría y bloquearía el reinicio automático. Tras un corte, se relanza el modo.

El vigilante lee el registro de Sunshine y toma como fin de sesión tanto `CLIENT DISCONNECTED` como
`Ping Timeout`: en los cortes de cable medidos el primero llegó unos 5 segundos después, y no se
depende de ello.

El vigilante no cubre al HP: si el portátil cae, nadie pide el `stop`. Por eso el lanzador del HP sondea
por TCP el puerto `47989` de Sunshine cada 5 segundos, con conexión acotada, y tras 3 fallos seguidos
cierra Moonlight, con lo que la unidad termina y el panel vuelve a `tty1` (criterio 7). Empieza tras
una espera breve, porque Sunshine puede estar arrancando. Los sondeos salen del HP: el cortafuegos no
cambia.

### 6.4 Comprobación

Nueva sección `verificar_sistema.sh --seccion pantalla`, que se omite si `PANTALLA_HABILITADA` no es
`si`. Comprueba paquetes, que `pantalla` puede ejecutar Moonlight, usuario sin grupos con privilegios,
unidad sin habilitar, que `display-manager` no existe y que `sudoers` tiene esa regla y ninguna más.

Debe distinguir «no puedo mirar» de «está mal»: `compass` no pertenece a `render`, así que `vainfo`
ejecutado por él falla por permisos, no porque falte VA-API.

## 7. Emisores pendientes

**Alcance (decisión del diseñador):** esta construcción termina con Fedora. Windows y Ubuntu son dos
etapas posteriores, con su propio plan y por ese orden, según lo pedido. Una limitación solo cuenta
como documentada tras un intento real. Cómo guarda Moonlight varios vínculos con una misma IP se
resuelve en la etapa de Windows; el `pantalla-hp` de Windows no será bash.

- **Windows 11**: Sunshine o Apollo con su pantalla virtual, mismo receptor del HP. Windows tiene su propia IP de Tailscale,
  `100.100.15.46`, y el HP debe saber a qué emisor conectarse. Hay que elegir entre ambos por prueba.
- **Ubuntu 24.04**: es el más incierto. No se ha demostrado una pantalla virtual capturable por
  Sunshine en GNOME Wayland. El respaldo es `gnome-remote-desktop` en modo `extend` con
  `freerdp3-sdl`, cuyo audio habría que comprobar. Si no se logra, se documenta la limitación.

Cada emisor añade su sección al capítulo 18 y su propia orden `pantalla-hp`. El HP podría necesitar
seleccionar el cliente solo en el caso de Ubuntu.

## 8. Criterios de aceptación

1. Escritorio extendido a 1920×1080 en el panel, con ventanas que pasan de una pantalla a otra.
2. `pantalla-hp extender` y `pantalla-hp principal` funcionan. En principal, la barra de Plasma pasa
   al HP, el ratón del HP alcanza toda la pantalla y la tapa cerrada no suspende el portátil.
3. Sonido audible por el HP tras un reinicio del servidor, sin ajustes manuales.
4. Los modos y `off` funcionan sin pedir contraseña, y `off` deja el panel en `tty1`.
5. Una sesión de **60 minutos** con vídeo y un respaldo de restic en marcha mantiene todos los
   contenedores sanos y sin avisos de Uptime Kuma.
6. Con el receptor cerrado, `who` no muestra a `pantalla` y el reinicio automático puede ocurrir. Con
   una sesión abierta se aplaza a la noche siguiente.
7. Una caída de red, de Sunshine o del portátil termina la unidad y devuelve el panel a `tty1`, y el
   portátil restaura la pantalla interna y retira el monitor virtual antes de 90 segundos.
8. `18_pantalla.sh` informa `Cambios que se aplicarían: 0` en la segunda ejecución,
   `verificar_sistema.sh --seccion pantalla` pasa y `make check` pasa.
9. Fedora cumple todo lo anterior. Windows y Ubuntu se aceptan en sus propias etapas.

## 9. Riesgos abiertos

- **Franja inferior:** detalle pendiente, por decisión del usuario, para el final del proyecto. En el
  panel aparece una franja de unos 150–200 px abajo que se pixela cada 2 segundos, incluso con el
  escritorio quieto. Sigue con HEVC y H.264 y con `cqp`; `vbr` la redujo. Sunshine no emite fotogramas
  completos periódicos, así que esa explicación queda descartada, y su registro no anota nada durante
  una sesión de 69 minutos. Falta revisar la captura y la salida al panel.
- **Wi-Fi:** fluido a unos 11 Mbit/s con el cable fuera toda la sesión. `pantalla-hp` limita Sunshine a
  15 Mbit/s (`max_bitrate`) cuando la salida a la red es Wi-Fi, sin tocar el HP.
- **Corte del cable:** el enlace del ThinkPad cayó 15 segundos a las 21:39 del 2026-11-05 sin causa
  conocida. Si se repite sin tocar el cable, revisar el cable y el puerto del router.
- **Cierre de Moonlight:** al pararlo por tiempo hubo un `segfault` en su hilo de audio. No afectó al
  servidor, pero la unidad debe parar sin dejar el panel bloqueado.
- **FPS por debajo de 60:** aceptado por el usuario. El registro muestra `Atomic commit failed` en
  `eDP-1`, unos 6 por minuto con y sin V-Sync, y quitar V-Sync no mejoró los FPS de forma
  demostrable. La causa sigue sin confirmar; `--no-vsync` se mantiene solo porque fue la última
  configuración probada.
- **`/var` con 11 GB libres:** las imágenes de Docker comparten ese espacio. Este diseño no lo usa.

## 10. Restos de la prueba

El script debe adoptar o reemplazar lo que dejó la prueba manual: `/opt/nomad-pantalla`, el usuario
`pantalla`, los paquetes instalados y el volumen. Al terminar se borra `~compass/pantalla-prueba`. En
el portátil ya existen `~/.config/sunshine`, la regla de `firewalld` y el vínculo `hp-pantalla`.

## 11. Decisiones que quedan al constructor

Orden de pasos internos del script, forma exacta de la regla de `sudoers`, nombres de archivos de
plantilla y división del capítulo, siempre con las convenciones de los capítulos 04 a 17.
