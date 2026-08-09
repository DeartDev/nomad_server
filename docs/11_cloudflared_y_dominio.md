# 11 — Cloudflared y dominio

> El puente con internet: un túnel que **sale** del servidor hacia Cloudflare, de modo que tus
> proyectos son accesibles desde el mundo sin que el mundo pueda alcanzar tu casa.

---

## 1. Objetivo

Al terminar tendrás un túnel de Cloudflare permanente que entrega todo el tráfico de tus subdominios
a Traefik, con certificados TLS gestionados por Cloudflare, y sin haber abierto un solo puerto en tu
router.

---

## 2. Requisitos previos

**Capítulos previos:** [10 — Traefik](10_traefik.md), funcionando y validado.

**Necesitas a mano:**

- Cuenta de Cloudflare con verificación en dos pasos.
- **Un dominio con los servidores de nombres delegados a Cloudflare.** Este es el único capítulo que
  lo exige de verdad.
- Un navegador para autorizar `cloudflared`.

**Si aún no tienes dominio**, puedes leer el capítulo entero y aplicarlo hasta el paso 3: el túnel se
crea igual. Los registros DNS (paso 6) esperan a que lo adquieras. Un dominio `.com` cuesta unos
10–15 € al año; `.dev`, `.app` o `.xyz` suelen ser más baratos.

**Tiempo estimado:** 40 minutos, más la propagación de DNS.

---

## 3. Decisiones y por qué

### 3.1 Túnel saliente en lugar de puertos abiertos

**Decisión: Cloudflare Tunnel.**

```
                 ┌── CON PUERTOS ABIERTOS (lo que NO hacemos) ──┐
   internet ────▶│ router: 80/443 abiertos ────▶ servidor       │
                 │ tu IP doméstica es pública y escaneable      │
                 └─────────────────────────────────────────────┘

                 ┌── CON TÚNEL SALIENTE (lo que hacemos) ───────┐
   internet ────▶│ Cloudflare ◀══ conexión iniciada por ══ servidor │
                 │              cloudflared                      │
                 │ el router no tiene ningún puerto abierto      │
                 └─────────────────────────────────────────────┘
```

Qué se gana, en concreto:

| Ventaja | Detalle |
|---|---|
| Nada que escanear | Un escaneo de puertos a tu IP doméstica no encuentra nada, porque no hay nada escuchando |
| Sin IP fija ni DNS dinámico | La conexión la inicia el servidor. Si tu IP cambia, el túnel se restablece solo |
| TLS resuelto | Cloudflare emite y renueva los certificados. No hay nada que caduque |
| Protección en el borde | Filtrado de abuso, límites de frecuencia y caché antes de que el tráfico llegue a tu casa |
| Tu IP doméstica no se publica | Los visitantes ven direcciones de Cloudflare |

| Alternativa descartada | Por qué |
|---|---|
| Redirección de puertos + Let's Encrypt | Expone la IP de tu casa y requiere IP fija o DNS dinámico. Muchos proveedores domésticos usan CGNAT, con lo que ni siquiera es posible |
| Un VPS con proxy inverso hacia casa | Funciona, y cuesta dinero todos los meses para hacer lo que Cloudflare hace gratis |
| Tailscale Funnel | Publicaría desde la misma infraestructura que usas para administrar. Separarlas es deliberado (capítulo 08 § 3.1) |
| ngrok y similares | Pensados para pruebas temporales, no para un servicio permanente |

**Lo que se acepta a cambio:** todo el tráfico de tus visitantes pasa por Cloudflare, que puede verlo
descifrado. Para proyectos personales y portafolios es un intercambio razonable. Para datos
sensibles de terceros, habría que pensarlo.

### 3.2 Túnel gestionado localmente, no desde el panel

**Decisión: crear el túnel con la CLI y guardar su configuración en un archivo.**

Cloudflare ofrece dos formas de gestionar un túnel:

