# Hermes como guardián de nomadservernw — especificación de diseño

> **Estado: NO CONSTRUIDO, por decisión del 2026-08-24.**
>
> Se construyó la **fase 1** y se paró ahí. El motivo, en corto: al desglosar el valor por piezas,
> casi todo lo que se buscaba —auditoría diaria, validación automática de los proyectos que llegan,
> aviso a Telegram de lo que cambió— lo dan tres piezas de bash sin ninguna IA de por medio. Lo que
> quedaba para Hermes era **interpretar** el informe y **escribir** la corrección de un compose; y
> esa segunda mitad ya se cubre desde el portátil con la skill `desplegar-en-nomadservernw`, con un
> modelo mejor y con el repositorio entero en contexto.
>
> Lo construido está en el **capítulo 17**, que se llama «Auditoría automática del servidor» y no
> menciona a Hermes: instala un recolector diario, un vigilante de proyectos y un aviso por el
> monitor Push de Uptime Kuma que ya existía. Ni contenedor, ni clave de API, ni bot nuevo, ni un
> solo dato del servidor saliendo hacia un tercero.
>
> **Este documento se conserva a propósito.** Dentro de unos meses el informe diario dará el dato
> que hoy no existe: cuántas veces dijo algo que no se sabía, y cuántos proyectos llegaron
> necesitando arreglo. Si ese dato dice que hace falta, las fases 2 a 6 están diseñadas aquí y se
> retoman sin volver a pensarlas. Si dice que no, se ahorró un contenedor, una factura y la pieza
> más delicada del repositorio.
>
> Para instalar Hermes si se retoma: `docs/instalar-hermes-debian.md`, sin versionar, en la raíz de
> trabajo. Sus indicaciones hay que corregirlas con lo de la § 3 de este documento.
>
> **Convención de este documento:** las variables que **todavía no existen** en
> `config/servidor.env.example` se escriben sin llaves (`HERMES_MODELO`) para que
> `verificar_repositorio.sh` no las marque como huérfanas antes de la fase 5. Las que ya existen
> se escriben como siempre (`${DATOS_RAIZ}`).

---

## 1. El problema

El repositorio tiene nueve reglas innegociables (anexo 96) y un script que las comprueba
(`revisar_proyecto.sh`). Tiene un verificador de estado del servidor (`verificar_sistema.sh`) y
tres rutinas de mantenimiento (capítulo 15). Todo eso funciona.

Lo que no tiene es **a alguien que se acuerde de ejecutarlo**. Las comprobaciones dependen de que
un humano abra el portátil, cargue el entorno y lance el script. Un proyecto que se copia a `/srv`
un martes por la noche no se audita hasta que alguien lo recuerda.

Hermes cubre exactamente ese hueco: la constancia. No sustituye a ninguna comprobación existente.

## 2. Principio rector

> **Ningún veredicto lo emite el modelo. Los veredictos los emite bash.**

`verificar_sistema.sh` y `revisar_proyecto.sh` siguen siendo la única fuente de verdad. Hermes lee
sus salidas, las interpreta, propone correcciones y avisa. Si mañana se retira Hermes, el servidor
sigue siendo igual de auditable: se pierde al que avisa, no al que sabe.

De este principio se derivan todas las decisiones que siguen. Cuando haya duda, gana él.

## 3. Decisiones y alternativas descartadas

