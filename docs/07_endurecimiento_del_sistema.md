# 07 — Endurecimiento del sistema

> Que el servidor se parchee solo, que los registros no llenen el disco, y que la superficie de
> ataque del host se reduzca a lo imprescindible — sin romper Docker, que es lo que hacen la mitad
> de las guías de endurecimiento.

---

## 1. Objetivo

Al terminar, el servidor instalará por su cuenta los parches de seguridad y se reiniciará si hace
falta, el registro tendrá un techo de espacio, los parámetros del kernel estarán ajustados, AppArmor
estará confinando servicios y tendrás una auditoría de referencia con la que comparar en el futuro.

---

## 2. Requisitos previos

**Capítulos previos:** [06 — Red y cortafuegos](06_red_y_firewall.md), con salida a internet
verificada.

**Necesitas a mano:**

- Acceso por SSH con llave.
- Que el capítulo 06 esté validado: las actualizaciones automáticas necesitan red estable.

**Preparar la sesión.**

```bash
# [servidor]
cd ~/nomad_server
source scripts/lib/entorno.sh
```

Este capítulo es el único que **no consume ninguna variable de `config/servidor.env`**: todos sus
ajustes son independientes de tu red y de tu dominio. Aun así conviene cargar el entorno, por dos
motivos: los ayudantes `nomad_plantilla` y `nomad_diff` sí hacen falta para aplicar las plantillas,
y el resumen que imprime confirma que estás en el servidor correcto.

> Este capítulo se hace **antes** de instalar Docker a propósito: así el sistema base queda cerrado
> antes de añadir un servicio que se comunica con internet y ejecuta código de terceros.

**Tiempo estimado:** 40 minutos, más 10 de auditoría.

---

## 3. Decisiones y por qué

### 3.1 Actualizaciones automáticas con reinicio a las 4:00

**Decisión: `unattended-upgrades` para seguridad y correcciones puntuales, con reinicio automático
en horario nocturno cuando sea necesario.**

En un servidor doméstico nadie revisa los boletines de seguridad. La alternativa realista a las
actualizaciones automáticas no es «actualizar a mano con criterio»: es «no actualizar en tres
meses».

| Aspecto | Decisión | Por qué |
|---|---|---|
| Qué se actualiza | Solo `-security` y `-updates` | No se salta de versión ni se tocan repositorios de terceros |
| Reinicio automático | **Sí**, a las 04:00 | Un parche de kernel instalado y sin reiniciar no protege de nada |
| Si hay alguien conectado | **No reinicia** | Si estás trabajando, decides tú |
| Kernels antiguos | Se eliminan solos | Sin esto, `/boot` se llena y la siguiente actualización falla |

**Sobre el reinicio automático.** Es la decisión más discutible del capítulo, y conviene entender
qué implica: los servicios se caen durante un minuto de madrugada. Como todos los contenedores
llevan `restart: unless-stopped` (capítulo 09), vuelven solos. Y como la UEFI está configurada para
encender tras un corte de luz (capítulo 02), el servidor ya está preparado para volver por su
cuenta.

Si prefieres decidir tú cada reinicio, pon `Automatic-Reboot "false"` y vigila
`/var/run/reboot-required` en la rutina del capítulo 15. Es una elección legítima siempre que la
revisión sea real.

**La configuración va en un archivo propio**, `52-nomad-unattended`, y no editando
`50unattended-upgrades`: el número mayor gana, y una actualización del paquete no pisará nuestros
ajustes.

### 3.2 Límites al registro

**Decisión: `journald` con techo de 500 MB y retención de un mes.**

Por omisión `journald` usa hasta el 10 % de `/var`, que en este servidor son varios gigabytes de
registros que nadie va a leer. Y `/var` es justo donde viven las imágenes y volúmenes de Docker: el
espacio que se lleva el registro se lo quita a lo que importa.

Se mantiene `Storage=persistent` a propósito. Sin registro persistente, un reinicio inesperado se
lleva justo el registro que explicaría por qué ocurrió.

Se añade también un limitador de ráfagas: un contenedor en bucle de error puede escribir cientos de
miles de líneas por minuto y llenar el disco en horas.

### 3.3 Parámetros del kernel: lo que NO se toca

**Decisión: endurecer red y kernel, pero dejar `net.ipv4.ip_forward` en paz.**

Esta es la trampa principal de este capítulo. Casi todas las guías de endurecimiento incluyen:

```
net.ipv4.ip_forward = 0
```

