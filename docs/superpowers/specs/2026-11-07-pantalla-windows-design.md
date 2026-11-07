# Pantalla extendida en Windows 11 — especificación de diseño

> **Estado: DISEÑO, sin construir.** Escrito en Fedora el 2026-11-07. Se construye desde Windows 11 con
> WSL2, en una sesión que no conoce la conversación anterior: este documento y su plan deben bastar.
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
