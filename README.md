# nomad_server

> Documentación reproducible para montar, desde cero, un servidor Debian doméstico
> que aloja proyectos web dockerizados sin exponer un solo puerto a internet.

![Debian](https://img.shields.io/badge/Debian-13%20Trixie-A81D33?logo=debian&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-CE-2496ED?logo=docker&logoColor=white)
![Traefik](https://img.shields.io/badge/Traefik-v3-24A1C1?logo=traefikproxy&logoColor=white)
![Cloudflare Tunnel](https://img.shields.io/badge/Cloudflare-Tunnel-F38020?logo=cloudflare&logoColor=white)
![Tailscale](https://img.shields.io/badge/Tailscale-VPN-242424?logo=tailscale&logoColor=white)
![Licencia](https://img.shields.io/badge/licencia-MIT-green)

---

## Qué es esto

Este repositorio **no es un servidor**: es el procedimiento completo para construirlo.

Su objetivo es que dentro de un año, o en otro equipo, o después de que se muera un disco,
cualquiera pueda repetir el montaje **paso por paso y obtener exactamente el mismo resultado**,
sin depender de la memoria de nadie ni de un tutorial de internet que ya no existe.

Para conseguirlo, cada capítulo documenta no solo *qué* comandos ejecutar, sino *por qué* se eligió
esa opción, *cómo verificar* que funcionó y *qué hacer* cuando falla.

### Principios

| Principio | Cómo se materializa |
|---|---|
| **Reproducibilidad** | Cero valores inventados sobre la marcha: todo sale de `config/servidor.env`. Cada paso tiene comando exacto y salida esperada. |
| **Consistencia** | Los 17 capítulos comparten la misma estructura de 10 secciones. Siempre sabes dónde mirar. |
| **Robustez** | Todo script es idempotente y admite `--check` para simular. Nada se sobrescribe sin copia de seguridad previa. |
| **Seguridad** | Nada se expone a internet. SSH solo con llaves. Firewall con política de denegación por defecto. Ningún contenedor publica puertos al host. |
| **Verificabilidad** | Cada capítulo termina con comandos de validación y un criterio de aceptación explícito. Un paso sin validación no está terminado. |
| **Recuperabilidad** | Respaldos cifrados con prueba de restauración obligatoria y un capítulo dedicado a reconstruir todo desde cero. |

---

## Arquitectura

```
                    INTERNET
                        │
                        │  (ningún puerto abierto hacia el servidor)
        ┌───────────────┴───────────────┐
        │                               │
   ┌────▼─────────────┐        ┌────────▼────────┐
   │   Cloudflare     │        │    Tailscale    │
   │   (borde TLS)    │        │  (malla WireGuard) │
   │  *.midominio.com │        │                 │
   └────┬─────────────┘        └────────┬────────┘
        │ túnel saliente                │ túnel saliente
        │ (cloudflared)                 │ (tailscaled)
════════╪═══════════════════════════════╪═══════════════════ RED LOCAL
        │                               │
   ┌────▼───────────────────────────────▼──────────────────────────┐
   │  SERVIDOR DEBIAN 13                                            │
   │  ┌──────────────────────────────────────────────────────────┐ │
   │  │  nftables — política DROP en entrada                      │ │
   │  │  Solo se admite: LAN (SSH) + tailscale0                   │ │
   │  └──────────────────────────────────────────────────────────┘ │
   │                                                                │
   │  ┌─ red docker "proxy" (interna, sin puertos publicados) ────┐ │
   │  │                                                            │ │
   │  │   cloudflared ──▶ Traefik ──┬──▶ proyecto-a                │ │
   │  │                             ├──▶ proyecto-b                │ │
   │  │                             ├──▶ Dozzle       (solo VPN)   │ │
   │  │                             └──▶ Uptime Kuma  (solo VPN)   │ │
   │  └────────────────────────────────────────────────────────────┘ │
   │                                                                │
   │  restic ──▶ disco USB cifrado  (+ repositorio remoto opcional) │
   └────────────────────────────────────────────────────────────────┘
                        │
                   ┌────▼────┐
                   │ tu PC   │  SSH por LAN o por Tailscale
                   └─────────┘
```

**La idea central**: el servidor nunca acepta conexiones entrantes desde internet. Tanto Cloudflare
como Tailscale funcionan con túneles que el propio servidor **inicia hacia fuera**. Por eso no hay
que abrir puertos en el router, no hay que exponer la IP doméstica y un escaneo de puertos desde
internet no encuentra absolutamente nada.

---

## Índice de capítulos

Los capítulos están numerados en su **orden de ejecución**. Cada uno declara de cuáles depende, así
que no los saltes: el 06 da por hecho lo que hizo el 05.

### Preparación (antes de tocar el servidor)

| # | Capítulo | Qué consigues |
|---|---|---|
| 00 | [Planificación](docs/00_planificacion.md) | La visión completa: arquitectura, decisiones y sus porqués, variables, dependencias |
| 01 | [Unidad USB booteable](docs/01_unidad_usb_booteable.md) | Un instalador verificado criptográficamente |
| 02 | [Validación del equipo](docs/02_validacion_equipo.md) | Hardware inventariado, comprobado y con la BIOS/UEFI lista |

### Sistema base

| # | Capítulo | Qué consigues |
|---|---|---|
| 03 | [Instalación de Debian](docs/03_instalacion_debian.md) | Debian 13 mínimo sobre LVM, arrancando |
| 04 | [Primer arranque y base](docs/04_primer_arranque_y_base.md) | Sistema actualizado, con hora, nombre y sudo correctos |
| 05 | [Usuarios y acceso SSH](docs/05_usuarios_y_acceso_ssh.md) | Acceso remoto solo con llave, sin contraseñas |
| 06 | [Red y cortafuegos](docs/06_red_y_firewall.md) | IP estable y nftables denegando todo por defecto |
| 07 | [Endurecimiento](docs/07_endurecimiento_del_sistema.md) | Actualizaciones automáticas y superficie de ataque reducida |

### Conectividad

| # | Capítulo | Qué consigues |
|---|---|---|
| 08 | [Tailscale](docs/08_tailscale.md) | Acceso al servidor desde cualquier lugar, sin abrir puertos |
| 09 | [Docker](docs/09_docker.md) | Motor de contenedores configurado y la red `proxy` creada |

### Publicación

| # | Capítulo | Qué consigues |
|---|---|---|
| 10 | [Traefik](docs/10_traefik.md) | Enrutado automático por subdominios mediante etiquetas |
| 11 | [Cloudflared y dominio](docs/11_cloudflared_y_dominio.md) | Tus proyectos accesibles desde internet por HTTPS |
| 12 | [Despliegue de proyectos](docs/12_despliegue_de_proyectos.md) | Un procedimiento repetible para publicar cada proyecto |

### Operación

| # | Capítulo | Qué consigues |
|---|---|---|
| 13 | [Observabilidad](docs/13_observabilidad.md) | Saber qué pasa dentro del servidor y enterarte si algo cae |
| 14 | [Respaldos con restic](docs/14_respaldos_restic.md) | Copias cifradas automáticas y restauración probada |
| 15 | [Mantenimiento](docs/15_mantenimiento_y_actualizaciones.md) | Una rutina para que el servidor no se pudra con el tiempo |
| 16 | [Recuperación ante desastres](docs/16_recuperacion_ante_desastres.md) | Volver a estar en pie tras un fallo grave |
| 99 | [Glosario y referencias](docs/99_glosario_y_referencias.md) | Términos y documentación oficial |

### Listas de comprobación

- [Antes de instalar](checklists/pre_instalacion.md) — imprímela y tenla al lado del equipo
- [Después de instalar](checklists/post_instalacion.md) — validación de extremo a extremo
- [Rutina de mantenimiento](checklists/mantenimiento.md) — semanal, mensual y trimestral

---

## Cómo se usa este repositorio

```bash
# 1. Clona el repositorio en TU EQUIPO (no en el servidor todavía)
git clone <url-del-repositorio> nomad_server
cd nomad_server

# 2. Crea tu configuración local a partir de la plantilla
make init
$EDITOR config/servidor.env      # rellena hostname, red, dominio, usuario…

# 3. Comprueba que el repositorio está sano
make check

# 4. Empieza a leer por el principio
$PAGER docs/00_planificacion.md
```

A partir del capítulo 04 el repositorio se clona **también en el servidor**, porque los scripts se
ejecutan allí. El capítulo 04 explica cómo.

### Anatomía de un capítulo

Todos los capítulos tienen exactamente las mismas 10 secciones, en el mismo orden:

1. **Objetivo** — qué queda funcionando al terminar
2. **Requisitos previos** — de qué capítulos depende y qué necesitas a mano
3. **Decisiones y por qué** — qué se descartó y por qué razón
4. **Variables usadas** — qué campos de `config/servidor.env` intervienen
5. **Procedimiento** — los pasos, con comandos exactos y salida esperada
6. **Script asociado** — qué parte está automatizada y cómo invocarla
7. **Validación** — cómo comprobar que quedó bien, con criterio de aceptación
8. **Reversión** — cómo deshacerlo sin reinstalar
9. **Errores frecuentes** — síntoma → causa → solución → documentación oficial
10. **Referencias** — enlaces a documentación oficial, nunca a blogs

### Convenciones

- **Nada de valores fijos.** La documentación usa `${VARIABLES}` que se definen una sola vez en
  `config/servidor.env`. Si tu red es `10.0.0.0/24` en lugar de `192.168.1.0/24`, cambias una línea
  y toda la documentación sigue siendo correcta.
- **Los scripts son idempotentes.** Ejecutarlos dos veces no rompe nada. Todos aceptan `--check`
  para ver qué harían sin tocar el sistema, y `--help` para saber qué hacen.
- **Nada se sobrescribe a ciegas.** Cualquier archivo del sistema que se modifique se copia antes a
  `<archivo>.bak-<fecha>`.
- **Los secretos nunca se versionan.** `config/servidor.env`, los `.env` de los proyectos y las
  credenciales del túnel viven solo en el servidor, con permisos `600`, y se respaldan con restic.

---

## Estructura del repositorio

```
nomad_server/
├── config/servidor.env.example   Todas las variables del despliegue, comentadas
├── docs/                         Los 18 capítulos
├── scripts/
│   ├── lib/common.sh             Biblioteca compartida: registro, validaciones, idempotencia
│   ├── 01…14_*.sh                Un script por capítulo, idempotente y con --check
│   ├── deploy.sh                 Despliegue de proyectos, con reversión automática
│   ├── verificar_sistema.sh      Estado del servidor: lo que se ejecuta cada semana
│   └── verificar_repositorio.sh  Lo que ejecuta 'make check'
├── templates/                    Configuración del sistema y ficheros compose parametrizados
│   ├── etc/                      nftables, sshd, sysctl, journald, respaldo…
│   ├── systemd/                  Unidades de servicio y temporizadores
│   └── compose/                  Traefik, cloudflared, observabilidad, proyecto de ejemplo
└── checklists/                   Listas de comprobación imprimibles
```

### Los tres scripts que se usan a diario

Cuando el montaje termina, estos son los que quedan:

```bash
./scripts/verificar_sistema.sh --rapido   # ¿está todo bien? (2 min, semanal)
./scripts/deploy.sh <proyecto>            # actualizar un proyecto
sudo ./scripts/14_restic.sh --probar      # ¿sirven mis respaldos? (trimestral)
```

---

## Requisitos

**En tu equipo:** un cliente SSH, `git`, y capacidad para escribir una imagen en un USB.
`make` para los atajos. Opcionalmente `shellcheck` y `lychee` para las validaciones
(`make herramientas` explica cómo instalarlos).

**En el servidor:** un PC x86_64 con UEFI, al menos 4 GB de RAM (8 recomendados), un disco SSD y
conexión por cable. El capítulo [02](docs/02_validacion_equipo.md) detalla cómo comprobarlo.

**Servicios externos:** una cuenta de [Tailscale](https://tailscale.com) (el plan gratuito sobra) y
una cuenta de [Cloudflare](https://cloudflare.com) con un dominio delegado (necesaria solo a partir
del capítulo 11).

---

## Licencia

[MIT](LICENSE). Úsalo, cópialo y adáptalo a tu propio servidor sin pedir permiso.
