# 17 — Auditoría automática del servidor

> El capítulo que hace que las comprobaciones de los capítulos anteriores se ejecuten **solas**.
> No añade ninguna comprobación nueva: pone en un temporizador las que ya existen y deja el
> resultado por escrito.

---

## 1. Objetivo

Al terminar este capítulo, el servidor:

- Produce **cada mañana** un informe de estado, redactado de secretos, en
  `${DATOS_RAIZ}/auditoria/informes/estado.txt`, junto a un resumen de **lo que cambió desde ayer**.
- **Valida solo** cualquier proyecto nuevo que aparezca en `${DATOS_RAIZ}`, ejecutando
  `revisar_proyecto.sh` sin que nadie se acuerde de hacerlo.
- **Avisa por el canal que ya tienes**: el monitor Push de Uptime Kuma del capítulo 14, con tu
  Telegram ya configurado. Ningún bot nuevo, ninguna credencial nueva.

Lo que **no** hace: interpretar el informe. Lo escribe; leerlo sigue siendo cosa tuya.

---

## 2. Requisitos previos

**Capítulos previos:** del 04 al 15. Este capítulo ejecuta `verificar_sistema.sh` y
`revisar_proyecto.sh`, así que necesita que lo que esos verifican exista. El aviso reutiliza el
monitor Push del capítulo 13/14, de modo que conviene tener ese canal probado antes.

**Ningún capítulo depende de este.** El montaje de los capítulos 04 a 16 está completo sin nada de
lo que hay aquí. Si `AUDITORIA_HABILITADA` vale `no`, el script no toca el sistema.

**Necesitas a mano:**

- Acceso a Uptime Kuma para crear un monitor de tipo *Push* (paso 6).
- Diez minutos para **leer el primer informe entero**. No es opcional: ver el paso 7.

**Preparar la sesión:**

```bash
# [servidor]
cd ~/nomad_server
source scripts/lib/entorno.sh
```

---

## 3. Decisiones y por qué

### 3.1 Los veredictos los emite bash, no una interpretación

El recolector **invoca** `verificar_sistema.sh` y `revisar_proyecto.sh` y transcribe su salida
íntegra, con su código de salida. No reimplementa ni resume ninguna comprobación.

Esto no es pereza: es lo que permite que el informe se pueda creer. Si el recolector interpretara,
habría dos fuentes de verdad que se separarían con el tiempo, y el día que discreparan no sabrías
cuál mirar.

### 3.2 Por qué el aviso va por Uptime Kuma y no por un bot propio

| Alternativa descartada | Por qué |
|---|---|
| Un bot de Telegram propio para la auditoría | Otra credencial que guardar, rotar y respaldar, para duplicar un canal que ya funciona y que ya ha disparado de verdad |
| Correo | Exige un servidor de correo o un relé externo. El capítulo 13 ya descartó ese camino |
| No avisar, solo dejar el fichero | Un informe que nadie abre no es una auditoría, es un fichero |

Se reutiliza el mecanismo del capítulo 14: un monitor **Push**. Con una sola URL se obtienen tres
señales:

| Señal | Qué significa |
|---|---|
| Aviso `up` | La auditoría corrió y el verificador no encontró fallos |
| Aviso `down` con recuento | La auditoría corrió y **sí** encontró fallos. Kuma te avisa con el número |
| **Ningún aviso** | La auditoría no llegó a ejecutarse, y el monitor salta solo por ausencia |

La tercera es la que más importa y es la que un aviso de fallo no puede dar: un servidor apagado o
sin red no envía nada, y solo la **ausencia** lo delata. Es el mismo razonamiento del capítulo 14
§ 3.6.

### 3.3 Redacción en origen, y falla cerrada

El informe describe la infraestructura con detalle. Antes de escribirlo, el recolector sustituye
claves, tokens, JWT, cabeceras de autorización, la IP de la tailnet, los UUID de túnel y de disco,
las rutas de repositorio de respaldo y las llaves SSH.

