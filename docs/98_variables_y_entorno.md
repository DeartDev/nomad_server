# 98 — Variables, entorno y sesiones de trabajo

> Anexo transversal. Explica de dónde sale cada valor que aparece entre `${llaves}` en el resto de
> capítulos, cómo hacer que exista en tu terminal, y qué hay que rehacer cada vez que reinicias el
> servidor o retomas el montaje días después.

---

## 1. El problema que resuelve este anexo

Toda la documentación de este repositorio escribe los valores concretos como `${VARIABLE}`:

```bash
sudo hostnamectl set-hostname ${SERVIDOR_HOSTNAME}
```

Eso es deliberado: si tu red es `10.0.0.0/24` en lugar de `192.168.1.0/24`, cambias una línea en
`config/servidor.env` y toda la documentación sigue siendo correcta, sin buscar y reemplazar nada.

La trampa es que **hay dos formas de recorrer el montaje, y solo una de ellas conoce ese archivo**:

| | ¿Quién lee `config/servidor.env`? | ¿Funciona un comando con `${VARIABLE}`? |
|---|---|---|
| **Vía A** — ejecutas `scripts/06_firewall.sh` | El propio script, al arrancar | Sí, siempre |
| **Vía B** — copias y pegas los comandos del capítulo | **Nadie**, salvo que lo cargues tú | **No**, hasta que cargues el entorno |

Si estás en la vía B y no has cargado nada, el comando anterior se convierte en:

```bash
sudo hostnamectl set-hostname
```

…que falla, o —lo que es peor en otros casos— hace algo distinto de lo previsto sin dar ningún
error. Por ejemplo, `sudo mkdir -p ${DATOS_RAIZ}/traefik` con `DATOS_RAIZ` vacía crea el directorio
`/traefik` en la raíz del sistema, y no dice nada.

Y hay una segunda trampa, más silenciosa todavía: **las variables de entorno mueren con la terminal
que las creó**. Este montaje no está pensado para hacerse de una sentada —son entre 9 y 12 horas de
trabajo repartidas, con reinicios de por medio—, así que vas a perder ese entorno muchas veces:

- al reiniciar el servidor para validar un capítulo,
- al reconectar por SSH tras cerrar el portátil,
- al abrir una segunda terminal (que este repositorio pide constantemente como red de seguridad),
- al abrir una ventana nueva de `tmux`,
- al entrar por consola física en una situación de rescate.

Después de cualquiera de esas cosas, tu shell vuelve a estar en blanco. Este anexo explica cómo
volver al punto donde estabas en menos de un minuto.

---

## 2. Las tres clases de valor

No todas las variables se comportan igual, y confundirlas es el origen de la mayoría de los
tropiezos.

| Clase | Dónde vive | Cuándo se conoce | Sobrevive a un reinicio |
|---|---|---|---|
| **1. Decidida** | `config/servidor.env` | En la planificación, capítulo 00 | Sí, está en un archivo |
| **2. Descubierta** | `config/servidor.env`, **si la escribes** | A mitad del montaje | Solo si la escribes |
| **3. Temporal de sesión** | Solo en tu shell | En el paso donde se usa | **No, nunca** |

### 2.1 Valores decididos (clase 1)

Los eliges tú antes de empezar: nombre del servidor, rango de red, usuario administrador, dominio,
zona horaria, política de retención de respaldos. Se rellenan de una vez en el capítulo
[00](00_planificacion.md) y no vuelven a cambiar.

### 2.2 Valores descubiertos (clase 2)

No se pueden saber de antemano porque los genera el propio montaje o dependen del hardware real.
**Cada uno de ellos es un punto donde el montaje se rompe si no lo persistes**, porque el capítulo
siguiente lo da por sabido.

| Variable | Se conoce en | Comando que lo averigua | Lo necesita |
|---|---|---|---|
| `DISCO_DESTINO` | Capítulo [02](02_validacion_equipo.md) | `ls -l /dev/disk/by-id/ \| grep -v part` | Capítulo 03 |
| `LAN_INTERFAZ` | Capítulo [06](06_red_y_firewall.md) | `ip -br link` | Capítulos 06, 15 |
| `TS_IP` | Capítulo [08](08_tailscale.md) | `tailscale ip -4` | Capítulos 10, 13 |
| `CF_TUNEL_ID` | Capítulo [11](11_cloudflared_y_dominio.md) | Lo imprime `cloudflared tunnel create` | Capítulos 11, 12, 16 |
| `RESTIC_USB_UUID` | Capítulo [14](14_respaldos_restic.md) | `sudo blkid /dev/sdX1` | Capítulos 14, 16 |
| `RESTIC_PUSH_URL` | Capítulo [14](14_respaldos_restic.md) | La da Uptime Kuma al crear el monitor | Capítulo 14 |
| `TRAEFIK_BIND_INTERNA` | Capítulo [08](08_tailscale.md) | `tailscale ip -4`, si eliges esa opción | Capítulos 10, 13 |

