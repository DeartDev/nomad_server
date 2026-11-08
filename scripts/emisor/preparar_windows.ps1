# ===========================================================================
#  nomad_server — preparar Windows 11 como emisor de la pantalla extendida
# ===========================================================================
#  Propósito : dejar Windows listo para 'pantalla-hp': Apollo configurado, el
#              cortafuegos limitado al HP, el agente de SSH y la orden
#              instalada. Idempotente: la segunda ejecución no cambia nada.
#  Uso       : powershell.exe -NoProfile -ExecutionPolicy Bypass -File preparar_windows.ps1 [-Check]
#              Desde WSL:
#              powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w scripts/emisor/preparar_windows.ps1)" -Check
#  Capítulo  : docs/18_pantalla_extendida.md
#
#  Lee de config/servidor.env del repositorio: TS_IP (la IP de Tailscale del
#  HP), PANTALLA_HP_SSH y PANTALLA_EMISOR_WINDOWS_IP.
#
#  Con -Check solo cuenta lo que cambiaría. Sin él, aplica lo que puede. Lo que
#  exige administrador (Apollo, el cortafuegos, el servicio ssh-agent) lo avisa
#  y lo cuenta como pendiente si la consola no es de administrador: no pide
#  elevación por su cuenta.
#
#  LO QUE NO HACE: instalar Apollo (se descarga y se comprueba su suma a mano,
#  capítulo 18), crear el usuario de su web ni vincular el HP (pantalla-hp
#  vincular).
# ===========================================================================
$ErrorActionPreference = 'Stop'

$Check = $args -contains '-Check'
if ($args | Where-Object { $_ -notin '-Check' }) {
    Write-Host 'Uso: preparar_windows.ps1 [-Check]'
    exit 2
}

$Raiz = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ArchivoEnv = Join-Path $Raiz 'config\servidor.env'
$DirApollo = 'C:\Program Files\Apollo'
$ConfApollo = Join-Path $DirApollo 'config\sunshine.conf'
$AppsApollo = Join-Path $DirApollo 'config\apps.json'
$ExeApollo = Join-Path $DirApollo 'sunshine.exe'
$Destino = Join-Path $env:LOCALAPPDATA 'nomad-pantalla'

$EsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

$script:Cambios = 0
$script:Pendientes = 0
$script:Errores = 0
$script:ReiniciarApollo = $false

function Paso { param([string]$T) Write-Host ''; Write-Host "==> $T" -ForegroundColor Cyan }
function Bien { param([string]$T) Write-Host "[OK]    $T" -ForegroundColor Green }
function Igual { param([string]$T) Write-Host "[=]     $T" }
function Aviso { param([string]$T) Write-Host "[AVISO] $T" -ForegroundColor Yellow }
function Mal { param([string]$T) Write-Host "[ERROR] $T" -ForegroundColor Red; $script:Errores++ }

# Un cambio: en -Check se cuenta; si no, se aplica, o se deja pendiente si
# necesita administrador y la consola no lo es.
function Cambiar {
    param([string]$Descripcion, [scriptblock]$Accion, [switch]$Admin)
    $script:Cambios++
    if ($Check) { Write-Host "[CHECK] cambiaría: $Descripcion" -ForegroundColor Magenta; return }
    if ($Admin -and -not $EsAdmin) {
        Aviso "Necesita administrador, pendiente: $Descripcion"
        $script:Pendientes++
        return
    }
    & $Accion
    Bien $Descripcion
}

function Read-Env {
    if (-not (Test-Path $ArchivoEnv)) { throw "No existe $ArchivoEnv. Copia config/servidor.env del HP (capítulo 18)." }
    $vars = @{}
    foreach ($linea in Get-Content -Encoding UTF8 $ArchivoEnv) {
        if ($linea -match '^([A-Z][A-Z0-9_]*)="?([^"]*)"?\s*$') { $vars[$Matches[1]] = $Matches[2] }
    }
    foreach ($v in 'TS_IP', 'PANTALLA_HP_SSH', 'PANTALLA_EMISOR_WINDOWS_IP') {
        if (-not $vars[$v]) { throw "$v está vacía en $ArchivoEnv." }
    }
    return $vars
}

# En PowerShell 5.1, redirigir la salida de error de un programa con
# ErrorActionPreference=Stop lanza una excepción si escribe algo en ella.
function Invoke-Nativo {
    param([string]$Programa, [string[]]$Argumentos)
    $antes = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Programa @Argumentos *> $null } finally { $ErrorActionPreference = $antes }
    return $LASTEXITCODE
}