Después **vuelve a buscar** esos mismos patrones sobre el resultado. Si encuentra algo, **no publica
el informe**: publica un aviso, marca el sello como `fuga-detectada` y deja el informe sin publicar
en `/root/nomad-auditoria-fuga.txt` con permisos `600`.

**Sobre-redactar es aceptable; sub-redactar no.** Si un patrón se come de más, el informe pierde
detalle. Si se queda corto, un secreto sale del servidor.

**Lo que el detector NO puede hacer:** cazar lo que ningún patrón sabe nombrar. Es una red contra el
fallo de la redacción, no contra el hueco en la lista. Ese hueco solo lo encuentra un humano
leyendo el informe entero, y por eso el paso 7 lo exige la primera vez y la rutina trimestral del
capítulo 15 lo repite.

### 3.4 Por qué hay un fichero de cambios además del informe

`cambios.txt` contiene el diff con el informe del día anterior, con las líneas volátiles filtradas
—la marca de tiempo del propio verificador, los tiempos de actividad de los contenedores—.

Sin ese filtro, dos ejecuciones seguidas **sin ningún cambio real** producían igualmente un diff.
Un fichero que siempre tiene contenido deja de significar nada, y se acaba ignorando.

### 3.5 El usuario propio, y por qué no puede nada

Los informes pertenecen a un usuario del sistema creado para eso: `nologin`, sin sudo, sin grupo
`docker` y sin grupo `adm`. Nadie inicia sesión como él.

Existe por trazabilidad: un `ls -l` distingue lo que escribiste tú de lo que escribió la máquina.
Y el script **comprueba sus grupos en cada ejecución** y se niega a seguir si alguien lo ha metido
en alguno con privilegios. Pertenecer al grupo `docker` equivale a ser root (capítulo 09 § 3.2).

### 3.6 El vigilante detecta proyectos nuevos, no compose editados

`systemd.path` vigila un directorio **sin recursividad** y no admite comodines. Por tanto
`nomad-conserje.path` detecta que aparece un proyecto nuevo en `${DATOS_RAIZ}`, pero **no** que se
edite el compose de un proyecto que ya existía, que está un nivel más abajo.

El hueco se cubre por dos caminos, y por eso se puede vivir con él:

1. `nomad-auditoria.service` arrastra a `nomad-conserje.service`, así que todos los proyectos se
   revisan otra vez cada día. Ningún cambio pasa más de 24 horas sin revisar.
2. El anexo 96 manda ejecutar `revisar_proyecto.sh` antes de desplegar, y eso no lo sustituye
   ninguna automatización.

Queda escrito aquí para no descubrirlo dentro de un año, cuando un compose editado no dispare nada
y parezca que la vigilancia está rota.

### 3.7 Lo que se decide NO hacer

| Medida | Por qué no |
|---|---|
| Que la auditoría **corrija** lo que encuentra | Un proceso automático que modifica el sistema de madrugada, sin nadie delante, convierte un fallo de diagnóstico en un incidente |
| Ejecutar `lynis` cada día | Tarda minutos y necesita escribir en `/var/log`. Se **lee** su último informe; renovarlo es la rutina trimestral del capítulo 15 |
| Lanzar autotests SMART | Desgastan más de lo que informan. Se lee lo que el disco ya sabe de sí mismo |
| Guardar un histórico de informes | Se conserva **uno** anterior, para poder comparar. El histórico lo guarda restic, que respalda `${DATOS_RAIZ}` entero |
| Un agente de IA que interprete el informe | Está diseñado en `docs/superpowers/specs/2026-08-23-hermes-guardian-design.md` y **deliberadamente no construido**: casi todo el valor que se buscaba lo dan las piezas de bash de este capítulo, sin contenedor, sin clave de API y sin que ningún dato del servidor salga hacia un tercero. Se retomará solo si el informe diario demuestra que hace falta |

