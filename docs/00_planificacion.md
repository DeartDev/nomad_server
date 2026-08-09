# 00 — Planificación general

> El capítulo que hay que leer entero antes de tocar nada. Fija la arquitectura, justifica cada
> decisión y establece las convenciones que heredan los 16 capítulos restantes.

---

## 1. Objetivo

Al terminar este capítulo tendrás decidido y anotado **todo** lo que el montaje necesita saber
—arquitectura, valores de red, dominio, hardware, política de respaldos— de modo que a partir del
capítulo 01 solo quede ejecutar, sin tener que detenerse a improvisar ninguna decisión.

---

## 2. Requisitos previos

**Capítulos previos:** ninguno. Este es el punto de entrada.

**Necesitas a mano:**

- Acceso de administrador al router de tu red local (para reservar una IP y consultar el rango DHCP).
- Un equipo candidato a servidor, o al menos sus características aproximadas.
- Una cuenta de correo para registrar las cuentas de Tailscale y Cloudflare.
- Un gestor de contraseñas donde guardar la contraseña del repositorio de respaldos. Esto no es
  opcional: si se pierde, los respaldos son matemáticamente irrecuperables.
- 40–60 minutos sin interrupciones para leer y rellenar `config/servidor.env`.

**Lo que aún NO necesitas:** el dominio de internet. La infraestructura se monta completa con un
dominio de ejemplo y solo hay que cambiar una variable cuando lo adquieras (capítulo 11).

---

## 3. Decisiones y por qué

Esta sección es el corazón del repositorio. Cada fila responde a la pregunta que se hará quien lea
esto dentro de un año: *«¿por qué está montado así y no de la otra forma?»*.

### 3.1 Modelo de amenazas

Antes de justificar decisiones de seguridad hay que decir contra qué se está protegiendo. Sin esto,
"seguridad" se convierte en acumular medidas sin criterio.

| Se protege | Contra | Cómo |
|---|---|---|
| Los servicios web publicados | Escaneo y explotación desde internet | El servidor no acepta conexiones entrantes: los túneles los inicia él hacia fuera. Un escaneo de puertos a tu IP doméstica no encuentra nada. |
| El acceso administrativo | Fuerza bruta de credenciales | SSH sin contraseñas, solo llaves. Sin acceso directo de root. `fail2ban` como red de seguridad. |
| Los datos de los proyectos | Fallo de disco, borrado accidental, ransomware | Respaldos cifrados con restic, con retención escalonada y prueba de restauración periódica. |
| El propio host Debian | Vulnerabilidades conocidas sin parchear | Actualizaciones de seguridad automáticas. Superficie mínima: sin escritorio, sin servicios innecesarios. |
| El host frente a los proyectos | Un proyecto mal escrito o comprometido | Todo va en contenedores. El host solo tiene Docker, SSH y Tailscale. |

**Lo que este montaje NO protege** (y conviene tenerlo claro):

- **Robo físico del equipo.** El disco no va cifrado. Es una decisión consciente: ver 3.3.
- **Un atacante ya dentro de tu LAN.** El puerto SSH está abierto a la red local. Si alguien está
  en tu Wi-Fi, la única barrera es la llave SSH.
- **Compromiso de tu cuenta de Cloudflare o Tailscale.** Ambas son puntos de confianza delegada.
  Actívales autenticación en dos factores; no es opcional.
- **Un contenedor que escape a root.** Pertenecer al grupo `docker` equivale a ser root. El
  capítulo 09 lo explica en detalle.

### 3.2 Sistema operativo

**Decisión: Debian 13 (Trixie), instalación mínima sin entorno gráfico.**

| Alternativa descartada | Por qué |
|---|---|
| Ubuntu Server LTS | Más paquetes recientes, pero añade `snap`, telemetría y ciclos de decisión ajenos. Debian es más previsible y más pequeño. |
| Debian 12 (Bookworm) | Su soporte estándar termina en julio de 2026; empezar un servidor nuevo en oldstable es empezar con deuda. |
| Proxmox / TrueNAS | Excelentes si el objetivo fuera virtualizar o servir archivos. Aquí el objetivo es Docker, y añadirían una capa de complejidad que no se usaría. |
| Distribuciones inmutables (Fedora CoreOS, Talos) | Muy alineadas con la idea de reproducibilidad, pero con una curva de aprendizaje que no compensa para un servidor doméstico de un solo administrador. |