En cualquier momento puedes preguntar cuáles te faltan:

```bash
# [servidor o cliente] — desde la raíz del repositorio
./scripts/variables.sh --faltan
```

Salida de ejemplo:

```
==> Variables pendientes

  CF_TUNEL_ID
    capítulo : 11
    se obtiene con: lo imprime 'cloudflared tunnel create' (capítulo 11 paso 3)
    se fija con   : scripts/variables.sh --fijar CF_TUNEL_ID=<valor>
```

Y escribirlas sin abrir un editor:

```bash
# [servidor]
./scripts/variables.sh --fijar CF_TUNEL_ID=8a1b2c3d-4e5f-6789-abcd-ef0123456789
```

El comando conserva el orden y los comentarios del archivo, deja una copia previa en
`config/servidor.env.bak-<fecha>` y vuelve a poner los permisos en `600`.

### 2.2.bis Las etiquetas de la plantilla

`config/servidor.env.example` marca cada variable, y esas marcas son las que usan
`scripts/variables.sh` y `scripts/lib/entorno.sh` para decidir de qué quejarse:

| Etiqueta | Significa | Vacía es… |
|---|---|---|
| `[OBLIGATORIA]` | Hay que decidirla: no trae un valor por omisión que sirva | **un error** |
| `[REQUERIDA]` | Algún script la exige, pero la plantilla trae un valor que funciona | **un error**: la vaciaste tú |
| `[SE-DESCUBRE: cmd]` | Se averigua durante el montaje, con ese comando | correcto hasta ese capítulo |
| sin etiqueta | Opcional de verdad | correcto siempre |

La distinción entre las dos primeras importa en la práctica: `[OBLIGATORIA]` son seis y responden a
«¿qué tengo que decidir?»; `[REQUERIDA]` son la mayoría y responden a «¿qué no puedo dejar en
blanco?». El fallo típico es borrar el valor de ejemplo de una `[REQUERIDA]` para rellenarla más
tarde, y no volver: el capítulo que la necesite abortará.

`make check` comprueba que **toda** variable exigida por algún script lleve una de las tres
etiquetas. Sin esa comprobación la plantilla podría prometer un aviso que nunca llega, que es lo que
ocurría con `SERVIDOR_LOCALE`, `DEBIAN_MIRROR` y `DEBIAN_SUITE`.

### 2.3 Valores temporales de sesión (clase 3)

Existen durante unos minutos y **no van en `config/servidor.env`** porque no describen el servidor,
sino lo que estás haciendo ahora mismo:

| Variable | Aparece en | Qué es |
|---|---|---|
| `ISO` | Capítulo [01](01_unidad_usb_booteable.md) | Nombre del archivo de imagen descargado |
| `USB` | Capítulo [01](01_unidad_usb_booteable.md) | Dispositivo de la memoria USB (`/dev/sdb`) |
| `BYTES` | Capítulo [01](01_unidad_usb_booteable.md) | Tamaño de la ISO, para verificar lo escrito |
| `DISCO` | Capítulo [14](14_respaldos_restic.md) | Dispositivo del disco USB de respaldo |
| `PROYECTO` | Capítulo [12](12_despliegue_de_proyectos.md) | Proyecto que estás desplegando |

La documentación **siempre las declara explícitamente** en el paso donde hacen falta, con una línea
de asignación visible, precisamente para que se distingan de las anteriores:

```bash
# [servidor]
PROYECTO=mi-proyecto
```

Si te desconectas a mitad de un capítulo, estas son las que hay que volver a declarar. Ninguna de
ellas es peligrosa de perder: el peligro es **creer que siguen definidas**. Un
`sudo rm -rf ${DATOS_RAIZ}/${PROYECTO}` con `PROYECTO` vacía borra el directorio de proyectos
entero.

> **Norma de este repositorio:** antes de usar una variable temporal en un comando destructivo,
> compruébala. `echo "${PROYECTO}"` cuesta un segundo.

---

## 3. Cargar el entorno en tu sesión

### 3.1 La forma recomendada

```bash
# [servidor]
cd ~/nomad_server
source scripts/lib/entorno.sh
```

Salida esperada:

```
[OK]    Entorno cargado desde /home/deart/nomad_server/config/servidor.env
        servidor   : nomad.lan
        usuario    : deart
        LAN        : 192.168.1.50/24 en 192.168.1.0/24
        dominio    : ejemplo.com
        proyectos  : /srv
[INFO]  Ayudantes disponibles: nomad_plantilla, nomad_diff, nomad_fijar, nomad_estado
```