| Modo | Dónde vive la configuración | Reproducible |
|---|---|---|
| **Gestionado localmente** (el elegido) | En `config.yml`, en tu servidor y en tu repositorio | Sí: se puede versionar, revisar y restaurar |
| Gestionado en remoto | En la base de datos de Cloudflare, editable en el panel | No: para reconstruirlo hay que recordar qué se pulsó |

El modo remoto es más rápido de poner en marcha —se copia un token y listo— y por eso lo recomienda
la mayoría de tutoriales. Pero contradice el objetivo entero de este repositorio: que el servidor se
pueda reconstruir desde cero siguiendo un procedimiento escrito.

### 3.3 Una sola regla de entrada

**Decisión: el `ingress` del túnel tiene una única regla que envía todo a Traefik.**

```yaml
ingress:
  - service: http://traefik:80
```

Es la pieza que hace que añadir un proyecto sea trivial. La alternativa habitual es declarar cada
subdominio en el túnel:

```yaml
# Lo que NO hacemos
ingress:
  - hostname: blog.midominio.com
    service: http://blog:3000
  - hostname: api.midominio.com
    service: http://api:8000
  - service: http_status:404
```

Con esa forma, cada proyecto nuevo obliga a editar la configuración del túnel y **reiniciarlo**, lo
que interrumpe brevemente a todos los demás. Y la configuración del enrutado queda repartida entre
dos sitios.

Con la regla única, el reparto lo hace Traefik leyendo etiquetas. **Publicar un proyecto nuevo no
toca este archivo ni reinicia el túnel.**

### 3.4 Un registro DNS por subdominio

**Decisión: crear un CNAME por cada subdominio publicado, con `cloudflared tunnel route dns`.**

Cada subdominio necesita un registro que apunte a `<UUID-del-túnel>.cfargotunnel.com`, proxiado por
Cloudflare (nube naranja). El comando lo crea por ti sin entrar al panel.

**Sobre los comodines** (`*.midominio.com`): serían más cómodos —un registro para todo— pero su
disponibilidad **proxiada** depende del plan de Cloudflare que tengas. Comprueba si tu cuenta lo
permite antes de contar con ello; si no, el registro por subdominio funciona en todos los planes y
es una línea de comando por proyecto.

Hay además una ventaja discreta en no usar comodín: solo existe públicamente lo que has creado a
propósito. Un servicio interno que se te olvide marcar como interno no queda expuesto por defecto.

### 3.5 Modo TLS «Full» en Cloudflare

**Decisión: `Full`, no `Flexible` ni `Full (strict)`.**

| Modo | Qué hace | Por qué no |
|---|---|---|
| Off | Sin HTTPS | No |
| Flexible | HTTPS hasta Cloudflare, HTTP en claro por internet hasta el origen | Peligroso: el tramo largo va sin cifrar |
| **Full** | HTTPS extremo a extremo; el tramo Cloudflare–origen va por el túnel cifrado | **El correcto aquí** |
| Full (strict) | Como Full, pero exige un certificado válido en el origen | Innecesario: el túnel ya autentica ambos extremos criptográficamente |

Con Cloudflare Tunnel el tramo entre Cloudflare y tu servidor es una conexión QUIC cifrada y
autenticada por las credenciales del túnel. `Full (strict)` obligaría a instalar un certificado de
origen en Traefik para verificar algo que ya está verificado.

### 3.6 Las credenciales del túnel son un secreto

**Decisión: el archivo `<UUID>.json` vive solo en el servidor, con permisos 600, y se respalda.**

Ese archivo **es** el túnel: quien lo tenga puede levantar un túnel que reciba el tráfico de tus
dominios. No se versiona nunca —`.gitignore` ya lo excluye— y se incluye en los respaldos del
capítulo 14, porque sin él hay que rehacer el túnel entero.

---

## 4. Variables usadas

