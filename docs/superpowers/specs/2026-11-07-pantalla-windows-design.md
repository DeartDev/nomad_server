# Pantalla extendida en Windows 11 — especificación de diseño

> **Estado: EN CONSTRUCCIÓN.** Tareas 2 a 5 del plan hechas el 2026-11-07: emisor elegido (§ 7), el HP
> elige emisor (§ 8) y validación real en Windows con los criterios 1 a 6 cumplidos (§ 9). **Desde la
> Tarea 3, Fedora no abre sesión** hasta recibir esta rama (regresión de la Tarea 6). Escrito en Fedora el
> 2026-11-07. Se construye desde Windows 11 con WSL2, en una sesión que no conoce la conversación
> anterior: este documento y su plan deben bastar.
> Plan: `docs/superpowers/plans/2026-11-07-pantalla-windows.md`. Antecedentes: el diseño de Fedora
> (`docs/superpowers/specs/2026-11-05-pantalla-extendida-design.md`) y el capítulo 18.

## 1. Qué se quiere y por qué

El panel del HP All-in-One (`nomadservernw`) sirve de pantalla al ThinkPad E14 por la red, sin dejar de
ser servidor. Con Fedora ya funciona. El mismo portátil arranca también Windows 11, y el usuario quiere
lo mismo desde ahí: una orden, dos modos y el sonido por el HP.

Lo decidido por el usuario, igual que en Fedora:

- **Dos modos:** extensor (segundo monitor) y principal (portátil como «CPU», pantalla interna apagada o
  tapa bajada, periféricos conectados al HP).
- **Sonido por el HP.**
- **Red:** cable, Wi-Fi o Tailscale, y el HP siempre sabe adónde conectarse.
- **Uso ocasional.** El HP queda encendido siempre y sigue siendo servidor.
- **Lo importante es que vídeo y sonido sean estables.** La franja inferior de Fedora se aceptó como
  limitación por ese motivo (capítulo 18, § 9). Si aparece aquí, se anota y no se investiga, salvo que
  el usuario lo pida.

## 2. Objetivos, no objetivos y fracasos

**Objetivos:** `pantalla-hp extender|principal|off|estado|vincular` en Windows; el HP elige emisor; todo
documentado en el capítulo 18 con las dos vías; Fedora sigue funcionando igual.

**No objetivos:** Ubuntu (etapa siguiente, aunque el receptor queda preparado); capturadora HDMI;
resolver la franja inferior.

**Sería un fracaso, aunque funcione:**

- Que Fedora deje de funcionar. Está validado y solo se puede volver a probar reiniciando.
- Que el emisor quede escuchando fuera de Tailscale, por ejemplo en una red Wi-Fi ajena.
- Que un corte deje el portátil sin imagen en su pantalla interna, o con la configuración de energía
  cambiada para siempre.
- Que el HP pierda servicios, o que se abra algún puerto en su cortafuegos. El HP es cliente.

## 3. Entorno

| Dato | Valor |
|---|---|
| Portátil | ThinkPad E14, Intel Core i5-1235U, gráfica integrada Intel |
| Windows | 11, con WSL, Tailscale y (según el usuario) Git. IP de Tailscale `100.100.15.46` |
| Fedora | IP de Tailscale `100.113.63.57`, en un SSD externo |
| HP | Celeron J4025, **2 núcleos**, UHD 600. Debian 13. IP de Tailscale `100.75.40.17`, LAN `192.168.1.10` |
| Receptor | `cage` + Xwayland + Moonlight 6.2.0 en `/opt/nomad-pantalla/moonlight`, usuario `pantalla` |
| Conexión | Por Tailscale, MTU 1280, `--packet-size 1024`, HEVC, 1080p60, 40 Mbit/s |

El repositorio es público: se clona por HTTPS sin credenciales, pero publicar exige autenticarse.

## 4. Arquitectura

### 4.1 Receptor: el HP elige emisor

Hoy la IP está fija en `/opt/nomad-pantalla/lanzar.sh`. Se pasa a unidad con instancia, **decisión del
diseñador**, porque Ubuntu será un emisor más:

- `nomad-pantalla@fedora.service` y `nomad-pantalla@windows.service` sustituyen a
  `nomad-pantalla.service`. Se conserva todo lo demás de la unidad.