con el razonamiento de que «este equipo no es un router». **Docker sí necesita reenvío de
paquetes**: sin él, ningún contenedor tiene red. El síntoma es especialmente desconcertante —los
contenedores arrancan bien, pero no resuelven nombres ni salen a internet— y no apunta ni al
cortafuegos ni al kernel.

Docker activa `ip_forward` por su cuenta al arrancar. Lo único que hay que hacer es no estorbar.
Tampoco se tocan los parámetros `net.bridge.*`, que Docker gestiona.

Lo que sí se ajusta:

| Grupo | Qué consigue |
|---|---|
| `rp_filter`, `accept_source_route`, `accept_redirects` | Que nadie manipule el encaminamiento con paquetes falsificados |
| `tcp_syncookies`, `tcp_max_syn_backlog` | Resistencia a inundación de conexiones |
| `kptr_restrict`, `dmesg_restrict`, `yama.ptrace_scope` | Ocultar información del kernel que se usa como base para escalar privilegios |
| `protected_hardlinks`, `protected_symlinks`, `protected_fifos` | Cortar una familia clásica de ataques en directorios compartidos |
| `swappiness = 10` | Con SSD y RAM suficiente, evitar swap innecesaria |
| `max_map_count = 262144` | Algunos contenedores (bases de datos, buscadores) no arrancan con el valor por omisión |

### 3.4 AppArmor: comprobar, no instalar

**Decisión: verificar que AppArmor está activo, que es lo normal en Debian.**

Debian activa AppArmor por omisión desde la versión 10. No hay que instalarlo ni configurarlo: hay
que **comprobar** que sigue activo, porque es exactamente el tipo de cosa que alguien desactiva
para depurar un problema y se olvida de volver a activar.

Docker se integra con AppArmor automáticamente: aplica el perfil `docker-default` a cada contenedor,
que limita las operaciones privilegiadas que puede hacer un proceso dentro.

Se descarta SELinux: Debian no lo usa y activarlo implicaría reetiquetar el sistema entero y
depurar denegaciones durante semanas.

### 3.5 Lynis como línea de base medible

**Decisión: ejecutar `lynis audit system` y guardar el resultado.**

El valor de Lynis no es su puntuación —que se puede inflar aplicando ajustes sin entenderlos— sino
tener **una referencia con fecha**. Dentro de seis meses, volver a ejecutarlo y comparar responde a
la pregunta «¿ha empeorado algo sin que me diera cuenta?».

Sus sugerencias se revisan, no se aplican en bloque: muchas asumen un servidor con servicios
instalados en el host y no aplican a un sistema donde todo va en contenedores.

### 3.6 Lo que se decide NO hacer

Igual de importante que lo que se activa:

| Medida habitual | Por qué no |
|---|---|
| Cambiar el puerto SSH | Ya justificado en el capítulo 05 § 3.5 |
| `auditd` | Genera un volumen enorme de eventos que nadie va a revisar. Sin alguien que los lea, es coste sin beneficio |
| Cortafuegos de salida restrictivo | Ya justificado en el capítulo 06 § 3.7 |
| Deshabilitar IPv6 por completo | Rompe conectividad de Tailscale y de algunos registros de imágenes. El cortafuegos ya cubre IPv6 con la familia `inet` |
| Endurecer `/tmp` con `noexec` | Debian 13 ya monta `/tmp` en memoria. Añadir `noexec` rompe instaladores de paquetes que se descomprimen ahí |
| Antivirus (ClamAV) | En un servidor Linux sin correo ni compartición de archivos, consume RAM sin aportar |

---

## 4. Variables usadas

### 4.1 De `config/servidor.env`

**Ninguna.** Es el único capítulo del que se puede decir eso: los límites del registro, los
parámetros del kernel y la política de actualizaciones son idénticos en cualquier servidor. El
script sí carga la configuración, pero solo para las comprobaciones previas comunes a todos
(`requerir_root`, `requerir_debian`).

Se referencia `${SSH_PUERTO}` en el paso 6 al revisar qué está escuchando; para que ese comando
funcione al pegarlo, carga el entorno como indica la sección 2.

### 4.2 Variables que NO son tuyas y no hay que sustituir

Este capítulo contiene el ejemplo más claro de todo el repositorio de un `${…}` que **pertenece a
otro programa**:

```
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
```

`${distro_codename}` es una variable **de APT**, no del shell ni de este repositorio. APT la
sustituye por `trixie` al leer el archivo, y por `forky` cuando subas de versión mayor. Si la
expandes tú al escribir el archivo, la configuración quedará atada a `trixie` para siempre y dejará
de aplicar parches el día que actualices.

