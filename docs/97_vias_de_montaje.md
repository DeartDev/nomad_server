# 97 — Las dos vías de montaje: con scripts o a mano

> Anexo transversal. El mismo servidor se puede construir clonando este repositorio y ejecutando
> los scripts, o tecleando los comandos capítulo por capítulo. Aquí están las dos rutas completas,
> qué hace exactamente cada script, qué no puede hacer ninguno, y cómo mezclarlas sin perderse.

---

## 1. Para qué sirve este anexo

Los capítulos 00 a 16 están escritos para leerse en orden y explican *por qué* se hace cada cosa.
Este anexo no repite esas explicaciones: es la vista de conjunto que falta cuando ya sabes lo que
quieres y necesitas saber **qué comando toca ahora**.

Sirve sobre todo en tres situaciones:

- **La primera vez**, para decidir con qué vía empezar y no cambiar de idea a mitad.
- **Al reconstruir el servidor** (capítulo [16](16_recuperacion_ante_desastres.md)), cuando ya
  entiendes el diseño y lo que quieres es velocidad y no volver a leerlo todo.
- **Al retomar tras una pausa**, para localizar en qué punto exacto de la secuencia te quedaste.

---

## 2. Comparación

| | Vía A — con scripts | Vía B — a mano |
|---|---|---|
| Tiempo del montaje completo | 3–4 h | 9–12 h |
| Qué aprendes | El diseño, leyendo los capítulos | El diseño **y** los comandos |
| Riesgo de olvidar un paso | Bajo: el script no se distrae | Alto: por eso existen las listas de comprobación |
| Copias de seguridad previas | Automáticas (`.bak-<fecha>`) | Tuyas |
| Validación antes de aplicar | Incluida (`sshd -t`, `nft -c`, `docker compose config`) | Tuya |
| Simulación previa | `--check` en todos | Comparando con `nomad_diff` |
| Idempotencia | Garantizada: repetir no rompe nada | Depende de cómo escribas los comandos |
| Hay que cargar el entorno | **No**: cada script lee `config/servidor.env` | **Sí**, en cada sesión |
| Cuándo conviene | Reconstrucciones, servidores adicionales, prisa | La primera vez, y para depurar |

> **No es una elección excluyente.** Lo habitual y lo más provechoso es hacer la primera vez a mano
> los capítulos que más enseñan (05, 06, 09, 10) y usar los scripts para el resto; y usar la vía A
> entera el día que haya que reconstruir. Los scripts son idempotentes, así que se pueden ejecutar
> **después** de haber hecho los pasos a mano: informarán con `[=]` de todo lo que ya estaba bien y
> corregirán lo que se te haya quedado a medias. Ese uso —el script como verificador— es una de las
> mejores formas de aprovecharlos.

---

## 3. Vía A — montaje con los scripts

### 3.1 Requisitos

- Los capítulos [01](01_unidad_usb_booteable.md), [02](02_validacion_equipo.md) y
  [03](03_instalacion_debian.md) hay que hacerlos igualmente: un instalador de Debian no se
  automatiza desde un sistema que todavía no existe. El capítulo 01 sí tiene script, y el 03 tiene
  la alternativa avanzada del *preseed*.
- `config/servidor.env` relleno, al menos con las variables `[OBLIGATORIA]`.
- Acceso por SSH al servidor recién instalado.

### 3.2 Llevar el repositorio al servidor

Los scripts se ejecutan **en el servidor**, así que el repositorio tiene que estar allí. Hay dos
formas, y ambas terminan igual.

**Si el repositorio está publicado** (la vía recomendada, y la que hace la reconstrucción trivial):

```bash
# [servidor]
sudo apt update && sudo apt install -y git
git clone <url-del-repositorio> ~/nomad_server
cd ~/nomad_server
```

**Si no lo está**, cópialo desde tu equipo:

```bash
# [cliente] — desde la raíz del repositorio
rsync -av --exclude='.git' --exclude='config/servidor.env' --exclude='inventario' \
    ./ <usuario>@<ip-del-servidor>:~/nomad_server/
```

En **los dos casos**, `config/servidor.env` viaja aparte: está en `.gitignore` y nunca se versiona.