Debian 13 se publicó el 9 de agosto de 2025, tiene soporte estándar hasta agosto de 2028 y LTS
hasta junio de 2030. Cinco años sin reinstalar es exactamente lo que se busca.

**Sin entorno gráfico** porque un servidor no lo necesita: consume RAM, amplía la superficie de
ataque y multiplica las actualizaciones. Toda la administración es por SSH.

### 3.3 Discos y cifrado

**Decisión: un disco, particionado con LVM, sin cifrado.**

LVM se incluye aunque hoy no haga falta: permite ampliar el sistema de archivos, añadir un disco
después o hacer instantáneas antes de una actualización arriesgada. Sin LVM, cualquiera de esas
cosas implica reinstalar.

**Por qué sin cifrado:** LUKS protege contra el robo físico del equipo, un escenario poco probable
en casa. A cambio, cada reinicio exige teclear una frase de paso delante del servidor, lo que
convierte un corte de luz a las 3 de la mañana en un servicio caído hasta que alguien vuelva a casa.
Existe `dropbear-initramfs` para desbloquear por SSH, pero añade una pieza frágil justo en el
arranque. Para datos que ya están respaldados cifrados fuera del equipo, la relación
coste/beneficio no sale.

**Si tu caso es distinto** (el servidor está en una oficina compartida, guardas datos de terceros,
te aplica alguna normativa), cifra: el capítulo 03 indica en qué paso exacto del instalador se
activa LUKS.

Esquema de particionado propuesto (justificación en el capítulo 03):

| Partición | Tamaño | Motivo |
|---|---|---|
| EFI | 512 MB | Requisito de UEFI. 512 MB evita quedarse corto con varios kernels. |
| `/boot` | 1 GB | Fuera de LVM para simplificar el arranque. Cabe holgadamente el histórico de kernels. |
| LVM: `/` | 40 GB | Sistema y paquetes. Suficiente con margen amplio. |
| LVM: `/var` | 30 GB | Imágenes, volúmenes y logs de Docker. Es lo que más crece. Separarlo evita que llenar el disco de contenedores tumbe el sistema. |
| LVM: `/srv` | resto | Código y datos de los proyectos. |
| LVM: swap | 2–4 GB | Red de seguridad, no sustituto de RAM. |

Se deja espacio libre sin asignar en el grupo de volúmenes a propósito: ampliar es trivial,
reducir no lo es.

### 3.4 Acceso administrativo

**Decisión: SSH solo con llaves ed25519, escuchando en la LAN y en `tailscale0`, con fail2ban.**

| Alternativa descartada | Por qué |
|---|---|
| Cambiar el puerto 22 a otro | Seguridad por oscuridad. El servicio no está expuesto a internet, así que no aporta nada y sí confusión al depurar. |
| SSH únicamente por Tailscale | Más cerrado, pero si Tailscale falla (caída del servicio, clave caducada, fallo de red) te quedas fuera y necesitas teclado y monitor físicos. Mantener la LAN es la vía de rescate. |
| Segundo factor TOTP | Protege contra el robo de la llave privada. A cambio, fricción diaria y una forma más de quedarse fuera. Con la llave protegida por frase de paso y el servicio no expuesto, el riesgo residual es bajo. |
| Contraseñas | No. |

**Regla que se repite en todos los capítulos**: nunca cierres la sesión SSH actual hasta haber
comprobado, desde una segunda terminal, que la nueva configuración deja entrar.

### 3.5 Cortafuegos

**Decisión: nftables nativo, con política `drop` en entrada, y ningún contenedor publicando puertos.**

Aquí hay un detalle que causa muchos disgustos: **Docker manipula directamente las reglas de
netfilter y salta por encima de UFW**. Un contenedor arrancado con `-p 8080:80` queda accesible
desde toda la red aunque UFW diga que ese puerto está bloqueado, porque las reglas de Docker se
evalúan antes.

