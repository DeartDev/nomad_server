# Migrar lo que ni git ni los seeds transportan

Un despliegue puede salir en verde y dejar el sitio a medias. Las migraciones
crean las tablas, los seeds ponen el contenido curado, pero casi todo proyecto
tiene una tercera categoría que no viaja con ninguno de los dos:

- **Archivos subidos** — imágenes, adjuntos, PDF. Están en el directorio de
  datos, que está en `.gitignore`.
- **Filas creadas por importadores** — las que genera un script a partir de
  material que tampoco se versiona.

Nada avisa de que faltan: las páginas cargan, el conteo de proyectos cuadra, y
solo se nota mirando.

**Antes de dar el despliegue por terminado, saca la huella de desarrollo y
compárala con producción**: número de archivos por directorio de datos y
número de filas por tabla que no venga de un seed.

## Los archivos

El directorio de datos pertenece al usuario de la aplicación, no al tuyo, así
que un `rsync` directo desde tu cuenta en el servidor da permiso denegado. La
vía limpia es empujarlos a través del contenedor: el demonio de Docker corre
como root y sí puede escribir en el bind mount.

```bash
# [cliente]
docker exec <contenedor-app> sh -c 'cd <raíz> && tar czf - -C <dir padre> <subdir>' > /tmp/datos.tgz
scp /tmp/datos.tgz <usuario>@nomadservernw:/tmp/

# [servidor]
cd ${DATOS_RAIZ}/<proyecto>
mkdir -p /tmp/datos && tar xzf /tmp/datos.tgz -C /tmp/datos
docker compose cp /tmp/datos/<subdir>/. app:<ruta en el contenedor>/
docker compose exec -T app chown -R <usuario-de-la-app> <ruta de datos>
```

## Las filas: por clave natural, nunca por id

Un `mysqldump` de la tabla lleva las claves foráneas **literales**. Si los `id`
del servidor no coinciden con los tuyos —y no tienen por qué, aunque ambos se
hayan sembrado del mismo archivo— las filas se cuelgan del registro
equivocado. Lo grave es cómo falla: el conteo cuadra, no hay huérfanas, y las
relaciones salen mezcladas sin que nada lo señale.

Exporta resolviendo la clave foránea **en destino**, por una clave natural
estable como un slug:

```sql
SELECT CONCAT(
  'INSERT INTO <tabla> (<fk>, <col1>, <col2>) SELECT p.id, ',
  QUOTE(c.<col1>), ', ', QUOTE(c.<col2>),
  ' FROM <tabla_padre> p WHERE p.slug = ', QUOTE(p.slug), ';')
FROM <tabla> c JOIN <tabla_padre> p ON p.id = c.<fk>
ORDER BY p.slug, c.orden;
```

`QUOTE()` escapa y entrecomilla, y devuelve `NULL` sin comillas cuando el valor
es nulo, que es justo lo que hace falta. Para columnas numéricas anulables usa
`IFNULL(col,'NULL')`.

Ejecutado con `-N -B`, eso produce un archivo de `INSERT ... SELECT` que se
importa tal cual y es inmune a que los `id` difieran.

### Compruébalo con los id cambiados a propósito

No te fíes de que coincidan: demuéstralo. Crea una base de prueba con la tabla
padre en **otro orden de id** y verifica que las filas caen igual en su sitio.

```sql
INSERT INTO prueba.<tabla_padre> (slug) SELECT slug FROM real.<tabla_padre> ORDER BY id DESC;
```

Si el import es correcto, el resultado es idéntico al de la base real.

**Cuidado al escribir la verificación**: un `JOIN` entre bases con
*collations* distintas lanza `Illegal mix of collations` y, si has silenciado
`stderr`, ves un resultado vacío y lo lees como «no hay problemas». Compara con
un `COLLATE` explícito, o crea la tabla de prueba con la misma collation.

Comparar una columna con un literal —lo que hace el `WHERE p.slug = '…'` del
export— sí es seguro: el literal adopta la collation de la columna.

## Después de importar

Comprueba las tres cifras contra desarrollo: filas, entidades padre con filas
asociadas, y archivos en disco. Si el proyecto tiene una clave foránea, busca
además huérfanas: debe dar cero.

Y ten presente que **reimportar duplica** si la tabla no tiene una clave única
sobre la combinación que importa. Para rehacerlo, vacíala antes.

## Cachés derivadas del contenido

Si el proyecto cachea algo generado a partir de los datos —un PDF, una imagen
social, un sitemap— mira cómo se invalida esa caché. Es habitual que la clave
dependa de una versión que solo se mueve al editar desde el panel, no al
sembrar ni al desplegar código. Entonces, cualquier petición hecha **antes** de
cargar el contenido deja cacheada una versión vacía que se sirve
indefinidamente.

Revisa el directorio de caché después del sembrado y borra lo que tenga fecha
anterior.