| Decisión | Alternativa descartada | Por qué |
|---|---|---|
| Hermes en contenedor, bajo el anexo 96 | Instalarlo en el host con el instalador oficial | El host solo tiene Docker, SSH y Tailscale (README). Además, un guardián que no cumple el contrato que vigila no es creíble. Y el argumento que parecía decisivo —«en el host ve más»— es falso: un usuario sin sudo tampoco lee nftables, journald, restic ni lynis |
| Los hechos los recoge bash con privilegios y los deja en informes | Dar a Hermes grupo `adm`, `docker` o sudoers acotado | Pertenecer al grupo `docker` equivale a ser root (capítulo 09). `adm` le daría journald en crudo, que es justo lo que no debe salir del servidor |
| Imagen fijada por digest, desplegada con `deploy.sh` | `curl \| bash` del instalador oficial, `hermes update` | El capítulo 01 verifica criptográficamente hasta el ISO. La pieza que vigila el resto no puede ser la menos verificada. Fijar el digest además cumple la regla 4 del anexo 96 |
| Planificación con temporizadores systemd | `hermes cron` | Dos planificadores divergen. El repositorio ya tiene la convención `nomad-*.timer` |
| Escritura de Hermes solo en ramas `hermes/*` | Escribir directamente en el árbol desplegado | Un cambio del modelo no debe llegar a producción sin que un humano lo lea. La rama deja diff, autor y fecha |
| Despliegue mediado por un portero de bash | Dar Docker a Hermes; o no desplegar nunca desde Telegram | Lo primero anula los tres anillos. Lo segundo deja la fricción que motivaba la integración. El portero da el resultado sin dar el privilegio |
| El código de confirmación viaja por un bot distinto | Que Hermes genere y muestre el código | Si Hermes lo genera, quien comprometa el bot de Hermes obtiene también el código. Sería teatro de seguridad |
| Dos bots de Telegram: Kuma conserva el suyo | Un único bot para avisos y conversación | Si el que avisa de que algo se cayó es el mismo que se cae, no te enteras de nada |
| El anexo 96 se monta como *skill* de Hermes | Confiar en que el modelo recuerde las reglas | El conocimiento del contrato debe ser el documento vigente, no lo que el modelo aprendiera. Cambias el anexo, cambia el guardián |

## 4. Arquitectura

```
┌─ HOST ─── lo único con privilegios, y es bash ─────────────────────────┐
│                                                                        │
│  nomad-auditoria.timer   (root, diario)                                │
│    ├─ verificar_sistema.sh                                             │
│    ├─ restic stats / check                                             │
│    ├─ lynis, smartctl, df                                              │
│    └─▶ redacta ─▶ /srv/hermes/informes/{estado,cambios}.txt            │
│                                                                        │
│  nomad-conserje.path     (root, vigila /srv/*/docker-compose.yml)      │
│    └─ revisar_proyecto.sh <p> ─▶ /srv/hermes/informes/<p>.auditoria    │
│                                                                        │
│  nomad-portero.path      (root, vigila /srv/hermes/solicitudes/)       │
│    └─ valida ─▶ reta por bot propio ─▶ deploy.sh como ${ADMIN_USUARIO} │
│                                                                        │
│  usuario hermes · nologin · sin sudo · sin grupo docker · uid fijo     │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
              ▲ informes (ro)          ▲ solicitudes (rw)
              │                        │
┌─ CONTENEDOR hermes ── cumple el anexo 96 ──────────────────────────────┐
│  digest fijado · sin ports · datos en ./datos/ · healthcheck           │
│  PUID = uid(hermes) · HERMES_WRITE_SAFE_ROOT = ${DATOS_RAIZ}           │
│  anexo 96 montado :ro como skill                                       │
│    ├─▶ Telegram, long-polling saliente (bot de Hermes)                 │
│    └─▶ panel :9119 vía Traefik interno, solo tailnet                   │
└────────────────────────────────────────────────────────────────────────┘
```

## 5. Los tres anillos

| Anillo | Alcance | Permiso de Hermes | Cómo se impone |
|---|---|---|---|
| **0 — Sistema** | `/etc`, systemd, nftables, restic, journald, socket de Docker, `config/servidor.env`, cualquier `.env` | **Ninguno, ni lectura** | No existe en el contenedor. Sin bind mount, sin socket, sin sudo, sin grupo. Refuerzo en `approvals.deny` |
| **1 — Informes** | `/srv/hermes/informes/` | Lectura | Bind mount `:ro` |
| **2 — Proyectos** | `${DATOS_RAIZ}/<proyecto>/` | Escritura, solo en ramas `hermes/*` | Bind mount `:rw` + `HERMES_WRITE_SAFE_ROOT` + rutas protegidas de serie (`.env`, `~/.ssh`) |

El anillo 0 no se protege con confianza en el modelo: se protege porque **el privilegio no está
ahí**, aunque el modelo lo intente. `approvals.deny` es un segundo cinturón, no el único.

