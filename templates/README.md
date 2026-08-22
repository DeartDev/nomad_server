# templates/ — plantillas de configuración

> Todos los archivos que este montaje escribe en el sistema, con sus `${VARIABLES}` sin sustituir.
> Los scripts los instalan por ti; esta guía explica cómo hacerlo a mano y obtener exactamente el
> mismo resultado.

---

## 1. Qué es una plantilla aquí

Un archivo de este directorio es el contenido **literal** que acabará en el sistema, con dos
diferencias respecto al archivo final:

1. Los valores concretos aparecen como `${VARIABLE}` en lugar de `192.168.1.50`, `nomad` o
   `/srv`. Se sustituyen por lo que tengas en `config/servidor.env`.
2. Llevan una cabecera de comentarios que dice a dónde van, qué script las instala, qué capítulo
   las explica y —cuando la hay— cuál es la decisión de diseño que no conviene deshacer.

Esa cabecera **se queda en el archivo instalado**, a propósito: dentro de un año, quien abra
`/etc/nftables.conf` en el servidor sabrá de dónde salió y dónde está explicado. Cada cabecera
incluye además el bloque «CÓMO APLICARLA A MANO», con los comandos exactos para instalarla sin usar
el script.

> **La única excepción es `etc/docker-daemon.json`**: el formato JSON no admite comentarios, así que
> su documentación está solo aquí y en el capítulo [09](../docs/09_docker.md) § 5 paso 4. Se aplica
> igual que las demás:
>
> ```bash
> # [servidor]
> sudo mkdir -p /etc/docker
> nomad_diff etc/docker-daemon.json /etc/docker/daemon.json
> nomad_plantilla etc/docker-daemon.json | sudo tee /etc/docker/daemon.json >/dev/null
> jq . /etc/docker/daemon.json >/dev/null && sudo systemctl restart docker
> ```

> **No edites el archivo del sistema directamente.** Si lo haces, el siguiente `--check` mostrará
> tus cambios como diferencias y la siguiente ejecución del script los sobrescribirá (dejando copia,
> eso sí). Lo correcto es cambiar el valor en `config/servidor.env`, o cambiar la plantilla si el
> cambio es estructural, y volver a aplicar.

---

## 2. Inventario

### Configuración del sistema — `templates/etc/`

| Plantilla | Destino en el sistema | Permisos | La instala | Capítulo |
|---|---|---|---|---|
| `debian.sources` | `/etc/apt/sources.list.d/debian.sources` | 644 | `04_base.sh` | [04](../docs/04_primer_arranque_y_base.md) |
| `sshd_50-nomad.conf` | `/etc/ssh/sshd_config.d/50-nomad.conf` | 644 | `05_ssh.sh` | [05](../docs/05_usuarios_y_acceso_ssh.md) |
| `fail2ban_nomad.local` | `/etc/fail2ban/jail.d/nomad.local` | 644 | `05_ssh.sh` | [05](../docs/05_usuarios_y_acceso_ssh.md) |
| `nftables.conf` | `/etc/nftables.conf` | 640 | `06_firewall.sh` | [06](../docs/06_red_y_firewall.md) |
| `interfaces` | `/etc/network/interfaces` | 644 | `06_firewall.sh` | [06](../docs/06_red_y_firewall.md) |
| `unattended-upgrades.conf` | `/etc/apt/apt.conf.d/52-nomad-unattended` | 644 | `07_hardening.sh` | [07](../docs/07_endurecimiento_del_sistema.md) |
| `apt-periodic.conf` | `/etc/apt/apt.conf.d/20auto-upgrades` | 644 | `07_hardening.sh` | [07](../docs/07_endurecimiento_del_sistema.md) |
| `journald-nomad.conf` | `/etc/systemd/journald.conf.d/50-nomad.conf` | 644 | `07_hardening.sh` | [07](../docs/07_endurecimiento_del_sistema.md) |
| `sysctl-nomad.conf` | `/etc/sysctl.d/60-nomad-endurecimiento.conf` | 644 | `07_hardening.sh` | [07](../docs/07_endurecimiento_del_sistema.md) |
| `tailscale.sources` | `/etc/apt/sources.list.d/tailscale.sources` | 644 | `08_tailscale.sh` | [08](../docs/08_tailscale.md) |
| `docker.sources` | `/etc/apt/sources.list.d/docker.sources` | 644 | `09_docker.sh` | [09](../docs/09_docker.md) |
| `docker-daemon.json` | `/etc/docker/daemon.json` | 644 | `09_docker.sh` | [09](../docs/09_docker.md) |
| `restic-excluir.txt` | `/etc/nomad/restic-excluir.txt` | 644 | `14_restic.sh` | [14](../docs/14_respaldos_restic.md) |
| `nomad-respaldo.sh` | `/usr/local/bin/nomad-respaldo.sh` | **700** | `14_restic.sh` | [14](../docs/14_respaldos_restic.md) |