| Variable | Uso |
|---|---|
| `DOMINIO_PUBLICO` | Dominio bajo el que se publican los subdominios |
| `CF_TUNEL_NOMBRE` | Nombre del túnel |
| `CF_TUNEL_ID` | UUID del túnel; **se obtiene en el paso 3** |
| `CF_CONFIG_DIR` | Directorio de configuración y credenciales |
| `DOCKER_RED_PROXY` | Red por la que `cloudflared` alcanza a Traefik |

---

## 5. Procedimiento

### Paso 1 — Delega el dominio a Cloudflare

Si el dominio ya está en Cloudflare, salta al paso 2.

1. En <https://dash.cloudflare.com>, **Add a site** e introduce tu dominio.
2. Elige el plan **Free**.
3. Cloudflare te dará dos servidores de nombres (`xxx.ns.cloudflare.com`).
4. En el panel de tu registrador, sustituye los servidores de nombres por esos dos.
5. Espera. La delegación tarda entre minutos y 24 horas.

```bash
# [cliente] — comprueba la delegación
dig NS ${DOMINIO_PUBLICO} +short
```

Criterio de aceptación: aparecen los servidores de Cloudflare.

### Paso 2 — Autoriza `cloudflared` en tu cuenta

`cloudflared` se ejecuta en un contenedor, pero para **crear** el túnel es más cómodo usarlo
puntualmente desde el propio servidor:

```bash
# [servidor]
mkdir -p ~/.cloudflared
docker run --rm -it \
    -v ~/.cloudflared:/home/nonroot/.cloudflared \
    cloudflare/cloudflared:2026.7.3 tunnel login
```

Imprime una URL. Ábrela en tu navegador, inicia sesión y **autoriza el dominio**.

Esto deja un certificado en `~/.cloudflared/cert.pem`, que sirve para crear y borrar túneles. No es
el mismo archivo que las credenciales del túnel (paso 3) y no hace falta en el contenedor que corre
el túnel.

### Paso 3 — Crea el túnel

```bash
# [servidor]
docker run --rm -it \
    -v ~/.cloudflared:/home/nonroot/.cloudflared \
    cloudflare/cloudflared:2026.7.3 tunnel create ${CF_TUNEL_NOMBRE}
```

Salida esperada:

```
Tunnel credentials written to /home/nonroot/.cloudflared/8a1b2c3d-....json
Created tunnel nomad-tunnel with id 8a1b2c3d-4e5f-6789-abcd-ef0123456789
```

**Anota ese UUID** y guárdalo en `config/servidor.env`:

```bash
# [servidor]
vim ~/nomad_server/config/servidor.env
# CF_TUNEL_ID="8a1b2c3d-4e5f-6789-abcd-ef0123456789"
```

### Paso 4 — Coloca las credenciales

```bash
# [servidor]
mkdir -p ${CF_CONFIG_DIR}
cp ~/.cloudflared/${CF_TUNEL_ID}.json ${CF_CONFIG_DIR}/
chmod 600 ${CF_CONFIG_DIR}/${CF_TUNEL_ID}.json
ls -l ${CF_CONFIG_DIR}/
```

Criterio de aceptación: el archivo existe con permisos `-rw-------`.

> **Guarda una copia de ese archivo en tu gestor de contraseñas.** Sin él hay que rehacer el túnel
> y todos los registros DNS. El capítulo 14 lo incluye en los respaldos automáticos, pero hasta
> entonces es tu única copia.

### Paso 5 — Configura el túnel

```bash
# [servidor]
vim ${CF_CONFIG_DIR}/config.yml
```

```yaml
tunnel: 8a1b2c3d-4e5f-6789-abcd-ef0123456789
credentials-file: /etc/cloudflared/8a1b2c3d-4e5f-6789-abcd-ef0123456789.json

metrics: 0.0.0.0:2000
no-autoupdate: true
protocol: quic

originRequest:
  connectTimeout: 30s
  noTLSVerify: false

ingress:
  - service: http://traefik:80
```

Y el fichero compose:

```bash
# [servidor]
vim ${CF_CONFIG_DIR}/docker-compose.yml
```

El contenido está en `templates/compose/cloudflared/docker-compose.yml`.

