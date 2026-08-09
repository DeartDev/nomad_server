# 99 — Glosario y referencias

> Anexo. No es un capítulo de procedimiento: no tiene pasos ni validación. Sirve para consultar un
> término cuando aparece en otro capítulo y para tener reunidos todos los enlaces oficiales.

---

## Glosario

### Sistema y arranque

**UEFI** — El firmware que arranca los ordenadores modernos, sucesor de la BIOS. Necesita una
partición especial (la ESP) y una tabla de particiones GPT. Ver capítulo 02.

**ESP (EFI System Partition)** — Partición pequeña en formato FAT32 donde la UEFI busca el gestor de
arranque. En este montaje ocupa 512 MB.

**GPT** — Tabla de particiones moderna, requisito para arrancar en modo UEFI. Sustituye a la tabla
`msdos`, limitada a 2 TB y cuatro particiones primarias.

**Secure Boot** — Mecanismo de la UEFI que solo permite arrancar código firmado. Debian lo soporta;
en este montaje se deja activado (capítulo 02 § 3.3).

**GRUB** — El gestor de arranque de Debian: presenta el menú y carga el kernel.

**LVM (Logical Volume Manager)** — Capa entre las particiones físicas y los sistemas de archivos que
permite crear volúmenes redimensionables. Es lo que hace posible ampliar `/var` en caliente
(capítulo 15 § 3.6).

**Grupo de volúmenes (VG)** — Conjunto de espacio físico agrupado por LVM. Aquí se llama `vg0`.

**Volumen lógico (LV)** — Cada «partición» dentro del grupo de volúmenes: `raiz`, `var`, `srv`,
`swap`.

**AHCI** — Modo de operación de la controladora SATA. Si está en RAID o Intel RST, Linux no ve los
discos: es la causa número uno de «el instalador no encuentra el disco».

**SMART** — Sistema de autodiagnóstico de los discos. Avisa de sectores reasignados y desgaste antes
de que el disco falle (capítulo 02 § 5 paso 3).

**systemd** — El sistema de inicio de Debian: arranca servicios, gestiona temporizadores y recoge
los registros.

**Unidad (unit)** — Cada cosa que systemd gestiona: un servicio (`.service`), un temporizador
(`.timer`), un punto de montaje (`.mount`).

**journald** — El componente de systemd que almacena los registros. Se consulta con `journalctl`.

**AppArmor** — Sistema de control de acceso obligatorio que limita lo que puede hacer cada programa,
independientemente de sus permisos de usuario. Debian lo activa por omisión.

### Paquetes

**APT** — El gestor de paquetes de Debian.

**deb822** — Formato moderno de los archivos de repositorio, con campos con nombre en lugar de una
línea densa. Debian 13 lo adopta por omisión (capítulo 04 § 3.1).

**Suite** — El nombre en clave de una versión de Debian: `trixie` (13), `forky` (14).

**`-security` / `-updates`** — Suites complementarias: la primera trae parches de seguridad; la
segunda, correcciones importantes que no son de seguridad.

**`Signed-By`** — Campo que ata un repositorio a una clave concreta, de modo que un repositorio de
terceros no pueda firmar paquetes que suplanten a los de Debian.

**unattended-upgrades** — El mecanismo que instala automáticamente las actualizaciones de seguridad
(capítulo 07 § 3.1).

### Red

**CIDR** — Notación para expresar un rango de direcciones: `192.168.1.0/24` son las 256 direcciones
de `192.168.1.0` a `192.168.1.255`.

**CGNAT** — Traducción de direcciones a gran escala que usan muchos proveedores domésticos. Impide
recibir conexiones entrantes, y es uno de los motivos por los que este montaje usa túneles salientes.

**nftables** — El cortafuegos del kernel de Linux, sucesor de iptables. Es lo que Debian trae de
serie.

**Tabla, cadena, regla** — La jerarquía de nftables: una **tabla** agrupa **cadenas**, y cada cadena
contiene **reglas**. Una cadena se «engancha» a un punto del recorrido del paquete (`input`,
`forward`, `output`).

**Política** — Lo que ocurre con un paquete que no coincide con ninguna regla de la cadena. Aquí es
`drop` en entrada: se descarta en silencio.

**`drop` frente a `reject`** — `drop` descarta sin responder (el emisor ve un tiempo de espera
agotado); `reject` responde que el puerto está cerrado. `drop` da menos información a quien escanea.

**Seguimiento de conexiones (conntrack)** — Mecanismo del kernel que recuerda las conexiones
establecidas, lo que permite aceptar las respuestas sin abrir puertos.

**MTU** — Tamaño máximo de paquete. Bloquear ICMP por completo rompe su descubrimiento automático y
provoca fallos difíciles de diagnosticar.

