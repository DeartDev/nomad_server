# Lista de comprobación — Rutina de mantenimiento

> Del capítulo [15](../docs/15_mantenimiento_y_actualizaciones.md). Tres listas cortas en lugar de
> una larga, porque las largas no se hacen.
>
> **Pon los recordatorios en el calendario ahora.** Es el único requisito de esta lista que no
> depende del servidor, y el que más se incumple.

---

## Semanal — 2 minutos

```bash
# [servidor]
./scripts/verificar_sistema.sh --rapido
```

- [ ] Todos los contenedores `Up` y `(healthy)`
- [ ] Ningún sistema de archivos por encima del 80 %
- [ ] La última copia de respaldo tiene menos de 30 horas
- [ ] Sin errores nuevos en `journalctl -p err --since "7 days ago"`

Si algo falla, el árbol de diagnóstico está en el capítulo
[13](../docs/13_observabilidad.md) § 5 paso 10.

---

## Mensual — 15 minutos

**Fecha de la última revisión:** ____________

### 1. Respaldar antes de tocar nada

```bash
sudo ./scripts/14_restic.sh --ahora
```

- [ ] Hecho

### 2. Sistema base

```bash
sudo apt update && apt list --upgradable
sudo apt full-upgrade
sudo apt autoremove --purge
```

- [ ] Actualizado
- [ ] Reiniciado si `/var/run/reboot-required` existía

### 3. Infraestructura, de una en una

- [ ] **Traefik** — versión revisada, actualizada y comprobada con `traefik healthcheck --ping`
- [ ] **cloudflared** — actualizado, con 2 o más conexiones registradas
- [ ] **Dozzle / Uptime Kuma** — actualizados y accesibles

Consultar antes las notas de publicación:
- <https://github.com/traefik/traefik/releases>
- <https://github.com/cloudflare/cloudflared/releases>

### 4. Proyectos

```bash
./scripts/deploy.sh --listar
./scripts/deploy.sh <proyecto>
```

- [ ] Todos actualizados y respondiendo

### 5. Limpieza

```bash
docker system df
docker system prune -f
docker volume ls -f dangling=true
```

- [ ] Espacio recuperado
- [ ] Volúmenes huérfanos revisados antes de borrar nada

### 6. Respaldos

```bash
sudo ./scripts/14_restic.sh --verificar
```

- [ ] `no errors were found`

### 7. Registros

```bash
sudo fail2ban-client status sshd
sudo journalctl -k --since "30 days ago" | grep -c 'nomad-descartado'
docker logs traefik --since 720h 2>&1 | grep -i error | tail -20
```

- [ ] Nada inesperado

### 8. Verificación final

```bash
./scripts/verificar_sistema.sh
```

- [ ] Sin fallos

---

## Trimestral — 45 minutos

**Fecha de la última revisión:** ____________

### 1. Prueba de restauración

```bash
sudo ./scripts/14_restic.sh --probar
```

- [ ] `PRUEBA SUPERADA`

> Este es el punto más importante de toda la rutina. Un respaldo que no se restaura desde hace
> meses es un respaldo cuya validez es una suposición.

### 2. Verificación profunda del repositorio

```bash
sudo ./scripts/14_restic.sh --verificar-datos
```

- [ ] Sin datos corruptos

### 3. Hardware

```bash
sudo smartctl -H /dev/sda
sudo smartctl -A /dev/sda | grep -E 'Reallocated|Pending|Wear|Percent'
sensors 2>/dev/null
```

- [ ] `PASSED` en todos los discos
- [ ] Sin sectores reasignados nuevos
- [ ] Temperaturas razonables
- [ ] Polvo revisado (una vez al año basta)

### 4. Auditoría de seguridad

```bash
sudo lynis audit system --quick --quiet \
    --report-file ~/nomad_server/inventario/lynis-$(date +%F).dat
grep '^hardening_index' ~/nomad_server/inventario/lynis-*.dat | tail -5
```

- [ ] El índice no ha bajado respecto al trimestre anterior

Índice actual: ______  ·  Anterior: ______

### 5. Superficie expuesta

```bash
sudo ss -tulpn | grep LISTEN
docker ps --format 'table {{.Names}}\t{{.Ports}}'
sudo nft list ruleset | head -40
```

- [ ] Solo SSH y el punto de entrada interno en su dirección privada
- [ ] Ningún contenedor publicando en `0.0.0.0`

Y desde fuera de tu red:

```bash
nmap -Pn -F <tu-ip-publica>
```

- [ ] Nada abierto

### 6. Accesos y credenciales

```bash
ssh-keygen -lf ~/.ssh/authorized_keys
```

- [ ] Reconozco todas las llaves autorizadas
- [ ] En Tailscale: eliminados los dispositivos que ya no existen
- [ ] En Tailscale: la caducidad de clave del servidor sigue desactivada
- [ ] En Cloudflare: eliminados los registros DNS de proyectos retirados

### 7. Espacio a medio plazo

```bash
sudo vgs && sudo lvs && df -h
```

- [ ] Ningún volumen por encima del 70 %
- [ ] Ampliado lo que hiciera falta con `sudo lvextend -r -L +20G /dev/vg0/<lv>`

### 8. Documentación

- [ ] Los cambios hechos este trimestre están reflejados en el capítulo correspondiente
- [ ] `config/servidor.env` sigue coincidiendo con la realidad
- [ ] `make check` pasa en el repositorio

---

## Anual

- [ ] Ensayo completo de recuperación en una máquina virtual (capítulo
      [16](../docs/16_recuperacion_ante_desastres.md) § 7)
- [ ] Revisión de si conviene subir de versión mayor de Debian
- [ ] Limpieza física del equipo
- [ ] Revisión de la antigüedad de los discos (`Power_On_Hours`)
- [ ] Revisión del modelo de amenazas: ¿ha cambiado lo que hay que proteger?

---

## Registro de mantenimiento

| Fecha | Tipo | Quién | Notas |
|---|---|---|---|
|  | mensual |  |  |
|  | mensual |  |  |
|  | trimestral |  |  |
|  |  |  |  |

---

**Anterior:** [Después de instalar](post_instalacion.md)
