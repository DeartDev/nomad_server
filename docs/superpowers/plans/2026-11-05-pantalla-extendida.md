# Pantalla extendida (Fedora) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convertir el panel del HP en pantalla extendida o principal del ThinkPad con Fedora, con una orden `pantalla-hp`, sin alterar la función de servidor.

**Architecture:** El HP corre un kiosco bajo demanda (`nomad-pantalla.service`: `cage` + Moonlight) que se conecta a Sunshine por la IP de Tailscale del portátil. El portátil crea un monitor virtual, fija la disposición de pantallas y arranca Sunshine con unidades transitorias de `systemd --user`. El capítulo 18 instala el lado del HP con un script idempotente.

**Tech Stack:** bash, systemd, Moonlight 6.2.0 (AppImage extraída), `cage`, Sunshine 2026.914, `krfb-virtualmonitor`, `kscreen-doctor`, Tailscale.

**Spec:** `docs/superpowers/specs/2026-11-05-pantalla-extendida-design.md`

## Global Constraints

- Documentación y mensajes en español. Cada capítulo lleva las 10 secciones y las dos vías de montaje.
- Todo script: cabecera con `Propósito`, `--help`, `--check` sin cambios, `shellcheck -S warning` limpio.
- Un capítulo está terminado cuando su script informa `Cambios que se aplicarían: 0`.
- `envsubst` solo sustituye nombres presentes en `config/servidor.env.example`.
- No tocar `nftables`, Docker, `graphical.target` ni instalar `display-manager`.
- La unidad del HP queda **sin habilitar** y sin `UtmpMode`.
- Moonlight: `6.2.0`, SHA-256 `787b0dcbd42ae90620e76fb8d77d7c441ba6473a91c2d7fc3a0fc2466f992437`.
- `compass` usa `sudo` con contraseña: los pasos con `sudo` en el HP o el portátil los ejecuta el usuario en una terminal real, nunca por `!`.
- Commits solo con permiso del usuario, y terminan con `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. Tailscale caído o `PANTALLA_EMISOR_IP` ausente en el portátil: `pantalla-hp` aborta **antes** de tocar las pantallas.
2. El HP no responde por SSH tras crear el monitor: se restaura la pantalla interna y se informa.
3. Sunshine muere en modo principal: el vigilante restaura la pantalla interna sin intervención.
4. Lanzar un modo con una sesión ya activa: se rechaza sin duplicar monitor ni Sunshine.
5. KDE reaplica una disposición guardada con las pantallas superpuestas: cada arranque la fija, y `extender` aborta si la interna no queda encendida.

---

### Task 1: Variables y plantillas del HP

**Files:**
- Modify: `config/servidor.env.example` (sección nueva tras la 9, `# 10. PANTALLA EXTENDIDA`)
- Create: `templates/systemd/nomad-pantalla.service`
- Create: `templates/systemd/nomad-pantalla-vincular@.service`
- Create: `templates/etc/nomad-pantalla-lanzar.sh`
- Create: `templates/etc/sudoers-nomad-pantalla`

**Interfaces:**
- Produces: variables `PANTALLA_HABILITADA="no"`, `PANTALLA_USUARIO="pantalla"`, `PANTALLA_EMISOR_IP=""`, `PANTALLA_BITRATE="40000"`, `PANTALLA_HP_SSH="nomadservernw"`, `MOONLIGHT_VERSION="6.2.0"`, `MOONLIGHT_SHA256="787b0dcb…2437"` (valor completo), todas con marcador `[CAPITULO: 18]`. `PANTALLA_HP_SSH` no está en el diseño: la necesita el portátil para llegar al HP por cualquier ruta.
- Produces: rutas `/opt/nomad-pantalla/moonlight/AppRun` y `/opt/nomad-pantalla/lanzar.sh`.

- [ ] **Step 1: Declarar las variables** en `servidor.env.example`, con el estilo de la sección 9 y explicando que `PANTALLA_EMISOR_IP` es la IP de Tailscale del emisor.