- `lanzar.sh` recibe el nombre del emisor y lo traduce a una IP. Un nombre desconocido termina con error
  y mensaje claro, sin arrancar Moonlight.
- `PANTALLA_EMISOR_IP` sigue siendo la de Fedora. Se añade `PANTALLA_EMISOR_WINDOWS_IP`.
- La vinculación pasa a `nomad-pantalla-vincular@<emisor>-<pin>.service`.
- El sudoers permite exactamente `start` y `stop` de las dos instancias: cuatro órdenes.

El portátil es uno solo, así que dos emisores a la vez no pueden existir. Sí puede quedar una sesión
huérfana del otro sistema: cada `pantalla-hp` para **las dos** instancias antes de arrancar la suya.

### 4.2 Emisor: Apollo primero, Sunshine como reserva

El diseño de Fedora pide elegir por prueba. **Decisión del diseñador:** se prueba primero Apollo
(`ClassicOldSong/Apollo`), una variante de Sunshine con pantalla virtual propia (SudoVDA) que se crea al
empezar la sesión y se retira al terminar. Eso da gratis buena parte de la limpieza que en Fedora hizo
falta programar. La reserva es Sunshine con un controlador de pantalla virtual aparte y órdenes de
preparación y deshacer.

Criterios, por orden: la pantalla virtual aparece a 1920×1080 y se retira sola; hay sonido en el HP y
silencio en el portátil; se puede hacer el modo principal; el codificador por hardware de Intel funciona
con HEVC.

### 4.3 Orden `pantalla-hp` en Windows

PowerShell (`scripts/emisor/pantalla-hp.ps1`), porque es lo que trae Windows. Misma interfaz que en
Fedora. Se aplican las mismas lecciones:

- Comprobar el resultado real de cada paso, no solo el código de salida.
- `off` y las caídas dejan siempre la pantalla interna activa.
- Aplicar y fijar el modo siempre: Windows, como KDE, puede recordar disposiciones antiguas.
- Las órdenes al HP van por SSH con `BatchMode`, sin contraseña.

### 4.4 Seguridad

- Reglas de entrada del Firewall de Windows limitadas a la IP del HP, `100.75.40.17`. Si el instalador
  crea reglas abiertas, se sustituyen.
- La interfaz web del emisor solo desde `localhost`, con usuario y contraseña propios.
- Sin puertos nuevos en el HP y sin secretos en el repositorio.

## 5. Preguntas que resuelve la construcción

Solo cuentan tras un intento real, y su resultado se escribe en este documento:

1. Si Moonlight guarda los dos vínculos sin perder el de Fedora. Las IP son distintas, pero el HP usa
   un solo certificado de cliente.
2. Cómo se hace el modo principal: `DisplaySwitch.exe`, opciones de pantalla del emisor, o dos
   aplicaciones del emisor.
3. Si el portátil sigue vivo con la tapa cerrada, y cómo restaurar el ajuste al terminar.
4. Si la pantalla de bloqueo y las ventanas de UAC se ven y se controlan desde el HP.
5. Si WSL2 llega al HP por Tailscale, o hay que usar `ssh.exe` por la MTU.

**Respuestas, tras la prueba real de la Tarea 2 (2026-11-07):**

1. **Sí.** Tras vincular con Windows, `Moonlight.conf` tiene dos anfitriones: `E14` (`100.100.15.46`) y
   `Nomad` (`100.113.63.57`), este último intacto.
2. **`DisplaySwitch.exe /external`** («Solo segunda pantalla»): la pantalla interna se apaga y el HP
   muestra el escritorio. No hicieron falta opciones del emisor ni una segunda aplicación.
3. **Sigue vivo sin cambiar nada.** Con la tapa cerrada 5 minutos, 36 muestras cada 10 s desde el HP, sin
   un corte, con imagen fluida. Windows registró la entrada y salida de espera moderna (sucesos 506 y
   507) en el mismo segundo. La acción de la tapa es la predeterminada, «suspender» (1) con corriente y
   batería, y no hubo que tocarla: no hay ajuste que restaurar.
4. **Sí.** La pantalla de bloqueo se ve en el HP y se desbloquea con su teclado; la ventana de UAC se ve
   y se responde con su ratón. El atajo `Win+L` no llega: Windows no lo acepta desde teclado simulado.
   Bloquear desde Inicio o con `LockWorkStation` sí funciona.