function Write-SinBom {
    param([string]$Ruta, [string]$Texto)
    [System.IO.File]::WriteAllText($Ruta, $Texto, (New-Object System.Text.UTF8Encoding($false)))
}

try {
    $Vars = Read-Env
} catch {
    Mal $_.Exception.Message
    exit 1
}
$IpHP = $Vars.TS_IP
$IpEste = $Vars.PANTALLA_EMISOR_WINDOWS_IP
if ($Check) { Write-Host '[CHECK] Simulación: no se modifica nada.' -ForegroundColor Magenta }
if (-not $EsAdmin) { Aviso 'La consola no es de administrador: lo que lo necesite quedará pendiente.' }

# ---------------------------------------------------------------------------
Paso 'Tailscale'
if (Get-NetIPAddress -IPAddress $IpEste -ErrorAction SilentlyContinue) {
    Bien "Este equipo tiene $IpEste."
} else {
    Mal "Este equipo no tiene $IpEste (PANTALLA_EMISOR_WINDOWS_IP). Conecta Tailscale o corrige la variable."
}

# ---------------------------------------------------------------------------
Paso 'Apollo'
$servicio = Get-Service -Name ApolloService -ErrorAction SilentlyContinue
if (-not (Test-Path $ExeApollo) -or -not $servicio) {
    Mal "Apollo no está instalado en $DirApollo. Instálalo antes (capítulo 18): descarga, suma SHA-256 y ejecución como administrador."
} else {
    Bien "Apollo instalado ($ExeApollo)."

    # Sin forzar QuickSync, Apollo elige solo y puede caer en el codificador por
    # software, que el portátil no aguanta a 1080p60.
    # El tope de bitrate: el HP pide siempre PANTALLA_BITRATE (40000), y por Wi-Fi
    # eso se percibe a ratos lento (medido, 2026-11-07). En Fedora el tope solo se
    # pone con Wi-Fi, al arrancar Sunshine; aquí Apollo es un servicio y cambiarlo
    # en cada sesión exigiría administrador, así que es fijo, también con cable.
    $ajustes = [ordered]@{ encoder = 'quicksync'; max_bitrate = '15000' }
    $conf = @(Get-Content -Encoding UTF8 $ConfApollo -ErrorAction SilentlyContinue)
    foreach ($clave in $ajustes.Keys) {
        $valor = $ajustes[$clave]
        if ($conf -match "^\s*$clave\s*=\s*$valor\s*$") {
            Igual "sunshine.conf: $clave = $valor."
        } else {
            Cambiar "fijar $clave = $valor en sunshine.conf" -Admin {
                $resto = @($conf | Where-Object { $_ -notmatch "^\s*$clave\s*=" })
                $script:ConfNueva = @("$clave = $valor") + $resto
                Write-SinBom $ConfApollo ($script:ConfNueva -join "`r`n")
                $script:ReiniciarApollo = $true
            }
            # La siguiente clave parte de lo ya escrito, no del archivo original.
            if (-not $Check -and $script:ConfNueva) { $conf = $script:ConfNueva }
        }
    }

    # Desktop: pantalla virtual siempre, y la aplicación termina al irse el HP.
    # Sin lo segundo, la virtual se queda como principal sin que nadie la vea.
    $apps = Get-Content -Raw -Encoding UTF8 $AppsApollo | ConvertFrom-Json
    $desktop = @($apps.apps | Where-Object { $_.name -eq 'Desktop' }) | Select-Object -First 1
    if (-not $desktop) {
        Mal "No hay aplicación 'Desktop' en $AppsApollo. Créala en la web de Apollo (Applications)."
    } else {
        $faltan = @()
        foreach ($clave in 'virtual-display', 'terminate-on-pause') {
            if (-not ($desktop.PSObject.Properties.Name -contains $clave) -or $desktop.$clave -ne $true) { $faltan += $clave }
        }
        if ($faltan.Count -eq 0) {
            Igual "Desktop: virtual-display y terminate-on-pause activos."
        } else {
            Cambiar "activar $($faltan -join ' y ') en la aplicación Desktop" -Admin {
                foreach ($clave in $faltan) {
                    if ($desktop.PSObject.Properties.Name -contains $clave) { $desktop.$clave = $true }
                    else { $desktop | Add-Member -NotePropertyName $clave -NotePropertyValue $true }
                }
                Write-SinBom $AppsApollo ($apps | ConvertTo-Json -Depth 20)
                $script:ReiniciarApollo = $true
            }
        }
    }

    if ($servicio.StartType -ne 'Automatic') {
        Cambiar 'arranque automático de ApolloService' -Admin { Set-Service -Name ApolloService -StartupType Automatic }
    } else {
        Igual 'ApolloService arranca solo.'
    }
}

