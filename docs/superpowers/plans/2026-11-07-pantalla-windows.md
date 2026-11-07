# Pantalla extendida (Windows 11) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Usar el panel del HP como pantalla del ThinkPad también desde Windows 11, con la misma orden `pantalla-hp`, sin romper Fedora.

**Architecture:** El receptor del HP pasa a unidad con instancia (`nomad-pantalla@<emisor>.service`) para elegir emisor. En Windows, Apollo (o Sunshine de reserva) emite y `pantalla-hp.ps1` abre y cierra la sesión por SSH.

**Tech Stack:** bash, systemd, PowerShell 5.1, Apollo o Sunshine, Moonlight 6.2.0, Tailscale, WSL2.

**Spec:** `docs/superpowers/specs/2026-11-07-pantalla-windows-design.md`. Lee también el capítulo `docs/18_pantalla_extendida.md`.

## Global Constraints

- Documentación y mensajes en español. Cada capítulo lleva las 10 secciones y las dos vías de montaje.
- **Clona dentro de WSL2** (`~/nomad_server`, nunca `/mnt/c`): `make check` comprueba permisos 600 y hacen falta los bits de ejecución.
- `make check` y `bash scripts/emisor/probar_pantalla_hp.sh` en verde antes de cada commit.
- Commits locales en una rama `pantalla-windows`. **Sin push ni merge** hasta que el usuario lo pida.
- El usuario ejecuta todo lo que pida contraseña o administrador, en su terminal. Nunca escribir contraseñas en el chat.
- `envsubst` solo sustituye nombres declarados en `config/servidor.env.example`.
- Los `.ps1` van en UTF-8 **con BOM**: PowerShell 5.1 leería mal los acentos. `.gitattributes` ya les fija CRLF.
- Sin puertos nuevos en el HP. Sin secretos en el repositorio, que es público.
- Una limitación solo cuenta como documentada tras un intento real. «No puedo mirar» no es «está mal».
- Las pruebas de `sed` o cambios manuales en `/opt` se revierten, y `18_pantalla.sh --check` debe volver a dar 0.

## Review Focus

- Sesión huérfana de Fedora al arrancar Windows, o al revés: el emisor nuevo debe parar las dos instancias y abrir la suya.
- `sudoers` antiguo con receptor nuevo durante la transición: `pantalla-hp` debe avisar con claridad, no fallar en silencio.
- `pantalla-hp off` con el HP inalcanzable: Windows debe recuperar su pantalla interna igualmente.
- Portátil bloqueado o suspendido en plena sesión: el HP debe cerrar solo y la tapa no debe quedar configurada para siempre.
- Tailscale apagado en Windows: `pantalla-hp` debe detenerse con un mensaje, sin tocar pantallas.

---

## Antes de reiniciar en Fedora

Esto no se puede hacer después. Lo hace el usuario:

- [ ] Publicar `main` con este plan (`git push`).
- [ ] Copiar a un USB `~/.ssh/nomadservernw` y anotar el bloque `Host nomadservernw` de `~/.ssh/config`. Los datos: `HostName 100.75.40.17`, `User compass`, `Port 22`, `IdentitiesOnly yes`. Borrar la clave del USB al acabar.
- [ ] `config/servidor.env` no hace falta en el USB: se copia del HP en la Tarea 1.

En Windows, Claude Code debe correr **dentro de WSL**, en `~/nomad_server`. No tendrá la memoria ni la conversación de Fedora: para empezar, basta pedirle que ejecute este plan. Para publicar desde WSL hará falta `gh auth login` o una clave de GitHub.

### Task 1: Puesto de trabajo en Windows

**Files:** ninguno del repositorio.

- [ ] **Step 1: Clonar en WSL.** `git clone https://github.com/DeartDev/nomad_server.git ~/nomad_server`, y `sudo apt-get install -y make shellcheck gettext-base jq openssh-client`.
Expected: `git ls-files --eol | grep -c 'w/crlf'` da 0 fuera de `.ps1`, `.cmd` y `.bat`.