5. **WSL2 llega** por Tailscale con `ssh` normal, sin cuelgues ni problemas de MTU. No hace falta
   `ssh.exe`.

## 6. Criterios de aceptación

1. `pantalla-hp extender` da un escritorio extendido a 1920×1080, con ventanas que pasan de una pantalla
   a otra.
2. `pantalla-hp principal` deja el escritorio en el HP y la pantalla interna apagada. Con la tapa
   cerrada, el portátil no se suspende, y los periféricos del HP lo controlan en toda la pantalla.
3. Sonido por el HP y silencio en el portátil.
4. `off` deja el panel en `tty1`, la pantalla interna activa y el ajuste de energía como estaba.
5. Con el portátil sin red, el HP vuelve a `tty1` solo, y Windows recupera la pantalla interna en menos
   de 90 segundos.
6. Una sesión de **30 minutos** con vídeo mantiene 17/17 contenedores sanos y sin avisos de Uptime Kuma.
   El respaldo con sesión ya se probó en Fedora y el receptor es el mismo.
7. `18_pantalla.sh` da `Cambios que se aplicarían: 0` en la segunda ejecución, y pasan
   `verificar_sistema.sh --seccion pantalla` y `make check`.
8. **Regresión de Fedora:** tras reiniciar en Fedora, `pantalla-hp extender` y `off` funcionan, con
   sonido, y su vínculo sigue vivo.

## 7. Resultados de la prueba del emisor (Tarea 2)

**Emisor elegido: Apollo 0.4.6** (`Apollo-0.4.6.exe`, SHA-256 `42b2aefa…f5021a`, comprobada con la que
publica GitHub). Cumple los cuatro criterios del § 4.2, así que no se probó Sunshine:

| Criterio | Resultado |
|---|---|
| Pantalla virtual a 1920×1080 que se retira sola | Sí, con los dos ajustes de la aplicación de abajo |
| Sonido en el HP y silencio en el portátil | Sí |
| Modo principal | Sí, con `DisplaySwitch.exe /external` |
| QuickSync con HEVC | Sí: `h264_qsv` y `hevc_qsv`. AV1 no existe en esta gráfica, y no hace falta |

Windows 11 Pro 26H2 (compilación 26300; el registro dice «Windows 10 Pro», un error conocido de ese
campo), Iris Xe con controlador `32.0.101.7088`, cuenta administradora. Controlador de pantalla virtual
de Apollo: `SudoMaker Virtual Display Adapter` 1.10.9.289.

### 7.1 Ajustes de Apollo que hacen falta

En `C:\Program Files\Apollo\config`. La Tarea 4 debe fijarlos, no suponerlos:

- `sunshine.conf`: `encoder = quicksync`. Apollo no tiene opción de dirección de escucha: escucha en
  `0.0.0.0` y solo IPv4, y la protección queda en manos del cortafuegos.
- `apps.json`, aplicación `Desktop`: `"virtual-display": true` y `"terminate-on-pause": true`.
  - **Sin `virtual-display`**, Apollo transmite la pantalla física y Windows queda en «Duplicar».
  - **Sin `terminate-on-pause`**, al parar la sesión la aplicación solo se pausa y la pantalla virtual
    **sigue siendo la principal, sin que nadie la vea**: el portátil se queda sin barra de tareas. Pasó
    en la prueba y se recuperó parando la aplicación en la web. Con el ajuste, Windows vuelve a la
    pantalla interna en unos 3 s, sin intervenir.

### 7.2 Extender: la pantalla virtual debe ser la principal

Apollo captura la pantalla **principal** («If unset, the primary display is captured»). En «Extender» con
la interna como principal, el HP muestra la interna. Lo que funciona es «Extender» con la virtual como
principal en 0,0 y la interna a su izquierda, en −1920,0. Así hay dos escritorios y las ventanas pasan
de uno a otro; la barra de tareas queda en el HP.

Windows recordó esa disposición en la sesión siguiente sin tocar nada, pero `pantalla-hp extender` debe
aplicarla siempre (§ 4.3). La pantalla virtual fue `\\.\DISPLAY5` en todas las sesiones del día; la
otra vía, fijar ese nombre en «Display Device Id» de Apollo, no se probó porque el número podría
cambiar.

