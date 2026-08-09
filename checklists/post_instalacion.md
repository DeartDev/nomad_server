# Lista de comprobación — Después de instalar

> Validación de extremo a extremo. Cubre los capítulos
> [03](../docs/03_instalacion_debian.md) a [14](../docs/14_respaldos_restic.md).
>
> El servidor no está terminado hasta que todo esté marcado.

---

## Verificación automática

```bash
# [servidor]
./scripts/verificar_sistema.sh
```

- [ ] Termina sin fallos

Lo que sigue lo cubre en su mayor parte ese script, pero conviene recorrerlo la primera vez para
saber **qué** se está comprobando y por qué.

---

## Sistema base (capítulos 03–04)

- [ ] `cat /etc/os-release` → Debian 13 (trixie)
- [ ] `[ -d /sys/firmware/efi ]` → arrancó en modo UEFI
- [ ] `lsblk` → `/`, `/var` y `/srv` son volúmenes lógicos separados
- [ ] `sudo vgs` → queda espacio libre en `vg0`
- [ ] `swapon --show` → hay swap activa
- [ ] `hostnamectl` → el nombre es el previsto
- [ ] `timedatectl` → zona correcta y `synchronized: yes`
- [ ] `apt-get -s upgrade | grep -c '^Inst'` → `0`
- [ ] `grep trixie-security /etc/apt/sources.list.d/debian.sources` → aparece
- [ ] `systemctl is-enabled sleep.target` → `masked`
- [ ] `dpkg -l | grep -c xserver-xorg` → `0`, no hay entorno gráfico

## Acceso (capítulo 05)

- [ ] Entro por SSH con llave, sin contraseña
- [ ] `ssh -o PreferredAuthentications=password` → `Permission denied (publickey)`
- [ ] `ssh root@...` → denegado
- [ ] `sudo sshd -T | grep passwordauthentication` → `no`
- [ ] `systemctl is-enabled ssh.socket` → desactivado
- [ ] `sudo systemctl reload ssh` → funciona sin error
- [ ] `sudo fail2ban-client status sshd` → muestra `Journal matches`
- [ ] `ls -ld ~/.ssh` → `drwx------`
- [ ] La frase de paso de la llave está en el gestor de contraseñas

## Red y cortafuegos (capítulo 06)

- [ ] `ip -br -4 addr` → la IP es la prevista y es fija
- [ ] `getent hosts deb.debian.org` → resuelve
- [ ] `sudo nft list chain inet nomad_filter entrada` → `policy drop`
- [ ] `grep -c 'flush ruleset' /etc/nftables.conf` → `0`
- [ ] `systemctl is-enabled nftables` → `enabled`
- [ ] Desde otro equipo: `nmap -Pn -p 1-1000 <ip>` → solo el 22 abierto
- [ ] Tras `sudo reboot`, todo vuelve con la IP correcta

## Endurecimiento (capítulo 07)

- [ ] `systemctl list-timers apt-daily-upgrade.timer` → programado
- [ ] `sudo unattended-upgrade --dry-run | grep -c trixie-security` → mayor que 0
- [ ] `journalctl --disk-usage` → por debajo de 500 MB
- [ ] `sudo aa-status --summary` → AppArmor cargado con perfiles en `enforce`
- [ ] `grep -rn ip_forward /etc/sysctl.d/` → **no aparece nada**
- [ ] `sudo ss -tulpn | grep LISTEN` → solo SSH
- [ ] Existe un informe de Lynis con fecha en `inventario/`

## Tailscale (capítulo 08)

- [ ] `tailscale status` → conectado
- [ ] `tailscale netcheck` → `UDP: true`
- [ ] **La caducidad de clave está desactivada** en la consola de administración
- [ ] MagicDNS activado
- [ ] ACLs definidas
- [ ] Entro por SSH desde datos móviles, fuera de casa
- [ ] Tras reiniciar, la VPN vuelve sola

## Docker (capítulo 09)

- [ ] `docker ps` funciona sin `sudo`
- [ ] `docker compose version` → v2
- [ ] `docker info` → `json-file`, `live-restore: true`, `overlay2`
- [ ] Existen las redes `proxy` y `socket`
- [ ] `docker network inspect socket --format '{{.Internal}}'` → `true`
- [ ] Ninguna subred de Docker solapa con la red local
- [ ] `sysctl -n net.ipv4.ip_forward` → `1`
- [ ] Un contenedor de prueba resuelve nombres y sale a internet

## Traefik (capítulo 10)

