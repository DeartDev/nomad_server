# 16 — Recuperación ante desastres

> Qué hacer cuando algo se rompe de verdad. Escrito para leerse con prisa y sin pensar demasiado.

---

## 1. Objetivo

Al terminar tendrás un procedimiento probado para cada escenario de fallo, sabrás cuánto tarda cada
recuperación, y habrás comprobado que la reconstrucción completa desde cero funciona con lo que hay
en el repositorio y en el respaldo.

---

## 2. Requisitos previos

**Capítulos previos:** todos, en especial [14 — Respaldos](14_respaldos_restic.md).

**Necesitas tener a mano, y esto es lo importante:**

| Elemento | Dónde debe estar | Sin él |
|---|---|---|
| Contraseña del repositorio restic | Gestor de contraseñas, **fuera del servidor** | Los respaldos son irrecuperables |
| **Copia de `config/servidor.env`** | Tu equipo, o el gestor de contraseñas | Hay que reconstruir la configuración de memoria (ver § 4.2) |
| Disco USB de respaldo | Físicamente accesible | No hay de dónde restaurar |
| Repositorio `nomad_server` | En git remoto o en otro equipo | Hay que reconstruir la documentación de memoria |
| Contraseña del usuario administrador | Gestor de contraseñas | No hay acceso por consola física |
| Acceso a Cloudflare y Tailscale | Gestor de contraseñas, con 2FA recuperable | No se puede rehacer el túnel ni la VPN |
| Llave privada SSH | Tu equipo, respaldada aparte | Hay que entrar por consola física |

> **Comprueba esta tabla ahora, no cuando la necesites.** Si algo falta, consíguelo hoy. Es
> literalmente el requisito de este capítulo.

**Preparar la sesión.** Aquí no hay una sola forma, porque depende del escenario:

| Escenario | Estado del entorno de trabajo |
|---|---|
| A, B, F — el servidor funciona | `cd ~/nomad_server && source scripts/lib/entorno.sh`, como siempre |
| C — no entras por SSH | Consola física. **No hay entorno cargado**: usa valores literales |
| D — no arranca | Sistema *live* o modo rescate. No hay repositorio ni configuración |
| E, G — reconstrucción | El entorno se reconstruye durante la fase 2; ver § 4.2 |

En los escenarios C y D, los comandos de este capítulo llevan valores explícitos a propósito: en una
consola de rescate no hay `config/servidor.env` que cargar.

**Tiempo estimado:** 30 minutos de lectura; entre 15 minutos y 3 horas de ejecución según el
escenario.

---

## 3. Decisiones y por qué

### 3.1 Reconstruir antes que reparar

**Decisión: ante un fallo grave del sistema, reinstalar y restaurar en lugar de diagnosticar.**

Puede sonar drástico, y es la consecuencia lógica de todo lo anterior: si el servidor se reconstruye
en dos horas siguiendo un procedimiento escrito, dedicar seis a diagnosticar un sistema en mal
estado rara vez compensa.

| | Reparar | Reconstruir |
|---|---|---|
| Tiempo | Impredecible: de 10 minutos a un fin de semana | Predecible: unas 2 horas |
| Resultado | Un sistema que funciona, con causas no entendidas | Un sistema idéntico al documentado |
| Qué aprendes | Qué falló | Si tu procedimiento y tus respaldos sirven |

Esto **no** aplica a problemas acotados —un contenedor caído, un certificado, una regla de
cortafuegos—: ahí se repara. Aplica cuando el sistema base está comprometido o inconsistente.

### 3.2 Orden de restauración

**Decisión: secretos primero, datos después, servicios al final.**

```
1. Sistema base           (capítulos 03–07)   ~60 min
2. Secretos y credenciales                    ~10 min
3. Conectividad           (capítulos 08–09)   ~15 min
4. Datos de proyectos                         ~20 min
5. Servicios              (capítulos 10–13)   ~20 min
6. Verificación                               ~15 min
```

Los secretos van antes que los datos porque sin ellos los servicios no arrancan, y descubrirlo al
final obliga a repetir pasos.

### 3.3 Lo que no se restaura

**Decisión: las imágenes de contenedor y los paquetes no se respaldan: se vuelven a descargar.**

Ocupan gigabytes y son idénticas a las del registro. Lo que sí se respalda es la **lista** —el
manifiesto del capítulo 14— para saber exactamente qué versiones había.

Consecuencia práctica: **la recuperación necesita conexión a internet.** Sin ella se pueden
restaurar los datos, pero no levantar los servicios.

---

## 4. Variables usadas

### 4.1 De `config/servidor.env`