### Paso 6 — Crea los registros DNS

Un registro por subdominio. Para empezar, uno de prueba:

```bash
# [servidor]
docker run --rm -it \
    -v ~/.cloudflared:/home/nonroot/.cloudflared \
    cloudflare/cloudflared:2026.7.3 \
    tunnel route dns ${CF_TUNEL_NOMBRE} prueba.${DOMINIO_PUBLICO}
```

Salida esperada:

```
Added CNAME prueba.midominio.com which will route to this tunnel
```

Compruébalo:

```bash
# [cliente]
dig prueba.${DOMINIO_PUBLICO} +short
```

Criterio de aceptación: devuelve direcciones IP de Cloudflare (no la tuya).

### Paso 7 — Comprueba el modo TLS

En <https://dash.cloudflare.com> → tu dominio → **SSL/TLS** → **Overview**, selecciona **Full**.

> Si está en **Flexible**, el tramo entre Cloudflare y tu servidor iría sin cifrar por internet.
> Es un error frecuente y silencioso: la web se ve bien y el candado aparece.

### Paso 8 — Levanta el túnel

```bash
# [servidor]
cd ${CF_CONFIG_DIR}
docker compose up -d
docker compose logs -f cloudflared
```

Busca en el registro:

```
INF Registered tunnel connection connIndex=0 location=mad01
INF Registered tunnel connection connIndex=1 location=mad02
```

Criterio de aceptación: al menos dos conexiones registradas. Sal del seguimiento con `Ctrl+C`.

### Paso 9 — Prueba de extremo a extremo

Levanta un contenedor de prueba con las etiquetas de Traefik:

```bash
# [servidor]
docker run -d --name prueba-publica \
    --network ${DOCKER_RED_PROXY} \
    --label traefik.enable=true \
    --label "traefik.http.routers.pruebapub.rule=Host(\`prueba.${DOMINIO_PUBLICO}\`)" \
    --label traefik.http.routers.pruebapub.entrypoints=web \
    --label traefik.http.services.pruebapub.loadbalancer.server.port=80 \
    traefik/whoami:latest
```

Y desde **cualquier equipo con internet**, incluido el móvil con datos:

```bash
# [cliente]
curl -sI https://prueba.${DOMINIO_PUBLICO}
```

Criterio de aceptación:

```
HTTP/2 200
server: cloudflare
x-frame-options: DENY
x-content-type-options: nosniff
```

Las tres cosas juntas confirman que funciona la cadena completa: Cloudflare resuelve y termina TLS,
el túnel entrega a Traefik, y Traefik aplica los middlewares antes de responder.

Limpia:

```bash
# [servidor]
docker rm -f prueba-publica
```

### Paso 10 — Comprueba que sigues sin exponer nada

```bash
# [servidor]
sudo ss -tulpn | grep LISTEN
docker ps --format 'table {{.Names}}\t{{.Ports}}'
```

Criterio de aceptación: nada nuevo escuchando. `cloudflared` no publica ningún puerto.

Y desde fuera de tu red:

```bash
# [cliente, desde datos móviles]
nmap -Pn -p 80,443,22 <tu-ip-publica>
```

Criterio de aceptación: los tres puertos aparecen como `filtered` o `closed`. **Tu servidor está en
internet sin estar expuesto en internet.**

### Paso 11 — Cómo publicar un proyecto a partir de ahora

Este es el procedimiento completo para cada proyecto nuevo:

```bash
# [servidor] — 1. crear el registro DNS (una vez por subdominio)
docker run --rm -v ~/.cloudflared:/home/nonroot/.cloudflared \
    cloudflare/cloudflared:2026.7.3 \
    tunnel route dns ${CF_TUNEL_NOMBRE} mi-proyecto.${DOMINIO_PUBLICO}
```

```yaml
# 2. añadir las etiquetas al docker-compose.yml del proyecto
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.mi-proyecto.rule=Host(`mi-proyecto.midominio.com`)"
  - "traefik.http.routers.mi-proyecto.entrypoints=web"
  - "traefik.http.services.mi-proyecto.loadbalancer.server.port=3000"
```