```bash
# [cliente]
scp config/servidor.env <usuario>@<ip-del-servidor>:~/nomad_server/config/
```

```bash
# [servidor]
chmod 600 ~/nomad_server/config/servidor.env
cd ~/nomad_server
./scripts/variables.sh --estado
```

Criterio de aceptación: ninguna variable obligatoria aparece como `FALTA` o `SIN CAMBIAR`.

> El repositorio va en `~/nomad_server` y no en `/opt` porque pertenece al administrador, se edita
> como administrador y solo se eleva a root al ejecutar un script concreto. Su ruta aparece en el
> archivo de respaldo del capítulo 14 y en la unidad de systemd, así que conviene no moverlo.

### 3.3 La secuencia completa

En orden. Cada línea con `--check` es opcional pero recomendable la primera vez: enseña exactamente
qué cambiaría sin tocar nada.

```bash
# ---------------------------------------------------------------------------
# [servidor] — capítulo 04: base del sistema
# ---------------------------------------------------------------------------
cd ~/nomad_server
sudo ./scripts/04_base.sh --check
sudo ./scripts/04_base.sh
sudo reboot                       # el script avisa si hace falta
```

```bash
# ---------------------------------------------------------------------------
# [cliente] — capítulo 05: llave SSH (esta parte NO tiene script: es tu equipo)
# ---------------------------------------------------------------------------
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_nomad
ssh-copy-id -i ~/.ssh/id_ed25519_nomad.pub <usuario>@<ip-del-servidor>
ssh -i ~/.ssh/id_ed25519_nomad <usuario>@<ip-del-servidor>   # debe entrar con la llave
```

```bash
# ---------------------------------------------------------------------------
# [servidor] — capítulo 05: endurecer sshd y fail2ban
# ---------------------------------------------------------------------------
sudo ./scripts/05_ssh.sh --check
sudo ./scripts/05_ssh.sh
# y AHORA, sin cerrar esta sesión, comprueba desde otra terminal: ssh nomad
```

```bash
# ---------------------------------------------------------------------------
# [servidor] — capítulo 06: cortafuegos y red
# ---------------------------------------------------------------------------
sudo ./scripts/06_firewall.sh --check
sudo ./scripts/06_firewall.sh --sin-red      # primero solo el cortafuegos
# comprueba el acceso desde otra terminal, y solo entonces:
sudo ./scripts/06_firewall.sh                # ahora sí, la IP estática
```

```bash
# ---------------------------------------------------------------------------
# [servidor] — capítulo 07: endurecimiento
# ---------------------------------------------------------------------------
sudo ./scripts/07_hardening.sh --check
sudo ./scripts/07_hardening.sh
sudo reboot
```

```bash
# ---------------------------------------------------------------------------
# [servidor] — capítulo 08: Tailscale
# ---------------------------------------------------------------------------
sudo ./scripts/08_tailscale.sh
# → abre la URL que imprime y autoriza el nodo en el navegador
# → EN LA CONSOLA WEB: desactiva la caducidad de clave, activa MagicDNS, define las ACL
./scripts/variables.sh --fijar TS_IP="$(tailscale ip -4)"
```

```bash
# ---------------------------------------------------------------------------
# [servidor] — capítulo 09: Docker
# ---------------------------------------------------------------------------
sudo ./scripts/09_docker.sh --check
sudo ./scripts/09_docker.sh
exit                                          # el grupo 'docker' necesita sesión nueva
```

```bash
# ---------------------------------------------------------------------------
# [servidor] — capítulo 10: Traefik   (sin sudo: usa el grupo docker)
# ---------------------------------------------------------------------------
cd ~/nomad_server
./scripts/10_traefik.sh --check
./scripts/10_traefik.sh
```