### Unidades de systemd — `templates/systemd/`

| Plantilla | Destino | Permisos | La instala | Capítulo |
|---|---|---|---|---|
| `nomad-respaldo.service` | `/etc/systemd/system/nomad-respaldo.service` | 644 | `14_restic.sh` | [14](../docs/14_respaldos_restic.md) |
| `nomad-respaldo.timer` | `/etc/systemd/system/nomad-respaldo.timer` | 644 | `14_restic.sh` | [14](../docs/14_respaldos_restic.md) |

### Contenedores — `templates/compose/`

Estas no van a `/etc`, sino al directorio del servicio dentro de `${DATOS_RAIZ}`.

| Plantilla | Destino | La instala | Capítulo |
|---|---|---|---|
| `traefik/traefik.yml` | `${DATOS_RAIZ}/traefik/config/traefik.yml` | `10_traefik.sh` | [10](../docs/10_traefik.md) |
| `traefik/dinamica/middlewares.yml` | `${DATOS_RAIZ}/traefik/config/dinamica/middlewares.yml` | `10_traefik.sh` | [10](../docs/10_traefik.md) |
| `traefik/docker-compose.yml` | `${DATOS_RAIZ}/traefik/docker-compose.yml` | `10_traefik.sh` | [10](../docs/10_traefik.md) |
| `cloudflared/config.yml` | `${CF_CONFIG_DIR}/config.yml` | `11_cloudflared.sh` | [11](../docs/11_cloudflared_y_dominio.md) |
| `cloudflared/docker-compose.yml` | `${CF_CONFIG_DIR}/docker-compose.yml` | `11_cloudflared.sh` | [11](../docs/11_cloudflared_y_dominio.md) |
| `observabilidad/docker-compose.yml` | `${DATOS_RAIZ}/observabilidad/docker-compose.yml` | `13_observabilidad.sh` | [13](../docs/13_observabilidad.md) |
| `proyecto-ejemplo/docker-compose.yml` | `${DATOS_RAIZ}/<proyecto>/docker-compose.yml` | — (la copias tú) | [12](../docs/12_despliegue_de_proyectos.md) |
| `proyecto-ejemplo/env.example` | `${DATOS_RAIZ}/<proyecto>/.env.example` | — (la copias tú) | [12](../docs/12_despliegue_de_proyectos.md) |

### Instalación desatendida

| Plantilla | Uso | Capítulo |
|---|---|---|
| `preseed.cfg` | Respuestas automáticas del instalador de Debian | [03](../docs/03_instalacion_debian.md) § 6 |

---

## 3. Aplicar una plantilla a mano

### 3.1 Con los ayudantes (lo más corto)

```bash
# [servidor]
cd ~/nomad_server
source scripts/lib/entorno.sh
```

```bash
# [servidor] — ver el resultado con tus valores, sin instalar nada
nomad_plantilla etc/nftables.conf
```

```bash
# [servidor] — comparar con lo que ya hay instalado
nomad_diff etc/nftables.conf /etc/nftables.conf
```

```bash
# [servidor] — copia previa e instalación
sudo mkdir -p /var/backups/nomad/config$(dirname /etc/nftables.conf)
sudo cp -a /etc/nftables.conf \
    /var/backups/nomad/config/etc/nftables.conf.bak-$(date +%Y%m%d-%H%M%S)
nomad_plantilla etc/nftables.conf | sudo tee /etc/nftables.conf >/dev/null
sudo chmod 640 /etc/nftables.conf
```

`nomad_plantilla` sin argumentos, o con una ruta que no existe, lista todas las plantillas
disponibles.

### 3.2 Sin los ayudantes

El comando completo, por si prefieres no depender de nada:

```bash
# [servidor]
cd ~/nomad_server
set -a; . config/servidor.env; set +a

envsubst "$(grep -oE '^[A-Z][A-Z0-9_]*=' config/servidor.env.example \
            | tr -d '=' | sed 's/^/${/; s/$/}/' | tr '\n' ' ')" \
    < templates/etc/nftables.conf \
    | sudo tee /etc/nftables.conf >/dev/null
```

### 3.3 Por qué esa lista explícita de variables

`envsubst` sin argumentos sustituye **todo** lo que parezca una variable. Estas plantillas contienen
símbolos `$` que pertenecen a otros programas y que hay que dejar intactos:

| Aparece en | Ejemplo | De quién es |
|---|---|---|
| `etc/nftables.conf` | `$lan_cidr`, `$ssh_port`, `$ts_iface` | Variables `define` de nftables |
| `etc/unattended-upgrades.conf` | `${distro_codename}` | Variable de APT: se deja literal para que siga siendo válida al subir de versión de Debian |
| `preseed.cfg` | `$primary{ }`, `$lvmok{ }` | Sintaxis del particionador `partman` |
| `compose/proyecto-ejemplo/docker-compose.yml` | `$${POSTGRES_USER}` | El doble `$` escapa la variable para que la resuelva el contenedor, no Compose |
| `etc/nomad-respaldo.sh` | `${punto_montaje}`, `${rutas[@]}` | Variables internas del propio script, en minúscula |

**La regla exacta es esta:** `envsubst` sustituye **solo** los nombres que aparecen en
`config/servidor.env.example`, porque es esa lista la que se le pasa. Todo lo demás llega intacto al
archivo instalado, sea cual sea su formato.

La convención de nombres es una ayuda para leerlo de un vistazo, no el mecanismo: las variables del
despliegue van en MAYÚSCULAS; las internas de un script, en minúscula.

> `templates/etc/nomad-respaldo.sh` es el caso más delicado, porque es un script que se sustituye
> con `envsubst` y **luego se ejecuta**. Ahí conviven tres clases de variable:
>
> | En la plantilla | Qué le pasa | Ejemplo |
> |---|---|---|
> | Está en `servidor.env.example` | Se sustituye al instalar | `${RESTIC_REPO_LOCAL}` |
> | En minúscula, propia del script | Llega intacta y la resuelve bash al ejecutarse | `${punto_montaje}` |
> | En mayúscula pero **no** en la plantilla de configuración | Llega intacta también | `${RESTIC_REPOSITORY}`, `${VERSION_CODENAME}` |
>
> Las dos últimas **deben** seguir ahí después de renderizar. Si alguna vez añades a
> `config/servidor.env.example` una variable con uno de esos nombres, la plantilla dejaría de
> funcionar: es el motivo de la convención de minúsculas.

### 3.4 Después de instalar

Casi ninguna plantilla surte efecto por el mero hecho de existir. Estos son los comandos que
completan cada una:

| Plantilla instalada | Para que tenga efecto |
|---|---|
| `debian.sources`, `docker.sources`, `tailscale.sources` | `sudo apt update` |
| `sshd_50-nomad.conf` | `sudo sshd -t && sudo systemctl restart ssh` |
| `fail2ban_nomad.local` | `sudo systemctl restart fail2ban` |
| `nftables.conf` | `sudo nft -c -f /etc/nftables.conf && sudo systemctl reload nftables` |
| `interfaces` | `sudo systemctl restart networking` (corta la sesión si cambia la IP) |
| `sysctl-nomad.conf` | `sudo sysctl --system` |
| `journald-nomad.conf` | `sudo systemctl restart systemd-journald` |
| `docker-daemon.json` | `sudo systemctl restart docker` |
| `unattended-upgrades.conf` | `sudo unattended-upgrade --dry-run` para comprobarla |
| `nomad-respaldo.service` / `.timer` | `sudo systemctl daemon-reload` y `sudo systemctl enable --now nomad-respaldo.timer` |
| Ficheros compose | `docker compose up -d` en su directorio |

**Valida siempre antes de reiniciar el servicio.** Es lo que hacen los scripts y lo que evita
quedarse fuera del servidor: `sshd -t` y `nft -c` no aplican nada, solo dicen si el archivo es
válido.

---

## 4. Modificar una plantilla

Si el cambio es de **valor** (otra red, otro dominio, otra hora de respaldo), no toques la
plantilla: cambia `config/servidor.env` y vuelve a aplicar.

Si el cambio es **estructural** (una regla nueva del cortafuegos, otro middleware, un parámetro del
kernel), edita la plantilla y deja constancia:

1. Edita el archivo de `templates/`.
2. Si el cambio necesita un valor configurable, añade la variable a
   `config/servidor.env.example` con sus comentarios y sus etiquetas. Si no está ahí, `envsubst`
   **no la sustituirá** y quedará literal en el archivo instalado.
3. Explica el porqué en la sección 3 del capítulo correspondiente. El valor de esta documentación
   está en el histórico de razonamientos, no solo en el estado final.
4. `make check` para comprobar que la variable nueva está declarada y no hay enlaces rotos.
5. Vuelve a ejecutar el script del capítulo, o aplica la plantilla a mano.

---

## 5. Referencias

- Capítulo [97 — Las dos vías de montaje](../docs/97_vias_de_montaje.md)
- Capítulo [98 — Variables, entorno y sesiones](../docs/98_variables_y_entorno.md) § 4.3 y § 4.4
- [`envsubst(1)`](https://manpages.debian.org/trixie/gettext-base/envsubst.1.en.html)