```bash
# [servidor] — 3. levantar
docker compose up -d
```

**Ni Traefik ni el túnel se reinician.** El capítulo [12](12_despliegue_de_proyectos.md) lo
desarrolla con una plantilla completa.

---

## 6. Script asociado

`scripts/11_cloudflared.sh` automatiza los pasos 4, 5, 8 y 10, y guía los que necesitan navegador.

```bash
# [servidor]
cd ~/nomad_server
./scripts/11_cloudflared.sh --help
./scripts/11_cloudflared.sh --check
./scripts/11_cloudflared.sh
```

Comportamiento destacable:

- **Aborta si `CF_TUNEL_ID` está vacío** e imprime el comando exacto para crear el túnel.
- Verifica que existe el archivo de credenciales y **corrige sus permisos a 600** si hacen falta.
- Comprueba que Traefik está en marcha antes de levantar el túnel: sin él, el túnel se conectaría a
  un origen inexistente.
- Espera a que aparezcan conexiones registradas y falla si no llegan en 60 segundos.
- Comprueba al terminar que no se ha publicado ningún puerto nuevo.

```bash
# [servidor] — crear un registro DNS para un subdominio
./scripts/11_cloudflared.sh --ruta mi-proyecto
```

En modo `--check` muestra las diferencias de `config.yml` y del compose, y valida que las
credenciales existan, sin levantar nada.

---

## 7. Validación

```bash
# [servidor]
cd ${CF_CONFIG_DIR} && docker compose ps
```

Criterio de aceptación: `cloudflared` en estado `running (healthy)`.

```bash
# [servidor]
docker logs cloudflared 2>&1 | grep -c 'Registered tunnel connection'
```

Criterio de aceptación: 2 o más.

```bash
# [servidor]
docker exec cloudflared cloudflared --metrics 127.0.0.1:2000 tunnel ready && echo "TUNEL LISTO"
```

Criterio de aceptación: `TUNEL LISTO`.

```bash
# [servidor]
ls -l ${CF_CONFIG_DIR}/${CF_TUNEL_ID}.json
```

Criterio de aceptación: permisos `-rw-------`.

```bash
# [cliente] — desde fuera de tu red
curl -sI https://prueba.${DOMINIO_PUBLICO} | head -3
```

Criterio de aceptación: `HTTP/2 200` y `server: cloudflare`.

```bash
# [cliente] — el certificado debe ser válido
echo | openssl s_client -connect ${DOMINIO_PUBLICO}:443 -servername prueba.${DOMINIO_PUBLICO} 2>/dev/null \
    | openssl x509 -noout -issuer -dates
```

Criterio de aceptación: emitido por Cloudflare y en vigor.

```bash
# [servidor] — nada expuesto
sudo ss -tulpn | grep LISTEN | grep '0.0.0.0' | grep -vc ':22'
```

Criterio de aceptación: `0`.

```bash
# [servidor] — el secreto no está en git
cd ~/nomad_server && git status --porcelain | grep -c '\.json' || echo "0 (correcto)"
```

Criterio de aceptación: `0`.

**Prueba de reinicio:** `sudo reboot` y comprobar que el túnel vuelve solo y el subdominio de prueba
responde sin intervención.

---

## 8. Reversión

```bash
# [servidor] — parar el túnel (los subdominios dejan de responder)
cd ${CF_CONFIG_DIR} && docker compose down
```

```bash
# [servidor] — eliminar un registro DNS
docker run --rm -v ~/.cloudflared:/home/nonroot/.cloudflared \
    cloudflare/cloudflared:2026.7.3 \
    tunnel route dns --overwrite-dns ${CF_TUNEL_NOMBRE} prueba.${DOMINIO_PUBLICO}
```

También se pueden borrar desde el panel, en **DNS → Records**.