Reglas de `approvals.deny` (globs fnmatch): `sudo *`, `su *`, `systemctl *`, `docker *`,
`nft *`, `mount *`, `rm -rf *`, `*/.env`, `*servidor.env*`, `*restic*`.

Backend de ejecución: **`local`**. El backend `docker` de Hermes se salta la capa de aprobaciones
por completo; dentro de un contenedor ya acotado, `local` es más seguro que `docker`.

## 6. Componentes

Cada componente se especifica con tres preguntas: qué hace, cómo se usa, de qué depende.

### 6.1 `nomad-auditoria` — el recolector

**Qué hace.** Ejecuta como root lo que Hermes no puede ejecutar, y deja el resultado en texto
plano ya redactado.

- `verificar_sistema.sh` (informe completo, con privilegios)
- `restic stats` y la antigüedad del último snapshot
- `lynis` en modo comparación contra la línea de base
- `smartctl`, `df`, estado de LVM
- Escribe `estado.txt` (completo) y `cambios.txt` (**solo lo que difiere del día anterior**)

**Cómo se usa.** `nomad-auditoria.timer`, diario. También a mano:
`sudo /usr/local/sbin/nomad-auditoria.sh --check`.

**De qué depende.** De los scripts del repositorio. No reimplementa ninguna comprobación: las
invoca. Si `verificar_sistema.sh` cambia, el recolector no se entera y sigue funcionando.

**Por qué `cambios.txt` existe.** Es control de coste, no comodidad: Hermes lee lo que cambió, no
el estado entero, y eso divide por diez los tokens de la revisión diaria.

### 6.2 `nomad-conserje` — el vigilante de proyectos

**Qué hace.** Una unidad `path` observa `${DATOS_RAIZ}/*/docker-compose.yml`. Al detectar un
fichero nuevo o modificado, lanza `revisar_proyecto.sh <proyecto>` y deja la salida íntegra —
incluido el código de salida — en `/srv/hermes/informes/<proyecto>.auditoria`.

**Cómo se usa.** Solo. Ese es el punto: clonas un proyecto en `/srv` y la auditoría ocurre sin que
nadie se acuerde.

**De qué depende.** De `revisar_proyecto.sh`, que a su vez necesita `docker compose config` y `jq`.
Por eso vive en el host y no en el contenedor.

**Antirrebote.** Un `git clone` toca muchos ficheros. La unidad espera 30 s de quietud antes de
disparar, y nunca más de una auditoría simultánea por proyecto.

### 6.3 `nomad-portero` — el guardián del despliegue

El componente más delicado. **No razona: comprueba.**

**Protocolo.** Hermes escribe `/srv/hermes/solicitudes/<proyecto>.solicitud`:

```
proyecto=tienda
accion=desplegar
solicitado=2026-08-23T09:14:02Z
```

El portero, disparado por `nomad-portero.path`:

1. El nombre del fichero casa con `^[a-z0-9-]+\.solicitud$` y coincide con el campo `proyecto`.
2. `accion` está en la lista permitida. Hoy solo `desplegar`.
3. `${DATOS_RAIZ}/<proyecto>/docker-compose.yml` existe.
4. El árbol de git del proyecto está limpio y la rama activa **no** es una rama `hermes/*`.
5. **Vuelve a ejecutar `revisar_proyecto.sh` por su cuenta.** No se fía de lo que diga Hermes ni
   del informe previo. Si falla, rechaza.
6. Genera un código de un solo uso, lo guarda en `/var/lib/nomad/portero/reto` (600, root) con TTL
   de 5 minutos, y **te lo envía usando su propio token de bot**, guardado en
   `/etc/nomad/portero.env` (600, root). Hermes no puede leer ese fichero ni ese token.
7. Espera `/srv/hermes/solicitudes/<proyecto>.confirmacion` con el código. Lo compara, lo consume
   (un solo uso) y borra el reto.
8. Ejecuta `runuser -u ${ADMIN_USUARIO} -- ./scripts/deploy.sh <proyecto>`, que conserva su
   reversión automática de siempre.
9. Escribe el resultado en `/srv/hermes/informes/<proyecto>.despliegue` y **anota la solicitud
   entera —aceptada o rechazada— en `/var/log/nomad/portero.log`**.

