---
name: desplegar-en-nomadservernw
description: Adapta un proyecto al contrato de dockerización de nomad_server y lo publica en el servidor doméstico nomadservernw, bajo un subdominio de nordirwork.com. Úsala siempre que se hable de desplegar, publicar o poner en producción cualquier proyecto propio, de nomadservernw, nordirwork.com, del contrato de dockerización, del anexo 96, de revisar_proyecto.sh o de deploy.sh — y también cuando se pida "montar esto en mi servidor", "sacarlo a internet", "que se vea desde fuera" o preparar un compose de producción, aunque no se nombre el servidor. Sirve tanto para escribir desde cero el `deploy/nomad/` de un proyecto como para ejecutar el despliegue paso a paso.
---

# Desplegar en nomadservernw

`nomad_server` documenta un servidor Debian doméstico que publica proyectos sin
abrir un solo puerto a internet. El servidor resuelve de una vez la publicación,
el TLS, el enrutado y el respaldo; a cambio, cada proyecto tiene que estar
construido de una forma concreta, descrita en el **anexo 96, contrato de
dockerización** (`docs/96_contrato_de_dockerizacion.md`).

Esta skill cubre las dos mitades del trabajo, que son muy distintas:

| Fase | Qué es | Dónde |
|---|---|---|
| **Adaptar** | Escribir el `docker-compose.yml`, el `.env.example` y el gancho de volcado del proyecto, y arreglar lo que impida arrancar en producción | `references/adaptar.md` |
| **Desplegar** | Registro DNS, gancho, auditoría, `deploy.sh`, contenido inicial | `references/desplegar.md` |

Y dos anexos que se consultan cuando toca:

- `references/migrar-datos.md` — llevar al servidor lo que ni git ni los seeds transportan (archivos subidos, filas creadas por importadores).
- `references/trampas.md` — los fallos que **no dan error**: pasan la auditoría, arrancan, y rompen algo en silencio. Léelo antes de dar un despliegue por bueno.

## Lo primero, siempre: los valores reales

`config/servidor.env.example` son valores de **ejemplo**, no los del servidor.
Configurar un proyecto a partir de la plantilla produce fallos silenciosos: un
`TRUSTED_PROXIES` equivocado no rompe nada visible, solo colapsa el rate
limiting en un único bucket para todos los visitantes.

```bash
cd ~/nomad_server && source scripts/lib/entorno.sh
cat <<VALORES
  Red compartida  : ${DOCKER_RED_PROXY}
  Subred          : ${DOCKER_RED_PROXY_SUBRED}
  Raíz de proyectos: ${DATOS_RAIZ}
  Dominio público : ${DOMINIO_PUBLICO}
VALORES
```

Si `config/servidor.env` no existe en la máquina donde estás trabajando, **no
inventes los valores**: pídeselos a quien tenga el servidor. Es preferible
parar a rellenar el hueco con la plantilla.

## Decisiones que no puedes tomar tú

Pregunta antes de escribir nada, porque cambian el resultado:

1. **El nombre de host.** Todos los proyectos van a un subdominio de
   `${DOMINIO_PUBLICO}`; el ápice queda reservado a un único proyecto
   principal. Comprueba si ya está reclamado —`grep -rn "Host(" ` en los
   compose de los demás proyectos— antes de proponerlo.
2. **El nombre del proyecto**, que es a la vez el directorio en
   `${DATOS_RAIZ}`, el prefijo de los contenedores y el nombre del router de
   Traefik. Conviene que coincida con el subdominio.
3. **Qué se hace con el despliegue anterior**, si el proyecto ya tenía uno.
   Mantener un script propio junto a `deploy.sh` del servidor produce dos
   comportamientos que divergen con el tiempo.

## El flujo

```
1. Leer el contrato          docs/96_contrato_de_dockerizacion.md
2. Cargar los valores reales source scripts/lib/entorno.sh
3. Decidir host y nombre     ← preguntar
4. Adaptar el proyecto       references/adaptar.md
5. Verificar en local        simulación + revisar_proyecto.sh
6. Desplegar                 references/desplegar.md
7. Migrar datos que faltan   references/migrar-datos.md
8. Repasar las trampas       references/trampas.md
```

## Verifica en local antes de tocar el servidor

Casi todo se puede comprobar sin salir de tu equipo, y merece la pena: un
despliegue fallido en el servidor cuesta mucho más de diagnosticar.

Monta la estructura que tendrá el servidor y ejecuta el auditor **real** contra
ella pasándole la ruta absoluta:

```bash
SIM=/tmp/sim/<proyecto>
mkdir -p ${SIM}/{datos,datos-db}
cp <proyecto>/deploy/nomad/docker-compose.yml ${SIM}/
ln -s $(pwd)/<proyecto> ${SIM}/codigo
cp <proyecto>/deploy/nomad/.env.example ${SIM}/.env   # y rellena los centinelas
chmod 600 ${SIM}/.env

cd ~/nomad_server && ./scripts/revisar_proyecto.sh ${SIM}
```

Solo dos comprobaciones fallarán siempre fuera del servidor: el registro DNS y
el gancho de volcado en `/etc/nomad/pre-respaldo.d/`. Cualquier otra cosa que
salga en rojo es un problema real del proyecto.

**Y levántalo de verdad, no te quedes en `docker compose config`.** Construir la
imagen no prueba que arranque. Los fallos más caros de esta migración —un
autoloader roto, un directorio sin permisos de escritura— solo aparecen cuando
el contenedor corre con el layout de producción, porque en desarrollo el bind
mount del repositorio tapa lo que está mal.

## Cuándo has terminado

- `revisar_proyecto.sh <proyecto>` cierra en verde en el servidor.
- El sitio responde `200` desde internet y las cabeceras de seguridad llegan
  (si llegan, `publico@file` se está aplicando de verdad y no solo carga la página).
- El gancho de volcado produce un archivo restaurable, probado a mano.
- El contenido está completo: no basta con que la home cargue. Compara con el
  entorno de desarrollo lo que no viajó en el repositorio.
- Hay un monitor en Uptime Kuma.
