# 95 · Desplegar un proyecto, paso a paso

> **Qué es esto.** La secuencia lineal para llevar un proyecto desde su repositorio hasta estar
> publicado en internet, sin decisiones y sin explicaciones. Un guion para seguir con el terminal
> abierto.
>
> **Qué NO es.** No sustituye a nada:
>
> | Si buscas… | Ve a |
> |---|---|
> | **Cómo debe estar construido** el proyecto, y por qué cada regla | [96 — Contrato de dockerización](96_contrato_de_dockerizacion.md) |
> | **Por qué** el servidor se despliega así y qué alternativas se descartaron | [12 — Despliegue de proyectos](12_despliegue_de_proyectos.md) |
> | **De dónde sale** cada `${VALOR}` | [98 — Variables y entorno](98_variables_y_entorno.md) |
>
> Aquí solo está el orden. **El orden importa**: cada paso comprueba algo que el siguiente da por
> hecho.

---

## La hoja de ruta en una pantalla

```
  0 · Preparar la sesión                      ~1 min
  1 · Acceso al repositorio (llave de despliegue)  ~5 min   ← solo la primera vez por proyecto
  2 · Registro DNS                            ~2 min
  3 · Estructura y código                     ~3 min
  4 · Secretos                                ~5 min
  5 · Gancho de volcado                       ~2 min   ← SOLO si hay base de datos
  6 · Auditar                                 ~1 min   ← si no sale limpio, no sigas
  7 · Desplegar                               2–10 min
  8 · Contenido inicial                       variable ← SOLO si hay base de datos o CMS
  9 · Comprobar desde fuera                   ~1 min
 10 · Monitor en Uptime Kuma                  ~2 min   ← sin esto no está terminado
```

---

## Los dos caminos

Casi todo es común. Esto es lo único que cambia:

| | **Proyecto estático** | **Proyecto con base de datos** |
|---|---|---|
| Ejemplos | Sitio HTML, SPA compilada, documentación | Laravel, WordPress, cualquier CMS o API con persistencia |
| Servicios en el compose | Uno | Dos o más |
| Red interna | No hace falta | **Obligatoria**: la base de datos nunca toca `${DOCKER_RED_PROXY}` |
| `datos-db/` | No | Sí |
| Paso 5 — gancho de volcado | Se salta | **Obligatorio antes del primer respaldo** |
| Paso 8 — contenido inicial | Se salta | Migraciones, semillas, usuario administrador |
| Antes de un despliegue con migraciones | Nada especial | Respaldo a mano primero |

**Para un proyecto estático**, parte del compose de referencia de
[`templates/compose/proyecto-ejemplo/`](../templates/compose/proyecto-ejemplo/) y quita tres cosas:
el servicio `db`, la red `interna` y el bloque `depends_on`. Lo demás —etiquetas de Traefik,
healthcheck, `no-new-privileges`, `restart`— se queda igual.

---

## Paso 0 · Preparar la sesión

```bash
# [servidor]
cd ~/nomad_server
source scripts/lib/entorno.sh
```

Hay que repetirlo **en cada sesión nueva**: al reconectar por SSH, tras reiniciar, al abrir otra
terminal. Sin esto, las variables entre llaves de más abajo se expanden a nada y algún comando hará
algo distinto de lo que parece.

Declara el nombre del proyecto una vez, y no lo vuelvas a teclear:

```bash
# [servidor]
PROYECTO=<nombre>
echo "${PROYECTO}"
```

Ese nombre es **tres cosas a la vez**: el directorio bajo `${DATOS_RAIZ}`, el prefijo de los
contenedores y el nombre del router de Traefik. Que coincida con el subdominio.

---

## Paso 1 · Acceso al repositorio

Solo la primera vez que se despliega ese proyecto. `deploy.sh` hace `git pull` en cada despliegue,
así que el servidor necesita acceso **permanente**, no un `git clone` con tu llave personal.

Primero, averigua si el repositorio es privado:

```bash
# [servidor]
curl -s -o /dev/null -w '%{http_code}\n' https://api.github.com/repos/<org>/<repo>
```

`200` es público: **salta al paso 2** y clona por HTTPS. `404` significa privado, y entonces hace
falta una llave de despliegue.

**Una llave por proyecto, y de solo lectura.** Si se filtra, no compromete a los demás repositorios
ni permite escribir en este.

```bash
# [servidor]
ssh-keygen -t ed25519 -C "${SERVIDOR_HOSTNAME}:${PROYECTO}" -f ~/.ssh/${PROYECTO}_deploy -N ''
cat ~/.ssh/${PROYECTO}_deploy.pub
```

Sin frase de paso (`-N ''`) a propósito: el despliegue no es interactivo y nadie va a teclearla a
las tres de la mañana. La llave queda en `~/.ssh` del usuario administrador, con permisos `600`, y
solo sirve para leer un repositorio.