Cómo se garantiza que no se expanda:

| Vía | Mecanismo |
|---|---|
| Con la plantilla (`nomad_plantilla`) | `envsubst` recibe solo la lista de variables en MAYÚSCULAS; `distro_codename` va en minúscula y no se toca |
| A mano con heredoc | Se usa `<<'EOF'` **con comillas**, que impide toda expansión |
| Con un editor | No expande nada; se escribe literalmente |

Es el caso inverso al de los capítulos 04 a 06, donde el heredoc iba sin comillas precisamente para
que sí se expandiera. La regla general está en el anexo
[98 § 4.1 y § 4.4](98_variables_y_entorno.md).

### 4.3 Variables temporales de esta sesión

Ninguna.

---

## 5. Procedimiento

### Paso 0 — Prepara la sesión

```bash
# [servidor]
cd ~/nomad_server
source scripts/lib/entorno.sh
```

Comprobación de que el capítulo anterior sigue en pie, porque las actualizaciones automáticas
necesitan red y el resto del capítulo da por hecho el cortafuegos:

```bash
# [servidor]
getent hosts deb.debian.org >/dev/null && echo "DNS OK"
sudo nft list chain inet nomad_filter entrada | grep -c 'policy drop'
```

Criterio de aceptación: `DNS OK` y `1`.

### Paso 1 — Actualizaciones automáticas

```bash
# [servidor]
sudo apt install -y unattended-upgrades apt-listchanges
```

**Así queda el archivo:**

```
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-updates";
};

Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";

Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";

Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::SyslogEnable "true";
```

> **`${distro_codename}` NO es una variable de este repositorio: es de APT.** Déjala literal. APT la
> sustituye por `trixie` al leer el archivo, y por `forky` el día que subas de versión mayor, de
> modo que la configuración sigue siendo correcta sin tocarla. Si la expandieras tú, la política de
> actualizaciones quedaría atada a `trixie` para siempre y **dejaría de aplicar parches tras la
> subida de versión**, en silencio.

**Y este es el comando que lo escribe.** Fíjate en que el heredoc va **con comillas** (`<<'EOF'`),
justo al revés que en los capítulos 04 a 06: aquí no queremos que el shell expanda nada.

```bash
# [servidor]
sudo tee /etc/apt/apt.conf.d/52-nomad-unattended >/dev/null <<'EOF'
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-updates";
};

Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";

Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";

Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::SyslogEnable "true";
EOF
```

O con la plantilla del repositorio, que además lleva los comentarios explicativos y el bloque de
correo comentado:

```bash
# [servidor]
nomad_plantilla etc/unattended-upgrades.conf \
    | sudo tee /etc/apt/apt.conf.d/52-nomad-unattended >/dev/null
```

**Comprueba que `${distro_codename}` sigue ahí, literal:**

```bash
# [servidor]
grep -c 'distro_codename' /etc/apt/apt.conf.d/52-nomad-unattended
```

Criterio de aceptación: `2`. Si devuelve `0`, la variable se expandió a nada y el patrón de orígenes
no coincidirá con ningún repositorio: el servidor dejaría de parchearse. Reescribe el archivo con
`<<'EOF'`.

Y activa las tareas periódicas:

```bash
# [servidor]
sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
```

### Paso 2 — Prueba las actualizaciones en seco

```bash
# [servidor]
sudo unattended-upgrade --dry-run --debug 2>&1 | tail -30
```

Criterio de aceptación: aparecen las líneas `Allowed origins are:` con
`origin=Debian,codename=trixie-security` y termina sin errores.

```bash
# [servidor]
systemctl list-timers | grep -E 'apt-daily|apt-daily-upgrade'
```

Criterio de aceptación: los dos temporizadores aparecen con próxima ejecución programada.

### Paso 3 — Límites del registro

**Así queda el archivo:**

```
[Journal]
Storage=persistent
SystemMaxUse=500M
SystemKeepFree=1G
SystemMaxFileSize=50M
MaxRetentionSec=1month
MaxFileSec=1week
RateLimitIntervalSec=30s
RateLimitBurst=10000
ForwardToSyslog=no
```

**Y este es el comando que lo escribe.** No lleva ninguna variable, así que el heredoc va con
comillas:

```bash
# [servidor]
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/50-nomad.conf >/dev/null <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=500M
SystemKeepFree=1G
SystemMaxFileSize=50M
MaxRetentionSec=1month
MaxFileSec=1week
RateLimitIntervalSec=30s
RateLimitBurst=10000
ForwardToSyslog=no
EOF
```