| Variable | Uso en la recuperación |
|---|---|
| `RESTIC_USB_UUID`, `RESTIC_USB_MOUNT` | Montar el disco de respaldo |
| `RESTIC_REPO_LOCAL`, `RESTIC_PASSWORD_FILE` | Abrir el repositorio |
| `DATOS_RAIZ` | Destino de los datos restaurados |
| `CF_TUNEL_ID`, `CF_TUNEL_NOMBRE` | Túnel a restaurar |
| `ADMIN_USUARIO`, `SERVIDOR_HOSTNAME`, `LAN_IP` | Identidad del servidor: **deben ser los mismos que antes** |

### 4.2 El problema del huevo y la gallina

Aquí hay una trampa que solo aparece el día de la reconstrucción, y conviene entenderla **antes**:

```
Para abrir el respaldo necesitas   →  RESTIC_USB_UUID, RESTIC_REPO_LOCAL, la contraseña
Esos valores están en              →  config/servidor.env
Y config/servidor.env está en      →  el respaldo
```

Se rompe de tres formas, y conviene tener al menos dos:

| Vía | Cómo | Fiabilidad |
|---|---|---|
| **Copia de `config/servidor.env` en tu equipo** | El `scp` que recomienda el anexo [98 § 5.2](98_variables_y_entorno.md) al terminar cada tanda | La mejor: lo tienes todo |
| **Los cuatro valores en el gestor de contraseñas** | Junto a la contraseña de restic: UUID del disco, punto de montaje, ruta del repositorio y nombre del servidor | Suficiente para abrir el repositorio |
| **Deducirlos del disco** | `sudo blkid` da el UUID; el repositorio se encuentra explorando el disco montado | Funciona, pero a ciegas y con prisa |

**Sin la contraseña no hay ninguna vía.** Es lo único de esta lista que no se puede deducir ni
recuperar.

Anota estos cuatro valores en tu gestor de contraseñas, ahora, junto a la contraseña de restic:

```bash
# [servidor] — con el servidor todavía sano
cd ~/nomad_server && source scripts/lib/entorno.sh
cat <<RESCATE
=== DATOS PARA UNA RECUPERACIÓN ===
 SERVIDOR_HOSTNAME    : ${SERVIDOR_HOSTNAME}
 ADMIN_USUARIO        : ${ADMIN_USUARIO}
 LAN_IP               : ${LAN_IP}
 RESTIC_USB_UUID      : ${RESTIC_USB_UUID}
 RESTIC_USB_MOUNT     : ${RESTIC_USB_MOUNT}
 RESTIC_REPO_LOCAL    : ${RESTIC_REPO_LOCAL}
 RESTIC_PASSWORD_FILE : ${RESTIC_PASSWORD_FILE}
 DATOS_RAIZ           : ${DATOS_RAIZ}
 CF_TUNEL_ID          : ${CF_TUNEL_ID}
 (la contraseña del repositorio NO se imprime aquí: está en tu gestor)
===================================
RESCATE
```

### 4.3 Cómo se reconstruye el entorno durante una recuperación

En el escenario E, el orden correcto es:

1. **Instalar Debian** y entrar por SSH (fase 1). No hay repositorio ni configuración.
2. **Clonar el repositorio** y **copiar `config/servidor.env`** desde tu equipo, exactamente igual
   que en el capítulo [04](04_primer_arranque_y_base.md) paso 2. Si no tienes la copia, crea uno
   nuevo con `make init` y rellena a mano los valores del gestor de contraseñas (§ 4.2).
3. `source scripts/lib/entorno.sh`, y a partir de ahí todos los comandos con `${…}` funcionan.
4. **Después** se abre el respaldo, y la restauración de la fase 3 sobrescribe
   `config/servidor.env` con la versión respaldada, que es la buena. Vuelve a cargar el entorno
   entonces.

### 4.4 Variables temporales de esta sesión

| Variable | Qué contiene | Dónde |
|---|---|---|
| `INSTANTANEA` | Identificador de la instantánea que vas a restaurar (`latest` o un hash) | Escenarios E, F y G |

Declararla evita repetir el mismo identificador en cinco comandos y equivocarse en uno:

```bash
# [servidor]
INSTANTANEA=latest        # o el hash concreto que muestre 'restic snapshots'
```

---

## 5. Procedimiento

### 5.0 Antes de nada: diagnóstico rápido

```
¿Qué ha pasado?
│
├─ Un proyecto no responde
│  └─▶ Escenario A — 5 minutos
│
├─ Ningún proyecto responde, pero entro por SSH
│  └─▶ Escenario B — 15 minutos
│
├─ No entro por SSH, pero el servidor está encendido
│  └─▶ Escenario C — 20 minutos
│
├─ El servidor no arranca
│  └─▶ Escenario D — de 30 minutos a 3 horas
│
├─ El disco está muerto
│  └─▶ Escenario E — 3 horas
│
├─ Borré datos sin querer
│  └─▶ Escenario F — 10 minutos
│
└─ Creo que alguien ha entrado
   └─▶ Escenario G — leer completo antes de tocar nada
```