**Nombres predecibles de interfaz** — `enp3s0` en lugar de `eth0`: derivan de la posición física de
la tarjeta y no cambian al añadir hardware.

### VPN y publicación

**WireGuard** — Protocolo de VPN moderno, rápido y con poco código. Es la base de Tailscale.

**Tailscale** — Red privada construida sobre WireGuard que conecta tus dispositivos sin abrir
puertos. Ver capítulo 08.

**Tailnet** — Tu red privada dentro de Tailscale.

**MagicDNS** — Función de Tailscale que hace que cada nodo sea alcanzable por su nombre.

**Caducidad de clave (key expiry)** — Los nodos de Tailscale caducan a los 180 días por omisión.
**En un servidor hay que desactivarla** o el acceso remoto dejará de funcionar sin aviso
(capítulo 08 § 3.4).

**DERP** — Los relés de Tailscale, que se usan cuando no se consigue una conexión directa. Funcionan,
pero añaden latencia.

**Cloudflare Tunnel** — Túnel que el servidor **inicia hacia fuera**, de modo que Cloudflare puede
entregarle tráfico sin que haya ningún puerto abierto. Ver capítulo 11.

**cloudflared** — El programa que mantiene ese túnel.

**Ingress** — Las reglas del túnel que deciden a dónde va cada petición. Aquí hay una sola: todo a
Traefik (capítulo 11 § 3.3).

**Proxy inverso** — Servicio que recibe las peticiones y las reparte entre varios servicios internos
según el nombre de host. Aquí es Traefik.

**Router (en Traefik)** — Regla que asocia una condición (por ejemplo `Host(...)`) con un servicio.
No confundir con el router de la red doméstica.

**EntryPoint** — Puerto en el que Traefik escucha. Aquí hay dos: `web` (público, no publicado en el
host) e `interna` (privado).

**Middleware** — Transformación que se aplica a una petición antes de entregarla: cabeceras de
seguridad, compresión, límite de frecuencia (capítulo 10 § 3.4).

**HSTS** — Cabecera que obliga al navegador a usar HTTPS durante un tiempo determinado. Difícil de
revertir: conviene entenderla antes de activarla con `includeSubDomains`.

**Modo TLS Full** — Ajuste de Cloudflare en el que el tráfico va cifrado en los dos tramos. El modo
`Flexible` deja el tramo hasta el origen sin cifrar (capítulo 11 § 3.5).

### Contenedores

**Contenedor** — Proceso aislado con su propio sistema de archivos, red y límites de recursos.

**Imagen** — Plantilla de solo lectura a partir de la cual se crean contenedores.

**Etiqueta de imagen (tag)** — La versión: `traefik:v3.7`. **Nunca `latest`** en este montaje
(capítulo 10 § 3.6).

**Compose** — Herramienta que describe un conjunto de contenedores en un archivo YAML.

**Publicar un puerto** — Hacer que un puerto del contenedor sea accesible desde el host. **En este
servidor no se hace**, salvo el punto de entrada interno de Traefik atado a una dirección privada
(capítulo 09 § 3.2).

**`expose`** — Declara un puerto para otros contenedores de la misma red, sin publicarlo en el host.

**Montaje de directorio (bind mount)** — Directorio del host montado dentro del contenedor. Es lo
que se usa aquí para los datos, porque simplifica el respaldo (capítulo 12 § 3.3).

**Volumen con nombre** — Almacenamiento gestionado por Docker en `/var/lib/docker/volumes`. No se
usa en este montaje.

**Red `bridge`** — Red virtual que conecta contenedores entre sí.

**`internal: true`** — Red sin salida a internet. Se usa para el intermediario del socket y para las
bases de datos.

**Socket de Docker** — `/var/run/docker.sock`, el canal de la API de Docker. **Quien lo alcanza
controla el host.** Montarlo con `:ro` **no** lo convierte en solo lectura (capítulo 10 § 3.2).

**socket-proxy** — Intermediario que expone solo una parte de la API de Docker, de lectura.

**Healthcheck** — Comprobación periódica que declara si un contenedor está realmente sano, no solo
en marcha (capítulo 12 § 3.6).

**Política de reinicio** — Qué hace Docker cuando un contenedor se para. Aquí `unless-stopped`.

**live-restore** — Opción que mantiene los contenedores en marcha mientras se reinicia el demonio de
Docker.

### Respaldos

**restic** — Programa de respaldo incremental, deduplicado y cifrado. Ver capítulo 14.

**Repositorio** — El destino donde restic guarda los datos, ya cifrados.

**Instantánea (snapshot)** — El estado respaldado en un momento concreto.

**Deduplicación** — Guardar una sola vez cada bloque repetido. Es lo que hace que 17 instantáneas
ocupen poco más que una.