Pega esa clave pública en el repositorio → *Settings* → *Deploy keys* → *Add deploy key*.
**Sin marcar *Allow write access*.**

Ahora un alias de host, para que git use esa llave y solo esa:

```bash
# [servidor]
cat >> ~/.ssh/config <<SSH

Host github-${PROYECTO}
    HostName github.com
    User git
    IdentityFile ~/.ssh/${PROYECTO}_deploy
    IdentitiesOnly yes
SSH
chmod 600 ~/.ssh/config
```

`IdentitiesOnly yes` no es decorativo: sin él, ssh ofrece todas tus llaves por orden y GitHub acepta
la primera que reconozca, que puede ser la tuya personal. Funcionaría hoy y fallaría el día que esa
llave cambie.

```bash
# [servidor] — comprobación
ssh -T git@github-${PROYECTO}
```

Sale con **código 1 aunque haya ido bien**. Lo que importa es que el mensaje diga
`successfully authenticated`.

---

## Paso 2 · Registro DNS

**Antes de desplegar, no después**: el auditor del paso 6 comprueba que el nombre resuelva.

```bash
# [servidor]
./scripts/11_cloudflared.sh --ruta ${PROYECTO}
dig @1.1.1.1 ${PROYECTO}.${DOMINIO_PUBLICO} +short
```

Debe devolver **IPs de Cloudflare**, no el nombre del túnel: el registro es proxificado, que es lo
correcto. Si sale vacío justo después de crearlo, casi siempre es caché del resolutor local — por
eso la consulta va contra `1.1.1.1`.

El túnel usa una única regla `ingress` hacia Traefik, así que no hay nada más que configurar por
cada host.

---

## Paso 3 · Estructura y código

```bash
# [servidor]
mkdir -p ${DATOS_RAIZ}/${PROYECTO}/datos
cd ${DATOS_RAIZ}/${PROYECTO}
```

Con base de datos, un directorio más:

```bash
# [servidor] — solo si hay base de datos
mkdir -p ${DATOS_RAIZ}/${PROYECTO}/datos-db
```

Clona el código **dentro** del directorio del proyecto, en `codigo/`:

```bash
# [servidor] — repositorio privado
git clone git@github-${PROYECTO}:<org>/<repo>.git codigo

# [servidor] — repositorio público
git clone https://github.com/<org>/<repo>.git codigo
```

Y sube un nivel el compose y las variables. **Esto no es un capricho**: `deploy.sh` hace `git pull`
dentro de `codigo/`, así que lo que viva ahí se sobrescribe en cada despliegue. El compose y el
`.env` viven un nivel por encima, fuera del alcance de `git pull`.

```bash
# [servidor]
cp codigo/deploy/nomad/docker-compose.yml .
cp codigo/deploy/nomad/.env.example .env
chmod 600 .env
```

Si el proyecto no trae `deploy/nomad/`, hay que escribirlo antes: eso es el
[anexo 96](96_contrato_de_dockerizacion.md), no este documento.

---

## Paso 4 · Secretos

Que no pasen por el terminal ni queden en el historial:

```bash
# [servidor]
sed -i "s/^APP_KEY=.*/APP_KEY=$(openssl rand -hex 32)/" .env
sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=$(openssl rand -hex 32)/" .env
${EDITOR:-vi} .env          # revisa el resto a mano
```

```bash
# [servidor] — comprobaciones
grep -c CAMBIAME .env       # tiene que dar 0
stat -c '%a' .env           # tiene que dar 600
```

Contrasta que la red y la subred del `.env` son **las de este servidor** y no las de la plantilla:

```bash
# [servidor]
echo "${DOCKER_RED_PROXY}  ${DOCKER_RED_PROXY_SUBRED}"
docker network ls | grep "${DOCKER_RED_PROXY}"
```

Una subred equivocada en `TRUSTED_PROXIES` no rompe nada visible: solo hace que el proyecto vea
todas las visitas como si vinieran de la misma dirección, y el limitador de peticiones colapse en
un único cubo para todo el mundo.

---

## Paso 5 · Gancho de volcado

**Solo si hay base de datos.** Si el proyecto es estático, salta al paso 6.

Una base de datos respaldada en caliente, copiando sus ficheros, produce una copia que restaura
mal. El gancho vuelca la base a un fichero antes de que restic pase.

```bash
# [servidor]
sudo mkdir -p /etc/nomad/pre-respaldo.d
sudo install -m 700 ${DATOS_RAIZ}/${PROYECTO}/codigo/deploy/nomad/pre-respaldo-<motor>.sh \
     /etc/nomad/pre-respaldo.d/10-${PROYECTO}-<motor>.sh
ls -l /etc/nomad/pre-respaldo.d/
```