---

## 4. Variables usadas

### 4.1 De `config/servidor.env`

| Variable | Para qué | Ejemplo |
|---|---|---|
| `AUDITORIA_HABILITADA` | `si`/`no`. Con `no`, el script no toca nada | `no` |
| `AUDITORIA_USUARIO` | Usuario dueño de los informes | `auditor` |
| `AUDITORIA_UID` | uid y gid fijos de ese usuario | `10000` |
| `AUDITORIA_HORA` | Hora diaria, `HH:MM`. Después de `RESTIC_HORA` | `06:30` |
| `DATOS_RAIZ` | Dónde viven los proyectos y los informes | `/srv` |
| `ADMIN_USUARIO` | Dónde está el repositorio, y quién ejecuta el revisor | `deart` |

### 4.2 La variable que se DESCUBRE aquí

| Variable | De dónde sale |
|---|---|
| `AUDITORIA_PUSH_URL` | La da Uptime Kuma al crear el monitor Push del paso 6 |

```bash
# [servidor]
./scripts/variables.sh --fijar AUDITORIA_PUSH_URL=<la-url-que-da-kuma>
```

Déjala vacía si no quieres avisos. El script lo advierte al instalar.

### 4.3 Variables temporales de esta sesión

Ninguna. Todo sale del archivo.

---

## 5. Procedimiento

### Paso 0 — Prepara la sesión

```bash
# [servidor]
cd ~/nomad_server
source scripts/lib/entorno.sh
```

### Paso 1 — Decide y activa

```bash
# [servidor] — comprueba que el uid está libre ANTES de nada
getent passwd ${AUDITORIA_UID}
```

No debe devolver nada. Si lo devuelve, elige otro por encima de 10000 y fíjalo con
`./scripts/variables.sh --fijar AUDITORIA_UID=<otro>`.

```bash
# [servidor]
./scripts/variables.sh --fijar AUDITORIA_HABILITADA=si
source scripts/lib/entorno.sh      # recarga: variables.sh escribe el archivo, no tu sesión
```

### Paso 2 — Crea el usuario

```bash
# [servidor]
sudo groupadd --system --gid ${AUDITORIA_UID} ${AUDITORIA_USUARIO}
sudo useradd --system --uid ${AUDITORIA_UID} --gid ${AUDITORIA_UID} \
     --home-dir ${DATOS_RAIZ}/auditoria --no-create-home \
     --shell /usr/sbin/nologin \
     --comment "Auditoria del servidor (capitulo 17)" \
     ${AUDITORIA_USUARIO}
```

```bash
# [servidor] — comprobación: no debe pertenecer a ningún grupo con privilegios
id -nG ${AUDITORIA_USUARIO}
```

Salida esperada: solo el nombre del propio grupo.

### Paso 3 — Prepara el directorio

```bash
# [servidor]
sudo install -d -m 0750 -o ${AUDITORIA_USUARIO} -g ${AUDITORIA_USUARIO} ${DATOS_RAIZ}/auditoria
sudo install -d -m 0750 -o ${AUDITORIA_USUARIO} -g ${AUDITORIA_USUARIO} ${DATOS_RAIZ}/auditoria/informes
```

`0750` y no `0755`: el informe redactado sigue describiendo la infraestructura con detalle.

### Paso 4 — Instala el recolector y el conserje

```bash
# [servidor] — mira antes qué va a cambiar
nomad_diff etc/nomad-auditoria.sh /usr/local/sbin/nomad-auditoria.sh
nomad_diff etc/nomad-conserje.sh  /usr/local/sbin/nomad-conserje.sh
```

```bash
# [servidor]
nomad_plantilla etc/nomad-auditoria.sh | sudo tee /usr/local/sbin/nomad-auditoria.sh >/dev/null
nomad_plantilla etc/nomad-conserje.sh  | sudo tee /usr/local/sbin/nomad-conserje.sh  >/dev/null
sudo chmod 0750 /usr/local/sbin/nomad-auditoria.sh /usr/local/sbin/nomad-conserje.sh
```