- [ ] **Step 2: Escribir `nomad-pantalla-lanzar.sh`** (destino `/opt/nomad-pantalla/lanzar.sh`): exporta `QT_QPA_PLATFORM=xcb SDL_AUDIODRIVER=alsa LIBVA_DRIVER_NAME=iHD` y hace `exec` de `AppRun stream ${PANTALLA_EMISOR_IP} Desktop --1080 --fps 60 --bitrate ${PANTALLA_BITRATE} --no-vsync --packet-size 1024 --display-mode fullscreen --video-decoder hardware --video-codec HEVC --audio-config stereo --absolute-mouse`. Sin `pair` ni `--performance-overlay`.

- [ ] **Step 3: Escribir `nomad-pantalla.service`** con `User=${PANTALLA_USUARIO}`, `PAMName=login`, `TTYPath=/dev/tty7`, `TTYReset=yes`, `TTYVHangup=yes`, `StandardInput=tty-fail`, `StandardOutput=journal`, `StandardError=journal`, `WorkingDirectory=/home/${PANTALLA_USUARIO}`, `CPUWeight=50`, `MemoryMax=2G`, `TimeoutStopSec=10`, `Restart=no`, `ExecStartPre=+/usr/bin/chvt 7`, `ExecStartPre=/usr/bin/amixer -q -c 0 sset Master 100% unmute`, `ExecStartPre=/usr/bin/amixer -q -c 0 sset Speaker 100% unmute`, `ExecStart=/usr/bin/cage -s -- /opt/nomad-pantalla/lanzar.sh`, `ExecStopPost=+/usr/bin/chvt 1`. Sin sección `[Install]`: no se puede habilitar por error.

- [ ] **Step 4: Escribir `nomad-pantalla-vincular@.service`**: misma base, `RuntimeMaxSec=90`, y `ExecStart=/usr/bin/cage -s -- /opt/nomad-pantalla/moonlight/AppRun pair ${PANTALLA_EMISOR_IP} --pin %i`, con las variables de entorno Qt del lanzador. El límite de tiempo existe porque `pair` queda abierto tras vincular.

- [ ] **Step 5: Escribir `sudoers-nomad-pantalla`**: `${ADMIN_USUARIO}` con `NOPASSWD` solo para `/usr/bin/systemctl start nomad-pantalla.service` y `/usr/bin/systemctl stop nomad-pantalla.service`.

- [ ] **Step 6: Verificar**

Run: `make check`
Expected: sin fallos de variables huérfanas ni de plantillas.

- [ ] **Step 7: Commit** con mensaje que explique por qué la unidad no lleva `[Install]`.

### Task 2: `scripts/18_pantalla.sh`

**Files:**
- Create: `scripts/18_pantalla.sh`

**Interfaces:**
- Consumes: variables y plantillas de la Task 1; `requerir_root`, `cargar_entorno`, `requerir_variables`, `instalar_paquetes`, `instalar_plantilla`, `marcar_cambio`, `ejecutar`, `resumen_final` de `lib/common.sh`.
- Produces: `18_pantalla.sh --check`, con `Cambios que se aplicarían: 0` en la segunda ejecución.

- [ ] **Step 1: Esqueleto** copiando el flujo de `17_auditoria.sh`: `PANTALLA_HABILITADA != si` termina con `resumen_final` sin hacer nada; exige `PANTALLA_EMISOR_IP`.

- [ ] **Step 2: Paquetes:** `cage intel-media-va-driver mesa-va-drivers vainfo libgl1-mesa-dri libegl-mesa0 alsa-utils libopengl0 libfontconfig1 libva-x11-2`. `libfuse2t64` no se instala; si existe por la prueba, se deja y se documenta su retirada manual.

- [ ] **Step 3: Usuario:** si `PANTALLA_USUARIO` no existe, `useradd --system --create-home --shell /usr/sbin/nologin --groups video,render,audio`. Si existe, **no se recrea** (guarda el vínculo). `die` si pertenece a `sudo`, `docker` o `adm`.