```bash
# [servidor] — eliminar el túnel por completo
cd ${CF_CONFIG_DIR} && docker compose down
docker run --rm -v ~/.cloudflared:/home/nonroot/.cloudflared \
    cloudflare/cloudflared:2026.7.3 tunnel delete ${CF_TUNEL_NOMBRE}
rm -rf ${CF_CONFIG_DIR}
```

Borra después los registros CNAME huérfanos en el panel de DNS: seguirían apuntando a un túnel que
ya no existe.

---

## 9. Errores frecuentes

| Síntoma | Causa probable | Solución | Documentación |
|---|---|---|---|
| Error 1033 «Argo Tunnel error» | El túnel no está conectado | `docker logs cloudflared`. Comprueba salida a internet y credenciales | [Cloudflare — Errores](https://developers.cloudflare.com/support/troubleshooting/cloudflare-errors/troubleshooting-cloudflare-1xxx-errors/) |
| Error 502 «Bad Gateway» | El túnel llega pero Traefik no responde | Comprueba que `traefik` está en marcha y en la red `${DOCKER_RED_PROXY}` | Capítulo [10](10_traefik.md) |
| Error 404 desde Traefik | No hay ningún router para ese nombre de host | Revisa las etiquetas del proyecto y el panel de Traefik | Capítulo [10](10_traefik.md) |
| «Too many redirects» | Modo TLS en **Flexible** y la aplicación redirige a HTTPS | Cambia a **Full** (§ 3.5) | [Cloudflare — Modos SSL](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/) |
| El subdominio no resuelve | El registro DNS no se creó, o falta propagación | `dig <subdominio> +short`. Recréalo con `tunnel route dns` | [Cloudflare — Tunnel DNS](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/) |
| `cloudflared` no arranca: «credentials file not found» | Ruta incorrecta en `config.yml`, o el archivo no se copió | Comprueba que `${CF_CONFIG_DIR}/${CF_TUNEL_ID}.json` existe y está montado | § 5 paso 4 |
| El túnel se reconecta continuamente | Bloqueo de UDP/QUIC en la red | Prueba `protocol: http2` en `config.yml` | [Cloudflare — Protocolos](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-run-parameters/) |
| Los registros muestran siempre la misma IP como visitante | Traefik no confía en las cabeceras reenviadas | Añade `forwardedHeaders.trustedIPs` (capítulo 10) | Capítulo [10](10_traefik.md) § 3.7 |
| Publiqué sin querer un servicio interno | Se creó un CNAME para un subdominio que debía ser privado | Bórralo en el panel de DNS. Usa el punto de entrada `interna` para lo privado | Capítulo [13](13_observabilidad.md) |
| Cambié de dominio y todo dejó de funcionar | Las etiquetas de Traefik llevan el dominio antiguo | Actualiza `DOMINIO_PUBLICO` y las etiquetas de cada proyecto | Capítulo [12](12_despliegue_de_proyectos.md) |
| Perdí el archivo `<UUID>.json` | Se borró o no se respaldó | Hay que crear un túnel nuevo y rehacer todos los CNAME. Por eso está en el capítulo 14 | Capítulo [14](14_respaldos_restic.md) |

---

## 10. Referencias

- [Cloudflare Tunnel — Documentación](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/)
- [Cloudflare Tunnel — Archivo de configuración](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/local-management/configuration-file/)
- [Cloudflare Tunnel — Reglas de ingreso](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/local-management/ingress/)
- [Cloudflare — Modos de cifrado SSL/TLS](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/)
- [Cloudflare — Códigos de error 1xxx](https://developers.cloudflare.com/support/troubleshooting/cloudflare-errors/troubleshooting-cloudflare-1xxx-errors/)
- [Cloudflare — Cambiar servidores de nombres](https://developers.cloudflare.com/dns/zone-setups/full-setup/setup/)

---

**Anterior:** [10 — Traefik](10_traefik.md) · **Siguiente:** [12 — Despliegue de proyectos](12_despliegue_de_proyectos.md)