La solución habitual es parchear la cadena `DOCKER-USER`. Funciona, pero deja el sistema en un
estado que hay que recordar y explicar. Este proyecto elige la raíz del problema:

> **Ningún contenedor publica puertos en el host.** Los contenedores se comunican entre sí por una
> red Docker interna llamada `proxy`. El único que recibe tráfico externo es `cloudflared`, y lo
> recibe por su propio túnel saliente, no por un puerto.

Con esa regla, el conflicto entre Docker y el cortafuegos simplemente no existe: no hay nada que
publicar. nftables se limita a proteger los servicios del host (SSH), y su configuración cabe en
una pantalla.

Se usa nftables directamente en lugar de UFW porque es lo que Debian trae de serie desde hace
años; UFW no es más que una capa encima. Una configuración tan corta no necesita esa capa.

### 3.6 Acceso remoto: Tailscale

**Decisión: Tailscale para toda la administración remota.**

Tailscale crea una red privada WireGuard entre tus dispositivos. El servidor inicia la conexión
hacia fuera, así que no hay que abrir ningún puerto en el router ni conocer la IP pública, que en
una conexión doméstica además suele cambiar.

| Alternativa descartada | Por qué |
|---|---|
| WireGuard puro | Sin dependencia de terceros y perfectamente válido, pero exige un puerto abierto en el router, IP pública estable o DNS dinámico, y gestión manual de claves por cada dispositivo. |
| Redirección de puertos + DNS dinámico | Expone SSH a internet. Es justamente lo que se quiere evitar. |
| Cloudflare Access para SSH | Concentra todo en un solo proveedor y ata la administración a que el túnel funcione. Conviene que las vías de administración y de publicación sean independientes. |

Tailscale y Cloudflare son proveedores distintos a propósito: si uno cae, el otro sigue. Y ambos
son gratuitos en el uso que se les da aquí.

### 3.7 Publicación web: Cloudflare Tunnel + Traefik

**Decisión: un único túnel de Cloudflare que entrega todo el tráfico a un Traefik interno.**

```
internet → Cloudflare (TLS, WAF, caché) → túnel saliente → cloudflared → Traefik → contenedor
```

Traefik descubre los contenedores leyendo sus etiquetas de Docker. Publicar un proyecto nuevo se
reduce a añadir cuatro etiquetas a su fichero compose y un registro DNS: **no hay que tocar la
configuración de Traefik ni la de Cloudflare**.

| Alternativa descartada | Por qué |
|---|---|
| Declarar cada subdominio en `cloudflared` | Cada proyecto nuevo obliga a editar la configuración del túnel y reiniciarlo, afectando a todos los demás. |
| Caddy | Configuración más legible, pero sin descubrimiento automático: hay que editar el Caddyfile por cada proyecto. |
| Nginx Proxy Manager | Cómodo por su interfaz web, pero su estado vive en una base de datos SQLite. No se puede versionar ni reconstruir desde el repositorio, que es justo lo que este proyecto busca. |
| Exponer puertos y usar Let's Encrypt | Requiere abrir 80 y 443 al mundo. Descartado por diseño. |

**TLS**: los certificados los gestiona Cloudflare en su borde. Entre Cloudflare y el servidor el
tráfico va por el túnel, ya cifrado. Traefik habla HTTP en claro dentro de la red interna de Docker,
que no sale de la máquina. No hay que renovar ningún certificado.

### 3.8 Contenedores

**Decisión: Docker CE del repositorio oficial, todo dockerizado, nada instalado en el host.**

El host solo lleva: Debian base, SSH, Tailscale, Docker y las utilidades de diagnóstico. Ni Node, ni
Python de aplicación, ni PostgreSQL, ni nginx. Cada proyecto trae sus dependencias en su imagen.

Esto tiene una consecuencia práctica muy concreta: **el capítulo 16 puede reconstruir el servidor
entero desde cero** porque el estado del sistema se reduce a "Debian + Docker + estos ficheros
compose + estos volúmenes restaurados".