O con la plantilla:

```bash
# [servidor]
nomad_diff etc/journald-nomad.conf /etc/systemd/journald.conf.d/50-nomad.conf
nomad_plantilla etc/journald-nomad.conf \
    | sudo tee /etc/systemd/journald.conf.d/50-nomad.conf >/dev/null
```

```bash
# [servidor]
sudo systemctl restart systemd-journald
journalctl --disk-usage
```

Salida esperada: `Archived and active journals take up XXX MB in the file system.`, por debajo de
500 MB.

Para recortar de inmediato lo que ya hubiera:

```bash
# [servidor]
sudo journalctl --vacuum-size=500M
```

### Paso 4 — Parámetros del kernel

El contenido completo está en `templates/etc/sysctl-nomad.conf`, con un comentario por parámetro
explicando qué consigue. Instálalo así:

```bash
# [servidor]
nomad_diff etc/sysctl-nomad.conf /etc/sysctl.d/60-nomad-endurecimiento.conf
nomad_plantilla etc/sysctl-nomad.conf \
    | sudo tee /etc/sysctl.d/60-nomad-endurecimiento.conf >/dev/null
```

Repasa la sección 3.3 antes de añadir nada por tu cuenta: **no pongas
`net.ipv4.ip_forward = 0`**. Si prefieres editarlo con un editor, la plantilla es exactamente el
contenido que hay que copiar:

```bash
# [servidor]
nomad_plantilla etc/sysctl-nomad.conf | less
sudo ${EDITOR:-vim} /etc/sysctl.d/60-nomad-endurecimiento.conf
```

```bash
# [servidor]
sudo sysctl --system
```

Salida esperada: una línea `* Applying /etc/sysctl.d/60-nomad-endurecimiento.conf ...` seguida de
cada parámetro aplicado, sin errores.

```bash
# [servidor] — comprobación explícita de que no hemos roto Docker
sysctl net.ipv4.ip_forward
```

Criterio de aceptación: en este momento puede valer `0` (Docker aún no está instalado). Lo
importante es que **nuestro archivo no lo fija**:

```bash
# [servidor]
grep -r 'ip_forward' /etc/sysctl.d/ /etc/sysctl.conf 2>/dev/null || echo "Nadie fija ip_forward: correcto"
```

### Paso 5 — Comprueba AppArmor

```bash
# [servidor]
sudo aa-status
```

Salida esperada, en sus primeras líneas:

```
apparmor module is loaded.
XX profiles are loaded.
XX profiles are in enforce mode.
```

> **`aa-status` sin opciones ya imprime ese resumen.** La opción `--summary` **no existe** en el
> `apparmor` de Debian 13 y responde `unrecognized option`. Para usarlo dentro de un script, lo
> cómodo es `aa-status --enforced`, que imprime solo el número de perfiles en modo `enforce`, o
> `aa-status --enabled`, que no imprime nada y devuelve 0 si el módulo está cargado.

Si dice `apparmor module is not loaded`, actívalo:

```bash
# [servidor]
sudo apt install -y apparmor apparmor-utils
sudo systemctl enable --now apparmor
```

Y si el módulo no carga, comprueba que el kernel lo tiene habilitado:

```bash
# [servidor]
cat /sys/module/apparmor/parameters/enabled
```

Criterio de aceptación: `Y`.

### Paso 6 — Revisa qué está escuchando

```bash
# [servidor]
sudo ss -tulpn | grep LISTEN
```

Criterio de aceptación: **solo `sshd` en el puerto `${SSH_PUERTO}`**. Cualquier otra cosa merece una
explicación.

Comprobación automática, que es la que usa el script:

```bash
# [servidor]
sudo ss -tulpn | grep LISTEN | grep -vc ":${SSH_PUERTO}\b"
```

Criterio de aceptación: `0`. Si el entorno no estuviera cargado, `${SSH_PUERTO}` se expandiría a
nada y el `grep -v ":"` descartaría casi todo, dando un `0` falso. Comprueba antes con
`echo "${SSH_PUERTO}"`.

Lo que puede aparecer legítimamente:

| Servicio | Dirección | Normal |
|---|---|---|
| `sshd` | `0.0.0.0:22` y `[::]:22` | Sí |
| `systemd-resolve` | `127.0.0.53:53` | Solo si se instaló; en este montaje no debería estar |
| `dhclient` | puerto alto UDP | No, si la IP ya es estática: revisa el capítulo 06 |

Y comprueba los servicios activos:

