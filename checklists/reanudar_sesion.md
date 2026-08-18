# Lista de comprobación — Empezar o retomar una sesión de trabajo

> Este montaje **no está pensado para hacerse de una sentada**: son entre 9 y 12 horas repartidas,
> con reinicios de por medio. Cada vez que vuelves, el servidor conserva todo lo que escribiste en
> disco, pero tu terminal está en blanco.
>
> Esta lista son los cinco minutos que hay que dedicar al empezar y al terminar cada tanda. Es corta
> a propósito: si fuera larga, no se haría.
>
> Explicación completa en [98 — Variables, entorno y sesiones](../docs/98_variables_y_entorno.md) § 5.

---

## Al empezar la sesión

### 1. Entrar

```bash
# [cliente] — elige la vía que ya tengas montada
ssh <usuario>@<ip-del-servidor>      # antes del capítulo 05
ssh nomad                            # con ~/.ssh/config, capítulo 05 en adelante
ssh <usuario>@<nombre-tailscale>     # desde fuera de casa, capítulo 08 en adelante
```

- [ ] Estoy dentro del servidor

### 2. Sesión persistente

```bash
# [servidor]
tmux new -s montaje       # la primera vez
tmux attach -t montaje    # si ya existía
```

- [ ] Trabajo dentro de `tmux`, así una desconexión no corta un `apt` a medias

### 3. Cargar el entorno ← **el paso que se olvida**

```bash
# [servidor]
cd ~/nomad_server
source scripts/lib/entorno.sh
```

- [ ] Aparece `[OK] Entorno cargado desde …`
- [ ] El resumen muestra **el servidor correcto** (nombre, LAN, dominio)

Comprobación rápida antes de pegar cualquier comando:

```bash
# [servidor]
echo "hostname=${SERVIDOR_HOSTNAME}  lan=${LAN_CIDR}  datos=${DATOS_RAIZ}"
```

- [ ] Los tres tienen valor. Si alguno sale vacío, **no sigas**: no está cargado

> Hay que repetir este paso en **cada** terminal nueva, en cada ventana de `tmux`, y después de
> cada reinicio del servidor. Las variables de entorno mueren con el shell que las creó.

### 4. Recuperar el contexto

```bash
# [servidor]
tail -5 inventario/progreso.txt          # dónde me quedé
./scripts/variables.sh --faltan          # qué valores siguen pendientes
```

- [ ] Sé en qué capítulo y en qué paso estoy
- [ ] Sé qué variables faltan y de qué capítulo salen

### 5. Comprobar que nada se ha movido

```bash
# [servidor]
./scripts/verificar_sistema.sh --rapido
```

- [ ] Sin fallos, o solo fallos de capítulos que todavía no he hecho

### 6. Actualizar el repositorio, si lo has tocado en tu equipo

```bash
# [servidor]
git -C ~/nomad_server pull
```

- [ ] El repositorio del servidor está al día
- [ ] `config/servidor.env` sigue con permisos `600` (`ls -l config/servidor.env`)

---

## Durante la sesión

- [ ] Cada valor que descubro lo escribo **en el momento**:
      `./scripts/variables.sh --fijar NOMBRE=valor`
- [ ] Antes de un comando destructivo, compruebo la variable: `echo "${DATOS_RAIZ}"`
- [ ] Si abro una segunda terminal (capítulos 05 y 06 lo piden), cargo el entorno también allí
- [ ] Tras cambiar `config/servidor.env`, recargo: `source scripts/lib/entorno.sh`

---

## Al terminar la sesión

### 1. Persistir lo descubierto

```bash
# [servidor]
./scripts/variables.sh --faltan
```

- [ ] Nada de lo que averigüé hoy se queda solo en la memoria de esta terminal

### 2. Dejar el sistema en un estado coherente

- [ ] No estoy parando en mitad de un paso peligroso. Los malos momentos son:
  - Capítulo 05 con la contraseña ya desactivada pero sin probar la llave desde otra terminal
  - Capítulo 06 con el cortafuegos aplicado y la IP sin cambiar, o al revés
  - Capítulo 14 con el disco formateado y el repositorio restic sin inicializar

```bash
# [servidor]
./scripts/verificar_sistema.sh --rapido
```

- [ ] Sin fallos inesperados

### 3. Anotar dónde me quedé

```bash
# [servidor]
mkdir -p ~/nomad_server/inventario
printf '%s  capítulo %s — %s\n' "$(date +%F\ %H:%M)" "07" "hecho hasta el paso 5" \
    >> ~/nomad_server/inventario/progreso.txt
```

- [ ] Capítulo y paso anotados, con lo que quedó pendiente

### 4. Copia del archivo de configuración

```bash
# [cliente]
scp <usuario>@<ip-del-servidor>:~/nomad_server/config/servidor.env ./config/servidor.env
```

- [ ] Tengo una copia fuera del servidor

> Hasta terminar el capítulo [14](../docs/14_respaldos_restic.md) **no hay respaldos automáticos**.
> Esta copia manual es la única red de seguridad de todo lo que has configurado.

### 5. Cerrar

```bash
# [servidor]
exit                 # deja tmux corriendo, por si vuelves pronto
```

o, si conviene dejar el sistema reiniciado y comprobado:

```bash
# [servidor]
sudo reboot
```

- [ ] Si he reiniciado, he comprobado que vuelve solo y que puedo entrar

---

## Qué sobrevive y qué no

| Sobrevive a un reinicio | No sobrevive |
|---|---|
| Todo lo escrito en `/etc`, `/srv`, `/usr/local/bin` | Las variables cargadas en tu shell |
| `config/servidor.env` | Las variables temporales (`PROYECTO`, `USB`, `DISCO`…) |
| Servicios con `systemctl enable` | Las sesiones de `tmux` |
| Contenedores con `restart: unless-stopped` | Los trabajos en segundo plano (`&`) |
| Reglas de nftables cargadas por su servicio | La red de seguridad `sleep 300 && nft flush ruleset` |
| El nodo de Tailscale registrado | Los túneles SSH (`ssh -L`) abiertos |

---

**Ver también:** [Antes de instalar](pre_instalacion.md) · [Después de instalar](post_instalacion.md) · [Rutina de mantenimiento](mantenimiento.md)