Se usa `docker-ce` del repositorio oficial de Docker y no el paquete `docker.io` de Debian porque
este último se queda varias versiones atrás y no incluye el plugin `compose` v2.

### 3.9 Automatización

**Decisión: scripts bash idempotentes, uno por capítulo, más un `Makefile` de atajos.**

| Alternativa descartada | Por qué |
|---|---|
| Ansible | Técnicamente superior para esto y la evolución natural del proyecto. Se descarta *de momento* porque exige aprender otra herramienta a la vez que se aprende la infraestructura, y porque oculta lo que ocurre por debajo justo cuando el objetivo es entenderlo. |
| Todo manual | Máxima comprensión, mínima reproducibilidad. Un procedimiento de 300 pasos manuales se ejecuta mal a la tercera vez. |
| Un único script gigante | Imposible de retomar si falla a mitad, e imposible de mapear contra la documentación. |

Los scripts **acompañan** a la documentación, no la sustituyen: cada capítulo explica primero qué
hay que hacer y por qué, y solo después ofrece el script que lo automatiza. Quien quiera puede
ejecutar los pasos a mano y obtener el mismo resultado.

### 3.10 Respaldos

**Decisión: restic hacia un disco USB local, con repositorio remoto opcional.**

restic hace copias incrementales, deduplicadas y cifradas de extremo a extremo. Un `restic backup`
diario de 50 GB de proyectos ocupa unos pocos megabytes cuando casi nada ha cambiado.

| Alternativa descartada | Por qué |
|---|---|
| `rsync` a otro disco | Simple, pero sin histórico ni cifrado. Un borrado accidental se replica en la copia. |
| Instantáneas de LVM | Útiles para revertir una actualización, inservibles como respaldo: viven en el mismo disco. |
| Solo copia en la nube | Restaurar 50 GB por una conexión doméstica tarda horas. El disco local es la copia rápida; la remota es el seguro contra incendio o robo. |

**La regla que no se negocia**: un respaldo que no se ha restaurado nunca no es un respaldo. El
capítulo 14 incluye la prueba de restauración como paso obligatorio, no como sugerencia.

### 3.11 Observabilidad

**Decisión: Dozzle y Uptime Kuma, más herramientas de línea de comandos.**

Dozzle muestra los logs de todos los contenedores en una interfaz web, sin base de datos ni
almacenamiento propio. Uptime Kuma vigila que los servicios respondan y avisa cuando dejan de
hacerlo. Ambos accesibles **solo por Tailscale**, nunca por el túnel público.

Se descarta Prometheus + Grafana: es la respuesta correcta cuando hay que analizar tendencias
históricas de decenas de servicios, y aquí el coste de mantenerlo supera con creces la información
que aportaría. `btop`, `lazydocker` y `journalctl` cubren el diagnóstico puntual.

### 3.12 Despliegue de proyectos

**Decisión: un directorio por proyecto en `${DATOS_RAIZ}`, con su fichero compose versionado, y un
script de despliegue.**

```
${DATOS_RAIZ}/mi-proyecto/
├── docker-compose.yml     ← versionado en el repositorio del proyecto
├── .env                   ← solo en el servidor, permisos 600
└── datos/                 ← volúmenes con nombre, incluidos en el respaldo
```

Se descarta por ahora un runner de CI/CD autoalojado: añade una superficie de ataque considerable
(ejecuta código en tu servidor) y solo compensa cuando el ritmo de despliegues lo justifica.
`git pull && ./deploy.sh` cubre el caso real sin ceremonia.

### 3.13 Gestión de secretos

**Decisión: ficheros `.env` fuera de git, con permisos `600`, incluidos en el respaldo.**

Se valoró cifrarlos con SOPS + age para poder versionarlos. Es más elegante y más reproducible,
pero introduce una clave maestra que hay que custodiar y un paso de descifrado en cada despliegue.
Con un solo administrador, los `.env` locales bien respaldados resuelven el problema con menos
piezas móviles.

**Consecuencia asumida**: los secretos no se reconstruyen desde el repositorio. Por eso el capítulo
14 los incluye explícitamente en el respaldo y el 16 los trata como primer paso de la recuperación.