---

### Escenario A — Un proyecto no responde

**Tiempo: 5 minutos.**

```bash
# [servidor]
cd ${DATOS_RAIZ}/<proyecto>
docker compose ps
docker compose logs --tail 100
```

```bash
# [servidor] — reinicio simple
docker compose restart
```

```bash
# [servidor] — recreación completa
docker compose down && docker compose up -d
```

```bash
# [servidor] — volver a la versión anterior
cd codigo && git log --oneline -5
git checkout <commit-anterior>
cd .. && docker compose up -d --force-recreate
```

Si los datos están dañados, salta al escenario F.

---

### Escenario B — Ningún proyecto responde

**Tiempo: 15 minutos.** El fallo está en la infraestructura compartida.

```bash
# [servidor] — comprobar de fuera hacia dentro
docker ps --format 'table {{.Names}}\t{{.Status}}'
docker logs cloudflared | tail -20
docker logs traefik | tail -20
```

| Síntoma | Causa | Solución |
|---|---|---|
| Error 1033 en el navegador | El túnel está caído | `cd ${CF_CONFIG_DIR} && docker compose restart` |
| Error 502 | Traefik no responde | `cd ${DATOS_RAIZ}/traefik && docker compose restart` |
| Error 404 | Traefik no ve los contenedores | Reinicia `socket-proxy` y después Traefik |
| Nada responde y `docker ps` está vacío | Docker está caído | `sudo systemctl restart docker` |

```bash
# [servidor] — orden de reinicio de la infraestructura
cd ${DATOS_RAIZ}/traefik   && docker compose up -d
cd ${CF_CONFIG_DIR}        && docker compose up -d
```

```bash
# [servidor] — si el problema es de red del host
ping -c2 1.1.1.1
getent hosts deb.debian.org
sudo systemctl restart networking
```

```bash
# [servidor] — si el disco está lleno, que es la causa más frecuente
df -h
docker system prune -f
sudo journalctl --vacuum-size=200M
```

---

### Escenario C — No entro por SSH

**Tiempo: 20 minutos.**

```bash
# [cliente] — probar las dos vías antes de moverse
ssh ${ADMIN_USUARIO}@${LAN_IP}          # por la red local
ssh ${ADMIN_USUARIO}@${TS_HOSTNAME}     # por Tailscale
ping ${LAN_IP}
```

| Situación | Qué hacer |
|---|---|
| Responde al ping pero no a SSH | El servicio SSH está caído: hace falta consola física |
| No responde al ping, pero sí por Tailscale | Problema de red local: revisa el cable y el router |
| No responde por ninguna vía, pero está encendido | Consola física |
| Fui bloqueado por fail2ban | Desde otra IP: `sudo fail2ban-client set sshd unbanip <tu-ip>` |

**Con monitor y teclado conectados:**

```bash
# [servidor] — consola física
systemctl status ssh
sudo journalctl -u ssh -n 50

# ¿la configuración es válida?
sudo sshd -t

# ¿el cortafuegos permite tu red?
sudo nft list chain inet nomad_filter entrada

# rescate: retirar el cortafuegos temporalmente
sudo nft flush ruleset

# rescate: retirar nuestra configuración de sshd
sudo mv /etc/ssh/sshd_config.d/50-nomad.conf /root/
sudo systemctl restart ssh
```

Una vez dentro, corrige y vuelve a aplicar los capítulos [05](05_usuarios_y_acceso_ssh.md) y
[06](06_red_y_firewall.md).

---

### Escenario D — El servidor no arranca

**Tiempo: de 30 minutos a 3 horas.**

**D.1 — No pasa del menú de GRUB, o ni eso.**

Arranca desde el USB del capítulo 01 → **Advanced options → Rescue mode**. Elige
`/dev/mapper/vg0-raiz` como raíz y acepta montar `/boot` y la partición EFI.

```bash
# [rescate]
chroot /target
grub-install /dev/sda
update-grub
exit
reboot
```

**D.2 — GRUB arranca pero el sistema no.**

En el menú de GRUB, **Advanced options** → elige un kernel anterior. Si arranca, el problema es el
kernel más reciente:

```bash
# [servidor]
dpkg --list | grep linux-image
sudo apt purge linux-image-<version-problematica>
sudo update-grub
```

**D.3 — Sistema de archivos dañado.**

```bash
# [rescate] — sin montar
sudo fsck -f /dev/mapper/vg0-raiz
sudo fsck -f /dev/mapper/vg0-var
sudo fsck -f /dev/mapper/vg0-srv
```