```bash
# ---------------------------------------------------------------------------
# [servidor] — capítulo 11: túnel de Cloudflare
# ---------------------------------------------------------------------------
# Estos dos pasos necesitan navegador y NO tienen script:
docker run --rm -it -v ~/.cloudflared:/home/nonroot/.cloudflared \
    cloudflare/cloudflared:2026.7.3 tunnel login
docker run --rm -it -v ~/.cloudflared:/home/nonroot/.cloudflared \
    cloudflare/cloudflared:2026.7.3 tunnel create nomad-tunnel
# → anota el UUID que imprime y persístelo:
./scripts/variables.sh --fijar CF_TUNEL_ID=<uuid-que-ha-impreso>

./scripts/11_cloudflared.sh --check
./scripts/11_cloudflared.sh
./scripts/11_cloudflared.sh --ruta prueba     # crea el registro DNS de prueba
```

```bash
# ---------------------------------------------------------------------------
# [servidor] — capítulo 12: primer proyecto
# ---------------------------------------------------------------------------
./scripts/deploy.sh --listar
./scripts/deploy.sh <proyecto> --check
./scripts/deploy.sh <proyecto>
```

```bash
# ---------------------------------------------------------------------------
# [servidor] — capítulo 13: observabilidad
# ---------------------------------------------------------------------------
./scripts/13_observabilidad.sh --check
./scripts/13_observabilidad.sh
# → EN LA INTERFAZ WEB: crear la cuenta de Uptime Kuma, los monitores,
#   el canal de avisos, y PROBAR que el aviso llega
```

```bash
# ---------------------------------------------------------------------------
# [servidor] — capítulo 14: respaldos
# ---------------------------------------------------------------------------
# El formateo del disco USB es destructivo y se hace a mano (capítulo 14 paso 1).
./scripts/variables.sh --fijar RESTIC_USB_UUID=<uuid-de-la-particion>
sudo ./scripts/14_restic.sh --check
sudo ./scripts/14_restic.sh --instalar
sudo ./scripts/14_restic.sh --ahora
sudo ./scripts/14_restic.sh --probar          # LA PRUEBA DE RESTAURACIÓN: obligatoria
```

```bash
# ---------------------------------------------------------------------------
# [servidor] — verificación final
# ---------------------------------------------------------------------------
sudo ./scripts/verificar_sistema.sh
```

Criterio de aceptación: termina con `Todas las comprobaciones han pasado` y código de salida 0.

### 3.4 Lo que ningún script puede hacer

Esta tabla es la parte de este anexo que más conviene leer entera antes de empezar: son los puntos
donde el montaje se detiene esperándote, y varios de ellos no dan error si se olvidan — simplemente
fallan meses después.

| Capítulo | Paso que es tuyo | Por qué no se automatiza | Qué pasa si se olvida |
|---|---|---|---|
| [02](02_validacion_equipo.md) | Comprobación de memoria con memtest86+ | Se ejecuta fuera del sistema operativo | Corrupción silenciosa de datos y respaldos |
| [02](02_validacion_equipo.md) | Rescate de los datos anteriores | Solo tú sabes qué merece la pena | Pérdida irreversible en el capítulo 03 |
| [02](02_validacion_equipo.md) | Configuración de la UEFI | No es accesible desde el sistema operativo | El servidor no vuelve solo tras un corte de luz |
| [03](03_instalacion_debian.md) | La instalación de Debian | El instalador es interactivo (salvo *preseed*) | — |
| [05](05_usuarios_y_acceso_ssh.md) | Generar la llave y copiarla | Ocurre en tu equipo, no en el servidor | El script se niega a seguir: es su salvaguarda |
| [05](05_usuarios_y_acceso_ssh.md) | Comprobar el acceso desde otra terminal | Requiere una segunda sesión que el script no controla | Te quedas fuera del servidor |
| [08](08_tailscale.md) | Autorizar el nodo en el navegador | Requiere iniciar sesión (evitable con `--authkey`) | El nodo no se conecta |
| [08](08_tailscale.md) | **Desactivar la caducidad de clave** | Es un ajuste de la consola web | **A los 180 días pierdes el acceso remoto, sin aviso** |
| [08](08_tailscale.md) | Activar MagicDNS y definir las ACL | Ajustes de la consola web | Sin nombres; tailnet abierta entre todos los dispositivos |
| [11](11_cloudflared_y_dominio.md) | Delegar el dominio a Cloudflare | Se hace en tu registrador | Nada resuelve |
| [11](11_cloudflared_y_dominio.md) | `tunnel login` y `tunnel create` | Requieren navegador | No hay túnel que levantar |
| [11](11_cloudflared_y_dominio.md) | Poner el modo TLS en **Full** | Ajuste de la consola web | El tramo hasta el origen viaja sin cifrar, y la web se ve bien igual |
| [13](13_observabilidad.md) | Cuenta, monitores y avisos de Uptime Kuma | Es una interfaz web con estado propio | No te enteras de las caídas |
| [13](13_observabilidad.md) | **Probar que el aviso llega** | Depende de un servicio externo | Crees que tienes avisos y no los tienes |
| [14](14_respaldos_restic.md) | Formatear el disco USB | Es destructivo, a propósito | — |
| [14](14_respaldos_restic.md) | Escribir la contraseña de restic **y guardarla fuera** | Es un secreto que solo tú custodias | Los respaldos son irrecuperables |
| [14](14_respaldos_restic.md) | La prueba de restauración | La lanza `--probar`, pero interpretarla es tuyo | Un respaldo cuya validez es una suposición |
| [16](16_recuperacion_ante_desastres.md) | Todo el capítulo | Automatizar una recuperación es peligroso | — |