---

## 4. Variables usadas

Todas las decisiones anteriores se concretan en valores dentro de `config/servidor.env`. Es el
único sitio donde existen valores literales: la documentación siempre los referencia como
`${VARIABLE}`.

```bash
make init                    # copia la plantilla y le pone permisos 600
$EDITOR config/servidor.env
```

| Grupo | Variables | Cuándo se usan |
|---|---|---|
| Identidad | `SERVIDOR_HOSTNAME`, `SERVIDOR_DOMINIO_LOCAL`, `SERVIDOR_ZONA_HORARIA`, `SERVIDOR_LOCALE` | Capítulos 03, 04 |
| Usuario | `ADMIN_USUARIO`, `ADMIN_SSH_CLAVE_PUBLICA` | Capítulos 03, 05 |
| Red | `LAN_CIDR`, `LAN_IP`, `LAN_PREFIJO`, `LAN_GATEWAY`, `LAN_DNS`, `LAN_INTERFAZ`, `SSH_PUERTO` | Capítulos 05, 06 |
| Tailscale | `TS_HOSTNAME`, `TS_CIDR`, `TS_INTERFAZ` | Capítulos 06, 08 |
| Docker | `DOCKER_RED_PROXY`, `DOCKER_RED_PROXY_SUBRED`, `DATOS_RAIZ`, `DOCKER_LOG_MAX_SIZE`, `DOCKER_LOG_MAX_FILE` | Capítulos 09, 12 |
| Publicación | `DOMINIO_PUBLICO`, `TRAEFIK_DASHBOARD_HOST`, `CF_TUNEL_NOMBRE`, `CF_CONFIG_DIR` | Capítulos 10, 11, 12 |
| Respaldos | `RESTIC_USB_UUID`, `RESTIC_USB_MOUNT`, `RESTIC_REPO_LOCAL`, `RESTIC_REPO_REMOTO`, `RESTIC_PASSWORD_FILE`, `RESTIC_RETENCION_*`, `RESTIC_HORA` | Capítulo 14 |
| Observabilidad | `DOZZLE_HOST`, `UPTIME_KUMA_HOST` | Capítulo 13 |
| Instalación | `DISCO_DESTINO`, `DEBIAN_MIRROR`, `DEBIAN_SUITE` | Capítulos 01, 03 |

### Cómo averiguar los valores de red

Desde cualquier equipo ya conectado a tu red local:

```bash
ip -4 addr show          # tu IP y el prefijo → deduce LAN_CIDR
ip -4 route show default # la puerta de enlace → LAN_GATEWAY
```

Salida de ejemplo:

```
    inet 192.168.1.34/24 brd 192.168.1.255 scope global dynamic enp0s31f6
default via 192.168.1.1 dev enp0s31f6 proto dhcp metric 100
```

De ahí: `LAN_CIDR="192.168.1.0/24"`, `LAN_GATEWAY="192.168.1.1"`.

Para `LAN_IP` entra en tu router, busca el rango DHCP (a menudo `.100`–`.200`) y elige una dirección
**fuera de ese rango**, por ejemplo `.50`. Si el router no permite ver el rango, reserva la IP por
dirección MAC.

---

## 5. Procedimiento

### 5.1 Fases y tiempos

| Fase | Capítulos | Dónde se trabaja | Tiempo estimado |
|---|---|---|---|
| Planificación | 00 | Tu equipo | 1 h |
| Preparación | 01–02 | Tu equipo + el servidor apagado | 1–3 h (memtest puede quedar toda la noche) |
| Instalación | 03 | Delante del servidor | 45 min |
| Base y seguridad | 04–07 | Por SSH | 1,5 h |
| Conectividad | 08–09 | Por SSH | 45 min |
| Publicación | 10–12 | Por SSH | 1,5 h |
| Operación | 13–14 | Por SSH | 1,5 h |
| Cierre | 15–16 | Lectura y prueba | 1 h |