**Retención** — Cuántas instantáneas se conservan de cada tipo. Aquí: 7 diarias, 4 semanales,
6 mensuales.

**`prune`** — Eliminar del repositorio los datos que ya no referencia ninguna instantánea.

**Monitor de tipo Push** — Monitor que espera recibir un aviso periódico. **Si no llega, salta.** Es
lo que detecta un respaldo que falla en silencio (capítulo 14 § 3.6).

### Seguridad

**Superficie de ataque** — El conjunto de puntos por los que alguien podría entrar. Reducirla es el
objetivo de los capítulos 05 a 07.

**Defensa en profundidad** — Varias barreras independientes, de modo que fallar una no baste.

**Modelo de amenazas** — Enunciar contra qué se protege, y contra qué no (capítulo 00 § 3.1).

**Endurecimiento (hardening)** — Reducir la superficie de ataque desactivando lo que no se usa y
ajustando lo que queda.

**ed25519** — Algoritmo de firma usado en las llaves SSH de este montaje: llaves cortas, rápidas y
seguras.

**Frase de paso** — Contraseña que cifra la llave privada. Convierte el robo del archivo en algo
inútil.

**fail2ban** — Servicio que bloquea direcciones tras varios intentos fallidos.

**`no-new-privileges`** — Opción que impide que un proceso dentro del contenedor gane privilegios
mediante binarios setuid.

**Lynis** — Herramienta de auditoría. Su valor no es la puntuación, sino poder comparar con la de
hace seis meses (capítulo 07 § 3.5).

### Este repositorio

**Idempotente** — Que ejecutarlo dos veces deja el mismo resultado que ejecutarlo una vez. Todos los
scripts lo son.

**Modo simulación (`--check`)** — Muestra lo que haría un script sin modificar nada.

**Plantilla** — Archivo de `templates/` con `${VARIABLES}` que se sustituyen por los valores de
`config/servidor.env`.

**Manifiesto del sistema** — Lista de paquetes, imágenes y contenedores que se genera antes de cada
respaldo. No vive en ningún archivo del sistema, y es lo primero que hace falta al reconstruir
(capítulo 14 § 3.2).

---

## Referencias oficiales

Solo documentación de origen. Los blogs y tutoriales envejecen mal y no se enlazan.

### Debian