### 7.3 Receptor: capturar las teclas del sistema

Sin `--capture-system-keys`, Moonlight no envía la tecla Win. Con
`--capture-system-keys fullscreen` en `lanzar.sh` funciona. La Tarea 3 debe añadirlo a
`templates/etc/nomad-pantalla-lanzar.sh`. En Fedora no se había probado la tecla Win, y la regresión
de la Tarea 6 debe comprobarla.

### 7.4 Cortafuegos de Windows

El instalador crea dos reglas `Apollo`, TCP y UDP, abiertas a todos los puertos, direcciones y perfiles.
Se desactivaron, sin borrarlas, y se crearon `Nomad Apollo TCP` (47984, 47989, 48010) y `Nomad Apollo UDP`
(47998-48000), solo desde `100.75.40.17`.

**No bastó:** Tailscale instala `Tailscale-In`, que permite toda entrada por su interfaz, que está en
perfil Privado. Desde el HP seguía abierto el 47990. Hicieron falta reglas de **bloqueo**, que en
Windows ganan a las de permitir:

- `Nomad Apollo bloquear web`: TCP 47990 desde todo menos `127.0.0.0/8`.
- `Nomad Apollo solo HP TCP` y `Nomad Apollo solo HP UDP`: los mismos puertos desde todo menos
  `100.75.40.17` y `127.0.0.0/8`.

Resultado desde el HP: 47984, 47989 y 48010 abiertos; 47990 cerrado. La web sigue disponible en
`https://localhost:47990`. No se probó el bloqueo desde otro equipo de la tailnet. `preparar_windows.ps1`
debe crear estas reglas y avisar si una actualización de Apollo vuelve a activar las suyas.

### 7.5 Observaciones sin causa conocida

- **Volumen bajo en el HP** tras unos minutos de sesión: `Master` de ALSA estaba al 69 % (−20 dB),
  aunque la unidad lo pone al 100 % al arrancar (`ExecStartPre`, estado 0). El mezclador se modificó a
  las 16:17:15, con la sesión ya abierta y durante pruebas de teclado. En el HP no hay demonios de
  teclas (`triggerhappy`, `acpid`). Se restauró con `amixer -c PCH sset Master 100%`; no se confirmó
  si el sonido volvió al nivel anterior. Vigilarlo en la Tarea 5.
- Con Windows bloqueado, la combinación `Win+L` tampoco llega; ver § 5, respuesta 4.

### 7.6 Restos de la prueba

- En el HP, `~compass/copias-pantalla-windows/` guarda las copias de `lanzar.sh`, de la unidad de
  vinculación, de `Moonlight.conf` y el registro de la prueba de tapa. `lanzar.sh` y la unidad se
  restauraron desde ahí, y `18_pantalla.sh --check` dio `Cambios que se aplicarían: 0`. La carpeta se
  puede borrar al cerrar la Tarea 3.
- El vínculo con Windows se queda en `Moonlight.conf`: lo usa la Tarea 3.
- En Windows, la sesión de Claude usó una copia portátil de Node en `%LOCALAPPDATA%\nomad-tools` para
  el MCP de Chrome DevTools, porque WSL con red NAT no llega al `localhost` de Windows. No forma parte
  del proyecto.

## 8. Resultado de la Tarea 3 en el HP

`18_pantalla.sh` aplicó 8 cambios: lanzador, `emisor.sh`, `nomad-pantalla@.service`, unidad de vínculo,
límites del usuario y sudoers, y retiró `nomad-pantalla.service` con `daemon-reload`. La segunda ejecución
dio `Cambios que se aplicarían: 0`; `verificar_sistema.sh --seccion pantalla` pasó entera y `sudo -n -l`
lista las cuatro órdenes.

`nomad-pantalla@windows.service` arrancó `lanzar.sh windows` contra `100.100.15.46`: escritorio extendido,
sonido a buen volumen (`Master` al 100 %) y tecla Win, confirmados por el usuario. Al parar, el HP volvió
a `tty1` sin procesos de `pantalla` y Windows a su pantalla interna como única principal.

## 9. Validación real en Windows (Tarea 5)

