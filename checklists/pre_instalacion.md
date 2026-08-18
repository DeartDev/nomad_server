# Lista de comprobación — Antes de instalar

> Imprímela o tenla abierta en otro dispositivo. Cubre los capítulos
> [00](../docs/00_planificacion.md), [01](../docs/01_unidad_usb_booteable.md) y
> [02](../docs/02_validacion_equipo.md).
>
> **No pases al capítulo 03 hasta que todo esté marcado.** El capítulo 03 borra el disco.

---

## Planificación (capítulo 00)

- [ ] He leído entera la sección 3 del capítulo 00 y entiendo por qué el servidor no expone puertos
- [ ] He decidido con qué vía voy a trabajar: con los scripts, a mano, o mezclando
      ([97](../docs/97_vias_de_montaje.md))
- [ ] `config/servidor.env` creado con `make init` y con permisos `600`
- [ ] Todas las variables `[OBLIGATORIA]` tienen valor
- [ ] `make variables` no muestra ninguna fila como `FALTA`
- [ ] Entiendo que las filas `pendiente` son valores que se descubrirán durante el montaje, y sé
      que hay que escribirlos con `./scripts/variables.sh --fijar` en cuanto aparezcan
      ([98 § 2.2](../docs/98_variables_y_entorno.md))
- [ ] `make check` termina sin errores
- [ ] `${LAN_IP}` está reservada en el router para la MAC del servidor, o está fuera del rango DHCP
- [ ] Cuenta de Tailscale creada, con verificación en dos pasos activada
- [ ] Cuenta de Cloudflare creada, con verificación en dos pasos activada
- [ ] Contraseña del repositorio restic generada y guardada en el gestor de contraseñas
- [ ] Contraseña del usuario administrador generada y guardada en el gestor de contraseñas

## Medio de instalación (capítulo 01)

- [ ] Imagen `netinst` descargada
- [ ] `sha256sum -c SHA256SUMS` da «La suma coincide»
- [ ] Claves de Debian importadas
- [ ] Huellas de las claves contrastadas contra <https://www.debian.org/CD/verify>
- [ ] `gpg --verify` da «Good signature»
- [ ] Dispositivo USB identificado con certeza (transporte `usb`, tamaño y modelo correctos)
- [ ] Imagen escrita con `dd` y `oflag=sync`
- [ ] Lectura del USB verificada: la suma coincide con la de la ISO
- [ ] El USB arranca y muestra el menú del instalador de Debian

## Hardware (capítulo 02)

### Inventario

- [ ] `scripts/02_inventario_equipo.sh` ejecutado y su archivo guardado
- [ ] Arquitectura `x86_64`, 2 núcleos o más
- [ ] 4 GB de RAM como mínimo (8 GB recomendados)
- [ ] Disco SSD identificado (`ROTA=0`)
- [ ] `DISCO_DESTINO` **escrito en `config/servidor.env`** con la ruta `/dev/disk/by-id/…`
      (`./scripts/variables.sh --fijar DISCO_DESTINO=…`)
- [ ] `LAN_INTERFAZ` escrita igual, o dejada vacía a propósito para autodetección
- [ ] `./scripts/variables.sh --ver DISCO_DESTINO` devuelve el valor correcto

### Salud

- [ ] `smartctl -H` da `PASSED` en todos los discos que se van a usar
- [ ] `Reallocated_Sector_Ct` y `Current_Pending_Sector` a 0
- [ ] Prueba SMART corta completada sin errores
- [ ] memtest86+: al menos una pasada completa con **0 errores**

### Datos anteriores

- [ ] He revisado qué había en el equipo
- [ ] Los datos que quiero conservar están copiados a un disco externo
- [ ] **He verificado el respaldo**: abro un archivo copiado y los tamaños cuadran
- [ ] El disco externo con el respaldo está desconectado del equipo

### UEFI

- [ ] Firmware actualizado a la última versión del fabricante
- [ ] **Restore on AC Power Loss = Power On** ← el ajuste más importante
- [ ] SATA Mode = **AHCI** (no RAID, no Intel RST)
- [ ] Secure Boot = **Enabled**
- [ ] Boot Mode = **UEFI only**, CSM **Disabled**
- [ ] Fast Boot = **Disabled**
- [ ] Estados de suspensión (S3, Deep Sleep) = **Disabled**
- [ ] Wake on LAN = **Enabled**
- [ ] Virtualización (VT-x / AMD-V) = **Enabled**
- [ ] Audio, Wi-Fi/Bluetooth y puertos serie integrados = **Disabled** (si no se usan)
- [ ] Perfil de ventiladores ajustado
- [ ] Cambios anotados en el inventario, por si algún día se restablecen los valores de fábrica

### Físico

- [ ] Polvo limpiado de disipadores y ventiladores
- [ ] Todos los ventiladores giran libremente
- [ ] Ningún condensador hinchado en la placa
- [ ] Cables SATA y de alimentación bien asentados
- [ ] Equipo en su ubicación definitiva, ventilado, sin tapar las rejillas
- [ ] Cable de red conectado al router
- [ ] Monitor y teclado conectados (harán falta durante el capítulo 03)

### Prueba del corte de luz

- [ ] Con el equipo encendido, he desconectado la corriente y al devolverla **se ha encendido solo**

---

## Antes de pulsar «Instalar»

- [ ] He generado la **chuleta de valores** del capítulo [03](../docs/03_instalacion_debian.md)
      paso 0 y la tengo en otro dispositivo (el instalador no puede leer `config/servidor.env`)
- [ ] Ningún campo de la chuleta sale vacío ni con `CAMBIAME`
- [ ] Sé qué disco es el destino y puedo distinguirlo por tamaño y modelo
- [ ] Tengo la contraseña del usuario administrador generada y en el gestor de contraseñas
- [ ] Acepto que a partir de aquí el contenido del disco se pierde

---

## Después de instalar, lo primero

No es parte de esta lista, pero conviene tenerlo presente: el capítulo
[04](../docs/04_primer_arranque_y_base.md) paso 2 lleva el repositorio al servidor y establece el
ritual que se repetirá en cada sesión a partir de entonces:

```bash
# [servidor]
cd ~/nomad_server
source scripts/lib/entorno.sh
```

La lista de ese ritual está en [reanudar_sesion.md](reanudar_sesion.md).

---

**Siguiente:** [03 — Instalación de Debian](../docs/03_instalacion_debian.md)
