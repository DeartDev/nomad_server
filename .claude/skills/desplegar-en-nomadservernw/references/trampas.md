# Lo que falla en silencio

Todo lo de aquí pasa la auditoría, o arranca, o da `200`. El patrón común es que
el entorno de desarrollo **tapa** el problema, y solo aparece en producción o
más tarde. Repásalo antes de dar un despliegue por bueno.

## El bind mount de desarrollo esconde la imagen

Es la causa raíz de casi todo lo demás. Si tu compose de desarrollo monta el
repositorio sobre la raíz de la aplicación, lo que se ejecuta es el código del
**anfitrión**, no el de la imagen. Todo lo que la imagen hornea —dependencias
instaladas, autoloaders, configuración del servidor web— queda enmascarado.

Consecuencia práctica: **construir la imagen no valida nada**. Hay que
levantarla con el layout de producción, sin ese bind mount.

Un caso concreto que costó caro: un autoloader generado en una etapa de
construcción que solo tenía el manifiesto de dependencias, sin el código de la
aplicación. Con el modo «solo mapa de clases» —que desactiva el respaldo por
convención de rutas— el mapa salía sin las clases propias y el contenedor moría
en bucle al arrancar. En desarrollo jamás se vio, porque el mapa que se usaba
era el del anfitrión.

Si tu construcción tiene una etapa de dependencias separada, asegúrate de que
el volcado del autoloader ocurre **después** de copiar el código.

## Reconstruir la imagen no recrea el contenedor

`docker compose build` deja la imagen nueva y el contenedor corriendo la vieja.
Y como el bind mount hace que los cambios de código se vean al instante, parece
que todo se ha aplicado. Lo que se queda atrás es lo que vive fuera de la raíz
de la aplicación: entrypoint, configuración del servidor web, extensiones.

El ciclo completo es `docker compose up -d --build`. Para verificarlo, compara
el id de imagen del contenedor con el de la etiqueta.

## Los bind mounts llegan con el uid del anfitrión

Un volumen con nombre hereda el propietario de la imagen; un bind mount, no. La
aplicación arranca, la portada responde, y el fallo aparece la primera vez que
alguien sube un archivo. Un healthcheck que solo pide la portada no lo detecta.

Comprueba explícitamente la **escritura** en cada ruta de datos, con el usuario
de la aplicación.

## El centinela del `.env` en un comentario

`revisar_proyecto.sh` busca la palabra centinela con un `grep` sobre el archivo
entero. Un comentario que la mencione —«sustituye los CAMBIAME»— deja la
auditoría fallando para siempre aunque todos los valores estén puestos.

## Un `HEALTHCHECK` en el Dockerfile no cuenta

El auditor lee `docker compose config --format json`, donde no aparece lo que
declara la imagen. Va en el compose.

## `servidor.env.example` no son los valores del servidor

Son ejemplos. Tomar de ahí la subred de proxies de confianza, la raíz de
proyectos o el nombre de la red produce fallos de distinta gravedad, y el peor
es el más silencioso: con una subred equivocada, la aplicación no reconoce a
Traefik como proxy de confianza, `REMOTE_ADDR` es siempre el mismo y todos los
visitantes comparten un único bucket de rate limiting. Nada falla a la vista.

## Un dump de tabla lleva los id literales

Ver `migrar-datos.md`. El conteo cuadra, no hay huérfanas, y las relaciones
salen mezcladas.

## Un `JOIN` entre collations distintas devuelve error, no vacío

Si has silenciado `stderr` en el comando de verificación, lo lees como «cero
problemas». Cuando una comprobación devuelva vacío, confirma que no es un error
tragado antes de celebrarlo.

## El repositorio privado y el `git clone`

`deploy.sh` hace `git pull` en cada despliegue, así que no basta con que el
código haya llegado una vez. Comprueba la visibilidad del repositorio antes de
escribir el procedimiento, no cuando el primer despliegue muera en el primer
comando.

## Cachés que no se invalidan al sembrar

Ver `migrar-datos.md`. Una petición hecha mientras el sitio estaba vacío puede
dejar cacheada una versión vacía que se sirve para siempre.

## El nombre de proyecto de Compose se deriva del directorio

Si el directorio de despliegue se llama igual que el proyecto de tu compose de
desarrollo, levantar uno **recrea los contenedores del otro**. En el servidor no
hay colisión, pero sí en tu equipo si pruebas ahí el compose de producción.
Compruébalo antes de lanzarlo en local.

## `/etc/nomad/pre-respaldo.d` y los permisos

Si el directorio quedara en `700` de root, `revisar_proyecto.sh` no puede
expandir el glob que busca el gancho, porque se ejecuta sin privilegios: la
comprobación falla **siempre**, también con el gancho bien instalado. Debe ser
`755`, con los ganchos en `700`. Si te encuentras esa comprobación fallando con
el archivo claramente en su sitio, mira los permisos del directorio antes de
dudar del gancho.

## `deploy.sh` no revierte migraciones

Su reversión devuelve código y configuración. Si el despliegue migró el esquema
y luego falló, quedas con código antiguo y datos nuevos. Respalda a mano antes
de un despliegue con migraciones.