**D.4 — No se recupera.** Salta al escenario E: reconstrucción completa.

---

### Escenario E — Reconstrucción completa

**Tiempo: unas 3 horas.** Es el escenario para el que existe todo este repositorio.

**Antes de empezar**, comprueba que tienes lo de la sección 2. Si falta la contraseña del
repositorio restic, para: los datos no se pueden recuperar y el resto del procedimiento no
compensa.

#### Fase 1 — Sistema base (60 min)

Sigue los capítulos [01](01_unidad_usb_booteable.md) a [07](07_endurecimiento_del_sistema.md) tal
como están escritos. Usa **el mismo `SERVIDOR_HOSTNAME`, el mismo `ADMIN_USUARIO` y la misma
`LAN_IP`**: los respaldos contienen configuración que los da por hecho.

Atajo si conservas la ISO verificada y el `config/servidor.env`:

```bash
# [servidor] — tras instalar Debian y entrar por SSH
sudo apt update && sudo apt install -y git
git clone <url-del-repositorio> ~/nomad_server
```

```bash
# [cliente] — la configuración nunca viaja por git
scp config/servidor.env <usuario>@<ip-del-servidor>:~/nomad_server/config/
```

```bash
# [servidor] — reconstruir el entorno de trabajo (§ 4.3)
chmod 600 ~/nomad_server/config/servidor.env
cd ~/nomad_server
source scripts/lib/entorno.sh
./scripts/variables.sh --estado
```

Criterio de aceptación: el resumen muestra los valores del servidor **anterior**, no los del
ejemplo. Si no tienes la copia, créala y rellénala con los datos del gestor de contraseñas:

```bash
# [servidor]
make init
./scripts/variables.sh --fijar SERVIDOR_HOSTNAME=nomad
./scripts/variables.sh --fijar ADMIN_USUARIO=deart
./scripts/variables.sh --fijar LAN_IP=192.168.1.50
./scripts/variables.sh --fijar RESTIC_USB_UUID=a1b2c3d4-e5f6-7890-abcd-ef1234567890
./scripts/variables.sh --fijar CF_TUNEL_ID=8a1b2c3d-4e5f-6789-abcd-ef0123456789
source scripts/lib/entorno.sh
```

```bash
# [servidor] — y ahora sí, los scripts del sistema base
sudo ./scripts/04_base.sh
sudo ./scripts/05_ssh.sh
sudo ./scripts/06_firewall.sh
sudo ./scripts/07_hardening.sh
```

#### Fase 2 — Recuperar el respaldo (10 min)

```bash
# [servidor] — conecta el disco USB de respaldo
sudo apt install -y restic
lsblk -f | grep -i respaldo

sudo mkdir -p ${RESTIC_USB_MOUNT}
sudo mount /dev/disk/by-uuid/${RESTIC_USB_UUID} ${RESTIC_USB_MOUNT}
```

```bash
# [servidor] — restablece la contraseña desde tu gestor
sudo touch ${RESTIC_PASSWORD_FILE}
sudo chmod 600 ${RESTIC_PASSWORD_FILE}
sudo vim ${RESTIC_PASSWORD_FILE}
```

```bash
# [servidor] — comprueba que el repositorio se abre
sudo restic snapshots \
    --repo ${RESTIC_REPO_LOCAL} \
    --password-file ${RESTIC_PASSWORD_FILE}
```

Criterio de aceptación: lista las instantáneas con sus fechas. Si dice `wrong password or no key
found`, la contraseña no coincide; si dice `unable to open config file`, la ruta del repositorio es
otra: explora el disco montado hasta dar con el directorio `restic`.

```bash
# [servidor] — si la ruta no es la esperada, búscala
sudo find ${RESTIC_USB_MOUNT} -maxdepth 3 -name config -path '*restic*' 2>/dev/null
```

**Elige la instantánea y declárala**, para no repetir el identificador en los cinco comandos
siguientes:

```bash
# [servidor]
INSTANTANEA=latest        # o el hash concreto que muestre 'restic snapshots'
echo "Se restaurará: ${INSTANTANEA}"
```

En el escenario G (sospecha de compromiso), **no uses `latest`**: elige un hash claramente anterior
a los indicios.

#### Fase 3 — Restaurar los secretos (10 min)

**Antes que los datos**, porque sin ellos los servicios no arrancan.

```bash
# [servidor]
sudo restic restore ${INSTANTANEA} \
    --repo ${RESTIC_REPO_LOCAL} \
    --password-file ${RESTIC_PASSWORD_FILE} \
    --target / \
    --include /home/${ADMIN_USUARIO}/.cloudflared \
    --include /home/${ADMIN_USUARIO}/nomad_server/config
```