Hecha el 2026-11-07 desde el E14, con la orden instalada por `preparar_windows.ps1` (la segunda ejecución
dio `Cambios que se aplicarían: 0`) y el vínculo de la Tarea 2, que convive con el de Fedora en
`Moonlight.conf`.

| Prueba | Resultado |
|---|---|
| `extender` (criterios 1, 3 y 4) | Escritorio extendido, ventanas entre pantallas, buen sonido; `off` deja la interna como única principal |
| `principal` (criterio 2) | Interna apagada y escritorio en el HP. Con la tapa cerrada no se suspende y los periféricos del HP lo controlan |
| Quitar el cable con el Wi-Fi activo | Windows recupera la interna en segundos; el HP vuelve a `tty1` solo (tras el arreglo de abajo) |
| Corte total: cable fuera y modo avión | El HP para casi al instante y vuelve a `tty1`; Windows recupera la interna (criterio 5) |
| Suspender el portátil en plena sesión | El HP vuelve a `tty1` a los ~20 s; al despertar, interna activa y principal, sin `off` |
| Wi-Fi, más de 5 minutos | Fluido con el tope de 15000 kbps; sin él, lentitud perceptible pasados unos 5 minutos |
| Sesión de 30 minutos con vídeo (criterio 6) | 17/17 sanos en todas las muestras y sin avisos de Uptime Kuma; ver § 9.4 |

### 9.1 Salidas fantasma de Apollo

El adaptador de Apollo deja diez salidas (`DISPLAY5`…`DISPLAY14`) sin monitor aunque no haya sesión.
`pantalla-hp` las contaba como pantalla virtual y creía que había sesión. Solo cuentan las salidas con
monitor (commit `8dc783a`).

### 9.2 El HP se quedaba en el diálogo de error de Moonlight

Al quitar el cable con el Wi-Fi activo, Windows recuperó la conexión por Wi-Fi y siguió respondiendo al
sondeo del puerto 47989, pero la sesión de Moonlight ya había muerto: el HP se quedó en el diálogo de
error hasta que el usuario lo aceptó con el ratón. En el journal (`journalctl _UID=988`, no `-u`):
`SDL Error (0): Connection terminated: -1`.

Arreglo en `lanzar.sh` (commit `b0d8fdc`): copia la salida de Moonlight al journal y lo cierra en cuanto
escribe `Connection terminated`. Cubre también a Fedora, y no hace falta un vigilante en Windows. Tras
instalarlo con `18_pantalla.sh`, los tres cortes (cable, corte total y suspensión) los cerró esta vía, en
el mismo segundo del aviso; el sondeo no llegó a actuar en ninguno y queda de respaldo. En la suspensión,
los ~20 s son lo que tarda Moonlight en dar la conexión por perdida.

### 9.3 Tope de bitrate fijo

El HP pide `PANTALLA_BITRATE` (40000). Por Wi-Fi se notó lentitud pasados unos 5 minutos. En Fedora el
tope solo se pone con Wi-Fi, al arrancar Sunshine; en Windows Apollo es un servicio y cambiarlo en cada
sesión exigiría administrador, así que `preparar_windows.ps1` fija `max_bitrate = 15000` en
`sunshine.conf` (commit `e2b61c5`). Con él, fluido por Wi-Fi y buena imagen por cable.

### 9.4 Sesión de 30 minutos

Una muestra por minuto en el HP, de 23:28 a 23:56 (29 muestras, sesión activa en todas):

| Medida | Mínimo | Máximo |
|---|---|---|
| CPU libre (`vmstat 5 2`) | 63 % | 82 % |
| Contenedores sanos | 17/17 | 17/17 |
| Memoria usada | 2176 MB | 2235 MB |

Antes de la sesión, el HP estaba al 71 % libre con 2,2 GB usados; tras el `off`, al 95 %. La memoria no
crece durante la sesión. Uptime Kuma no dio ningún aviso (confirmado por el usuario).

### 9.5 Observaciones

- **Tapa cerrada en modo `principal`:** al cerrarla, Windows entra un instante en el modo de espera
  moderno y se bloquea; se desbloquea desde el HP y sigue funcionando. Al abrirla, la interna sigue
  apagada hasta el `off`. Se acepta como está.
- El volumen bajo del § 7.5 no se repitió.