```bash
# [servidor] — comprobación obligatoria: ninguna variable sin sustituir
sudo grep -nE '\$\{[A-Z][A-Z0-9_]*\}' /usr/local/sbin/nomad-auditoria.sh || echo "CORRECTO"
```

Una variable sin sustituir produce un script que arranca y no hace lo que dice.

### Paso 5 — Instala y activa las unidades

```bash
# [servidor]
for u in nomad-auditoria.service nomad-auditoria.timer nomad-conserje.service nomad-conserje.path; do
    nomad_plantilla "systemd/${u}" | sudo tee "/etc/systemd/system/${u}" >/dev/null
    sudo chmod 644 "/etc/systemd/system/${u}"
done
sudo systemctl daemon-reload
sudo systemctl enable --now nomad-auditoria.timer nomad-conserje.path
```

```bash
# [servidor] — comprobación
systemctl list-timers nomad-auditoria.timer --no-pager
systemctl cat nomad-auditoria.timer | grep OnCalendar
```

La segunda línea debe mostrar tu hora real, no `${AUDITORIA_HORA}`. systemd acepta un `OnCalendar`
mal formado sin rechistar y **se queda sin disparar nunca**.

### Paso 6 — Crea el monitor de avisos

Esto **no lo hace ningún script**: es interfaz web.

1. En Uptime Kuma, *Add New Monitor* → tipo **Push**.
2. Nombre: `Auditoría diaria`.
3. *Heartbeat Interval*: **93600** segundos (26 horas). Da margen a un reinicio sin falsas alarmas.
4. Asigna tu notificación de Telegram, la misma del respaldo.
5. Copia la *Push URL* y fíjala:

```bash
# [servidor]
./scripts/variables.sh --fijar AUDITORIA_PUSH_URL=<la-url>
source scripts/lib/entorno.sh
nomad_plantilla etc/nomad-auditoria.sh | sudo tee /usr/local/sbin/nomad-auditoria.sh >/dev/null
sudo chmod 0750 /usr/local/sbin/nomad-auditoria.sh
```

**Y pruébalo.** Un sistema de avisos sin probar no es un sistema de avisos:

```bash
# [servidor]
curl -fsS "${AUDITORIA_PUSH_URL}?status=down&msg=prueba+de+aviso"
```

Debe llegarte el mensaje a Telegram. Si no llega, arréglalo antes de seguir.

### Paso 7 — Ejecuta la primera auditoría y LÉELA ENTERA

```bash
# [servidor]
sudo systemctl start nomad-auditoria.service
sudo cat ${DATOS_RAIZ}/auditoria/informes/sello.txt
```

Esperado: `resultado=publicado`.

```bash
# [servidor]
sudo less ${DATOS_RAIZ}/auditoria/informes/estado.txt
```

**Este paso no se salta.** Es la única vez que un humano va a leer el informe completo antes de que
empiece a existir a diario. Busca a conciencia lo que la redacción se haya podido dejar: rutas con
nombres de cliente, cabeceras, un token dentro de un mensaje de error de Docker.

Lo que encuentres se convierte en un patrón nuevo en `patrones_fuga`, dentro de
`templates/etc/nomad-auditoria.sh`, y se reinstala con el paso 4.

### Paso 8 — Comprueba el fichero de cambios

```bash
# [servidor] — ejecútala dos veces seguidas
sudo systemctl start nomad-auditoria.service
sudo grep lineas_cambiadas ${DATOS_RAIZ}/auditoria/informes/sello.txt
```