```bash
# [servidor] — comprobar
ls -l ~/.cloudflared/
ls -l ~/nomad_server/config/servidor.env
chmod 600 ~/nomad_server/config/servidor.env
chmod 600 ~/.cloudflared/*.json
```

**Y vuelve a cargar el entorno**, porque acabas de sobrescribir `config/servidor.env` con la versión
respaldada, que es la buena:

```bash
# [servidor]
cd ~/nomad_server
source scripts/lib/entorno.sh
./scripts/variables.sh --faltan
```

Criterio de aceptación: no falta nada, y `CF_TUNEL_ID` coincide con el nombre del archivo de
credenciales que acabas de restaurar:

```bash
# [servidor]
ls ~/.cloudflared/${CF_TUNEL_ID}.json
```

```bash
# [servidor] — consultar el manifiesto: qué había instalado
sudo restic restore ${INSTANTANEA} \
    --repo ${RESTIC_REPO_LOCAL} \
    --password-file ${RESTIC_PASSWORD_FILE} \
    --target /tmp/manifiesto \
    --include /var/backups/nomad
cat /tmp/manifiesto/var/backups/nomad/sistema.txt
cat /tmp/manifiesto/var/backups/nomad/imagenes.txt
```

#### Fase 4 — Conectividad (15 min)

```bash
# [servidor]
cd ~/nomad_server
sudo ./scripts/08_tailscale.sh
sudo ./scripts/09_docker.sh
```

Tailscale reconocerá el nodo si se restauró `/var/lib/tailscale`; si no, habrá que autorizarlo otra
vez y **volver a desactivar la caducidad de clave**.

#### Fase 5 — Restaurar los datos (20 min)

```bash
# [servidor]
sudo restic restore ${INSTANTANEA} \
    --repo ${RESTIC_REPO_LOCAL} \
    --password-file ${RESTIC_PASSWORD_FILE} \
    --target / \
    --include ${DATOS_RAIZ}
```

**Comprobación previa antes del `chown -R`.** Con `${DATOS_RAIZ}` o `${ADMIN_USUARIO}` vacías, ese
comando cambiaría el propietario de la raíz del sistema entero, justo cuando menos falta hace:

```bash
# [servidor]
[ -n "${DATOS_RAIZ}" ] && [ "${DATOS_RAIZ}" != "/" ] && [ -n "${ADMIN_USUARIO}" ] \
  && echo "SEGURO: ${DATOS_RAIZ} para ${ADMIN_USUARIO}" \
  || echo "PARA: carga el entorno antes de continuar"
```

```bash
# [servidor] — el propietario debe ser el administrador, no root
sudo chown -R ${ADMIN_USUARIO}:${ADMIN_USUARIO} ${DATOS_RAIZ}
find ${DATOS_RAIZ} -name '.env' -exec chmod 600 {} \;
ls -la ${DATOS_RAIZ}
```

#### Fase 6 — Servicios (20 min)

```bash
# [servidor] — infraestructura primero
cd ~/nomad_server
./scripts/10_traefik.sh
./scripts/11_cloudflared.sh
./scripts/13_observabilidad.sh
```

```bash
# [servidor] — proyectos, de uno en uno
./scripts/deploy.sh --listar
./scripts/deploy.sh <proyecto>
```

#### Fase 7 — Respaldos y verificación (15 min)

```bash
# [servidor]
sudo ./scripts/14_restic.sh --instalar
./scripts/verificar_sistema.sh
```

```bash
# [cliente] — desde internet
curl -sI https://<proyecto>.${DOMINIO_PUBLICO} | head -3
```

```bash
# [cliente] — desde datos móviles, por Tailscale
ssh ${ADMIN_USUARIO}@${TS_HOSTNAME}
```

**El servidor está reconstruido.**

---

### Escenario F — Recuperar datos borrados

**Tiempo: 10 minutos.**

```bash
# [servidor] — ¿qué instantáneas hay?
sudo restic snapshots \
    --repo ${RESTIC_REPO_LOCAL} \
    --password-file ${RESTIC_PASSWORD_FILE}
```

```bash
# [servidor] — buscar el archivo en el histórico
sudo restic find \
    --repo ${RESTIC_REPO_LOCAL} \
    --password-file ${RESTIC_PASSWORD_FILE} \
    "nombre-del-archivo"
```

```bash
# [servidor] — declara la instantánea elegida (§ 4.4)
INSTANTANEA=<id-de-la-instantanea>
echo "Se restaurará: ${INSTANTANEA}"
```

```bash
# [servidor] — restaurar a un directorio temporal, NUNCA encima del original
sudo restic restore ${INSTANTANEA} \
    --repo ${RESTIC_REPO_LOCAL} \
    --password-file ${RESTIC_PASSWORD_FILE} \
    --target /tmp/recuperado \
    --include /srv/mi-proyecto/datos
```