Ese resumen no es decorativo: es la comprobación de que estás trabajando con la configuración del
servidor correcto y no con la de otra máquina.

Qué hace exactamente:

1. Localiza `config/servidor.env` a partir de su propia ruta, así que da igual desde qué directorio
   lo invoques.
2. Avisa si los permisos no son `600`.
3. Carga y **exporta** todas las variables (`set -a`). Exportar importa: sin `export`, una variable
   existe en tu shell pero **no la heredan los programas que lanzas**, como `envsubst` o
   `docker compose`, y el fallo es silencioso.
4. Comprueba que las variables `[OBLIGATORIA]` tienen valor, y avisa de las que siguen con el valor
   de ejemplo.
5. Define cuatro ayudantes: `nomad_plantilla`, `nomad_diff`, `nomad_fijar` y `nomad_estado`.

> **`source`, no `./`.** Ejecutar `./scripts/lib/entorno.sh` no serviría de nada: crearía un proceso
> hijo, cargaría las variables ahí y las perdería al terminar. Tiene que ser `source` (o su
> abreviatura `.`) para que las variables se queden en **tu** shell. El archivo se niega
> explícitamente a ejecutarse de la otra forma, para que no pase inadvertido.

### 3.2 La forma cruda, sin el repositorio

Útil en una recuperación, cuando el repositorio aún no está clonado pero sí tienes el archivo de
configuración:

```bash
# [servidor]
set -a
. ~/nomad_server/config/servidor.env
set +a
```

Es exactamente lo que hace el ayudante por dentro, sin comprobaciones ni resumen. Recuerda el
`set +a` al final: si se te olvida, **toda** variable que definas después en esa terminal quedará
exportada, lo que puede tener efectos raros al lanzar contenedores.

### 3.3 Qué NO hace cargar el entorno

Esto es tan importante como lo que sí hace:

- **No es permanente.** Solo afecta a la terminal donde lo ejecutaste, hasta que la cierres.
- **No se propaga a otras terminales.** Si abres una segunda sesión SSH —cosa que los capítulos 05 y
  06 piden explícitamente— hay que cargarlo también allí.
- **No sobrevive a `sudo`** en todos los casos. Ver la sección 4.2, que es donde más gente tropieza.
- **No modifica el sistema.** Cargar el entorno es una operación de solo lectura: se puede repetir
  todas las veces que quieras, y ante la duda, repítelo.
- **No convierte tu entorno en la verdad.** Lo que valida es el contenido del archivo, no el
  resultado de mezclarlo con lo que ya tuvieras. Ver § 3.4, que es la razón de que exista
  `scripts/lib/leer_config.sh`.

### 3.4 El archivo manda, tu sesión no

Esta es la trampa más difícil de diagnosticar de todo el montaje, y merece un apartado propio porque
**no produce ningún error hasta mucho después**.

Durante un montaje manual es natural exportar variables a mano para que los comandos de la
documentación funcionen:

```bash
# [servidor]
export ADMIN_USUARIO=compass
```

A partir de ese momento tus comandos funcionan. Pero si esa variable **no está escrita en
`config/servidor.env`**, ocurre lo siguiente:

| Quién | Qué ve | Por qué |
|---|---|---|
| Tus comandos manuales | `compass` | Está en tu entorno |
| `source scripts/lib/entorno.sh` | `compass` | Carga el archivo **encima** de tu entorno; lo que el archivo no define, sobrevive |
| `sudo ./scripts/04_base.sh` | **nada** | `sudo` limpia el entorno (`env_reset`) y solo lee el archivo |
| Una terminal nueva mañana | **nada** | El `export` murió con la sesión |

El síntoma es desconcertante: una herramienta dice que la configuración está completa y otra dice
que faltan variables, **y tiene razón la segunda**.

Por eso `scripts/variables.sh` y `scripts/lib/entorno.sh` leen el archivo **en un entorno vacío**
(`scripts/lib/leer_config.sh`), de modo que informan de lo mismo que verá un script con `sudo`. Ese
caso concreto se señala como **`ENMASCARADA`**:

```bash
# [servidor]
./scripts/variables.sh --estado
```

```
  ADMIN_USUARIO                  (sin valor)                  ENMASCARADA

[ERROR] Variables ENMASCARADAS: 1
[ERROR] Tienen valor en tu sesión pero NO en el archivo.
```

Y `--faltan` te da el comando ya resuelto con el valor que tienes en la sesión:

```bash
# [servidor]
./scripts/variables.sh --faltan
```