- [Debian — Página principal](https://www.debian.org/)
- [Debian — Releases y fechas de soporte](https://www.debian.org/releases/)
- [Debian 13 «Trixie» — Notas de publicación](https://www.debian.org/releases/trixie/releasenotes)
- [Guía de instalación de Debian 13 (amd64)](https://www.debian.org/releases/trixie/amd64/)
- [Debian — Instalación automatizada con preseed](https://www.debian.org/releases/trixie/amd64/apb)
- [Debian — Verificación de imágenes](https://www.debian.org/CD/verify)
- [Debian — Manual de seguridad](https://www.debian.org/doc/manuals/securing-debian-manual/)
- [Debian — Información de seguridad](https://www.debian.org/security/)
- [Debian Wiki](https://wiki.debian.org/)
- [Debian Wiki — LVM](https://wiki.debian.org/LVM)
- [Debian Wiki — nftables](https://wiki.debian.org/nftables)
- [Debian Wiki — AppArmor](https://wiki.debian.org/AppArmor)
- [Debian Wiki — SecureApt](https://wiki.debian.org/SecureApt)
- [Debian Wiki — UnattendedUpgrades](https://wiki.debian.org/UnattendedUpgrades)
- [Debian Wiki — Firmware](https://wiki.debian.org/Firmware)
- [Debian Wiki — Nombres de interfaces de red](https://wiki.debian.org/NetworkInterfaceNames)

### systemd

- [systemd — Índice de páginas de manual](https://www.freedesktop.org/software/systemd/man/)
- [`systemd.timer(5)`](https://www.freedesktop.org/software/systemd/man/systemd.timer.html)
- [`systemd.exec(5)`](https://www.freedesktop.org/software/systemd/man/systemd.exec.html)
- [`journald.conf(5)`](https://manpages.debian.org/trixie/systemd/journald.conf.5.en.html)
- [`logind.conf(5)`](https://www.freedesktop.org/software/systemd/man/logind.conf.html)

### Red y cortafuegos

- [nftables — Wiki oficial](https://wiki.nftables.org/)
- [Documentación del kernel — Parámetros de red IP](https://docs.kernel.org/networking/ip-sysctl.html)
- [`interfaces(5)`](https://manpages.debian.org/trixie/ifupdown/interfaces.5.en.html)
- [`resolv.conf(5)`](https://manpages.debian.org/trixie/manpages/resolv.conf.5.en.html)

### SSH

- [OpenSSH — Página oficial](https://www.openssh.com/)
- [`sshd_config(5)`](https://manpages.debian.org/trixie/openssh-server/sshd_config.5.en.html)
- [`ssh_config(5)`](https://manpages.debian.org/trixie/openssh-client/ssh_config.5.en.html)
- [Mozilla — Guía de configuración de OpenSSH](https://infosec.mozilla.org/guidelines/openssh)
- [fail2ban — Wiki](https://github.com/fail2ban/fail2ban/wiki)

### Tailscale

- [Tailscale — Documentación](https://tailscale.com/kb/)
- [Tailscale — Instalación en Debian](https://tailscale.com/kb/1187/install-debian-trixie)
- [Tailscale — Caducidad de claves](https://tailscale.com/kb/1028/key-expiry)
- [Tailscale — ACLs](https://tailscale.com/kb/1018/acls)
- [Tailscale — MagicDNS](https://tailscale.com/kb/1081/magicdns)
- [Tailscale — Puertos y cortafuegos](https://tailscale.com/kb/1082/firewall-ports)

### Docker

- [Docker — Documentación](https://docs.docker.com/)
- [Docker — Instalación en Debian](https://docs.docker.com/engine/install/debian/)
- [Docker — Pasos posteriores a la instalación](https://docs.docker.com/engine/install/linux-postinstall/)
- [Docker — Filtrado de paquetes y cortafuegos](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
- [Docker — Configuración del demonio](https://docs.docker.com/reference/cli/dockerd/)
- [Docker — Redes](https://docs.docker.com/engine/network/)
- [Docker — Seguridad](https://docs.docker.com/engine/security/)
- [Docker Compose — Especificación](https://docs.docker.com/reference/compose-file/)
- [Docker — Limpieza de recursos](https://docs.docker.com/engine/manage-resources/pruning/)

### Traefik

- [Traefik Proxy v3 — Documentación](https://doc.traefik.io/traefik/)
- [Traefik — Proveedor de Docker](https://doc.traefik.io/traefik/providers/docker/)
- [Traefik — Routers](https://doc.traefik.io/traefik/routing/routers/)
- [Traefik — Middlewares HTTP](https://doc.traefik.io/traefik/middlewares/http/overview/)
- [Traefik — Notas de publicación](https://github.com/traefik/traefik/releases)
- [Tecnativa — docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy)

### Cloudflare

- [Cloudflare Tunnel — Documentación](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/)
- [Cloudflare Tunnel — Archivo de configuración](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/local-management/configuration-file/)
- [Cloudflare — Modos de cifrado SSL/TLS](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/)
- [Cloudflare — Códigos de error 1xxx](https://developers.cloudflare.com/support/troubleshooting/cloudflare-errors/troubleshooting-cloudflare-1xxx-errors/)

### Respaldos y observabilidad

- [restic — Documentación](https://restic.readthedocs.io/)
- [restic — Preparar un repositorio](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html)
- [restic — Restaurar](https://restic.readthedocs.io/en/stable/050_restore.html)
- [Dozzle — Documentación](https://dozzle.dev/)
- [Uptime Kuma — Wiki](https://github.com/louislam/uptime-kuma/wiki)
- [Lynis — Documentación](https://cisofy.com/lynis/)
- [smartmontools — Preguntas frecuentes](https://www.smartmontools.org/wiki/FAQ)
- [memtest86+](https://www.memtest.org)

---

## Índice rápido de comandos

Los que más se usan, reunidos.

```bash
# Estado general
./scripts/verificar_sistema.sh              # verificación completa
./scripts/verificar_sistema.sh --rapido     # rutina semanal
./scripts/deploy.sh --listar                # estado de los proyectos
sudo ./scripts/14_restic.sh --estado        # estado de los respaldos

# Despliegue
./scripts/deploy.sh <proyecto>              # desplegar o actualizar
./scripts/11_cloudflared.sh --ruta <sub>    # publicar un subdominio nuevo

# Respaldos
sudo ./scripts/14_restic.sh --ahora         # respaldo inmediato
sudo ./scripts/14_restic.sh --listar        # instantáneas
sudo ./scripts/14_restic.sh --probar        # prueba de restauración
sudo ./scripts/14_restic.sh --verificar     # integridad

# Diagnóstico
docker ps --format 'table {{.Names}}\t{{.Status}}'
docker compose logs --tail 100
journalctl -p err --since today
sudo nft list ruleset
sudo ss -tulpn | grep LISTEN
df -h && free -h

# Seguridad
sudo fail2ban-client status sshd
sudo lynis audit system --quick
tailscale status
```

---

**Anterior:** [16 — Recuperación ante desastres](16_recuperacion_ante_desastres.md) · **Índice:** [README](../README.md)