**Por qué el código viaja por otro bot.** Si Hermes generase el código, quien comprometa el bot de
Hermes obtendría también el código: sería teatro. Al viajar por un token que vive en `/etc` y que
Hermes no puede leer, hacen falta **dos** compromisos independientes para desplegar algo.

**Límites.** Máximo 5 solicitudes por hora. Nunca dos despliegues a la vez. Una solicitud sin
confirmar caduca a los 5 minutos y se borra.

**Peor caso realista.** Con el bot de Hermes y el del portero comprometidos a la vez, un atacante
puede volver a desplegar un proyecto que **ya estaba en `/srv` y ya cumplía el contrato**. No puede
introducir código nuevo, ni desplegar algo que no pase la auditoría, ni tocar el sistema. Y
`deploy.sh` revierte solo si el resultado no queda sano.

### 6.4 El contenedor `hermes`

Vive en `${DATOS_RAIZ}/hermes/` y se despliega con `deploy.sh` como cualquier otro proyecto. Debe
pasar `revisar_proyecto.sh hermes` **limpio**; es criterio de aceptación, no una aspiración.

| Regla del anexo 96 | Cómo se cumple |
|---|---|
| 1 · sin `ports:` | El panel se alcanza por Traefik, no por puerto publicado |
| 3 · datos en `./datos/` | `./datos/hermes:/opt/data` |
| 4 · versión fijada | Imagen por digest. El compose oficial usa `:latest`; se descarta |
| 5 · healthcheck | Contra el endpoint de salud del gateway en `:8642` |
| 6 · secretos en `.env` 600 | La clave del proveedor, fuera de git |
| 7 · red interna | Solo en `${DOCKER_RED_PROXY}`. Sin acceso a la red del socket |
| 8 · router prefijado | `hermes-panel` |

`PUID`/`PGID` se fijan al uid/gid del usuario `hermes` del host, de modo que todo lo que escriba en
`/srv` aparezca a su nombre en `ls -l`.

### 6.5 El usuario `hermes`

Se crea en el host con `--shell /usr/sbin/nologin`, sin sudo, sin grupo `docker`, sin grupo `adm`.
**Nadie inicia sesión como él, ni siquiera él.** Existe para dos cosas: ser propietario de los
ficheros que el contenedor escribe, y firmar los commits de las ramas `hermes/*`.

Eso satisface la trazabilidad —`ls -l` y `git log` dicen quién tocó qué— sin conceder ni un
privilegio.

### 6.6 El anexo 96 como skill

`docs/96_contrato_de_dockerizacion.md` se monta `:ro` dentro del contenedor y se registra como
skill de Hermes. Su conocimiento de las reglas es el documento vigente, no su entrenamiento.
Actualizar el contrato actualiza al guardián sin tocar nada más.

## 7. Flujo de datos y política de redacción

**Lo que Hermes puede leer:** los informes de `/srv/hermes/informes/`, los `docker-compose.yml` y
`.env.example` de los proyectos, y el historial de git.

**Lo que no puede leer, nunca:** ningún `.env` real, `config/servidor.env`, `/etc/nomad/*`, la
contraseña de restic, las llaves SSH, journald en crudo.

**Redacción en origen.** El recolector limpia antes de escribir el informe, no después:

| Se redacta | Motivo |
|---|---|
| Claves, tokens, cadenas tipo `sk-*`, cabeceras `Authorization` | Evidente |
| La IP de Tailscale y el rango de la tailnet | Es topología de acceso administrativo |
| UUID del túnel y del disco de respaldo | Identificadores de infraestructura |
| Rutas de repositorio restic y credenciales B2 | Un respaldo localizable es un respaldo atacable |

**Lo que sí sale del servidor,** y hay que asumirlo conscientemente: nombres de proyecto, rutas
bajo `/srv`, versiones de imagen, nombres de contenedor, mensajes de error y fragmentos de
compose.

## 8. Canales

### Telegram

Long-polling: Hermes sale hacia `api.telegram.org`. **No hay webhook ni puerto entrante**, así que
el principio del capítulo 00 —el servidor no acepta conexiones entrantes— se mantiene intacto.