Si el proyecto no trae el suyo, hay una plantilla por motor en
[`templates/etc/`](../templates/etc/): `pre-respaldo-postgres.sh`, `pre-respaldo-mysql.sh`,
`pre-respaldo-mongodb.sh`.

**No lo ejecutes todavía**: no hay base que volcar hasta después del despliegue. Se prueba en el
paso 8.

---

## Paso 6 · Auditar

```bash
# [servidor]
cd ~/nomad_server
./scripts/revisar_proyecto.sh ${PROYECTO}
```

**Tiene que cerrar en verde.** Si queda algo, corrígelo aquí: cada punto pendiente es algo que
fallará más tarde y con peor información.

`[AVISO] Hay bases de datos: db` es informativo, no un fallo.

> Desde el capítulo 17, el conserje ejecuta esta misma revisión **solo** cuando aparece un proyecto
> nuevo, y una vez al día sobre todos. Que lo haga la máquina no te exime de mirarlo aquí: el
> conserje avisa *después*, y este paso existe para no desplegar algo roto.

---

## Paso 7 · Desplegar

```bash
# [servidor]
./scripts/deploy.sh ${PROYECTO} --check
./scripts/deploy.sh ${PROYECTO}
```

**Sin `sudo`.** `deploy.sh` aborta si se ejecuta como root.

Dos cosas normales que **no** son errores: un aviso de que alguna imagen no se pudo descargar —la
del proyecto se construye aquí, no vive en ningún registro— y que la primera construcción tarde
varios minutos.

`deploy.sh` guarda el estado actual, actualiza el código, construye, levanta, espera a que los
servicios estén sanos y **revierte solo si no lo consiguen**.

⚠️ **La reversión devuelve el código y la configuración; NO deshace migraciones de base de datos.**
Antes de un despliegue que las traiga:

```bash
# [servidor] — solo con base de datos y migraciones nuevas
sudo ~/nomad_server/scripts/14_restic.sh --ahora
```

---

## Paso 8 · Contenido inicial

**Solo si hay base de datos o un CMS.** Si el proyecto es estático, salta al paso 9.

Las migraciones las aplicó el arranque; el contenido no. Siembra lo que el proyecto tenga y crea el
usuario administrador **sin dejar la contraseña en el historial**:

```bash
# [servidor]
cd ${DATOS_RAIZ}/${PROYECTO}
read -rs -p 'Contraseña admin: ' PW; echo
docker compose exec -T -e ADMIN_PASSWORD="$PW" app <comando de creación>
unset PW
```

Y ahora sí, prueba el gancho contra una base que ya tiene datos:

```bash
# [servidor]
sudo /etc/nomad/pre-respaldo.d/10-${PROYECTO}-<motor>.sh && echo CORRECTO
ls -l /var/backups/nomad/volcados/
```

Un gancho que nunca se ha ejecutado no es un gancho, es un fichero.

---

## Paso 9 · Comprobar desde fuera

Desde tu equipo, no desde el servidor: lo que importa es el camino completo.

```bash
# [cliente]
curl -sS -o /dev/null -m 15 -w 'HTTP %{http_code}\n' https://${PROYECTO}.${DOMINIO_PUBLICO}/
curl -sSI https://${PROYECTO}.${DOMINIO_PUBLICO}/ | grep -iE 'x-frame|x-content|referrer'
```

Criterio: **`200` y las tres cabeceras presentes**. Si llegan las cabeceras, el middleware
`publico@file` se está aplicando de verdad y no solo carga la página.

Y comprueba que no publicó puertos por accidente:

```bash
# [servidor]
docker compose -f ${DATOS_RAIZ}/${PROYECTO}/docker-compose.yml ps --format '{{.Ports}}'
```

No debe aparecer `0.0.0.0` en ninguna línea.

---

## Paso 10 · Monitor en Uptime Kuma

En `${UPTIME_KUMA_HOST}`, por túnel SSH o por la tailnet: *Add New Monitor* → **HTTP(s)**.

| Campo | Valor |
|---|---|
| URL | `https://<proyecto>.<dominio público>/` |
| Heartbeat Interval | 60 |
| Notificación | la misma de Telegram que usan el respaldo y la auditoría |

**Es el paso que hace que te enteres si se cae.** Sin él, el despliegue no está terminado: tienes un
sitio publicado del que nadie vigila nada.

---

## Actualizaciones posteriores

```bash
# [servidor]
cd ~/nomad_server && ./scripts/deploy.sh ${PROYECTO}
```

Eso basta cuando solo cambió el código. Si el cambio tocó `docker-compose.yml` o `.env.example`,
hay que volver a subirlos: **`git pull` actualiza `codigo/`, no lo que vive un nivel por encima**.