```bash
# [servidor]
systemctl list-units --type=service --state=running
```

Cualquier servicio que no reconozcas es una pregunta pendiente, no un detalle.

### Paso 7 — Auditoría de referencia

```bash
# [servidor]
sudo apt install -y lynis
sudo lynis audit system --quick
```

Tarda unos minutos. Al final muestra un índice de endurecimiento y una lista de sugerencias.

Guarda el resultado con fecha:

```bash
# [servidor]
mkdir -p ~/nomad_server/inventario
sudo lynis audit system --quick --quiet --report-file \
    ~/nomad_server/inventario/lynis-$(date +%F).dat

# El informe lo escribe root con permisos restrictivos, dentro de TU directorio:
# sin esto no puedes ni leerlo.
sudo chown "${USER}:" ~/nomad_server/inventario/lynis-$(date +%F).dat

grep -E '^hardening_index' ~/nomad_server/inventario/lynis-$(date +%F).dat
```

Anota el índice. En un Debian mínimo recién endurecido suele quedar **entre 65 y 80**. Ese número
por sí solo no significa nada: lo que importa es que dentro de seis meses no haya bajado.

Revisa las sugerencias con criterio:

```bash
# [servidor]
sudo lynis show suggestions
```

Muchas no aplican a este montaje (esperan servicios instalados en el host). Las que sí suelen tener
sentido: instalar `apt-listbugs`, activar `process accounting`, o revisar permisos de archivos
concretos. **No apliques nada que no entiendas** solo por subir la puntuación.

### Paso 8 — Reinicia y comprueba

```bash
# [servidor]
sudo reboot
```

Espera un minuto y valida con la sección 7.

---

## 6. Script asociado

### 6.1 Vía A — con el script

`scripts/07_hardening.sh` automatiza los pasos 1 a 7.

```bash
# [servidor]
cd ~/nomad_server
./scripts/07_hardening.sh --help
sudo ./scripts/07_hardening.sh --check
sudo ./scripts/07_hardening.sh
```

| Opción | Para qué |
|---|---|
| `--sin-auditoria` | Omite el paso 7 (Lynis), que es el que más tarda |
| `-n, --check` | Muestra las diferencias de los cuatro archivos y ejecuta las comprobaciones de solo lectura |
| `-y, --si` | No pide confirmación |

Comportamiento destacable:

- **Nunca fija `net.ipv4.ip_forward`**, y avisa si encuentra otro archivo en `/etc/sysctl.d/` que lo
  ponga a 0. Es la comprobación que evita el fallo descrito en 3.3.
- Ejecuta `unattended-upgrade --dry-run` para verificar que la configuración es válida antes de
  darla por buena.
- Genera la auditoría de Lynis en `inventario/lynis-<fecha>.dat` y muestra el índice.
- Enumera lo que está escuchando en red y avisa de cualquier cosa que no sea SSH.

En modo `--check` muestra las diferencias de los cuatro archivos de configuración y ejecuta las
comprobaciones de solo lectura (AppArmor, puertos en escucha), sin aplicar nada.

### 6.2 Correspondencia entre el script y los pasos manuales

| Paso de la sección 5 | ¿Lo hace el script? | Nota |
|---|---|---|
| 0 — preparar la sesión | Sí | Comprueba red y cortafuegos antes de nada |
| 1 — actualizaciones automáticas | Sí | Instala `templates/etc/unattended-upgrades.conf` y `apt-periodic.conf` |
| 2 — prueba en seco | Sí | `unattended-upgrade --dry-run`, y avisa si no lista orígenes |
| 3 — límites del registro | Sí | |
| 4 — parámetros del kernel | Sí | Y **aborta si otro archivo pone `ip_forward` a 0** |
| 5 — comprobar AppArmor | Sí | Lo instala si faltara |
| 6 — revisar qué escucha | Sí | Avisa de cualquier cosa que no sea SSH |
| 7 — auditoría de Lynis | Sí | Se omite con `--sin-auditoria` |
| 8 — reinicio | **No** | Avisa si hace falta |

### 6.3 Si prefieres la vía manual

Lo que asumes:

- [ ] Usar `<<'EOF'` **con comillas** en el archivo de `unattended-upgrades`, para no expandir
      `${distro_codename}` (§ 4.2). Es el único error de este capítulo que no da ningún síntoma
      hasta la siguiente subida de versión de Debian.