# ---------------------------------------------------------------------------
Paso 'Cortafuegos'
# Apollo crea reglas abiertas a todo. No basta con permitir solo al HP:
# 'Tailscale-In' permite toda entrada por Tailscale, así que hacen falta reglas
# de bloqueo, que ganan a las de permitir. 127.0.0.0/8 queda fuera de los
# bloqueos para que la web siga en localhost.
function Move-IP {
    param([string]$IP, [int]$Delta)
    $b = ([System.Net.IPAddress]$IP).GetAddressBytes(); [array]::Reverse($b)
    $n = [BitConverter]::GetBytes([uint32]([BitConverter]::ToUInt32($b, 0) + $Delta)); [array]::Reverse($n)
    return ([System.Net.IPAddress]::new($n)).ToString()
}
$noHP = @("0.0.0.0-$(Move-IP $IpHP -1)", "$(Move-IP $IpHP 1)-126.255.255.255", '128.0.0.0-255.255.255.255')
$noLocal = @('0.0.0.0-126.255.255.255', '128.0.0.0-255.255.255.255')

$abiertas = @(Get-NetFirewallRule -DisplayName 'Apollo' -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq 'True' })
if ($abiertas.Count -gt 0) {
    Cambiar "desactivar las $($abiertas.Count) reglas abiertas 'Apollo' del instalador" -Admin {
        Disable-NetFirewallRule -DisplayName 'Apollo'
    }
} else {
    Igual "Reglas 'Apollo' del instalador desactivadas o ausentes."
}

$reglas = @(
    @{ N = 'Nomad Apollo TCP'; A = 'Allow'; P = 'TCP'; L = @('47984', '47989', '48010'); R = @($IpHP) },
    @{ N = 'Nomad Apollo UDP'; A = 'Allow'; P = 'UDP'; L = @('47998-48000'); R = @($IpHP) },
    @{ N = 'Nomad Apollo bloquear web'; A = 'Block'; P = 'TCP'; L = @('47990'); R = $noLocal },
    @{ N = 'Nomad Apollo solo HP TCP'; A = 'Block'; P = 'TCP'; L = @('47984', '47989', '48010'); R = $noHP },
    @{ N = 'Nomad Apollo solo HP UDP'; A = 'Block'; P = 'UDP'; L = @('47998-48000'); R = $noHP }
)
foreach ($r in $reglas) {
    $actual = Get-NetFirewallRule -DisplayName $r.N -ErrorAction SilentlyContinue
    $bien = $false
    if ($actual) {
        $dir = ($actual | Get-NetFirewallAddressFilter).RemoteAddress
        $puertos = ($actual | Get-NetFirewallPortFilter).LocalPort
        $bien = ($actual.Enabled -eq 'True') -and ("$($actual.Action)" -eq $r.A) -and
                (@($puertos) -join ',') -eq ($r.L -join ',') -and (@($dir).Count -eq $r.R.Count)
    }
    if ($bien) {
        Igual "Regla '$($r.N)' como debe."
    } else {
        $regla = $r
        Cambiar "regla '$($r.N)' ($($r.A) $($r.P) $($r.L -join ','))" -Admin {
            Get-NetFirewallRule -DisplayName $regla.N -ErrorAction SilentlyContinue | Remove-NetFirewallRule
            $parametros = @{
                DisplayName = $regla.N; Direction = 'Inbound'; Action = $regla.A; Protocol = $regla.P
                LocalPort = $regla.L; RemoteAddress = $regla.R
            }
            if ($regla.A -eq 'Allow') { $parametros.Program = $ExeApollo }
            New-NetFirewallRule @parametros | Out-Null
        }
    }
}

# ---------------------------------------------------------------------------
Paso 'Agente de SSH'
# pantalla-hp habla con el HP con BatchMode: la clave tiene que estar en el
# agente. El servicio viene desactivado en Windows.
$agente = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
if (-not $agente) {
    Mal 'No está el servicio ssh-agent: instala el Cliente OpenSSH (Configuración > Sistema > Características opcionales).'
} else {
    if ($agente.StartType -ne 'Automatic') {
        Cambiar 'arranque automático de ssh-agent' -Admin { Set-Service -Name ssh-agent -StartupType Automatic }
    } else {
        Igual 'ssh-agent arranca solo.'
    }
    if ($agente.Status -ne 'Running') {
        Cambiar 'arrancar ssh-agent' -Admin { Start-Service -Name ssh-agent }
    } else {
        Igual 'ssh-agent en marcha.'
    }
}