Total: entre 9 y 12 horas repartidas. **No intentes hacerlo de una sentada.** Los capítulos 03, 07
y 14 son buenos puntos para parar: el sistema queda en un estado coherente y verificado.

### 5.2 Matriz de dependencias

Cada capítulo da por hecho el estado que dejaron los anteriores. Estas son las dependencias reales,
no solo el orden de lectura:

| Capítulo | Depende de | Por qué |
|---|---|---|
| 01 USB | — | |
| 02 Equipo | — | Se puede hacer en paralelo con el 01 |
| 03 Instalación | 01, 02 | Necesita el medio verificado y la UEFI configurada |
| 04 Base | 03 | Necesita el sistema arrancando |
| 05 SSH | 04 | Necesita el usuario administrador y los paquetes base |
| 06 Red y firewall | 05 | El cortafuegos debe conocer el puerto SSH ya configurado |
| 07 Endurecimiento | 06 | Las actualizaciones automáticas necesitan salida a internet estable |
| 08 Tailscale | 06 | El cortafuegos debe permitir `tailscale0` antes de levantar la VPN |
| 09 Docker | 07 | Instala paquetes de un repositorio externo |
| 10 Traefik | 09 | Necesita el motor de contenedores y la red `proxy` |
| 11 Cloudflared | 10 | El túnel entrega el tráfico a Traefik |
| 12 Despliegue | 10, 11 | Un proyecto necesita enrutado y publicación |
| 13 Observabilidad | 10, 08 | Se publican tras Traefik y se acceden por Tailscale |
| 14 Respaldos | 12 | Hay que saber qué volúmenes existen para respaldarlos |
| 15 Mantenimiento | 14 | La rutina incluye verificar los respaldos |
| 16 Recuperación | 14 | Restaurar exige tener de qué |

Hay una dependencia que suele pillar por sorpresa: **el capítulo 06 debe permitir `tailscale0` antes
de que el capítulo 08 levante la VPN**. Si se hace al revés y estás administrando remotamente,
puedes cortarte el acceso a ti mismo.

### 5.3 Pasos de este capítulo

**Paso 1 — Clona el repositorio en tu equipo.**

```bash
git clone <url-del-repositorio> nomad_server
cd nomad_server
```

**Paso 2 — Crea tu configuración local.**

```bash
make init
```

Salida esperada:

```
[OK]    Creado config/servidor.env (permisos 600).
[INFO]  Edítalo antes de ejecutar cualquier script.
```

**Paso 3 — Averigua los valores de red** con los comandos de la sección 4 y anótalos.

**Paso 4 — Reserva la IP del servidor en el router.** Entra en su interfaz de administración y
reserva `${LAN_IP}` para la dirección MAC del servidor, o comprueba que está fuera del rango DHCP.
Esto se hace **ahora**, no después: si el servidor cambia de IP a mitad del montaje, se rompen las
sesiones SSH y las reglas del cortafuegos.

**Paso 5 — Rellena `config/servidor.env`.** Recórrelo de arriba abajo. Toda variable marcada como
`[OBLIGATORIA]` debe tener valor. Las demás pueden quedarse como están en una primera pasada.

**Paso 6 — Crea las cuentas externas.**