- [ ] Comprobar con `grep -c distro_codename` que sigue literal.
- [ ] Ejecutar `sudo unattended-upgrade --dry-run` y leer que aparecen los orígenes.
- [ ] No añadir `net.ipv4.ip_forward = 0` a la configuración del kernel (§ 3.3).
- [ ] Guardar el informe de Lynis con fecha, que es lo que da valor al paso 7.

---

## 7. Validación

```bash
# [servidor]
systemctl list-timers apt-daily-upgrade.timer --no-pager
```

Criterio de aceptación: aparece con próxima ejecución programada.

```bash
# [servidor]
sudo unattended-upgrade --dry-run 2>&1 | grep -c 'trixie-security'
```

Criterio de aceptación: mayor que 0. **Si es 0, el servidor no se está parcheando.**

```bash
# [servidor]
journalctl --disk-usage
```

Criterio de aceptación: por debajo de 500 MB.

```bash
# [servidor]
sysctl kernel.kptr_restrict kernel.dmesg_restrict net.ipv4.tcp_syncookies vm.swappiness
```

Criterio de aceptación: `2`, `1`, `1`, `10`.

```bash
# [servidor] — nadie debe estar fijando ip_forward a 0
grep -rn 'ip_forward' /etc/sysctl.conf /etc/sysctl.d/ 2>/dev/null && echo "REVISAR" || echo "CORRECTO"
```

Criterio de aceptación: `CORRECTO`.

```bash
# [servidor]
sudo aa-status
```

Criterio de aceptación: el módulo está cargado y hay perfiles en modo `enforce`.

```bash
# [servidor]
sudo ss -tulpn | grep LISTEN | grep -vc ":${SSH_PUERTO}\b"
```

Criterio de aceptación: `0` **en este punto del montaje**, cuando todavía no hay ni VPN ni
contenedores.

> **Ese `0` deja de ser el criterio en cuanto avanzas**, y conviene saberlo antes de alarmarse al
> revalidar el capítulo más adelante. A partir del capítulo 08 aparecen escuchas legítimas:
>
> | Proceso | Dirección | Desde el capítulo | ¿Es correcto? |
> |---|---|---|---|
> | `sshd` | `0.0.0.0:${SSH_PUERTO}` y `[::]:${SSH_PUERTO}` | 03 | Sí |
> | `tailscaled` | `${TS_IP}:<puerto alto>` y su equivalente IPv6 | 08 | Sí: es la API entre pares de la tailnet, solo alcanzable desde tu red privada |
> | `docker-proxy` | `${TRAEFIK_BIND_INTERNA}:${TRAEFIK_PUERTO_INTERNA}` | 10 | Sí, **si y solo si** la dirección es privada |
>
> **El criterio no es dónde escucha un proceso, sino qué deja pasar el cortafuegos.** Un servicio
> atado a `0.0.0.0` cuyo puerto nftables no acepta no es alcanzable por nadie. Y al revés: lo que el
> cortafuegos abre sí lo es, escuche donde escuche.
>
> La diferencia no es teórica. `tailscaled` escucha en `0.0.0.0:41641` **a propósito** —lo necesita
> para las conexiones directas entre pares, y el capítulo [06](06_red_y_firewall.md) le abre ese
> puerto—, así que un criterio de «nada en `0.0.0.0` salvo SSH» marca como problema algo que el
> propio montaje configuró. Ese es el criterio que se mantiene durante todo el montaje:
>
> ```text
> escuchas en todas las interfaces  ∩  puertos que abre nftables  =  { SSH, udp 41641 }
> ```
>
> Para verlo a mano, primero las escuchas y después las reglas:
>
> ```bash
> # [servidor] — se mira la columna de la dirección LOCAL, la quinta
> ss -tulnH | awk '{print $5}' \
>     | grep -E '^(0\.0\.0\.0|\*|\[::\]):' | grep -v ":${SSH_PUERTO}$"
> ```
>
> ```bash
> # [servidor] — y qué abre el cortafuegos
> sudo nft list chain inet nomad_filter entrada | grep -E 'dport|policy'
> ```
>
> Criterio de aceptación: lo único que aparece en ambas listas es SSH y, tras el capítulo 08, el
> `udp 41641` de Tailscale. Lo que escuche en todas las interfaces pero no tenga regla que lo abra
> no está expuesto; conviene saber que está ahí, pero no es un fallo.
>
> **Con una excepción que invierte el razonamiento: `docker-proxy`.** Docker inserta sus propias
> reglas de reenvío y **no pasa por la cadena de entrada**, así que un puerto publicado por Docker
> en `0.0.0.0` está expuesto aunque nftables no lo abra — el cortafuegos del capítulo
> [06](06_red_y_firewall.md) no lo protege. Es el único caso de esta lista que es un error, y es
> justo el que se le escapa a quien razona mirando solo las reglas:
>
> ```bash
> # [servidor] — nada de esto debe aparecer
> sudo ss -tulpnH | awk '$5 ~ /^(0\.0\.0\.0|\*|\[::\]):/ && /docker-proxy/'
> ```
>
> Criterio de aceptación: no imprime nada. Cada publicación de Docker va atada a una dirección
> privada (capítulo [09](09_docker.md) § 3.2).
>
> **Por qué la quinta columna y no un `grep` sobre la línea.** `ss` imprime `0.0.0.0:*` en la
> columna del **par remoto** de todo socket en escucha —significa «acepto de cualquiera»—, así que
> filtrar la línea entera por `0.0.0.0` casa con absolutamente todas y el criterio deja de decir
> nada. Es un error fácil de cometer y difícil de ver: el comando parece funcionar, solo que la
> cuenta que devuelve no es la que crees.