- [ ] **Step 2: Clave SSH.** Copiar la clave del USB a `~/.ssh/` en WSL y a `%USERPROFILE%\.ssh\` en Windows, con permisos 600 en WSL. La misma entrada `Host nomadservernw` en los dos `config`.

- [ ] **Step 3: Comprobar llegada al HP.** Desde WSL: `ssh nomadservernw hostname`, y `scp nomadservernw:nomad_server/config/servidor.env config/ && chmod 600 config/servidor.env`.
Expected: `nomadservernw`. Si WSL no llega o se cuelga (MTU de Tailscale), usar `ssh.exe` desde WSL y anotarlo (pregunta 5 del diseño).

- [ ] **Step 4: Línea base.** `make check` y `bash scripts/emisor/probar_pantalla_hp.sh`.
Expected: `Todas las comprobaciones han pasado` y `Pasan: 105. Fallan: 0.`

- [ ] **Step 5: Datos de Windows.** `tailscale ip -4` debe dar `100.100.15.46`. Anotar edición de Windows, versión del controlador Intel y si la cuenta es administradora. Sin administrador, parar y avisar al usuario.

### Task 2: Prueba del emisor, sin tocar el repositorio

Prueba desechable para decidir emisor y responder las preguntas del diseño. El receptor se apunta a Windows de forma temporal.

**Files:** al terminar, `docs/superpowers/specs/2026-11-07-pantalla-windows-design.md` (resultados, § 5).

- [ ] **Step 1: Instalar Apollo** desde las publicaciones de `ClassicOldSong/Apollo`, comprobando la suma del archivo si la publica. Lo hace el usuario como administrador. Crear usuario de la interfaz web. Fijar la dirección de escucha a la IP de Tailscale si la opción existe, y el codificador a QuickSync.

- [ ] **Step 2: Cortafuegos.** Revisar reglas con `Get-NetFirewallRule | ? DisplayName -match 'Apollo|Sunshine'`. Dejar la entrada de TCP 47984, 47989, 48010 y UDP 47998-48000 solo desde `100.75.40.17`. El 47990 es la interfaz web: no se abre, solo se usa desde `localhost`.
Expected: desde el HP, `timeout 3 bash -c 'exec 3<>/dev/tcp/100.100.15.46/47989' && echo abierto` dice `abierto`.

- [ ] **Step 3: Apuntar el HP.** En el HP, guardar copia de `/opt/nomad-pantalla/lanzar.sh`, y que el usuario cambie la IP con `sudo sed -i 's/^EMISOR=.*/EMISOR=100.100.15.46/' /opt/nomad-pantalla/lanzar.sh`.

- [ ] **Step 4: Vincular.** El usuario lanza en el HP una vinculación contra Windows con un PIN de 4 cifras, tras cambiar también la IP en la unidad (`sudo sed -i 's/100\.113\.63\.57/100.100.15.46/' /etc/systemd/system/nomad-pantalla-vincular@.service && sudo systemctl daemon-reload`) y con `sudo systemctl start nomad-pantalla-vincular@<pin>.service`, y mete el PIN en la web de Apollo. Antes, guardar copia de `~pantalla/.config/Moonlight Game Streaming Project/Moonlight.conf`.
Expected: vínculo aceptado, y en `Moonlight.conf` hay **dos** anfitriones, con el de Fedora intacto (pregunta 1).

- [ ] **Step 5: Sesión.** `ssh nomadservernw sudo -n systemctl start nomad-pantalla.service`.
Expected: el usuario ve el escritorio en el HP. Anotar: pantalla virtual a 1920×1080 en Windows, sonido en el HP y silencio en el portátil, control, y si la pantalla se retira sola al parar.

- [ ] **Step 6: Modo principal.** Probar, por orden y parando en la primera que funcione: `DisplaySwitch.exe /external` con la sesión abierta; la opción de pantalla del emisor que deje solo la virtual; dos aplicaciones del emisor. Anotar cuál funciona y si Windows se recupera solo al cerrar la sesión.

- [ ] **Step 7: Tapa y bloqueo.** Con sesión abierta, cerrar la tapa 3 minutos y comprobar que sigue. Si suspende, probar `powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0` y `powercfg /setactive SCHEME_CURRENT`, anotando el valor anterior para restaurarlo. Después, bloquear con Win+L y provocar una ventana de UAC.
Expected: se ven y se controlan desde el HP, o queda anotada la limitación.

- [ ] **Step 8: Decidir.** Si Apollo falla en un criterio del diseño (§ 4.2), repetir Steps 1-5 con Sunshine y Virtual Display Driver. Escribir emisor elegido y respuestas en el diseño.

- [ ] **Step 9: Deshacer.** Restaurar `lanzar.sh` y la IP de la unidad de vinculación, y que `sudo bash scripts/18_pantalla.sh --check` dé `Cambios que se aplicarían: 0`.

- [ ] **Step 10: Commit** de los resultados en el diseño, en la rama `pantalla-windows`.

### Task 3: Receptor con elección de emisor

**Files:**
- Rename: `templates/systemd/nomad-pantalla.service` → `templates/systemd/nomad-pantalla@.service`
- Modify: `templates/systemd/nomad-pantalla-vincular@.service`, `templates/etc/nomad-pantalla-lanzar.sh`, `templates/etc/sudoers-nomad-pantalla`, `config/servidor.env.example`, `scripts/18_pantalla.sh`, `scripts/verificar_sistema.sh`, `scripts/emisor/pantalla-hp.sh`, `scripts/emisor/preparar_fedora.sh`, `templates/README.md`
- Create: `templates/etc/nomad-pantalla-emisor.sh`
- Test: `scripts/emisor/probar_pantalla_hp.sh`

**Interfaces:**
- Produces: unidades `nomad-pantalla@fedora.service`, `nomad-pantalla@windows.service`, `nomad-pantalla-vincular@<emisor>-<pin>.service`; `/opt/nomad-pantalla/emisor.sh <nombre>`, que imprime la IP o sale con 1; `/opt/nomad-pantalla/lanzar.sh <emisor>`; variable `PANTALLA_EMISOR_WINDOWS_IP`.

- [ ] **Step 1: Pruebas que fallan** en `probar_pantalla_hp.sh`, siguiendo su estilo de dobles: `pantalla-hp` de Fedora para y arranca `nomad-pantalla@fedora.service`, y para también la instancia `windows`; `emisor.sh fedora` y `emisor.sh windows` dan su IP; `emisor.sh otro` sale con 1 sin imprimir IP; la plantilla del sudoers tiene exactamente cuatro órdenes; el lanzador sin argumento sale con error sin arrancar Moonlight; con un sudoers que no lista la instancia, `pantalla-hp` se detiene diciendo que hay que ejecutar `18_pantalla.sh` en el HP.

- [ ] **Step 2: Ver que fallan.** `bash scripts/emisor/probar_pantalla_hp.sh`.

- [ ] **Step 3: Implementar.**
  - `nomad-pantalla@.service`: `ExecStart=/usr/bin/cage -- /opt/nomad-pantalla/lanzar.sh %i`, y el resto igual.
  - `lanzar.sh`: `EMISOR="$(/opt/nomad-pantalla/emisor.sh "${1:-}")" || exit 1`.
  - Vinculación: `%i` llega como `windows-1234`. Un guion nuevo o el propio `emisor.sh` separa nombre y PIN, y el `Conflicts=` nombra las dos instancias.
  - `PANTALLA_EMISOR_WINDOWS_IP` en la sección 10 de `servidor.env.example`, con sus etiquetas, opcional. `18_pantalla.sh` instala las plantillas, y **retira** `/etc/systemd/system/nomad-pantalla.service`, con `daemon-reload`.
  - `verificar_sistema.sh`: `regla_unica` con las cuatro órdenes, y comprobación de que no se habilita al arranque por cada instancia.
  - `pantalla-hp.sh`: sustituir la unidad en la comprobación de `sudo -n -l` y al parar y arrancar. Si el sudoers no permite la instancia, decir que hay que ejecutar `18_pantalla.sh` en el HP.

- [ ] **Step 4: Verde.** `bash scripts/emisor/probar_pantalla_hp.sh` y `make check`.

- [ ] **Step 5: Aplicar en el HP.** **A partir de aquí, Fedora no abre sesión** hasta recibir esta rama (Tarea 6), porque su `pantalla-hp` usa la unidad antigua. Avisar al usuario antes. Llevar la rama con `git bundle` por SSH y `git pull --ff-only`, sin push. Fijar en el `servidor.env` del HP y en el local `PANTALLA_EMISOR_WINDOWS_IP=100.100.15.46`. El usuario ejecuta `sudo bash scripts/18_pantalla.sh` dos veces.
Expected: la segunda da `Cambios que se aplicarían: 0`; `sudo bash scripts/verificar_sistema.sh --seccion pantalla` pasa; `sudo -n -l` lista las cuatro órdenes.

- [ ] **Step 6: Prueba real.** `ssh nomadservernw sudo -n systemctl start nomad-pantalla@windows.service`, con el emisor en marcha.
Expected: escritorio en el HP. Al parar, `tty1` y sin procesos de `pantalla`.

- [ ] **Step 7: Commit.**

### Task 4: `pantalla-hp` para Windows

**Files:**
- Create: `scripts/emisor/pantalla-hp.ps1`, `scripts/emisor/preparar_windows.ps1`, `scripts/emisor/probar_pantalla_hp.ps1`
- Modify: `scripts/verificar_repositorio.sh`

**Interfaces:**
- Consumes: unidades e instancias de la Tarea 3; emisor y método del modo principal de la Tarea 2.
- Produces: `pantalla-hp extender|principal|off|estado|vincular`, instalado por `preparar_windows.ps1` en `%LOCALAPPDATA%\nomad-pantalla\` y añadido al `PATH` del usuario, con `pantalla-hp.cmd` como envoltorio y `pantalla-hp.conf` (`HP_SSH`, `EMISOR_IP`).

- [ ] **Step 1: Pruebas que fallan** en `probar_pantalla_hp.ps1`. `pantalla-hp.ps1` admite `-Simular`, o funciones sustituibles, para no tocar el equipo, y separa la lógica en funciones. Casos: `extender` para las dos instancias y arranca `windows`; `principal` además aplica el modo y confirma que la interna está apagada; `off` restaura aunque el SSH falle; sin la IP de Tailscale se detiene antes de tocar pantallas; el ajuste de tapa se restaura al valor guardado; un argumento desconocido muestra la ayuda y sale con 2.

- [ ] **Step 2: Ver que fallan.** Desde WSL: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w scripts/emisor/probar_pantalla_hp.ps1)"`.