Control de acceso: allowlist por id de usuario más emparejamiento explícito
(`hermes pairing approve`). Sin allowlist no arranca.

**Dos bots, no uno.** El de Uptime Kuma sigue avisando de caídas por su cuenta y no se toca; el de
Hermes es solo para conversar; el del portero solo emite códigos. Tres tokens, tres funciones, y
ningún punto único de fallo en los avisos.

### Panel por tailnet

El panel (`:9119`) se publica por el punto de entrada **interno** de Traefik, alcanzable por túnel
SSH o, si se activa `TRAEFIK_ACCESO_TAILNET`, desde la tailnet. **Hermes no recibe hostname público
jamás:** ni ruta en Cloudflare, ni registro DNS en `${DOMINIO_PUBLICO}`.

### SSRF

Hermes bloquea RFC 1918, loopback y metadatos de nube por defecto. Sin abrirlo no ve nada de casa.
Se abre **acotado a `${LAN_CIDR}` y `${TS_CIDR}`**, se documenta como decisión en el capítulo 17 y
se deja constancia de que amplía la superficie: un modelo con acceso a la red local puede sondearla.

## 9. Modelo y coste

Proveedor inicial: **DeepSeek**. Encaja por precio, que importa en un agente que despierta a
diario.

Dos advertencias que el capítulo 17 debe recoger sin adornos:

1. **Dónde acaban los datos.** La API procesa fuera de la UE y sus términos han contemplado usar
   datos para mejorar el servicio. Hay que revisar los términos vigentes de la cuenta que se use.
   El diseño no depende del proveedor: cambiar `HERMES_PROVEEDOR` y `HERMES_MODELO` basta.
2. **Un modelo flojo importa poco aquí,** y eso es mérito de la arquitectura: Hermes solo edita
   YAML y redacta texto. Si se equivoca, `revisar_proyecto.sh` lo caza, el portero lo rechaza y la
   rama de git lo enseña antes de fusionar.

**Control de gasto.** Tres disparadores y nada más: un cambio detectado por el conserje, un mensaje
tuyo, o el resumen diario sobre `cambios.txt`. `HERMES_TOPE_DIARIO` corta el día si se supera.

## 10. Modelo de amenazas: lo que cambia

Filas nuevas para `docs/00_planificacion.md` § 3.1, en **«lo que este montaje NO protege»**:

- **El contenido de los informes de auditoría se envía a un proveedor de IA externo.** Nombres de
  contenedores, rutas, versiones y mensajes de error salen del servidor en cada consulta.
- **El bot de Telegram es una superficie de control nueva.** Es saliente y con allowlist, pero
  quien comprometa el token puede conversar con un agente que lee los informes del servidor. El
  daño está acotado a divulgación de información: no puede modificar el sistema.
- **Un modelo puede ser manipulado por el contenido que lee.** Un `docker-compose.yml` malicioso
  puede intentar inyectar instrucciones. Por eso el portero repite la auditoría por su cuenta y por
  eso Hermes no puede desplegar: el daño de una inyección exitosa se detiene en «escribió una rama
  de git que nadie fusionó».

## 11. Errores y degradación

El sistema debe degradar hacia el estado actual, nunca hacia uno peor:

| Falla | Consecuencia |
|---|---|
| La API del proveedor está caída | Hermes queda mudo. El recolector sigue escribiendo informes, Kuma sigue avisando, `deploy.sh` sigue funcionando desde la consola |
| El contenedor de Hermes está parado | Igual que lo anterior. El conserje sigue auditando proyectos |
| El recolector falla | Hermes lo detecta por la antigüedad de `estado.txt` y avisa. Kuma vigila el temporizador |
| El portero no puede enviar el código | Rechaza la solicitud. Nunca despliega sin confirmación |
| `deploy.sh` falla a mitad | Su reversión automática de siempre. El portero solo transcribe el resultado |

**Ninguna pieza nueva está en el camino crítico de nada que hoy funcione.**

## 12. Validación y criterios de aceptación

Pruebas positivas:

```
sudo /usr/local/sbin/nomad-auditoria.sh --check   → sin cambios pendientes
./scripts/revisar_proyecto.sh hermes              → limpio, 9 de 9
./scripts/verificar_sistema.sh --seccion hermes   → CORRECTO
make check                                        → sin fallos
```