```bash
# [servidor] — revisa antes de copiar
ls -la /tmp/recuperado/srv/mi-proyecto/datos
diff -r /tmp/recuperado/srv/mi-proyecto/datos ${DATOS_RAIZ}/mi-proyecto/datos
```

```bash
# [servidor] — y solo entonces
cp -a /tmp/recuperado/srv/mi-proyecto/datos/<archivo> ${DATOS_RAIZ}/mi-proyecto/datos/
```

**Para explorar sin restaurar**, restic puede montar el repositorio como un sistema de archivos:

```bash
# [servidor]
sudo mkdir -p /mnt/restic
sudo restic mount /mnt/restic \
    --repo ${RESTIC_REPO_LOCAL} \
    --password-file ${RESTIC_PASSWORD_FILE}
# en otra terminal:
ls /mnt/restic/snapshots/
# para desmontar, Ctrl+C en la primera terminal
```

Es la forma más cómoda de encontrar «la versión de hace tres semanas» sin restaurar nada.

---

### Escenario G — Sospecha de compromiso

**Lee este escenario entero antes de tocar nada.**

**Indicios que lo justifican:** procesos desconocidos, tráfico saliente inexplicable, archivos
modificados sin motivo, accesos SSH que no reconoces, uso de CPU sostenido sin causa.

**Paso 1 — Aislar sin apagar.**

```bash
# [servidor] — desconecta el cable de red, o:
sudo nft flush ruleset
sudo nft add table inet emergencia
sudo nft add chain inet emergencia entrada '{ type filter hook input priority 0; policy drop; }'
sudo nft add chain inet emergencia salida  '{ type filter hook output priority 0; policy drop; }'
```

**No apagues el servidor**: la memoria contiene información sobre lo que estaba pasando, y algunas
intrusiones no dejan rastro en disco.

**Paso 2 — Recoger evidencias, sin limpiar.**

```bash
# [servidor]
mkdir -p /tmp/evidencias && cd /tmp/evidencias
ps auxf > procesos.txt
ss -tulpanw > conexiones.txt
last -20 > accesos.txt
sudo journalctl --since "7 days ago" > journal.txt
docker ps -a > contenedores.txt
sudo find / -mtime -7 -type f -not -path '/proc/*' -not -path '/sys/*' \
    -not -path '/var/lib/docker/*' 2>/dev/null > modificados.txt
sudo debsums -c > paquetes-alterados.txt 2>/dev/null || true
```

Copia ese directorio a un disco externo.

**Paso 3 — Asumir que el sistema no es de fiar.**

Un sistema comprometido no se limpia: se reconstruye. Un atacante con root puede haber modificado
cualquier binario, y no hay forma razonable de comprobarlo todo.

**Paso 4 — Rotar todas las credenciales**, desde otro equipo:

- [ ] Contraseña del usuario administrador
- [ ] Llaves SSH: generar nuevas y eliminar las antiguas de `authorized_keys`
- [ ] Túnel de Cloudflare: crear uno nuevo y borrar el anterior
- [ ] Tailscale: eliminar el nodo y revocar las claves de autenticación
- [ ] Todos los `.env` de los proyectos
- [ ] Contraseñas de bases de datos
- [ ] Cualquier clave de API que estuviera en el servidor

**Paso 5 — Reconstruir** siguiendo el escenario E, con una precaución importante: **restaura los
datos, no la configuración**. La configuración se regenera desde el repositorio, que está limpio.

**Paso 6 — Restaurar de una instantánea anterior al compromiso.** Los respaldos con retención
escalonada del capítulo 14 permiten elegir un punto anterior:

```bash
# [servidor]
sudo restic snapshots --repo ${RESTIC_REPO_LOCAL} --password-file ${RESTIC_PASSWORD_FILE}
# elige una instantánea claramente anterior a los indicios
```

---

## 6. Script asociado

### 6.1 Por qué no hay uno

Este capítulo **no tiene script**, y es deliberado: automatizar una recuperación es peligroso.
Cada escenario requiere decisiones —qué instantánea, qué restaurar, qué conservar— que solo tiene
sentido que tome una persona con el contexto delante. Un script que restaurara «lo último» sobre un
sistema comprometido reintroduciría el compromiso.

Lo que sí está automatizado son las **piezas** de la reconstrucción: los capítulos 04 a 14 tienen
sus scripts, y la fase 1 del escenario E los encadena. Es la diferencia entre automatizar el
montaje —que es repetible— y automatizar la recuperación —que es una decisión.

### 6.2 Lo que sí ayuda