### 3.5 Convenciones comunes a todos los scripts

```bash
./scripts/<script>.sh --help      # qué hace, qué opciones admite, qué NO hace
./scripts/<script>.sh --check     # simula: enseña las diferencias, no toca nada
./scripts/<script>.sh --si        # no pide confirmación (para desatendido)
```

| Propiedad | Qué significa en la práctica |
|---|---|
| **Idempotencia** | Ejecutarlo dos veces deja el sistema igual que ejecutarlo una. La segunda vez informa con `[=]` de lo que ya estaba en su sitio, y termina con **`Cambios aplicados: 0`** |
| **Reinicios condicionados** | Un servicio solo se reinicia o se recarga si su configuración ha cambiado. `apt-get update` solo se ejecuta si cambió la definición de repositorios o falta por instalar algo |
| **`--check` evalúa el estado real** | La simulación consulta las mismas condiciones que la ejecución real. Anunciar una acción que después no se haría convertiría `--check` en una suposición, y haría imposible el criterio de los cero cambios |
| **Copia previa** | Todo archivo del sistema que se modifique se copia antes a `<archivo>.bak-<fecha-hora>` |
| **Validación antes de aplicar** | `sshd -t`, `nft -c`, `docker compose config` y `unattended-upgrade --dry-run` se ejecutan **antes** de reiniciar nada |
| **Carga del entorno** | Cada script lee `config/servidor.env` por su cuenta y aborta si falta una variable obligatoria |
| **Código de salida** | `0` correcto, distinto de `0` fallo. Se pueden encadenar con `&&` |
| **Privilegios** | Los de sistema piden `sudo`; los de Docker (10, 11, 13, `deploy.sh`) se ejecutan **sin** `sudo`, con el grupo `docker` |

> **El criterio de «capítulo terminado» es que su script informe de cero cambios.** No basta con que
> no dé errores: mientras siga proponiendo algo, hay una diferencia entre lo documentado y lo
> instalado, aunque sea inofensiva. Es la comprobación que conviene repetir al final de cada
> capítulo:
>
> ```bash
> sudo ./scripts/NN_*.sh --check 2>&1 | tail -3
> ```
>
> Criterio de aceptación: `Cambios que se aplicarían: 0`.

Prefijos de salida, iguales en todos:

| Prefijo | Significado |
|---|---|
| `[OK]` | Hecho correctamente |
| `[=]` | Ya estaba en el estado deseado; no se ha tocado nada |
| `[INFO]` | Información del progreso |
| `[CHECK]` | Modo simulación: esto es lo que se *haría* |
| `[AVISO]` | Merece tu atención, pero no detiene la ejecución |
| `[ERROR]` | Falló; el script se detiene |

---

## 4. Vía B — montaje a mano

### 4.1 El ritual de cada sesión

**Siempre, antes de pegar el primer comando de un capítulo:**

```bash
# [servidor]
cd ~/nomad_server
source scripts/lib/entorno.sh
```