- [Tailscale](https://login.tailscale.com/start): cuenta gratuita, con verificación en dos pasos activada.
- [Cloudflare](https://dash.cloudflare.com/sign-up): cuenta gratuita, con verificación en dos pasos activada.

El dominio puede esperar al capítulo 11.

**Paso 7 — Guarda en tu gestor de contraseñas** una entrada nueva llamada
`nomad_server — repositorio restic`, con una contraseña larga generada al azar. La usarás en el
capítulo 14 y **no existe forma de recuperar los respaldos sin ella**.

**Paso 8 — Valida el repositorio.**

```bash
make check
```

### 5.4 Convenciones del repositorio

Conviene conocerlas antes de empezar, porque se aplican en todos los capítulos.

**Los bloques de comandos** indican dónde se ejecutan mediante un comentario en la primera línea:

```bash
# [servidor] — por SSH, como ${ADMIN_USUARIO}
sudo systemctl status ssh
```

```bash
# [cliente] — en tu propio equipo
ssh ${ADMIN_USUARIO}@${LAN_IP}
```

**Los scripts** viven en `scripts/`, se llaman igual que su capítulo y comparten interfaz:

```bash
sudo ./scripts/06_firewall.sh --check   # simula: enseña qué haría, no toca nada
sudo ./scripts/06_firewall.sh           # aplica
./scripts/06_firewall.sh --help         # qué hace y qué opciones admite
```

Todos son **idempotentes**: ejecutarlos dos veces deja el sistema igual que ejecutarlos una vez, y
la segunda ejecución informa de que no había nada que cambiar. Antes de modificar cualquier archivo
del sistema hacen una copia en `<archivo>.bak-<fecha>`.

**Los prefijos de salida** significan siempre lo mismo:

| Prefijo | Significado |
|---|---|
| `[OK]` | Hecho correctamente |
| `[=]` | Ya estaba en el estado deseado; no se ha tocado nada |
| `[INFO]` | Información del progreso |
| `[CHECK]` | Modo simulación: esto es lo que se *haría* |
| `[AVISO]` | Algo merece tu atención, pero no detiene la ejecución |
| `[ERROR]` | Falló; el script se detiene |

---

## 6. Script asociado

Este capítulo no configura el servidor, así que solo intervienen los objetivos del `Makefile`:

| Comando | Qué hace |
|---|---|
| `make ayuda` | Lista los objetivos disponibles |
| `make init` | Crea `config/servidor.env` desde la plantilla, con permisos 600 |
| `make check` | Valida todo el repositorio: scripts, documentación, variables y secretos |
| `make indice` | Lista los capítulos en su orden de ejecución |
| `make herramientas` | Explica cómo instalar las herramientas de validación opcionales |

`make check` ejecuta `scripts/verificar_repositorio.sh`, que comprueba la sintaxis de los scripts,
que todos los capítulos tengan las 10 secciones obligatorias, que ninguna `${VARIABLE}` usada en la
documentación falte en la plantilla, que no haya enlaces rotos y que no se haya colado ningún
secreto en el control de versiones.

---

## 7. Validación

Este capítulo está terminado cuando **todo** lo siguiente es cierto:

```bash
# [cliente]
make check
```

Criterio de aceptación: termina con `[OK] Todas las comprobaciones han pasado.` y código de salida 0.

```bash
# [cliente]
grep -c 'CAMBIAME' config/servidor.env
```

Criterio de aceptación: devuelve `0`.

```bash
# [cliente] — comprueba que no quedan variables obligatorias vacías
grep -B1 'OBLIGATORIA' config/servidor.env.example \
  | grep -oE '^[A-Z_]+' \
  | while read -r v; do
      grep -qE "^${v}=\"..*\"" config/servidor.env || echo "sin valor: ${v}"
    done
```

Criterio de aceptación: no imprime nada.

Además, comprobación manual:

- [ ] `${LAN_IP}` está reservada en el router o fuera del rango DHCP.
- [ ] La cuenta de Tailscale existe y tiene verificación en dos pasos activada.
- [ ] La cuenta de Cloudflare existe y tiene verificación en dos pasos activada.
- [ ] La contraseña del repositorio restic está guardada en el gestor de contraseñas.
- [ ] Has leído entera la sección 3 y entiendes por qué el servidor no expone puertos.

### Criterios de "hecho" del proyecto completo

Estos son los criterios que se validan al final del capítulo 14 y que definen el proyecto como
terminado:

1. Puedes entrar por SSH con llave desde la LAN **y** desde Tailscale, y la contraseña es rechazada.
2. `nft list ruleset` muestra política `drop` en entrada y solo lo previsto permitido.
3. `docker ps` no muestra **ningún** puerto publicado en el host.
4. Un proyecto de ejemplo responde por HTTPS en su subdominio a través del túnel.
5. `restic snapshots` muestra al menos un snapshot y una restauración de prueba ha funcionado.
6. Tras `sudo reboot`, todo vuelve solo, sin intervención manual.
7. `scripts/verificar_sistema.sh` termina sin errores.

---

## 8. Reversión

No hay nada que revertir: este capítulo no modifica el sistema.

**Si necesitas cambiar una decisión más adelante**, el procedimiento es:

1. Edita la sección 3 de este documento explicando la nueva decisión **y por qué cambió**. No
   borres la anterior: añade una línea de contexto. El valor de este archivo está en el histórico
   de razonamientos, no solo en el estado final.
2. Ajusta `config/servidor.env` si el cambio afecta a algún valor.
3. Vuelve a ejecutar el script del capítulo correspondiente. Al ser idempotentes, aplican solo la
   diferencia.
4. Ejecuta `make check` y `scripts/verificar_sistema.sh`.

**Si te equivocaste al rellenar `config/servidor.env`** y ya has ejecutado scripts: corrige el
valor y vuelve a ejecutar los scripts de los capítulos afectados, en orden. La sección 8 de cada
capítulo indica qué hay que deshacer a mano, si algo.

---

## 9. Errores frecuentes

| Síntoma | Causa probable | Solución | Documentación |
|---|---|---|---|
| Los scripts fallan con «Variables sin definir» | `config/servidor.env` no existe o quedaron variables vacías | `make init` y rellena las marcadas como `[OBLIGATORIA]` | Sección 4 de este capítulo |
| El servidor cambia de IP a los pocos días | La IP elegida está dentro del rango DHCP y el router se la ha dado a otro equipo | Reserva la IP por MAC en el router, o elige una fuera del rango DHCP | Paso 4 |
| `make check` avisa de que falta `shellcheck` | Es una dependencia opcional | `sudo apt install shellcheck`, o ignóralo: es un aviso, no un fallo | `make herramientas` |
| No sé qué poner en `LAN_INTERFAZ` | Debian usa nombres predecibles (`enp3s0`, `eno1`), no `eth0`, y solo se ven desde el propio servidor | Déjala vacía: los scripts la detectan automáticamente. Se confirma en el capítulo 06 | [Predictable Network Interface Names](https://wiki.debian.org/NetworkInterfaceNames) |
| No tengo dominio todavía | No hace falta hasta el capítulo 11 | Deja `DOMINIO_PUBLICO` con el valor de ejemplo y sigue | Capítulo 11 |
| Dudo entre cifrar el disco o no | Depende de tu escenario físico, no de una regla general | Lee 3.3. Si el servidor está en un espacio compartido, cifra | Capítulo 03 |
| Me preocupa que Docker ignore el cortafuegos | Es un problema real, pero este diseño lo evita de raíz | Lee 3.5: ningún contenedor publica puertos | [Docker and iptables](https://docs.docker.com/engine/network/packet-filtering-firewalls/) |
| El equipo candidato solo tiene Wi-Fi | Un servidor con Wi-Fi es frágil: reconexiones, latencia variable, firmware propietario | Usa cable. Si es imposible, un adaptador USB-Ethernet cuesta poco y es más fiable | Capítulo 02 |

---

## 10. Referencias

**Debian**

- [Debian — Releases](https://www.debian.org/releases/) — versiones vigentes y fechas de soporte
- [Debian 13 «Trixie» — Notas de publicación](https://www.debian.org/releases/trixie/releasenotes)
- [Debian Wiki — LVM](https://wiki.debian.org/LVM)
- [Debian Wiki — nftables](https://wiki.debian.org/nftables)
- [Debian Wiki — Nombres de interfaces de red](https://wiki.debian.org/NetworkInterfaceNames)

**Docker**

- [Instalación de Docker Engine en Debian](https://docs.docker.com/engine/install/debian/)
- [Docker y el filtrado de paquetes](https://docs.docker.com/engine/network/packet-filtering-firewalls/)

**Tailscale**

- [Documentación de Tailscale](https://tailscale.com/kb/)

**Cloudflare**

- [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)

**Traefik**

- [Traefik Proxy v3 — Documentación](https://doc.traefik.io/traefik/)

**restic**

- [restic — Documentación](https://restic.readthedocs.io/)

---

**Siguiente:** [01 — Unidad USB booteable](01_unidad_usb_booteable.md)