Esperado: `lineas_cambiadas=0`. Dos ejecuciones seguidas sin ningún cambio real **no deben producir
ninguna diferencia**. Si sale distinto de cero, hay ruido que cambia solo y hay que añadirlo a
`sin_volatil()` en la plantilla del recolector: en un fichero que siempre tiene contenido, lo que
importa deja de verse.

### Paso 9 — Comprueba el conserje

```bash
# [servidor]
sudo systemctl start nomad-conserje.service
sudo ls -l ${DATOS_RAIZ}/auditoria/informes/*.auditoria
sudo cat ${DATOS_RAIZ}/auditoria/informes/<un-proyecto>.auditoria
```

Debe haber un fichero por proyecto, cada uno con la salida de `revisar_proyecto.sh` y su código de
salida al final.

---

## 6. Script asociado

### 6.1 Vía A — con el script

```bash
# [servidor]
sudo ./scripts/17_auditoria.sh --check     # qué haría
sudo ./scripts/17_auditoria.sh             # aplicar
sudo ./scripts/17_auditoria.sh --check     # debe decir: Cambios que se aplicarían: 0
```

Con `AUDITORIA_HABILITADA` en `no`, sale sin tocar nada.

### 6.2 Correspondencia entre el script y los pasos manuales

| Paso manual | Lo hace el script |
|---|---|
| 1 — activar | No. Es una decisión tuya |
| 2 — usuario | Sí, y además comprueba los grupos en cada ejecución |
| 3 — directorio | Sí |
| 4 — recolector y conserje | Sí, con copia previa y diff en `--check` |
| 5 — unidades | Sí, y recarga systemd solo si algo cambió |
| 6 — monitor de Kuma | **No.** Es interfaz web. El script avisa si la URL está vacía |
| 7 — leer el informe | **No, y no puede.** Es el paso que ningún script hace por ti |
| 8 y 9 — comprobaciones | No. Están en § 7 |

### 6.3 Si prefieres la vía manual

Los pasos 1 a 5 de § 5 son la equivalencia completa. El script no hace nada que no esté ahí escrito.

---

## 7. Validación

```bash
# [servidor]
./scripts/verificar_sistema.sh --seccion auditoria
```

Salida esperada:

```
==> Auditoría automática
[OK]    nomad-auditoria.timer habilitado.
[OK]    nomad-conserje.path habilitado.
[OK]    Informe de hace 0 h.
[OK]    Último informe publicado correctamente.
[OK]    Ningún proyecto incumple el contrato de dockerización.
```

```bash
# [servidor] — permisos y dueño de los informes
sudo ls -l ${DATOS_RAIZ}/auditoria/informes/
```

Esperado: todo `-rw-r-----` y dueño `${AUDITORIA_USUARIO}`.

```bash
# [servidor] — el usuario no puede iniciar sesión
sudo -u ${AUDITORIA_USUARIO} -s
```

Esperado: `This account is currently not available`.

```bash
# [servidor] — el usuario no pertenece a ningún grupo con privilegios
id -nG ${AUDITORIA_USUARIO}
```

Esperado: solo su propio grupo.

```bash
# [servidor] — el temporizador tiene una hora real
systemctl cat nomad-auditoria.timer | grep OnCalendar
```

**Criterio de aceptación:** las cinco comprobaciones anteriores salen como se indica, y
`sudo ./scripts/17_auditoria.sh --check` informa de `Cambios que se aplicarían: 0`.

---

## 8. Reversión

```bash
# [servidor] — desactivar sin borrar nada
sudo systemctl disable --now nomad-auditoria.timer nomad-conserje.path
```

```bash
# [servidor] — quitarlo del todo
sudo systemctl disable --now nomad-auditoria.timer nomad-conserje.path
sudo rm -f /etc/systemd/system/nomad-auditoria.{service,timer}
sudo rm -f /etc/systemd/system/nomad-conserje.{service,path}
sudo rm -f /usr/local/sbin/nomad-auditoria.sh /usr/local/sbin/nomad-conserje.sh
sudo systemctl daemon-reload
./scripts/variables.sh --fijar AUDITORIA_HABILITADA=no
```