```
  ADMIN_USUARIO  ← tiene valor en tu sesión, pero NO en el archivo
    valor en tu sesión: compass
    se fija con   : scripts/variables.sh --fijar ADMIN_USUARIO="compass"
```

**Comprobación directa**, por si quieres verlo con tus propios ojos. Así lee el archivo un script
ejecutado con `sudo`:

```bash
# [servidor]
env -i HOME="${HOME}" bash -c 'set -a; . config/servidor.env; set +a
echo "ADMIN_USUARIO=[${ADMIN_USUARIO}]"'
```

Si eso imprime `[]` y `echo "${ADMIN_USUARIO}"` en tu shell imprime un nombre, tienes una variable
enmascarada.

> **Y revisa tu `~/.bashrc`.** Un `export` puesto ahí durante el montaje manual enmascara la
> variable en **todas** las sesiones futuras, con lo que el problema deja de ser transitorio:
>
> ```bash
> grep -nE 'export\s+(ADMIN_|SERVIDOR_|LAN_|DOMINIO_|DATOS_|TS_|CF_|RESTIC_|DOCKER_)' \
>     ~/.bashrc ~/.profile 2>/dev/null || echo "(ninguna)"
> ```
>
> Si aparece alguna, escríbela en `config/servidor.env` con `--fijar` y quítala del perfil.

### 3.5 Atajo permanente (opcional pero recomendable)

Si vas a repetirlo muchas veces, añade una función a tu `~/.bashrc` del servidor:

```bash
# [servidor]
cat >> ~/.bashrc <<'PERFIL'

# --- nomad_server ---------------------------------------------------------
# Carga las variables del despliegue en la sesión actual.
# Se invoca a mano con 'nomad'; NO se carga sola al abrir la terminal, para
# que quede constancia de cuándo se ha cargado y con qué valores.
nomad() {
    source "$HOME/nomad_server/scripts/lib/entorno.sh"
}
PERFIL
source ~/.bashrc
```

A partir de ahí, en cada sesión nueva basta con:

```bash
# [servidor]
nomad
```

> **Por qué no cargarlo automáticamente en cada login.** Sería cómodo, pero esconde el paso: el día
> que el archivo tenga un error de sintaxis, o que estés en un servidor distinto, no habría ninguna
> señal. Que la carga sea explícita y muestre un resumen es parte de la comprobación.

### 3.6 Comprobar que está cargado

Antes de pegar cualquier comando destructivo:

```bash
# [servidor]
echo "hostname=${SERVIDOR_HOSTNAME}  lan=${LAN_CIDR}  datos=${DATOS_RAIZ}"
```

Criterio de aceptación: los tres tienen valor. Si alguno sale vacío, no está cargado.

Y una comprobación más completa:

```bash
# [servidor]
./scripts/variables.sh --estado
```

---

## 4. Reglas de expansión que hay que conocer

Estas cuatro reglas explican prácticamente todos los casos de «he pegado el comando tal cual y no ha
hecho lo que decía».

### 4.1 Quién expande: comillas simples frente a comillas dobles

| Escritura | Quién sustituye `${VARIABLE}` | Cuándo usarla |
|---|---|---|
| `"texto ${VAR}"` | Tu shell, antes de ejecutar | Lo normal |
| `'texto ${VAR}'` | **Nadie**: llega literal | Cuando el `$` es para otro programa |
| `<<EOF` (heredoc sin comillas) | Tu shell | Escribir archivos con tus valores |
| `<<'EOF'` (heredoc con comillas) | **Nadie** | Escribir archivos que llevan `$` propios |

Ejemplo concreto del capítulo 05. Estas dos órdenes producen archivos **distintos**:

```bash
# [servidor] — el shell sustituye: el archivo queda con 'AllowUsers deart'
sudo tee /etc/ssh/sshd_config.d/50-nomad.conf >/dev/null <<EOF
AllowUsers ${ADMIN_USUARIO}
EOF
```

```bash
# [servidor] — el shell NO sustituye: el archivo queda con '${ADMIN_USUARIO}' literal
sudo tee /etc/ssh/sshd_config.d/50-nomad.conf >/dev/null <<'EOF'
AllowUsers ${ADMIN_USUARIO}
EOF
```

La segunda deja un archivo que OpenSSH rechazará. Cuando en un capítulo veas `<<EOF` sin comillas,
es a propósito: ese bloque **necesita** tus valores.

### 4.2 `sudo` y el entorno: la trampa más común

`sudo` viene configurado en Debian con `env_reset`: **limpia el entorno** antes de ejecutar el
comando. Eso no siempre importa, porque en muchos casos la expansión ya ocurrió antes. Conviene
saber distinguir los casos:

| Orden | ¿Funciona? | Por qué |
|---|---|---|
| `sudo hostnamectl set-hostname ${SERVIDOR_HOSTNAME}` | **Sí** | Tu shell expande antes de llamar a `sudo`; `sudo` recibe el valor ya sustituido |
| `echo "${LAN_IP}" \| sudo tee /etc/x` | **Sí** | Ídem: la expansión ocurre en tu lado de la tubería |
| `sudo tee /etc/x <<EOF … ${LAN_IP} … EOF` | **Sí** | El heredoc lo procesa tu shell |
| `sudo sh -c 'echo ${LAN_IP} > /etc/x'` | **No** | Las comillas simples impiden la expansión, y `sudo` ya limpió el entorno del shell interno |
| `sudo bash -c "echo ${LAN_IP} > /etc/x"` | Sí | Las comillas dobles hacen que expanda tu shell antes |
| `sudo vim /etc/x` y escribir `${LAN_IP}` | **No** | Un editor no expande nada: escribe el texto literal |
| `sudo ./scripts/06_firewall.sh` | **Sí** | El script carga `config/servidor.env` por su cuenta |

Cuando de verdad necesites que el proceso con privilegios vea tus variables:

```bash
# [servidor] — conservar el entorno completo
sudo -E bash -c 'echo "${LAN_IP}"'

# [servidor] — pasar solo lo necesario, que es más limpio
sudo LAN_IP="${LAN_IP}" bash -c 'echo "${LAN_IP}"'
```

> **Consecuencia práctica:** cuando un capítulo te diga «edita este archivo con `vim` y déjalo con
> este contenido», el bloque que sigue está escrito con valores de ejemplo. Si prefieres no
> teclearlo, cada capítulo ofrece al lado la variante con `tee` y heredoc, que escribe el archivo
> con **tus** valores en un solo comando.

### 4.3 `envsubst` y las plantillas

Los archivos de `templates/` llevan `${VARIABLES}` sin sustituir. Para aplicarlos a mano:

```bash
# [servidor] — ver el resultado antes de instalar nada
nomad_plantilla etc/nftables.conf
```

```bash
# [servidor] — comparar con lo que hay instalado
nomad_diff etc/nftables.conf /etc/nftables.conf
```

```bash
# [servidor] — instalarlo
nomad_plantilla etc/nftables.conf | sudo tee /etc/nftables.conf >/dev/null
```

Si prefieres no depender del ayudante, el comando completo es:

```bash
# [servidor]
envsubst "$(grep -oE '^[A-Z][A-Z0-9_]*=' config/servidor.env.example \
            | tr -d '=' | sed 's/^/${/; s/$/}/' | tr '\n' ' ')" \
    < templates/etc/nftables.conf
```

Ese rodeo tiene un motivo: **`envsubst` sin lista de variables sustituye todo lo que parezca una
variable**, y destrozaría los archivos. Pasarle la lista explícita, derivada de la plantilla de
configuración, hace que solo toque lo nuestro.

### 4.4 Los `$` que NO hay que expandir

En varios archivos aparecen símbolos `$` que pertenecen a otro programa. Si los expandes, rompes el
archivo:

| Aparece en | Ejemplo | De quién es |
|---|---|---|
| `templates/etc/nftables.conf` | `$lan_cidr`, `$ssh_port` | Variables internas de nftables (`define`) |
| `templates/etc/unattended-upgrades.conf` | `${distro_codename}` | Variable de APT; se deja literal para que siga valiendo al subir de versión |
| `templates/preseed.cfg` | `$primary{ }`, `$lvmok{ }` | Sintaxis del particionador de Debian |
| Ficheros compose | `$${POSTGRES_USER}` | El doble `$` escapa la variable para que la resuelva el contenedor, no Compose |

**La regla exacta:** `envsubst` sustituye únicamente los nombres que aparecen en
`config/servidor.env.example`, porque es esa lista la que se le pasa. Todo lo demás llega intacto.

La convención de nombres —**variables del despliegue en MAYÚSCULAS, variables internas de un script
en minúscula**— es lo que hace esa lista fácil de razonar, pero no es el mecanismo. De hecho
`templates/etc/nomad-respaldo.sh` contiene variables en mayúscula que **sí** deben sobrevivir
(`${RESTIC_REPOSITORY}`, `${VERSION_CODENAME}`): sobreviven porque no están en la plantilla de
configuración, no por cómo se llaman.

Consecuencia práctica: antes de añadir una variable nueva a `config/servidor.env.example`,
comprueba que ese nombre no lo usa internamente ninguna plantilla.

---

## 5. Trabajar por tandas: parar y retomar

El montaje completo son entre 9 y 12 horas. Hacerlo de una sentada es mala idea: los capítulos 03,
07, 09 y 14 terminan con un reinicio, y la fatiga es responsable de más errores que la complejidad.