Sin eso, todos los ejemplos con `${VARIABLE}` se expanden a nada. Es el error número uno de esta
vía, y el capítulo [98](98_variables_y_entorno.md) lo explica en detalle. Hay que repetirlo tras
cada reinicio, en cada terminal nueva y en cada ventana de `tmux`.

Comprobación de que está cargado:

```bash
# [servidor]
echo "hostname=${SERVIDOR_HOSTNAME}  lan=${LAN_CIDR}  datos=${DATOS_RAIZ}"
```

Criterio de aceptación: los tres tienen valor.

### 4.2 Cómo está escrito cada paso manual

A partir del capítulo 04, los pasos que escriben archivos del sistema aparecen de dos formas
seguidas, y las dos producen exactamente lo mismo:

**Forma 1 — el contenido, para leerlo y entenderlo.** Se muestra ya con valores de ejemplo, porque
un archivo lleno de `${LLAVES}` no se puede leer:

```
127.0.0.1       localhost
127.0.1.1       nomad.lan nomad
```

**Forma 2 — el comando que lo escribe con TUS valores**, para no teclear nada:

```bash
# [servidor]
sudo tee /etc/hosts >/dev/null <<EOF
127.0.0.1       localhost
127.0.1.1       ${SERVIDOR_HOSTNAME}.${SERVIDOR_DOMINIO_LOCAL} ${SERVIDOR_HOSTNAME}
EOF
```

Fíjate en que el heredoc va **sin comillas** (`<<EOF`, no `<<'EOF'`): es lo que permite que el shell
sustituya las variables. Ver [98 § 4.1](98_variables_y_entorno.md).

### 4.3 Aplicar una plantilla a mano

Cuando un capítulo diga «el contenido completo está en `templates/…`», el equivalente manual del
script son cuatro comandos:

```bash
# [servidor] — 1. ver el resultado con tus valores
nomad_plantilla etc/nftables.conf
```

```bash
# [servidor] — 2. comparar con lo instalado
nomad_diff etc/nftables.conf /etc/nftables.conf
```

```bash
# [servidor] — 3. copia previa
sudo cp -a /etc/nftables.conf /etc/nftables.conf.bak-$(date +%Y%m%d-%H%M%S)
```

```bash
# [servidor] — 4. instalar
nomad_plantilla etc/nftables.conf | sudo tee /etc/nftables.conf >/dev/null
```

Las plantillas y su destino están listados en [templates/README.md](../templates/README.md).

### 4.4 Lo que tienes que hacer tú y el script haría solo

Si eliges la vía B, estas son las tareas que asumes:

- [ ] Copia previa de todo archivo del sistema que modifiques.
- [ ] Validar la sintaxis **antes** de reiniciar el servicio (`sshd -t`, `nft -c`, `docker compose config`).
- [ ] La red de seguridad del capítulo 06 antes de aplicar el cortafuegos.
- [ ] Comprobar el acceso desde una segunda terminal antes de cerrar la primera.
- [ ] Persistir en `config/servidor.env` cada valor que descubras.
- [ ] Recorrer la sección 7 de cada capítulo, que es la que dice si quedó bien.

Las listas de comprobación de `checklists/` existen exactamente para esto.

---

## 5. Correspondencia capítulo → script