Pruebas **negativas** — un guardián que no se puede demostrar acotado no está acotado. Estas
**tienen que fallar**:

```
Hermes ejecuta  sudo -n true                      → denegado
Hermes lee      ${DATOS_RAIZ}/<p>/.env            → denegado
Hermes lee      config/servidor.env               → no existe en su vista
Hermes escribe  /etc/cualquier-cosa               → fuera de WRITE_SAFE_ROOT
Hermes habla    con el socket de Docker           → no está en su red
Hermes escribe  una solicitud con código inventado→ el portero la rechaza
Hermes escribe  solicitud de un proyecto que falla→ el portero la rechaza
```

Criterio de aceptación del capítulo 17: **las siete pruebas negativas fallan y quedan registradas
en `/var/log/nomad/portero.log` las que llegan hasta él.**

## 13. Reversión

```
./scripts/deploy.sh --parar hermes
sudo systemctl disable --now nomad-auditoria.timer nomad-conserje.path nomad-portero.path
sudo userdel hermes          # los informes y las ramas de git se conservan
```

El servidor vuelve exactamente al estado anterior. Ninguna pieza de Hermes es prerequisito de otra
cosa.

## 14. Variables nuevas

Bloque nuevo en `config/servidor.env.example`, con el formato de comentarios del resto del fichero:

| Variable | Para qué |
|---|---|
| `HERMES_HABILITADO` | `si`/`no`. Todo el capítulo 17 es opcional |
| `HERMES_USUARIO` | Nombre del usuario del host. Por defecto `hermes` |
| `HERMES_UID` | uid fijo, para que `PUID` del contenedor coincida |
| `HERMES_IMAGEN_DIGEST` | La imagen fijada por digest |
| `HERMES_PROVEEDOR` | `deepseek` de inicio |
| `HERMES_MODELO` | El modelo concreto |
| `HERMES_TOPE_DIARIO` | Techo de gasto diario |
| `HERMES_PANEL_HOST` | Nombre interno del panel. Nunca bajo `${DOMINIO_PUBLICO}` |
| `HERMES_TELEGRAM_ALLOWLIST` | Ids autorizados |
| `HERMES_AUDITORIA_HORA` | Hora del recolector |
| `HERMES_PORTERO_HABILITADO` | `si`/`no`. El despliegue desde Telegram se puede desactivar solo |

Los secretos —tokens de bot y clave del proveedor— **no van aquí**: van en
`${DATOS_RAIZ}/hermes/.env` y `/etc/nomad/portero.env`, ambos 600, como el resto del montaje.

## 15. Impacto en el repositorio existente

| Fichero | Cambio |
|---|---|
| `docs/17_hermes_guardian.md` | Capítulo nuevo, con las 10 secciones obligatorias |
| `docs/00_planificacion.md` | Tres filas nuevas en el modelo de amenazas (§ 10 de este documento) |
| `docs/96_contrato_de_dockerizacion.md` | Sección nueva: qué hace el guardián con un proyecto que llega de fuera |
| `README.md` | **Rompe la cuenta de «17 capítulos»**: pasan a ser 18. Índice, estructura y arquitectura |
| `checklists/mantenimiento.md` | El informe de Hermes entra en la rutina semanal |
| `scripts/verificar_sistema.sh` | Sección `hermes` nueva |
| `scripts/verificar_repositorio.sh` | Debe aceptar el capítulo 17 |
| `config/servidor.env.example` | El bloque de § 14 |
| `templates/compose/hermes/` | Compose y `.env.example` nuevos |
| `templates/systemd/` | `nomad-auditoria.{service,timer}`, `nomad-conserje.path`, `nomad-portero.path` y sus units |
| `templates/etc/` | `nomad-auditoria.sh`, `nomad-conserje.sh`, `nomad-portero.sh` |
| `scripts/17_hermes.sh` | Script del capítulo: idempotente, `--check`, `--help` |
| `docs/instalar-hermes-debian.md` | **Se absorbe y desaparece.** Ver más abajo |