### 5.1 Qué sobrevive a un reinicio y qué no

| Sobrevive | No sobrevive |
|---|---|
| Todo lo escrito en `/etc`, `/srv`, `/usr/local/bin` | Las variables cargadas en tu shell |
| `config/servidor.env` y sus valores | Las variables temporales (`PROYECTO`, `USB`, `DISCO`…) |
| Servicios habilitados con `systemctl enable` | Las sesiones de `tmux` |
| Contenedores con `restart: unless-stopped` | Los trabajos en segundo plano (`&`) |
| Reglas de nftables cargadas por su servicio | La red de seguridad `sleep 300 && nft flush ruleset` |
| El nodo de Tailscale registrado | Los túneles SSH (`ssh -L`) abiertos |

> **La red de seguridad del capítulo 06 no sobrevive a un reinicio**, y eso es lo correcto: si el
> cortafuegos te dejó fuera, reiniciar lo vuelve a cargar con las mismas reglas. La vía de rescate
> tras un reinicio es la consola física, no esperar cinco minutos.

### 5.2 Antes de parar

Cinco minutos aquí ahorran media hora al volver:

```bash
# [servidor] — 1. persistir lo descubierto en esta tanda
./scripts/variables.sh --faltan
```

- [ ] Toda variable que hayas averiguado está escrita en `config/servidor.env`.

```bash
# [servidor] — 2. comprobar que lo hecho hasta ahora está aplicado y es estable
./scripts/verificar_sistema.sh --rapido
```

- [ ] Sin fallos, o con fallos que corresponden a capítulos que aún no has hecho.

```bash
# [servidor] — 3. dejar constancia de dónde te quedaste
mkdir -p ~/nomad_server/inventario
printf '%s  capítulo %s — %s\n' "$(date +%F\ %H:%M)" "07" "hecho hasta el paso 5" \
    >> ~/nomad_server/inventario/progreso.txt
tail -5 ~/nomad_server/inventario/progreso.txt
```

- [ ] Anotado el capítulo y el paso exactos.

```bash
# [cliente] — 4. sincronizar el archivo de configuración con tu equipo
scp ${ADMIN_USUARIO}@${LAN_IP}:~/nomad_server/config/servidor.env ./config/servidor.env
```

- [ ] Tienes una copia fuera del servidor. Hasta el capítulo 14 no hay respaldos automáticos, así
      que esta copia manual es tu única red.

```bash
# [servidor] — 5. cerrar limpiamente
sudo reboot
```

`inventario/` está en `.gitignore`, así que ese registro de avance no se versiona: es tuyo y puede
contener detalles del hardware.

### 5.3 Al retomar

Siempre el mismo ritual, en este orden:

```bash
# [cliente] — 1. entrar
ssh ${ADMIN_USUARIO}@${LAN_IP}
# o, a partir del capítulo 05:  ssh nomad
# o, a partir del capítulo 08:  ssh ${ADMIN_USUARIO}@${TS_HOSTNAME}
```

```bash
# [servidor] — 2. sesión persistente, para que una desconexión no corte nada a medias
tmux new -s montaje       # o 'tmux attach -t montaje' si ya existía
```

```bash
# [servidor] — 3. cargar el entorno (esto es lo que se olvida)
cd ~/nomad_server
source scripts/lib/entorno.sh
```

```bash
# [servidor] — 4. ¿dónde me quedé?
tail -5 inventario/progreso.txt
./scripts/variables.sh --faltan
```

```bash
# [servidor] — 5. ¿sigue todo como lo dejé?
./scripts/verificar_sistema.sh --rapido
```

```bash
# [servidor] — 6. si el repositorio ha cambiado en tu equipo, tráelo
git pull        # o repite el rsync del capítulo 04 paso 2
```

> Fíjate en que el paso 3 va **antes** que cualquier comando del capítulo. Es la única forma de que
> los ejemplos con `${VARIABLE}` funcionen al pegarlos.

La lista imprimible de este ritual está en [checklists/reanudar_sesion.md](../checklists/reanudar_sesion.md).

### 5.4 Buenos puntos para parar

No todos los momentos son igual de buenos. Estos dejan el sistema en un estado coherente y
verificado:

| Tras terminar | Estado en el que queda |
|---|---|
| Capítulo [03](03_instalacion_debian.md) | Debian instalado y accesible por SSH con contraseña |
| Capítulo [05](05_usuarios_y_acceso_ssh.md) | Acceso por llave, comprobado desde dos terminales |
| Capítulo [07](07_endurecimiento_del_sistema.md) | Sistema base cerrado y parcheándose solo |
| Capítulo [09](09_docker.md) | Docker en marcha, sin nada publicado |
| Capítulo [11](11_cloudflared_y_dominio.md) | Un subdominio de prueba respondiendo desde internet |
| Capítulo [14](14_respaldos_restic.md) | Respaldos automáticos y restauración probada |