- [ ] **Step 4: Moonlight:** si `/opt/nomad-pantalla/moonlight/.version` no contiene `MOONLIGHT_VERSION`, descargar `Moonlight-${MOONLIGHT_VERSION}-x86_64.AppImage` del release oficial a un directorio temporal, comprobar `sha256sum` contra `MOONLIGHT_SHA256` (`die` si difiere), extraer con `--appimage-extract`, mover a `/opt/nomad-pantalla/moonlight`, `chown -R root:root`, `chmod -R u=rwX,go=rX` y escribir `.version`. La instalación de la prueba no tiene `.version`, así que se reemplaza una vez. En `--check` solo informa.

- [ ] **Step 5: Plantillas:** instalar las de la Task 1. El lanzador con `755 root:root`; las unidades en `/etc/systemd/system/`, con `systemctl daemon-reload` si cambiaron. `sudoers` en `/etc/sudoers.d/nomad-pantalla` con `440 root:root`, validado con `visudo -cf` sobre un temporal **antes** de instalarlo.

- [ ] **Step 6: Salvaguardas finales:** `die` si existe `display-manager.service`; nunca ejecutar `systemctl enable`.

- [ ] **Step 7: Verificar**

Run: `make check-scripts`, y `./scripts/18_pantalla.sh --help`
Expected: `shellcheck limpio: scripts/18_pantalla.sh` y ayuda en español.

- [ ] **Step 8: Commit.**

### Task 3: `verificar_sistema.sh --seccion pantalla`

**Files:**
- Modify: `scripts/verificar_sistema.sh` (función `verificar_pantalla`, `case` de `SECCION`, sección `todo` y `--help`)

**Interfaces:**
- Consumes: variables de la Task 1 y la función `fallo` existente.
- Produces: `verificar_sistema.sh --seccion pantalla`.

- [ ] **Step 1: Implementar `verificar_pantalla()`**, modelada en `verificar_auditoria`: omitir con `log_sinca` si `PANTALLA_HABILITADA` no es `si`. Comprobar: `AppRun` ejecutable para todos, `.version` igual a `MOONLIGHT_VERSION`, `PANTALLA_USUARIO` sin `sudo`/`docker`/`adm`, `systemctl is-enabled nomad-pantalla.service` distinto de `enabled`, sin `display-manager.service`, `sudoers` con las dos reglas exactas.

- [ ] **Step 2: VA-API sin falso negativo.** `vainfo` solo se ejecuta como root (`sudo -u ${PANTALLA_USUARIO}`). Sin privilegios, `log_aviso "No puedo comprobar VA-API sin sudo"`, nunca `fallo`: es «no puedo mirar», no «está mal».

- [ ] **Step 3: Verificar**

Run: `make check-scripts` y `scripts/verificar_sistema.sh --seccion pantalla` con `PANTALLA_HABILITADA="no"`
Expected: limpio, y `PANTALLA_HABILITADA no es 'si'`.

- [ ] **Step 4: Commit.**

### Task 4: `pantalla-hp` con pruebas de orden

**Files:**
- Create: `scripts/emisor/pantalla-hp.sh`
- Create: `scripts/emisor/probar_pantalla_hp.sh`
- Modify: `scripts/verificar_repositorio.sh` (incluir `scripts/emisor/*.sh` en `comprobar_scripts`)

**Interfaces:**
- Consumes: `cargar_entorno`, `PANTALLA_EMISOR_IP`, `PANTALLA_HP_SSH`.
- Produces: `pantalla-hp extender|principal|off|estado|vincular`. Unidades de usuario: `pantalla-hp-monitor`, `pantalla-hp-sunshine`, `pantalla-hp-vigilante`, `pantalla-restaurar`. Constantes `V=Virtual-hp-pantalla`, `I=eDP-1`.

- [ ] **Step 1: Escribir las pruebas que fallan.** `probar_pantalla_hp.sh` crea un directorio con dobles en `PATH` para `kscreen-doctor`, `systemd-run`, `systemctl`, `ssh`, `ip` y `sleep`, que anotan cada llamada en un archivo, y comprueba:

```bash
prueba_principal_fija_pantallas_antes_de_sunshine      # kscreen ...V.position.0,0 antes de pantalla-hp-sunshine
prueba_extender_fija_ambas_pantallas                   # I.enable, V.position.1920,0
prueba_restauracion_se_programa_antes_de_tocar_pantallas
prueba_restauracion_mueve_virtual_antes_de_encender_interna
prueba_sin_ip_tailscale_no_toca_pantallas              # Review Focus 1
prueba_hp_inaccesible_restaura_interna                 # Review Focus 2
prueba_sesion_activa_se_rechaza                        # Review Focus 4
prueba_extender_aborta_si_interna_apagada              # Review Focus 5
prueba_off_para_hp_antes_que_sunshine
prueba_vigilante_restaura_sin_cliente_60s              # Review Focus 3
prueba_vigilante_rearma_restauracion_con_cliente
```

- [ ] **Step 2: Ejecutarlas**

Run: `bash scripts/emisor/probar_pantalla_hp.sh`
Expected: FALLA, porque `pantalla-hp.sh` no existe.

- [ ] **Step 3: Implementar `pantalla-hp.sh`** con estas funciones:

`comprobar_red()`: `ip -4 -br addr` contiene `PANTALLA_EMISOR_IP`, si no `die`. `sesion_activa()`: `systemctl --user is-active pantalla-hp-sunshine`. `disposicion(modo)`: aplica la tabla de la § 6.2 del diseño. `restaurar()`: en una sola llamada `output.$V.position.1920,0 output.$I.enable output.$I.position.0,0 output.$I.priority.1`. `arrancar(modo)`: `comprobar_red`, rechazar sesión activa, `systemd-run --user --unit=pantalla-hp-monitor` con contraseña aleatoria y `--port 15905`, esperar a la salida, programar `pantalla-restaurar` con `--on-active=600`, `disposicion`, arrancar Sunshine con `systemd-inhibit --what=handle-lid-switch:sleep:idle`, lanzar el vigilante y `ssh "$PANTALLA_HP_SSH" sudo -n systemctl start nomad-pantalla.service`. Si el `ssh` falla: `detener`. `detener()`: `ssh ... stop` (sin abortar si falla), parar Sunshine, `restaurar`, parar monitor y timer. `vigilar()`: sondea `~/.config/sunshine/sunshine.log`; sin `CLIENT CONNECTED` activo durante 60 s, llama a `detener`. Mientras haya cliente, rearma `pantalla-restaurar` cada minuto: así una sesión larga no se corta, y si el vigilante muere la pantalla interna vuelve en 10 minutos. No abre SSH salvo el `stop`. `vincular()`: genera PIN de 4 dígitos, pide la contraseña del panel de Sunshine sin eco, arranca la pila en `extender`, ejecuta `ssh -t` con `sudo systemctl start nomad-pantalla-vincular@$PIN.service`, obtiene `pairing_id` con `GET /api/pin`, exige que `address` sea `TS_IP` y confirma con `POST /api/pin`.

- [ ] **Step 4: Ejecutar las pruebas**

Run: `bash scripts/emisor/probar_pantalla_hp.sh && make check-scripts`
Expected: todas pasan y `shellcheck limpio`.

- [ ] **Step 5: Commit** explicando por qué el modo se aplica antes de Sunshine.

### Task 5: Preparación de Fedora

**Files:**
- Create: `scripts/emisor/preparar_fedora.sh`

**Interfaces:**
- Consumes: `PANTALLA_EMISOR_IP`.
- Produces: `~/.config/sunshine/sunshine.conf`, regla de `firewalld`, enlace `~/.local/bin/pantalla-hp`.

- [ ] **Step 1: Implementar**, idempotente y con `--check`: comprobar Fedora con KDE, `dnf copr enable lizardbyte/stable` e instalar `Sunshine intel-media-driver`; escribir `capture = kwin`, `encoder = vaapi`, `output_name = Virtual-hp-pantalla`, `bind_address = ${PANTALLA_EMISOR_IP}`, `upnp = disabled`, `vaapi_rc = vbr`, `vaapi_strict_rc_buffer = disabled`; regla permanente `rule port port="15905" protocol="tcp" reject` en la zona por defecto; enlace simbólico a `pantalla-hp.sh`. No añadir el usuario al grupo `input`.