| Capítulo | Script | Pasos que automatiza | Pasos que siguen siendo tuyos |
|---|---|---|---|
| [00](00_planificacion.md) | `make init`, `make check`, `scripts/variables.sh` | Crear y validar la configuración | Decidir los valores, crear las cuentas |
| [01](01_unidad_usb_booteable.md) | `01_crear_usb.sh` | Descargar, verificar firma, escribir, comprobar | Elegir el dispositivo USB |
| [02](02_validacion_equipo.md) | `02_inventario_equipo.sh` | Inventario, SMART, red | memtest86+, rescate de datos, UEFI |
| [03](03_instalacion_debian.md) | — (`templates/preseed.cfg`) | — | La instalación completa |
| [04](04_primer_arranque_y_base.md) | `04_base.sh` | Pasos 4 a 10 | Clonar el repositorio, copiar `servidor.env`, reiniciar |
| [05](05_usuarios_y_acceso_ssh.md) | `05_ssh.sh` | Pasos 5 a 9 | Generar y copiar la llave; comprobar desde otra terminal |
| [06](06_red_y_firewall.md) | `06_firewall.sh` | Pasos 2 a 8 | Confirmar el cambio de IP; anotar `LAN_INTERFAZ` |
| [07](07_endurecimiento_del_sistema.md) | `07_hardening.sh` | Pasos 1 a 7 | Revisar las sugerencias de Lynis |
| [08](08_tailscale.md) | `08_tailscale.sh` | Pasos 1, 2, 6 y 9 | Caducidad de clave, MagicDNS, ACL, anotar `TS_IP` |
| [09](09_docker.md) | `09_docker.sh` | Pasos 1 a 8 | Cerrar sesión para que aplique el grupo `docker` |
| [10](10_traefik.md) | `10_traefik.sh` | Pasos 1 a 6 y 8 | Abrir el panel y reconocerlo |
| [11](11_cloudflared_y_dominio.md) | `11_cloudflared.sh` | Pasos 4, 5, 8 y 10 | Delegar el dominio, `tunnel login`/`create`, modo TLS |
| [12](12_despliegue_de_proyectos.md) | `deploy.sh` | Despliegue, salud y reversión | Escribir el compose y el `.env` del proyecto |
| [13](13_observabilidad.md) | `13_observabilidad.sh` | Pasos 1 a 3 | Cuenta, monitores, avisos y su prueba |
| [14](14_respaldos_restic.md) | `14_restic.sh` | Pasos 2 a 9 y las operaciones diarias | Formatear el disco, la contraseña, leer la prueba |
| [15](15_mantenimiento_y_actualizaciones.md) | `verificar_sistema.sh` | Las comprobaciones | Decidir y aplicar las actualizaciones |
| [16](16_recuperacion_ante_desastres.md) | — | — | Todo: automatizar una recuperación es peligroso |

---

## 6. Errores frecuentes

| Síntoma | Causa | Solución |
|---|---|---|
| Los comandos manuales fallan con argumentos vacíos | Entorno no cargado (vía B) | `source scripts/lib/entorno.sh` |
| Un script aborta con «Variables sin definir» | Falta un valor en `config/servidor.env` | `./scripts/variables.sh --faltan` |
| `./scripts/10_traefik.sh` falla por permisos | Se lanzó con `sudo`, y no debe | Ejecútalo con tu usuario, que está en el grupo `docker` |
| `sudo ./scripts/04_base.sh` no encuentra el repositorio | Se ejecutó desde otro directorio | `cd ~/nomad_server` primero |
| Ejecuté el script después de hacerlo a mano y cambió cosas | Los scripts normalizan la configuración a la del repositorio | Es el comportamiento correcto. Revisa el `--check` antes si quieres ver qué tocará |
| El script dice `[=]` en todo y no hace nada | Ya estaba aplicado | Correcto: eso es la idempotencia |
| Tras `09_docker.sh`, `docker ps` pide permisos | El grupo `docker` no aplica hasta reiniciar sesión | `exit` y vuelve a entrar |
| Cloné el repositorio y no está `config/servidor.env` | Está en `.gitignore` a propósito | Cópialo con `scp` (§ 3.2) |
| No sé qué me falta por hacer | — | `./scripts/verificar_sistema.sh` y `./scripts/variables.sh --faltan` |

---

## 7. Referencias

- Capítulo [98 — Variables, entorno y sesiones](98_variables_y_entorno.md)
- [templates/README.md](../templates/README.md) — todas las plantillas y su destino
- [checklists/reanudar_sesion.md](../checklists/reanudar_sesion.md) — el ritual al volver
- [checklists/post_instalacion.md](../checklists/post_instalacion.md) — validación de extremo a extremo
- [Manual de `make`](https://www.gnu.org/software/make/manual/make.html) — para los atajos del `Makefile`

---

**Anterior:** [16 — Recuperación ante desastres](16_recuperacion_ante_desastres.md) · **Siguiente:** [98 — Variables, entorno y sesiones](98_variables_y_entorno.md)