**Malos momentos para parar**, porque dejan el sistema a medias:

- Entre los pasos 5 y 8 del capítulo [06](06_red_y_firewall.md): el cortafuegos aplicado pero la IP
  todavía sin cambiar, o al revés.
- A mitad del capítulo [05](05_usuarios_y_acceso_ssh.md), con la contraseña ya desactivada pero sin
  haber comprobado la llave desde otra terminal.
- Con el disco de respaldo formateado pero sin el repositorio restic inicializado (capítulo 14).

Si tienes que parar en uno de esos puntos, deja escrito exactamente qué falta antes de levantarte.

---

## 6. Persistir un valor descubierto

Cada vez que un capítulo te dé un valor nuevo, el paso siguiente es siempre el mismo. Hay tres
formas, de más a menos cómoda.

**Con el ayudante, si ya tienes el entorno cargado** (lo escribe y lo recarga en la sesión):

```bash
# [servidor]
nomad_fijar TS_IP "$(tailscale ip -4)"
```

**Con el script, desde cualquier sitio:**

```bash
# [servidor]
./scripts/variables.sh --fijar TS_IP="$(tailscale ip -4)"
source scripts/lib/entorno.sh        # recargar para usarlo ya
```

**A mano**, si prefieres ver el archivo:

```bash
# [servidor]
${EDITOR:-vim} ~/nomad_server/config/servidor.env
# busca la línea TS_IP="" y rellénala
chmod 600 ~/nomad_server/config/servidor.env
source scripts/lib/entorno.sh
```

> **Recarga siempre después de escribir.** Editar el archivo no cambia las variables ya cargadas en
> tu terminal: siguen teniendo el valor antiguo hasta que vuelvas a hacer `source`. Es una fuente de
> confusión clásica —«lo he cambiado y sigue igual»— y se resuelve con un comando.

### Los seis valores que hay que recordar persistir

```bash
# [equipo]    capítulo 02 — disco donde se instalará Debian
./scripts/variables.sh --fijar DISCO_DESTINO=/dev/disk/by-id/ata-Marca_Modelo_Serie

# [servidor]  capítulo 06 — interfaz de red real
./scripts/variables.sh --fijar LAN_INTERFAZ="$(ip -o -4 route show to default | awk '{print $5}')"

# [servidor]  capítulo 08 — IP dentro de la tailnet
./scripts/variables.sh --fijar TS_IP="$(tailscale ip -4)"

# [servidor]  capítulo 08/10 — publicar el panel en la tailnet (opcional)
./scripts/variables.sh --fijar TRAEFIK_BIND_INTERNA="$(tailscale ip -4)"

# [servidor]  capítulo 11 — UUID del túnel
./scripts/variables.sh --fijar CF_TUNEL_ID=8a1b2c3d-4e5f-6789-abcd-ef0123456789

# [servidor]  capítulo 14 — UUID del disco de respaldo y aviso del monitor
./scripts/variables.sh --fijar RESTIC_USB_UUID=a1b2c3d4-e5f6-7890-abcd-ef1234567890
./scripts/variables.sh --fijar RESTIC_PUSH_URL=http://localhost:8080/api/push/XXXXXX
```

---

## 7. Un mismo paso por las dos vías

Para que la equivalencia quede clara, aquí está el mismo trabajo —instalar el cortafuegos del
capítulo 06— resuelto de las dos formas.

### Vía A — con el script

```bash
# [servidor]
cd ~/nomad_server
sudo ./scripts/06_firewall.sh --check     # enseña las diferencias, no toca nada
sudo ./scripts/06_firewall.sh
```

No hace falta cargar el entorno: el script lo hace internamente. Tampoco hace falta acordarse de la
copia de seguridad ni de validar la sintaxis: ambas cosas están dentro.

### Vía B — a mano

```bash
# [servidor] — 0. preparar la sesión
cd ~/nomad_server
source scripts/lib/entorno.sh
```

```bash
# [servidor] — 1. ver qué se va a escribir, antes de escribir nada
nomad_diff etc/nftables.conf /etc/nftables.conf
```

```bash
# [servidor] — 2. copia de seguridad, que el script haría por ti
sudo cp -a /etc/nftables.conf /etc/nftables.conf.bak-$(date +%Y%m%d-%H%M%S)
```

```bash
# [servidor] — 3. escribir el archivo con TUS valores ya sustituidos
nomad_plantilla etc/nftables.conf | sudo tee /etc/nftables.conf >/dev/null
sudo chmod 640 /etc/nftables.conf
```