- [ ] **Step 3: Implementar** las funciones `Test-Requisitos`, `Open-Sesion`, `Set-Modo`, `Close-Sesion`, `Get-Estado`, `Invoke-Vincular`. SSH con `-o BatchMode=yes -o ConnectTimeout=5`. El estado de energía anterior se guarda en `%LOCALAPPDATA%\nomad-pantalla\estado.json`, para que un `off` tras un reinicio aún pueda restaurar.

- [ ] **Step 4: Vigilante.** Si la Tarea 2 mostró que Windows no se recupera solo, o si se cambió la tapa, añadir un proceso oculto que compruebe cada 5 s la conexión con el HP y llame a `Close-Sesion` a los 3 fallos. Si no hace falta, no escribirlo.

- [ ] **Step 5: `preparar_windows.ps1`.** Idempotente, con `-Check`, que imprime `Cambios que se aplicarían: N`. Comprueba: emisor instalado y su servicio, reglas de cortafuegos limitadas al HP, configuración, SSH al HP sin contraseña, y `pantalla-hp` instalado. Lo que exige administrador lo avisa, no lo fuerza.

- [ ] **Step 6: Comprobación del repositorio.** `verificar_repositorio.sh` falla si un `.ps1` no empieza por BOM (`EF BB BF`), y pasa `make check`.