```bash
# [servidor] — estado del sistema de respaldos
sudo ./scripts/14_restic.sh --estado

# [servidor] — instantáneas disponibles
sudo ./scripts/14_restic.sh --listar

# [servidor] — prueba de restauración (también sirve de ensayo)
sudo ./scripts/14_restic.sh --probar

# [servidor] — verificación completa tras recuperar
sudo ./scripts/verificar_sistema.sh

# [servidor] — ¿la configuración quedó completa tras la restauración?
./scripts/variables.sh --faltan
```

### 6.3 Los scripts durante una reconstrucción

En el escenario E se ejecutan en este orden. **Todos leen `config/servidor.env` por su cuenta**, así
que lo único imprescindible es haberlo restaurado o rellenado antes (§ 4.3):

```bash
# [servidor] — sistema base
cd ~/nomad_server
sudo ./scripts/04_base.sh && sudo ./scripts/05_ssh.sh \
  && sudo ./scripts/06_firewall.sh && sudo ./scripts/07_hardening.sh
```

```bash
# [servidor] — conectividad
sudo ./scripts/08_tailscale.sh && sudo ./scripts/09_docker.sh
```

```bash
# [servidor] — servicios, ya sin sudo
./scripts/10_traefik.sh && ./scripts/11_cloudflared.sh && ./scripts/13_observabilidad.sh
```

```bash
# [servidor] — respaldos
sudo ./scripts/14_restic.sh --instalar
```

El encadenado con `&&` es deliberado: si uno falla, los siguientes no se ejecutan sobre un estado
incompleto. Y entre el bloque de conectividad y el de servicios hay que **cerrar sesión y volver a
entrar** para que aplique el grupo `docker` (capítulo [09](09_docker.md) § 5 paso 5), lo que
significa volver a cargar el entorno si estás en la vía manual.

---

## 7. Validación

Este capítulo se valida **ensayándolo**, no leyéndolo.

**Ensayo mínimo (30 minutos, trimestral):**

```bash
# [servidor]
sudo ./scripts/14_restic.sh --probar
```

Criterio de aceptación: `PRUEBA SUPERADA`.

**Ensayo completo (3 horas, anual), en una máquina virtual:**

1. Instala Debian 13 en una VM siguiendo el capítulo 03.
2. Conecta el disco de respaldo, o una copia del repositorio.
3. Ejecuta el escenario E completo.
4. Comprueba que los proyectos arrancan con sus datos.

Criterio de aceptación: la VM llega a un estado equivalente al servidor real. **Cada paso que
necesites improvisar es un fallo de esta documentación**: corrígelo en el capítulo correspondiente.

**Comprobaciones de preparación**, que son las que de verdad determinan si podrás recuperarte:

- [ ] La contraseña del repositorio restic está en el gestor de contraseñas, **fuera del servidor**.
- [ ] El repositorio `nomad_server` está en un remoto o en otro equipo.
- [ ] La llave privada SSH está respaldada en otro sitio.
- [ ] Tengo acceso a Cloudflare y a Tailscale desde otro dispositivo, con 2FA recuperable.
- [ ] Sé dónde está físicamente el disco de respaldo.
- [ ] He hecho la prueba de restauración en los últimos tres meses.
- [ ] Existe una copia del respaldo fuera de casa, o asumo conscientemente ese riesgo.

```bash
# [servidor] — verificación automática de lo comprobable
sudo ./scripts/14_restic.sh --estado
ls -l ~/.cloudflared/*.json
git -C ~/nomad_server remote -v
```

```bash
# [cliente] — ¿tienes la copia de la configuración fuera del servidor?
ls -l ~/nomad_server/config/servidor.env
```

Criterio de aceptación: existe. Si no, cópiala ahora; es la pieza que rompe el problema del huevo y
la gallina de la § 4.2:

```bash
# [cliente]
cd ~/nomad_server && source scripts/lib/entorno.sh
scp ${ADMIN_USUARIO}@${LAN_IP}:~/nomad_server/config/servidor.env ./config/servidor.env
```

```bash
# [servidor] — imprime los datos de rescate para guardarlos en tu gestor (§ 4.2)
cd ~/nomad_server && source scripts/lib/entorno.sh
./scripts/variables.sh --estado
```

---

## 8. Reversión

No aplica: este capítulo describe recuperaciones, no cambios.

**Si una recuperación va mal a mitad**, el principio es siempre el mismo: **no sobrescribas el
origen**. Restaura a un directorio temporal, revisa, y solo entonces copia. Las instantáneas de
restic son de solo lectura y no se pueden estropear restaurando mal, así que siempre se puede
volver a empezar.

---

## 9. Errores frecuentes