- [ ] `traefik` y `socket-proxy` en `running (healthy)`
- [ ] El puerto 80 **no** aparece en `ss -tlnp` del host
- [ ] El único puerto publicado está atado a una dirección privada
- [ ] El panel responde en `/dashboard/` (con la barra final)
- [ ] El intermediario del socket devuelve **403** al intentar crear un contenedor
- [ ] Los middlewares `seguridad`, `compresion` y `solo-privada` están cargados

## Publicación (capítulo 11)

- [ ] `docker logs cloudflared | grep -c 'Registered tunnel connection'` → 2 o más
- [ ] Un subdominio de prueba responde `HTTP/2 200` desde internet
- [ ] Las cabeceras incluyen `server: cloudflare` y `x-frame-options: DENY`
- [ ] El modo SSL/TLS de Cloudflare es **Full**
- [ ] `ls -l ${CF_CONFIG_DIR}/*.json` → permisos `600`
- [ ] Desde fuera: `nmap -Pn -p 80,443,22 <ip-publica>` → nada abierto
- [ ] Las credenciales del túnel están copiadas en el gestor de contraseñas

## Proyectos (capítulo 12)

- [ ] Al menos un proyecto desplegado y accesible por su subdominio
- [ ] `find /srv -name .env -exec stat -c '%n %a' {} \;` → todos `600`
- [ ] Ningún proyecto publica puertos en `0.0.0.0`
- [ ] Las bases de datos **no** están en la red `proxy`
- [ ] Todos los servicios declaran `healthcheck`
- [ ] Ningún `.env` aparece en `git status`
- [ ] Tras reiniciar, los proyectos vuelven solos

## Observabilidad (capítulo 13)

- [ ] Dozzle lista todos los contenedores y muestra sus registros
- [ ] Uptime Kuma accesible y con la cuenta creada
- [ ] Al menos tres monitores en verde
- [ ] El canal de avisos configurado **y la prueba recibida**
- [ ] Monitor de espacio en disco en verde
- [ ] Desde internet, sin Tailscale, las herramientas **no** responden
- [ ] Prueba real: paré un contenedor y **llegó el aviso**

## Respaldos (capítulo 14)

- [ ] `mountpoint /mnt/respaldo` → montado
- [ ] La entrada de `/etc/fstab` incluye `nofail`
- [ ] `stat -c '%a' /root/.restic-password` → `600`
- [ ] `restic snapshots` → al menos una instantánea
- [ ] `systemctl list-timers nomad-respaldo` → programado
- [ ] `sudo systemctl start nomad-respaldo.service` → `success`
- [ ] `restic check` → sin errores
- [ ] El manifiesto del sistema está dentro del respaldo
- [ ] **`sudo ./scripts/14_restic.sh --probar` → PRUEBA SUPERADA**
- [ ] La contraseña del repositorio está en el gestor de contraseñas, **fuera del servidor**
- [ ] Monitor de respaldo en Uptime Kuma en verde

---

## Los siete criterios de «hecho»

Del capítulo [00](../docs/00_planificacion.md) § 7. Si estos siete se cumplen, el proyecto está
terminado:

- [ ] 1. Entro por SSH con llave desde la LAN **y** desde Tailscale; la contraseña es rechazada
- [ ] 2. `nft list ruleset` muestra política `drop` y solo lo previsto permitido
- [ ] 3. `docker ps` no muestra **ningún** puerto publicado en `0.0.0.0`
- [ ] 4. Un proyecto responde por HTTPS en su subdominio a través del túnel
- [ ] 5. `restic snapshots` muestra instantáneas y la restauración de prueba ha funcionado
- [ ] 6. Tras `sudo reboot`, todo vuelve solo, sin intervención manual
- [ ] 7. `scripts/verificar_sistema.sh` termina sin errores

---

## Preparación ante desastres

Del capítulo [16](../docs/16_recuperacion_ante_desastres.md) § 2. Comprobar **ahora**, no cuando
haga falta:

- [ ] Contraseña del repositorio restic en el gestor de contraseñas, fuera del servidor
- [ ] Repositorio `nomad_server` en un remoto o en otro equipo
- [ ] Llave privada SSH respaldada en otro sitio
- [ ] Acceso a Cloudflare y a Tailscale desde otro dispositivo, con 2FA recuperable
- [ ] Sé dónde está físicamente el disco de respaldo
- [ ] Recordatorios de mantenimiento mensual y trimestral en el calendario

---

**Siguiente:** [Rutina de mantenimiento](mantenimiento.md)