**Sobre `docs/instalar-hermes-debian.md`.** Es el documento de partida de esta integración y
**no se versiona**: se absorbe en el capítulo 17 durante la fase 5 y se borra del árbol de trabajo.

Lo que se conserva de él es su sección de errores frecuentes, que está bien vista y encaja tal cual
en la sección 9 del capítulo 17: `hermes: command not found` tras instalar, `/tmp` sin espacio,
`No space left on device`, y los fallos de configuración de la clave del proveedor.

Lo que **no** se conserva, porque este diseño lo descarta expresamente:

| Del documento de partida | Por qué no sobrevive |
|---|---|
| `curl \| bash` del instalador oficial | Imagen fijada por digest y `deploy.sh` (§ 3) |
| `sudo adduser hermes` + `usermod -aG sudo` | El usuario existe, pero con `nologin` y sin sudo (§ 6.5) |
| `systemctl --user` y `loginctl enable-linger` | Unidades de sistema `nomad-*`, la convención del repositorio |
| `hermes cron` | Temporizadores systemd; dos planificadores divergen |
| `hermes gateway run` sin acotar | Allowlist obligatoria y panel solo por tailnet (§ 8) |
| `usermod -aG adm` para leer logs | El anillo 0 no se abre: los logs llegan redactados en los informes (§ 7) |
| `hermes update` | Cambiar el digest, revisar el diff y `deploy.sh`, como con Traefik |

Hasta que llegue la fase 5, el fichero se queda sin versionar. Es deuda consciente y con fecha de
caducidad, no un descuido.

## 16. Fases de entrega

Cada fase entrega capítulo, plantilla, script y validación juntos, y **aporta valor aunque el
montaje se detenga ahí**.

| # | Fase | Al terminar tienes | Depende de |
|---|---|---|---|
| 0 | Proveedor, modelo, tope de gasto y digest de la imagen | Los valores reales, no los de ejemplo | decisión humana |
| 1 | El recolector y su redacción | **Informes diarios de estado aunque Hermes no llegue nunca** | — |
| 2 | El contenedor, solo lectura, sin Telegram | Un auditor que responde por consola | 1 |
| 3 | Telegram y panel por tailnet | Preguntarle desde el móvil | 2 |
| 4 | El conserje y las ramas `hermes/*` | Validación automática al subir un proyecto | 2 |
| 5 | Cierre documental | Capítulo 17, anexos, README, checklists, `make check` verde | 1–4 |
| 6 | El portero | Desplegar desde Telegram sin conceder Docker | 3, 4, 5 |

El portero va **el último a propósito**: es la pieza con más superficie y la única que ejecuta algo.
No se construye hasta que todo lo demás esté documentado y validado.

## 17. Fuera de alcance

Descartado por YAGNI, y anotado para no rediscutirlo:

- Que Hermes modifique la configuración del sistema, aunque sea con lista blanca.
- Que Hermes gestione respaldos o restauraciones. El capítulo 14 ya lo hace y el coste de un error
  ahí no es recuperable.
- Que Hermes sea el canal principal de avisos. Kuma lo hace, ya ha disparado de verdad y no
  depende de una API externa.
- Un modelo local en el servidor. El hardware no da, y el capítulo 00 no contempla GPU.
- Que Hermes clone repositorios de internet por su cuenta.
- `hermes cron`, el backend de ejecución `docker`, y el dashboard publicado en internet.

## 18. Riesgos abiertos

1. **El digest de la imagen hay que mantenerlo a mano.** Igual que la versión de cloudflared, que
   ya tiene una comprobación dedicada en `verificar_repositorio.sh`. Conviene añadir una análoga.
2. **La redacción del recolector es una lista de patrones, y las listas de patrones se quedan
   cortas.** Hay que revisarla en la rutina trimestral, con un `diff` manual del informe antes de
   fiarse de ella la primera vez.
3. **La inyección de prompt vía `docker-compose.yml` no se puede eliminar, solo acotar.** El
   diseño la acota a «escribió una rama que nadie fusionó». Conviene comprobarlo con un compose
   hostil de prueba en la fase 4.
4. **`revisar_proyecto.sh` se ejecuta dos veces** (conserje y portero). Es redundancia deliberada,
   pero si el script se vuelve lento habrá que revisarlo.