```bash
# [servidor]
cd ${DATOS_RAIZ}/${PROYECTO}
cp codigo/deploy/nomad/docker-compose.yml .
diff codigo/deploy/nomad/.env.example .env      # ¿variables nuevas que rellenar?
cd ~/nomad_server && ./scripts/deploy.sh ${PROYECTO}
```

Ese `diff` es el paso que más se olvida. Una variable nueva en el `.env.example` que no llega al
`.env` deja al proyecto arrancando con un valor por defecto que nadie eligió.

---

## Retirar un proyecto

```bash
# [servidor] — parar conservando los datos
cd ${DATOS_RAIZ}/${PROYECTO} && docker compose down
```

```bash
# [servidor] — eliminarlo por completo
# COMPROBACIÓN OBLIGATORIA antes de un rm -rf con una variable dentro:
echo "Se borraría: ${DATOS_RAIZ}/${PROYECTO}"
```

```bash
# [servidor] — y solo si la línea anterior mostró la ruta correcta
sudo rm -rf ${DATOS_RAIZ}/${PROYECTO}
sudo rm -f /etc/nomad/pre-respaldo.d/10-${PROYECTO}-*.sh
rm -f ~/.ssh/${PROYECTO}_deploy ~/.ssh/${PROYECTO}_deploy.pub
```

Quita también su registro DNS en Cloudflare, su monitor en Uptime Kuma y la llave de despliegue en
el repositorio. El conserje del capítulo 17 retirará solo su informe de auditoría.

---

## Qué hace el servidor por su cuenta, una vez desplegado

Para que no lo busques a mano:

| Cuándo | Qué |
|---|---|
| Al aparecer el proyecto en `${DATOS_RAIZ}` | El conserje ejecuta `revisar_proyecto.sh` y deja el veredicto |
| Cada noche | restic respalda `${DATOS_RAIZ}` entero, cifrado, con el volcado de las bases previo |
| Cada mañana | La auditoría publica el informe de estado y avisa si algo falla |
| Continuamente | Uptime Kuma vigila la URL pública, si creaste el monitor del paso 10 |

---

## Errores frecuentes

| Síntoma | Causa | Solución |
|---|---|---|
| `Permission denied (publickey)` al clonar | La llave de despliegue no está en el repositorio, o falta el alias en `~/.ssh/config` | `ssh -T git@github-<proyecto>` y revisa el paso 1 |
| `git pull` en el despliegue pide frase de paso | Se creó la llave con frase, o git usa tu llave personal | Recrea la llave con `-N ''` y comprueba `IdentitiesOnly yes` |
| El subdominio no resuelve | Falta el registro DNS | Paso 2. Consulta contra `1.1.1.1`, no contra el resolutor local |
| `revisar_proyecto.sh` falla en la regla 8 | Dos proyectos usan el mismo nombre de router | Prefija el router con el nombre del proyecto |
| Error de TLS en el navegador, pero el DNS resuelve y el contenedor responde | El host tiene dos niveles (`api.proyecto.dominio`). El *Universal SSL* de Cloudflare solo cubre un nivel | Usa un subdominio plano. Capítulo [11](11_cloudflared_y_dominio.md) § 3.4 |
| HTTP 502 desde internet | El contenedor no está en `${DOCKER_RED_PROXY}`, o el puerto de la etiqueta no coincide | Capítulo [10](10_traefik.md) |
| HTTP 404 desde internet | Traefik no tiene router para ese host | Revisa `traefik.enable=true` y la regla |
| Cambié el `.env` y no pasa nada | `deploy.sh` no recrea contenedores por un cambio de variables | `docker compose up -d --force-recreate` en el directorio del proyecto |
| El healthcheck nunca pasa a `healthy` | El comando de comprobación no existe en la imagen | En Alpine, `wget -q -O /dev/null`. Capítulo [12](12_despliegue_de_proyectos.md) § 9 |
| La reversión dejó la base de datos rara | `deploy.sh` no deshace migraciones | Restaura desde el respaldo. Capítulo [16](16_recuperacion_ante_desastres.md) |

---

## Referencias

- [96 — Contrato de dockerización](96_contrato_de_dockerizacion.md) — las nueve reglas y su porqué
- [12 — Despliegue de proyectos](12_despliegue_de_proyectos.md) — decisiones, script y reversión
- [11 — Cloudflared y dominio](11_cloudflared_y_dominio.md) — cómo se crean las rutas
- [14 — Respaldos con restic](14_respaldos_restic.md) — ganchos de volcado y restauración
- [17 — Auditoría automática](17_auditoria_del_servidor.md) — el conserje y el informe diario
- [98 — Variables y entorno](98_variables_y_entorno.md) — de dónde sale cada valor