```bash
# [servidor] — y el usuario, si tampoco lo quieres
# COMPROBACIÓN OBLIGATORIA antes de borrar con una variable dentro:
echo "Se borraría el usuario: ${AUDITORIA_USUARIO}"
```

```bash
# [servidor] — solo si la línea anterior mostró el nombre correcto
sudo userdel ${AUDITORIA_USUARIO}
```

Los informes se conservan: son ficheros de texto dentro de `${DATOS_RAIZ}`, y restic ya los tiene.
El servidor vuelve exactamente al estado anterior; **ningún otro capítulo depende de este**.

---

## 9. Errores frecuentes

| Síntoma | Causa | Solución |
|---|---|---|
| El informe dice `NO DISPONIBLE: no se encuentra .../verificar_sistema.sh` | El repositorio no está en `/home/${ADMIN_USUARIO}/nomad_server`, o la unidad tiene `ProtectHome` | Comprueba la ruta. La unidad **no** debe llevar `ProtectHome`: el recolector invoca los scripts del repositorio |
| `sello.txt` dice `resultado=fuga-detectada` | Un secreto sobrevivió a la redacción | `sudo less /root/nomad-auditoria-fuga.txt`, localiza el patrón que falta, añádelo a `patrones_fuga` y reinstala (§ 5 paso 4) |
| El temporizador está habilitado y no dispara nunca | Una variable sin sustituir en `OnCalendar` | `systemctl cat nomad-auditoria.timer \| grep OnCalendar`. Si ves `${AUDITORIA_HORA}`, reinstala la unidad |
| `cambios.txt` sale enorme todos los días | Ruido que cambia en cada ejecución | Añade el patrón a `sin_volatil()` en la plantilla del recolector y reinstala |
| No llega ningún aviso, ni bueno ni malo | `AUDITORIA_PUSH_URL` vacía, o el monitor no existe | `./scripts/variables.sh --estado \| grep PUSH`, y § 5 paso 6 |
| Kuma avisa de que la auditoría cayó, pero el servidor está bien | El *Heartbeat Interval* del monitor es menor que 24 h | Súbelo a 93600 s (26 h): la auditoría solo avisa una vez al día |
| Un proyecto nuevo no dispara el conserje | `systemd.path` no es recursivo | Es una limitación conocida, explicada en § 3.6. La revisión diaria lo cubre en menos de 24 h |
| `El uid 10000 ya está ocupado` | Otro usuario tiene ese uid | Elige otro por encima de 10000 con `variables.sh --fijar AUDITORIA_UID=<otro>` |
| El script se niega: `pertenece al grupo 'docker'` | Alguien metió al usuario en un grupo con privilegios | `sudo gpasswd -d ${AUDITORIA_USUARIO} docker`. Pertenecer a `docker` equivale a ser root |

---

## 10. Referencias

- [`systemd.timer(5)`](https://www.freedesktop.org/software/systemd/man/systemd.timer.html) — sintaxis de `OnCalendar` y `Persistent`
- [`systemd.path(5)`](https://www.freedesktop.org/software/systemd/man/systemd.path.html) — `PathChanged` y por qué no es recursivo
- [`systemd.exec(5)`](https://www.freedesktop.org/software/systemd/man/systemd.exec.html) — `ProtectSystem`, `ReadWritePaths`, `ProtectHome`
- [Uptime Kuma — monitor Push](https://github.com/louislam/uptime-kuma/wiki) — el mecanismo de aviso por ausencia
- [`sed(1)`](https://www.gnu.org/software/sed/manual/sed.html) — expresiones de la redacción
- [96 — Contrato de dockerización](96_contrato_de_dockerizacion.md) — lo que valida el conserje
- [14 — Respaldos con restic](14_respaldos_restic.md) — de donde sale el patrón del aviso por ausencia
