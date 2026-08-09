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

**Tiempo estimado:** 30 minutos, más 10 minutos de auditoría.

> Este capítulo se hace **antes** de instalar Docker a propósito: así el sistema base queda cerrado
> antes de añadir un servicio que se comunica con internet y ejecuta código de terceros.

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

Este capítulo no consume variables de `config/servidor.env`: todos sus ajustes son independientes
del entorno concreto. El script sí carga la configuración para las comprobaciones previas comunes.

---

## 5. Procedimiento

### Paso 1 — Actualizaciones automáticas

```bash
# [servidor]
sudo apt install -y unattended-upgrades apt-listchanges
```

```bash
# [servidor]
sudo vim /etc/apt/apt.conf.d/52-nomad-unattended
```

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

`${distro_codename}` es una variable **de APT**, no del entorno: déjala tal cual. APT la sustituye
por `trixie` automáticamente, de modo que la configuración sigue siendo válida tras actualizar a la
siguiente versión de Debian.

Y activa las tareas periódicas:

```bash
# [servidor]
sudo vim /etc/apt/apt.conf.d/20auto-upgrades
```

```
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
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

```bash
# [servidor]
sudo mkdir -p /etc/systemd/journald.conf.d
sudo vim /etc/systemd/journald.conf.d/50-nomad.conf
```

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

```bash
# [servidor]
sudo vim /etc/sysctl.d/60-nomad-endurecimiento.conf
```

El contenido completo está en `templates/etc/sysctl-nomad.conf`. Repasa la sección 3.3 antes de
añadir nada por tu cuenta: **no pongas `net.ipv4.ip_forward = 0`**.

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
sudo aa-status --summary
```

Salida esperada:

```
apparmor module is loaded.
XX profiles are loaded.
XX profiles are in enforce mode.
```

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

`scripts/07_hardening.sh` automatiza los pasos 1 a 7.

```bash
# [servidor]
cd ~/nomad_server
./scripts/07_hardening.sh --help
sudo ./scripts/07_hardening.sh --check
sudo ./scripts/07_hardening.sh
```

Comportamiento destacable:

- **Nunca fija `net.ipv4.ip_forward`**, y avisa si encuentra otro archivo en `/etc/sysctl.d/` que lo
  ponga a 0. Es la comprobación que evita el fallo descrito en 3.3.
- Ejecuta `unattended-upgrade --dry-run` para verificar que la configuración es válida antes de
  darla por buena.
- Genera la auditoría de Lynis en `inventario/lynis-<fecha>.dat` y muestra el índice.
- Enumera lo que está escuchando en red y avisa de cualquier cosa que no sea SSH.

```bash
# [servidor] — omitir la auditoría, que es lo que más tarda
sudo ./scripts/07_hardening.sh --sin-auditoria
```

En modo `--check` muestra las diferencias de los cuatro archivos de configuración y ejecuta las
comprobaciones de solo lectura (AppArmor, puertos en escucha), sin aplicar nada.

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
sudo aa-status --summary
```

Criterio de aceptación: el módulo está cargado y hay perfiles en modo `enforce`.

```bash
# [servidor]
sudo ss -tulpn | grep LISTEN | grep -vc ':22'
```

Criterio de aceptación: `0`.

```bash
# [servidor]
ls ~/nomad_server/inventario/lynis-*.dat
```

Criterio de aceptación: existe al menos un informe con fecha.

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
| Un contenedor falla con denegaciones de AppArmor | El perfil `docker-default` bloquea una operación privilegiada | Diagnostica con `sudo dmesg \| grep -i apparmor`. Ajusta el contenedor antes que desactivar AppArmor | [Docker — AppArmor](https://docs.docker.com/engine/security/apparmor/) |
| Lynis sugiere decenas de cosas | Es normal: asume un servidor con servicios en el host | Revísalas una a una. No apliques nada que no entiendas | [Lynis — Controles](https://cisofy.com/lynis/controls/) |
| El sistema no arranca tras un cambio de `sysctl` | Un parámetro incompatible con el hardware | Arranca en modo rescate y elimina `/etc/sysctl.d/60-nomad-endurecimiento.conf` | § 8 |
| `apt` avisa de paquetes retenidos tras la actualización automática | `unattended-upgrades` no instala cambios que requieran eliminar paquetes | Revísalo a mano con `sudo apt full-upgrade` en la rutina del capítulo 15 | Capítulo [15](15_mantenimiento_y_actualizaciones.md) |

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

---

**Anterior:** [06 — Red y cortafuegos](06_red_y_firewall.md) · **Siguiente:** [08 — Tailscale](08_tailscale.md)