```bash
# [servidor]
ls ~/nomad_server/inventario/lynis-*.dat
```

Criterio de aceptación: existe al menos un informe con fecha.

```bash
# [servidor] — la variable de APT sigue literal, no expandida
grep -c 'distro_codename' /etc/apt/apt.conf.d/52-nomad-unattended
```

Criterio de aceptación: `2`. **Si es `0`, el servidor dejará de parchearse tras la siguiente subida
de versión de Debian** y nada lo avisará (§ 4.2).

```bash
# [servidor] — tras el reinicio, todo sigue en su sitio
uptime
sudo nft list chain inet nomad_filter entrada | grep -c 'policy drop'
systemctl is-active ssh nftables
```

Criterio de aceptación: el sistema ha reiniciado, el cortafuegos sigue con política `drop` y los dos
servicios están activos.

---

## 8. Reversión

```bash
# [servidor] — desactivar las actualizaciones automáticas
sudo rm /etc/apt/apt.conf.d/52-nomad-unattended
sudo sed -i 's/"1"/"0"/g' /etc/apt/apt.conf.d/20auto-upgrades
```

```bash
# [servidor] — solo desactivar el reinicio automático, manteniendo los parches
sudo sed -i 's/Automatic-Reboot "true"/Automatic-Reboot "false"/' \
    /etc/apt/apt.conf.d/52-nomad-unattended
```

```bash
# [servidor] — límites del registro
sudo rm /etc/systemd/journald.conf.d/50-nomad.conf
sudo systemctl restart systemd-journald
```

```bash
# [servidor] — parámetros del kernel
sudo rm /etc/sysctl.d/60-nomad-endurecimiento.conf
sudo sysctl --system
```

Los valores del kernel vuelven a los de Debian tras un reinicio.

**Si un parámetro concreto está causando problemas**, no hace falta revertirlo todo: coméntalo en
`/etc/sysctl.d/60-nomad-endurecimiento.conf`, ejecuta `sudo sysctl --system`, y **anota en la
sección 3.3 por qué se desactivó**. Ese registro es lo que evita que alguien lo vuelva a activar
dentro de un año.

---

## 9. Errores frecuentes