- [ ] **Step 7: Verde** y **commit.**

### Task 5: Validación real en Windows

Con el usuario, que informa de lo que ve. Anotar cifras.

- [ ] **Step 1: Instalar.** `preparar_windows.ps1`, dos veces. Expected: la segunda da 0.
- [ ] **Step 2: Vincular** con `pantalla-hp vincular`, si la Tarea 2 no dejó ya el vínculo. Después comprobar que el de Fedora sigue en `Moonlight.conf`.
- [ ] **Step 3: Extensor.** Criterios 1, 3 y 4.
- [ ] **Step 4: Principal.** Criterio 2, con tapa cerrada y periféricos del HP.
- [ ] **Step 5: Cortes.** Quitar la red al portátil en plena sesión con el usuario presente, y solo desde la bandeja de Windows o el cable. Criterio 5. No apagar Tailscale del HP.
- [ ] **Step 5b: Bloqueo y suspensión.** Suspender el portátil en plena sesión. Expected: el HP vuelve solo a `tty1`, y al despertar la pantalla interna funciona y la tapa está como antes, o se restaura con `pantalla-hp off`.
- [ ] **Step 6: Wi-Fi.** Sesión de 5 minutos sin cable. Si se entrecorta, añadir el tope de 15000 kbps, igual que en Fedora (`max_bitrate`).
- [ ] **Step 7: Sesión de 30 minutos.** Muestra por minuto en el HP de `idle`, contenedores sanos y memoria. Criterio 6. Si `who` muestra a `pantalla` con la sesión abierta, es lo esperado.

### Task 6: Documentación y regresión de Fedora

**Files:**
- Modify: `docs/18_pantalla_extendida.md`, `docs/05_usuarios_y_acceso_ssh.md`, `docs/16_recuperacion_ante_desastres.md`, `README.md`, `docs/superpowers/specs/2026-11-07-pantalla-windows-design.md`

- [ ] **Step 1: Capítulo 18.** Sección de Windows con las dos vías, los nuevos nombres de unidad en todo el capítulo, la tabla de resultados y los errores nuevos. Quitar «No funciona con Windows». Ajustar los capítulos 05 y 16.
- [ ] **Step 2: `make check`** y **commit.**
- [ ] **Step 3: Regresión.** Antes de reiniciar, avisar al usuario de que la sesión de Claude en WSL se corta y dejar escrito el estado. En Fedora, sin push, traer la rama desde el HP (`git fetch nomadservernw:nomad_server pantalla-windows:pantalla-windows && git checkout pantalla-windows`), y ejecutar `pantalla-hp extender`, comprobar imagen y sonido, y `pantalla-hp off`. Criterio 8.
Expected: si falla, volver a la rama y corregir antes de cualquier merge.
- [ ] **Step 4: Cierre.** Actualizar el estado del diseño a `CONSTRUIDO`, commit, y preguntar al usuario por el merge y el push. Después sigue Ubuntu, con su propio plan.