```bash
# [servidor] — 4. validar la sintaxis SIN aplicar
sudo nft -c -f /etc/nftables.conf && echo "SINTAXIS CORRECTA"
```

```bash
# [servidor] — 5. aplicar
sudo systemctl enable --now nftables
```

El resultado es idéntico byte a byte. La vía B enseña qué está pasando; la vía A no se olvida de
nada. Lo habitual es usar la B la primera vez y la A al reconstruir.

---

## 8. Errores frecuentes

| Síntoma | Causa | Solución |
|---|---|---|
| Un comando falla diciendo que le falta un argumento | El entorno no está cargado y `${VARIABLE}` se expandió a nada | `source scripts/lib/entorno.sh` y repite |
| Se ha creado un directorio raro en `/` | Una variable vacía dentro de una ruta: `${DATOS_RAIZ}/x` → `/x` | Borra el directorio, carga el entorno y repite |
| El archivo escrito contiene `${ADMIN_USUARIO}` literal | Se usó un heredoc con comillas: `<<'EOF'` | Reescríbelo con `<<EOF`, sin comillas (§ 4.1) |
| «Lo he cambiado en `servidor.env` y sigue igual» | La sesión conserva el valor cargado antes del cambio | Vuelve a hacer `source scripts/lib/entorno.sh` |
| `sudo sh -c '…${VAR}…'` no sustituye nada | `sudo` limpia el entorno y las comillas simples impiden la expansión previa | Usa comillas dobles, `sudo -E`, o pasa la variable explícitamente (§ 4.2) |
| Tras reiniciar, nada de lo que había definido existe | Es el comportamiento normal: el entorno vive en el shell | Repite el ritual de la § 5.3 |
| `envsubst` ha destrozado una plantilla | Se ejecutó sin la lista explícita de variables | Usa `nomad_plantilla` o el comando completo de la § 4.3 |
| El script dice «Variables sin definir» aunque las veo en mi shell | Están **enmascaradas**: en tu entorno sí, en el archivo no | `./scripts/variables.sh --faltan` te da el comando `--fijar` ya resuelto (§ 3.4) |
| `entorno.sh` dice que todo está bien y `sudo ./scripts/…` dice que faltan variables | Lo mismo, visto desde los dos lados | Tiene razón el que usa `sudo`. Ver § 3.4 |
| `--estado` marca una variable como `ENMASCARADA` | Tiene valor en tu sesión y no en el archivo | Escríbela con `--fijar`; al cerrar la terminal se perdería |
| Cada sesión nueva vuelve a estar mal | Hay un `export` en `~/.bashrc` que la enmascara siempre | Escríbela en el archivo y quítala del perfil (§ 3.4) |
| Vacié una variable «para rellenarla luego» y ahora un script aborta | Era `[REQUERIDA]`: traía un valor por omisión que funcionaba | Cópialo de `config/servidor.env.example` (§ 2.2.bis) |
| `./scripts/lib/entorno.sh` no hace nada | Se ejecutó en lugar de importarse | Usa `source scripts/lib/entorno.sh` (§ 3.1) |
| En la segunda terminal las variables no existen | El entorno no se propaga entre terminales | Cárgalo también allí |
| Un contenedor no ve una variable que sí tengo en el shell | Estaba definida pero sin exportar | El ayudante exporta; si lo hiciste a mano, usa `set -a` (§ 3.2) |
| No recuerdo por dónde iba | No se anotó al parar | Mira `inventario/progreso.txt` y `./scripts/verificar_sistema.sh` |

---

## 9. Referencias

- [Manual de `bash` — Expansión de parámetros](https://www.gnu.org/software/bash/manual/bash.html#Shell-Parameter-Expansion)
- [Manual de `bash` — Documentos en línea (heredocs)](https://www.gnu.org/software/bash/manual/bash.html#Here-Documents)
- [`sudoers(5)` — `env_reset` y variables de entorno](https://manpages.debian.org/trixie/sudo/sudoers.5.en.html)
- [`envsubst(1)` — sustitución de variables en archivos](https://manpages.debian.org/trixie/gettext-base/envsubst.1.en.html)
- [`tmux(1)`](https://manpages.debian.org/trixie/tmux/tmux.1.en.html)
- Capítulo [97 — Las dos vías: scripts o manual](97_vias_de_montaje.md)
- Capítulo [00 — Planificación](00_planificacion.md) § 4, donde se rellenan las variables por primera vez

---

**Anterior:** [97 — Las dos vías de montaje](97_vias_de_montaje.md) · **Siguiente:** [99 — Glosario y referencias](99_glosario_y_referencias.md)