| Síntoma | Causa probable | Solución | Documentación |
|---|---|---|---|
| Los contenedores no tienen red tras endurecer | Algún archivo de `/etc/sysctl.d/` pone `ip_forward = 0` | `grep -rn ip_forward /etc/sysctl.d/`, elimínalo y `sudo sysctl -w net.ipv4.ip_forward=1` | § 3.3 |
| El servidor se reinicia solo de madrugada | Es el comportamiento configurado | Correcto. Si no lo quieres, pon `Automatic-Reboot "false"` | § 3.1 |
| `unattended-upgrade --dry-run` no lista orígenes | El patrón de `Origins-Pattern` no coincide con la versión instalada | Usa `${distro_codename}` literal, sin sustituir. Comprueba con `apt-cache policy` | [Debian Wiki — UnattendedUpgrades](https://wiki.debian.org/UnattendedUpgrades) |
| `/boot` se llena pese a todo | `Remove-Unused-Kernel-Packages` no está activo | Verifica el paso 1 y ejecuta `sudo apt autoremove --purge` | [Debian Wiki — UnattendedUpgrades](https://wiki.debian.org/UnattendedUpgrades) |
| `journalctl` no muestra nada de antes del reinicio | `Storage` no es `persistent` | Revisa el paso 3 y comprueba que existe `/var/log/journal` | [`journald.conf(5)`](https://manpages.debian.org/trixie/systemd/journald.conf.5.en.html) |
| Un contenedor falla con «max virtual memory areas too low» | `vm.max_map_count` insuficiente | Ya está en la plantilla. Comprueba con `sysctl vm.max_map_count` | § 3.3 |
| `aa-status` dice que el módulo no está cargado | AppArmor desactivado en la línea de arranque del kernel | Revisa `/etc/default/grub`: no debe haber `apparmor=0`. Tras cambiarlo, `sudo update-grub` y reiniciar | [Debian Wiki — AppArmor](https://wiki.debian.org/AppArmor) |
| `aa-status: unrecognized option '--summary'` | Esa opción no existe en el `apparmor` de Debian 13 | `sudo aa-status` a secas ya imprime el resumen | § 5 paso 5 |
| `sysctl: command not found` sin `sudo` | `/usr/sbin` no está en el `PATH` de un usuario normal en Debian | `sudo sysctl …`, o la ruta completa `/usr/sbin/sysctl` | — |
| `ss -tulpn` muestra `tailscaled` y `docker-proxy` escuchando | Es lo esperado a partir de los capítulos 08 y 10 | Comprueba que **ninguno** escucha en `0.0.0.0`, que es el criterio que sí se mantiene | § 7 |
| Un contenedor falla con denegaciones de AppArmor | El perfil `docker-default` bloquea una operación privilegiada | Diagnostica con `sudo dmesg \| grep -i apparmor`. Ajusta el contenedor antes que desactivar AppArmor | [Docker — AppArmor](https://docs.docker.com/engine/security/apparmor/) |
| Lynis sugiere decenas de cosas | Es normal: asume un servidor con servicios en el host | Revísalas una a una. No apliques nada que no entiendas | [Lynis — Controles](https://cisofy.com/lynis/controls/) |
| El sistema no arranca tras un cambio de `sysctl` | Un parámetro incompatible con el hardware | Arranca en modo rescate y elimina `/etc/sysctl.d/60-nomad-endurecimiento.conf` | § 8 |
| `apt` avisa de paquetes retenidos tras la actualización automática | `unattended-upgrades` no instala cambios que requieran eliminar paquetes | Revísalo a mano con `sudo apt full-upgrade` en la rutina del capítulo 15 | Capítulo [15](15_mantenimiento_y_actualizaciones.md) |
| `Origins-Pattern` contiene `codename=-security`, sin nombre | Se escribió el archivo con `<<EOF` sin comillas y el shell expandió `${distro_codename}` a nada | Reescríbelo con `<<'EOF'` o con `nomad_plantilla` | § 4.2 |
| Tras subir de versión mayor, dejaron de llegar parches | Alguien sustituyó `${distro_codename}` por `trixie` literal | Vuelve a poner la variable de APT | § 4.2 |
| `ss -tulpn \| grep -v` da 0 pero sí hay puertos abiertos | `${SSH_PUERTO}` estaba vacío y el filtro descartó todo | `echo "${SSH_PUERTO}"` y carga el entorno | § 5 paso 6 |
| `nomad_plantilla` dice que no encuentra la plantilla | El entorno no está cargado, o el nombre está mal | `source scripts/lib/entorno.sh`; sin argumentos lista las disponibles | Anexo [98](98_variables_y_entorno.md) § 4.3 |

---

## 10. Referencias

- [Debian Wiki — UnattendedUpgrades](https://wiki.debian.org/UnattendedUpgrades)
- [Debian Wiki — AppArmor](https://wiki.debian.org/AppArmor)
- [Debian — Manual de seguridad](https://www.debian.org/doc/manuals/securing-debian-manual/)
- [`journald.conf(5)`](https://manpages.debian.org/trixie/systemd/journald.conf.5.en.html)
- [`sysctl.d(5)`](https://manpages.debian.org/trixie/systemd/sysctl.d.5.en.html)
- [Documentación del kernel — Parámetros de red IP](https://docs.kernel.org/networking/ip-sysctl.html)
- [Lynis — Documentación](https://cisofy.com/lynis/)
- [Docker — Seguridad y AppArmor](https://docs.docker.com/engine/security/apparmor/)
- [templates/README.md](../templates/README.md) — las cuatro plantillas de este capítulo
- Anexo [98 — Variables, entorno y sesiones](98_variables_y_entorno.md) § 4.1 y § 4.4

---

**Anterior:** [06 — Red y cortafuegos](06_red_y_firewall.md) · **Siguiente:** [08 — Tailscale](08_tailscale.md)