- [ ] **Step 2: Comprobar `vainfo`:** `die` si no aparece `VAProfileHEVCMain` con `VAEntrypointEncSlice`, porque sin él se codifica por CPU.

- [ ] **Step 3: Verificar en el portátil**

Run: `scripts/emisor/preparar_fedora.sh --check`
Expected: `Cambios que se aplicarían: 0`, ya que la prueba manual dejó todo aplicado.

- [ ] **Step 4: Commit.**

### Task 6: Documentación

**Files:**
- Create: `docs/18_pantalla_extendida.md`
- Modify: `docs/05_usuarios_y_acceso_ssh.md:145` (excepción a `NOPASSWD`)
- Modify: `docs/16_recuperacion_ante_desastres.md` (revincular tras reconstruir, Escenario E)
- Modify: `README.md:183` y `README.md:299`, `templates/README.md`
- Modify: `docs/superpowers/specs/2026-11-05-pantalla-extendida-design.md` (`PANTALLA_HP_SSH`)

- [ ] **Step 1: Escribir el capítulo 18** siguiendo `docs/17_auditoria_del_servidor.md`: las 10 secciones, las dos vías y las tablas de variables. La § 3 recoge las decisiones del diseño; la § 5 cubre HP, Fedora y vínculo; la § 9 recoge: ratón a media pantalla, pantalla negra por disposición guardada, panel sin barra en modo extensor (añadir uno en Plasma), `moonlight pair` que queda abierto, y la franja inferior pendiente.

- [ ] **Step 2: Capítulo 05:** bajo la decisión de la línea 145, documentar la excepción limitada y por qué es aceptable.

- [ ] **Step 3: Capítulo 16 y README:** añadir `pantalla-hp vincular` a la reconstrucción, enlazar el capítulo y subir `01…17` a `01…18`.

- [ ] **Step 4: Verificar**

Run: `make check`
Expected: sin fallos de plantilla, variables ni enlaces.

- [ ] **Step 5: Commit.**

### Task 7: Aplicación y aceptación en el servidor

**Files:**
- Modify: `docs/superpowers/specs/2026-11-05-pantalla-extendida-design.md` (resultados)
- Modify: `docs/18_pantalla_extendida.md` (lo que aparezca)

Pasos con `sudo`: los ejecuta el usuario en una terminal real. Método acordado: `--check`, revisar, aplicar, `--check`.

- [ ] **Step 1: Aplicar.** En el HP, `git pull`, `./scripts/variables.sh --fijar PANTALLA_HABILITADA=si`, `./scripts/variables.sh --fijar PANTALLA_EMISOR_IP=100.113.63.57`, `sudo ./scripts/18_pantalla.sh --check`, aplicar y repetir. En el portátil, además: `PANTALLA_EMISOR_IP`, `PANTALLA_HABILITADA` y el resto de `PANTALLA_*` en su propio `config/servidor.env` (el archivo no viaja por git), y ejecutar `scripts/emisor/preparar_fedora.sh` **sin** `--check`.
Expected: `Cambios que se aplicarían: 0`, y `verificar_sistema.sh --seccion pantalla` y `--seccion seguridad` pasan.

- [ ] **Step 2: Vínculo.** Comprobar que el vínculo con `hp-pantalla` sobrevivió. Si no, `pantalla-hp vincular`.