# ---------------------------------------------------------------------------
Paso 'Orden pantalla-hp'
$conf = "HP_SSH=`"$($Vars.PANTALLA_HP_SSH)`"`r`nEMISOR_IP=`"$IpEste`"`r`n"
$archivoConf = Join-Path $Destino 'pantalla-hp.conf'
$cmd = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0pantalla-hp.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n"
$archivoCmd = Join-Path $Destino 'pantalla-hp.cmd'
$origenPs1 = Join-Path $PSScriptRoot 'pantalla-hp.ps1'
$destinoPs1 = Join-Path $Destino 'pantalla-hp.ps1'

function Get-Texto { param([string]$Ruta) if (Test-Path $Ruta) { [System.IO.File]::ReadAllText($Ruta) } else { $null } }

if ((Get-Texto $archivoConf) -ne $conf) {
    Cambiar "escribir $archivoConf" { New-Item -ItemType Directory -Force $Destino | Out-Null; Write-SinBom $archivoConf $conf }
} else { Igual "$archivoConf al día." }

# Se compara por bytes: el BOM de pantalla-hp.ps1 debe llegar intacto. Con .NET
# y no con Get-FileHash, que no siempre se carga si se lanza desde WSL.
function Get-Huella {
    param([string]$Ruta)
    if (-not (Test-Path $Ruta)) { return '' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    return [BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($Ruta)))
}
$hashOrigen = Get-Huella $origenPs1
$hashDestino = Get-Huella $destinoPs1
if ($hashOrigen -ne $hashDestino) {
    Cambiar "copiar pantalla-hp.ps1 a $Destino" { New-Item -ItemType Directory -Force $Destino | Out-Null; Copy-Item -Force $origenPs1 $destinoPs1 }
} else { Igual 'pantalla-hp.ps1 al día.' }

if ((Get-Texto $archivoCmd) -ne $cmd) {
    Cambiar "escribir $archivoCmd" {
        New-Item -ItemType Directory -Force $Destino | Out-Null
        [System.IO.File]::WriteAllText($archivoCmd, $cmd, [System.Text.Encoding]::ASCII)
    }
} else { Igual 'pantalla-hp.cmd al día.' }

$ruta = [Environment]::GetEnvironmentVariable('Path', 'User')
if (@($ruta -split ';') -notcontains $Destino) {
    Cambiar "añadir $Destino al PATH del usuario" {
        $nueva = if ($ruta) { "$ruta;$Destino" } else { $Destino }
        [Environment]::SetEnvironmentVariable('Path', $nueva, 'User')
    }
} else { Igual "$Destino está en el PATH del usuario." }

# ---------------------------------------------------------------------------
if ($script:ReiniciarApollo -and -not $Check -and $EsAdmin) {
    Paso 'Reinicio de Apollo'
    Restart-Service -Name ApolloService
    Bien 'ApolloService reiniciado con la configuración nueva.'
}

# ---------------------------------------------------------------------------
Paso 'Comprobaciones (solo lectura)'
if ((Invoke-Nativo 'ssh-add.exe' @('-l')) -eq 0) {
    $rc = Invoke-Nativo 'ssh.exe' @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', $Vars.PANTALLA_HP_SSH,
                                    'sudo -n -l /usr/bin/systemctl start nomad-pantalla@windows.service')
    switch ($rc) {
        0 { Bien "$($Vars.PANTALLA_HP_SSH) acepta la sesión de Windows sin contraseña." }
        1 { Aviso "El sudo de $($Vars.PANTALLA_HP_SSH) no conoce nomad-pantalla@windows.service: ejecuta allí sudo ./scripts/18_pantalla.sh." }
        default { Aviso "No se llega a $($Vars.PANTALLA_HP_SSH) por ssh sin preguntas (código $rc)." }
    }
} else {
    Aviso "La clave no está en el agente: no se comprueba el HP. 'pantalla-hp' la carga la primera vez (o: ssh-add `$HOME\.ssh\nomadservernw)."
}

Write-Host ''
if ($Check) {
    Write-Host "[CHECK] Cambios que se aplicarían: $($script:Cambios)" -ForegroundColor Magenta
} else {
    $aplicados = $script:Cambios - $script:Pendientes
    Write-Host "[OK]    Cambios aplicados: $aplicados" -ForegroundColor Green
    if ($script:Pendientes -gt 0) {
        Aviso "Quedan $($script:Pendientes) cambios que necesitan administrador: ejecútalo en PowerShell como administrador."
    }
}
if ($script:Errores -gt 0) { exit 1 }
if ($script:Pendientes -gt 0) { exit 1 }
exit 0