| Síntoma | Causa probable | Solución | Documentación |
|---|---|---|---|
| «wrong password or no key found» | La contraseña no coincide | Comprueba que no hay espacios ni salto de línea extra. **Si se perdió, no hay recuperación posible** | Capítulo [14](14_respaldos_restic.md) § 3.8 |
| El disco de respaldo no monta | Cambió la letra de dispositivo | Monta por UUID: `sudo mount /dev/disk/by-uuid/<uuid> /mnt/respaldo` | Capítulo [14](14_respaldos_restic.md) § 3.3 |
| Tras restaurar, los proyectos no arrancan | Faltan los `.env` o perdieron permisos | Restaura los secretos primero y ejecuta `chmod 600` (fase 3) | § 3.2 |
| Tras restaurar, «permission denied» en los datos | El propietario quedó como root | `sudo chown -R ${ADMIN_USUARIO}: ${DATOS_RAIZ}` | § 5 fase 5 |
| El túnel no conecta tras reconstruir | No se restauró `~/.cloudflared` | Restáuralo, o crea un túnel nuevo y rehaz los registros DNS | Capítulo [11](11_cloudflared_y_dominio.md) |
| Tailscale pide autorizar de nuevo | No se restauró `/var/lib/tailscale` | Autoriza y **vuelve a desactivar la caducidad de clave** | Capítulo [08](08_tailscale.md) § 3.4 |
| `restic restore` tarda muchísimo | Se restaura todo en lugar de lo necesario | Usa `--include` para acotar | [restic — Restaurar](https://restic.readthedocs.io/en/stable/050_restore.html) |
| No sé qué instantánea elegir | Sin referencia temporal del incidente | `restic snapshots` muestra fechas. Ante la duda, elige una claramente anterior | § 5 escenario F |
| Restauré encima del original y ahora está peor | Se restauró directamente sobre los datos | Restaura siempre a `/tmp` primero, revisa, y luego copia | § 8 |
| El servidor reconstruido tiene otra IP | Se usó una `LAN_IP` distinta | Usa la misma. Si cambia, actualiza el cortafuegos, `~/.ssh/config` y el router | Capítulo [06](06_red_y_firewall.md) |
| Faltan imágenes de contenedor y no hay internet | Las imágenes no se respaldan a propósito | La recuperación necesita conexión. El manifiesto dice qué versiones había | § 3.3 |
| Descubro que el respaldo llevaba meses fallando | No había monitor de respaldo | Configúralo (capítulo 14 § 3.6). La ausencia de aviso es la que detecta el fallo | Capítulo [14](14_respaldos_restic.md) |
| No sé el UUID del disco ni la ruta del repositorio | No había copia de `config/servidor.env` fuera del servidor | `sudo blkid` para el UUID; explora el disco montado para el repositorio | § 4.2 |
| Los comandos de restauración fallan con rutas vacías | El entorno no está cargado: el servidor es nuevo | Restaura o rellena `config/servidor.env` **antes** | § 4.3 |
| `chown -R` cambió el propietario de todo el sistema | `${DATOS_RAIZ}` vacía durante la fase 5 | Restaura desde el respaldo. La comprobación de la fase 5 existe para esto | § 5 fase 5 |
| Restauré `config/servidor.env` y los comandos siguen con valores viejos | La sesión conserva lo que cargó antes | `source scripts/lib/entorno.sh` de nuevo | § 4.3 |
| Restauré la última instantánea sobre un sistema comprometido | En el escenario G hay que elegir una anterior | Vuelve a restaurar desde un hash previo a los indicios | § 5 escenario G |
| El túnel no arranca tras restaurar | El `CF_TUNEL_ID` de la configuración no coincide con el archivo de credenciales restaurado | Compáralos y corrige con `--fijar` | § 5 fase 3 |

---

## 10. Referencias

- [restic — Restaurar](https://restic.readthedocs.io/en/stable/050_restore.html)
- [restic — Montar el repositorio](https://restic.readthedocs.io/en/stable/050_restore.html#restore-using-mount)
- [Debian — Modo rescate del instalador](https://www.debian.org/releases/trixie/amd64/ch08s07)
- [Debian Wiki — GRUB: recuperación](https://wiki.debian.org/GRUB)
- [Debian Wiki — fsck](https://wiki.debian.org/fsck)
- [Debian — Manual de seguridad: tras un compromiso](https://www.debian.org/doc/manuals/securing-debian-manual/ch-after-compromise.en.html)
- Anexo [97 — Las dos vías de montaje](97_vias_de_montaje.md) § 3.3, la secuencia completa con scripts
- Anexo [98 — Variables, entorno y sesiones](98_variables_y_entorno.md) § 5.2, la copia de la configuración fuera del servidor

---

**Anterior:** [15 — Mantenimiento y actualizaciones](15_mantenimiento_y_actualizaciones.md) · **Siguiente:** [97 — Las dos vías de montaje](97_vias_de_montaje.md)