- [ ] **Step 2b: Comprobaciones tempranas.** Parten de suposiciones que las pruebas con dobles no pueden confirmar. Con el usuario creado:
  - `id pantalla`: el grupo propio, `video`, `render` y `audio`, y nada más.
  - `stat -c '%a %U' /home/pantalla`: el modo real del directorio que guarda el vínculo. Si lo leen otros usuarios, corregirlo y documentarlo.
  - `apt-cache depends cage`: qué trae con `--no-install-recommends`, y si `xwayland` es dependencia o recomendación.
  - Desde el portátil, `ssh -o BatchMode=yes <alias> sudo -n -l /usr/bin/systemctl start nomad-pantalla.service`: devuelve 0 con la clave en el agente y sin pedir contraseña.

  Con una sesión abierta (`pantalla-hp extender`), en el HP:
  - `who` y `users`, y `ldd /usr/bin/who | grep systemd`: si `who` está enlazado con systemd lee las sesiones de logind, no utmp, y podría mostrar a `pantalla`. Decide el criterio 6 y lo que el capítulo afirma en § 3.8.
  - `cat /proc/$(pgrep -u pantalla -f moonlight | head -n 1)/cgroup`: debe decir `session-N.scope` dentro de `user-<uid>.slice`. Si dice `nomad-pantalla.service`, lo que limita es la unidad, y el añadido sobra: corregir § 3.5 y el diseño.
  - `systemctl show user-$(id -u pantalla).slice -p CPUWeight -p MemoryMax` y `cat /sys/fs/cgroup/user.slice/user-$(id -u pantalla).slice/memory.max`: los límites se aplican de verdad.
  - `sudo chvt 1`, `sudo fgconsole` y `sudo chvt 7`: `chvt` funciona como root con `cage` sin `-s`, igual que lo usan `ExecStartPre` y `ExecStopPost`.

  Tras `pantalla-hp off`, en el HP:
  - `pgrep -u pantalla`: sin salida. El `pkill` de `ExecStopPost` no deja nada.
  - `sudo fgconsole`: `1`.
  - `systemctl --failed`: `pkill` también alcanza a `user@<uid>.service` si sigue vivo. Si aparece como fallida, ajustar el `pkill` o la unidad, y repasar `verificar_sistema.sh`.

- [ ] **Step 3: Modos.** `pantalla-hp extender`, `off`, `pantalla-hp principal` con tapa cerrada, `off`.
Expected: sin contraseña salvo la clave SSH; criterios 1, 2 y 4 del diseño. Con los periféricos del HP, comprobar que desde el kiosco no se llega a un shell: `cage` va sin `-s`, así que `Ctrl+Alt+F1` no debe cambiar de consola, y `tty1` debe pedir usuario y contraseña. Medir también con `kscreen-doctor -o` cómo aparece una salida deshabilitada (la interna en `principal`), y que `output.<interna>.priority.2` junto con `output.<interna>.disable` en una sola llamada se aplican las dos.

- [ ] **Step 4: Sonido tras reinicio.** `sudo reboot` del HP y una sesión.
Expected: criterio 3.

- [ ] **Step 5: Fallos.** Durante una sesión en modo principal, desconectar el cable; en otra, `pkill -x sunshine`; y en otra, cortar el HP a mitad de sesión en `principal` (por ejemplo, `sudo systemctl stop nomad-pantalla.service` en el HP desde otra máquina), con un camino de vuelta disponible: otra máquina con SSH al portátil para ejecutar `pantalla-hp off`, o el portátil con la tapa abierta para ver qué pasa.
Expected: criterio 7, antes de 90 segundos. Anotar si el corte de 15 s del cable reaparece. En el corte de cable, y apagando el portátil de golpe, la unidad del HP debe terminar sola: `journalctl -u nomad-pantalla.service` dice `Sin respuesta de` y `sudo fgconsole` dice `1`. Comprobar también que un sondeo de `lanzar.sh` a `47989` no aparece como cliente en el registro de Sunshine.

- [ ] **Step 6: Wi-Fi.** Sin cable durante toda la sesión, con `PANTALLA_BITRATE=15000`, dos minutos de vídeo.
Expected: anotar FPS, latencia y pérdida. Si va mal con `vaapi_rc = vbr`, comparar con el valor automático y documentar el perfil Wi-Fi.

- [ ] **Step 7: Sesión larga.** 60 minutos con vídeo, lanzando `sudo systemctl start nomad-respaldo.service` a mitad.
Expected: criterio 5, y `who` sin `pantalla` (criterio 6).

- [x] **Step 8: Limpiar.** Borrar `~compass/pantalla-prueba` en el HP tras revisarlo.

- [ ] **Step 9: Franja inferior.** Investigarla ahora, con el resto cerrado: captura de `Virtual-hp-pantalla` en el portátil para separar el emisor del receptor, y errores `Atomic commit failed` en el HP. Documentar la causa o la limitación.

- [ ] **Step 10: Commit** de resultados y actualizar la memoria del proyecto.
