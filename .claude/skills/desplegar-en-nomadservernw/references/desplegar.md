# Desplegar

El orden importa: cada paso comprueba algo que el siguiente da por hecho.
Sustituye `<proyecto>` por el nombre real, que es a la vez el directorio, el
prefijo de los contenedores y el router.

## 0 · Acceso al repositorio

`deploy.sh` hace `git pull` en `codigo/` en cada despliegue, así que el servidor
necesita acceso permanente al repositorio. Compruébalo antes de nada:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://api.github.com/repos/<org>/<repo>
```

`404` significa privado, y entonces hace falta una llave de despliegue. Una por
proyecto y de solo lectura: si se filtra, no compromete a los demás
repositorios ni permite escribir en este.

```bash
# [servidor]
ssh-keygen -t ed25519 -C "nomadservernw:<proyecto>" -f ~/.ssh/<proyecto>_deploy -N ''
cat ~/.ssh/<proyecto>_deploy.pub
```

Esa clave se pega en GitHub → el repositorio → *Settings* → *Deploy keys*, **sin**
*Allow write access*. Y se le da un alias de host para que git use esa llave y
solo esa:

```bash
# [servidor]
cat >> ~/.ssh/config <<'SSH'

Host github-<proyecto>
    HostName github.com
    User git
    IdentityFile ~/.ssh/<proyecto>_deploy
    IdentitiesOnly yes
SSH
chmod 600 ~/.ssh/config
ssh -T git@github-<proyecto>
```

`ssh -T` contra GitHub sale con código 1 aunque la autenticación haya ido bien.
Lo que importa es que diga `successfully authenticated`.

## 1 · Registro DNS

Antes de desplegar, no después: el auditor comprueba que el nombre resuelva.

```bash
# [servidor]
cd ~/nomad_server && source scripts/lib/entorno.sh
./scripts/11_cloudflared.sh --ruta <proyecto>
dig @1.1.1.1 <proyecto>.${DOMINIO_PUBLICO} +short
```

Debe devolver **IPs de Cloudflare**, no el nombre del túnel: el registro es
proxificado, que es lo correcto. Si sale vacío justo después de crearlo, casi
siempre es caché del resolutor local — por eso la consulta va contra `1.1.1.1`.
El túnel usa una regla `ingress` única hacia Traefik, así que no hay nada más
que configurar por host.

## 2 · Estructura y código

```bash
# [servidor]
mkdir -p ${DATOS_RAIZ}/<proyecto>/{datos,datos-db}
cd ${DATOS_RAIZ}/<proyecto>
git clone git@github-<proyecto>:<org>/<repo>.git codigo
cp codigo/deploy/nomad/docker-compose.yml .
cp codigo/deploy/nomad/.env.example .env
chmod 600 .env
```

## 3 · Secretos

Que no pasen por el terminal ni queden en el historial:

```bash
# [servidor]
sed -i "s/^APP_KEY=.*/APP_KEY=$(openssl rand -hex 32)/" .env
sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=$(openssl rand -hex 32)/" .env
vim .env                 # revisa el resto
grep -c CAMBIAME .env    # 0
stat -c '%a' .env        # 600
```

Contrasta que la red y la subred del `.env` son las del servidor:

```bash
echo "${DOCKER_RED_PROXY} ${DOCKER_RED_PROXY_SUBRED}"
docker network ls | grep "${DOCKER_RED_PROXY}"
```

## 4 · Gancho de volcado

Solo si el proyecto tiene base de datos.

```bash
# [servidor]
sudo mkdir -p /etc/nomad/pre-respaldo.d
sudo install -m 700 ${DATOS_RAIZ}/<proyecto>/codigo/deploy/nomad/pre-respaldo-<motor>.sh \
     /etc/nomad/pre-respaldo.d/10-<proyecto>-<motor>.sh
ls -l /etc/nomad/pre-respaldo.d/
```

No lo ejecutes todavía: no hay base que volcar hasta después del despliegue.

## 5 · Auditar

```bash
# [servidor]
cd ~/nomad_server
./scripts/revisar_proyecto.sh <proyecto>
```

Tiene que cerrar en verde. Si queda algo, corrígelo aquí: cada punto pendiente
es algo que fallará más tarde y con peor información. El `[AVISO] Hay bases de
datos` es informativo, no un fallo.

## 6 · Desplegar

```bash
# [servidor]
./scripts/deploy.sh <proyecto> --check
./scripts/deploy.sh <proyecto>
```

**Sin `sudo`**: `deploy.sh` aborta como root.

Dos cosas normales que no son errores: un aviso de que alguna imagen no se pudo
descargar —la del proyecto se construye aquí, no vive en ningún registro— y que
la primera construcción tarde varios minutos.

`deploy.sh` guarda el estado, actualiza el código, construye, levanta, espera a
que los servicios estén sanos y **revierte solo si no lo consiguen**. La
reversión devuelve el código y la configuración; **no** deshace migraciones de
base de datos. Antes de un despliegue con migraciones:

```bash
sudo ~/nomad_server/scripts/14_restic.sh --ahora
```

## 7 · Contenido inicial

Las migraciones ya las aplicó el arranque; el contenido no. Siembra lo que el
proyecto tenga, y crea el usuario administrador sin dejar la contraseña en el
historial:

```bash
# [servidor]
cd ${DATOS_RAIZ}/<proyecto>
read -rs -p 'Contraseña admin: ' PW; echo
docker compose exec -T -e ADMIN_PASSWORD="$PW" app <comando de creación>
unset PW
```

Y ahora sí, prueba el gancho contra una base con datos:

```bash
sudo /etc/nomad/pre-respaldo.d/10-<proyecto>-<motor>.sh && echo CORRECTO
```

## 8 · Comprobar desde fuera

```bash
curl -sS -o /dev/null -m 15 -w 'HTTP %{http_code}\n' https://<proyecto>.${DOMINIO_PUBLICO}/
curl -sSI https://<proyecto>.${DOMINIO_PUBLICO}/ | grep -iE 'x-frame|x-content|referrer'
```

Criterio: `200` y las cabeceras presentes. Si llegan las cabeceras, el
middleware `publico@file` se está aplicando de verdad y no solo carga la página.

## 9 · Monitor

Añádelo en Uptime Kuma: HTTP(s), la URL pública, intervalo 60 s. Es el paso que
hace que te enteres si se cae; sin él, el despliegue no está terminado.

## Actualizaciones

```bash
cd ~/nomad_server && ./scripts/deploy.sh <proyecto>
```

Si el cambio toca `docker-compose.yml` o `.env.example`, vuelve a copiarlos:
`git pull` actualiza `codigo/`, no lo que vive un nivel por encima.

```bash
cd ${DATOS_RAIZ}/<proyecto>
cp codigo/deploy/nomad/docker-compose.yml .
diff codigo/deploy/nomad/.env.example .env    # ¿variables nuevas?
```
