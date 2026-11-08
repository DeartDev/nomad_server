# ===========================================================================
#  nomad_server — usar el panel del HP como pantalla de Windows
# ===========================================================================
#  Propósito : abrir y cerrar la sesión de pantalla extendida desde Windows 11:
#              pide al HP que conecte con Apollo, coloca las pantallas y deja
#              siempre la interna activa al terminar.
#  Uso       : pantalla-hp extender|principal|off|estado|vincular|--help
#  Capítulo  : docs/18_pantalla_extendida.md
#
#  Lo instala preparar_windows.ps1 en %LOCALAPPDATA%\nomad-pantalla, con
#  pantalla-hp.cmd como envoltorio y pantalla-hp.conf (HP_SSH, EMISOR_IP).
#
#  CÓMO FUNCIONA (medido en la Tarea 2 del plan, 2026-11-07)
#
#  - Apollo crea la pantalla virtual al conectar el HP y la retira al terminar
#    la sesión, si su aplicación Desktop tiene 'virtual-display' y
#    'terminate-on-pause'. Al retirarla, Windows vuelve solo a la interna.
#  - Apollo transmite la pantalla PRINCIPAL. Por eso extender deja la virtual
#    como principal y la interna a su izquierda, y principal es
#    'DisplaySwitch /external'.
#  - Con la tapa cerrada la sesión sigue: no se toca la energía.
#
#  Con -Biblioteca solo define las funciones: así lo cargan las pruebas
#  (probar_pantalla_hp.ps1), que sustituyen las de bajo nivel por dobles.
# ===========================================================================
$ErrorActionPreference = 'Stop'

$script:Argumentos = @($args)

$script:UHp = 'nomad-pantalla@windows.service'
$script:UHpOtra = 'nomad-pantalla@fedora.service'
$script:Directorio = Join-Path $env:LOCALAPPDATA 'nomad-pantalla'
$script:ArchivoConf = Join-Path $script:Directorio 'pantalla-hp.conf'
$script:UrlPin = 'https://localhost:47990/pin'

$script:PlazoVirtual = 30     # s: lo que puede tardar Apollo en crear la pantalla virtual
$script:PlazoRetirada = 20    # s: Apollo deja de ver al HP a los 10 s ('Ping Timeout')
$script:PlazoModo = 10        # s: DisplaySwitch aplica el modo después de volver
$script:LimiteSsh = 20        # s: tope de una orden por ssh sin preguntas

$script:Conf = $null

# ===========================================================================
#  BAJO NIVEL: lo único que toca el equipo. Las pruebas lo sustituyen.
# ===========================================================================

function Escribir {
    param([string]$Nivel, [string]$Texto)
    if ($Nivel -eq 'USO') { Write-Host $Texto; return }
    $color = switch ($Nivel) { 'OK' { 'Green' } 'AVISO' { 'Yellow' } 'ERROR' { 'Red' } default { 'Gray' } }
    Write-Host ("[{0}]`t{1}" -f $Nivel, $Texto) -ForegroundColor $color
}

function Read-Conf {
    if (-not (Test-Path $script:ArchivoConf)) {
        throw "No existe $($script:ArchivoConf). Ejecuta preparar_windows.ps1."
    }
    $conf = @{}
    foreach ($linea in Get-Content -Encoding UTF8 $script:ArchivoConf) {
        if ($linea -match '^\s*([A-Z_]+)\s*=\s*"?([^"]*)"?\s*$') { $conf[$Matches[1]] = $Matches[2] }
    }
    return $conf
}

# Sin -Interactivo, con BatchMode: no puede preguntar nada, y con la interna
# apagada nadie vería la pregunta. El tope cubre un HP que acepta la conexión y
# no contesta. Con -Interactivo puede pedir la frase de la clave o la contraseña
# de sudo: 'AddKeysToAgent' deja la clave en el agente para lo que viene después.
function Invoke-SshHP {
    param([string]$Orden, [switch]$Interactivo)
    $hp = $script:Conf.HP_SSH
    if ($Interactivo) {
        & ssh.exe -t -o AddKeysToAgent=yes -o ConnectTimeout=5 $hp $Orden
        return $LASTEXITCODE
    }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = 'ssh.exe'
    $info.Arguments = '-o BatchMode=yes -o ConnectTimeout=5 {0} "{1}"' -f $hp, $Orden
    $info.UseShellExecute = $false
    $proceso = [System.Diagnostics.Process]::Start($info)
    if (-not $proceso.WaitForExit($script:LimiteSsh * 1000)) {
        try { $proceso.Kill() } catch { }
        return 124
    }
    return $proceso.ExitCode
}

function Initialize-TipoPantallas {
    if ('NomadPantallas' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class NomadPantallas {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    // DEVMODEW, variante de pantalla: 220 bytes.
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields;
        public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType;
        public int dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplayDevices(string dispositivo, uint indice, ref DISPLAY_DEVICE dd, uint banderas);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplaySettings(string dispositivo, int modo, ref DEVMODE dm);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeDisplaySettingsExW")]
    static extern int Cambiar(string dispositivo, ref DEVMODE dm, IntPtr ventana, uint banderas, IntPtr parametro);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeDisplaySettingsExW")]
    static extern int Aplicar(string dispositivo, IntPtr dm, IntPtr ventana, uint banderas, IntPtr parametro);

    const int ENUM_CURRENT_SETTINGS = -1;
    const int DM_POSITION = 0x20;
    const uint CDS_UPDATEREGISTRY = 0x1, CDS_SET_PRIMARY = 0x10, CDS_NORESET = 0x10000000;

    public class Pantalla {
        public string Nombre, Adaptador;
        public bool Activa, Principal, TieneMonitor;
        public int X, Ancho;
    }

    public static List<Pantalla> Listar() {
        var lista = new List<Pantalla>();
        for (uint i = 0; i < 32; i++) {
            var d = new DISPLAY_DEVICE(); d.cb = Marshal.SizeOf(d);
            if (!EnumDisplayDevices(null, i, ref d, 0)) break;
            var m = new DISPLAY_DEVICE(); m.cb = Marshal.SizeOf(m);
            var p = new Pantalla();
            p.Nombre = d.DeviceName;
            p.Adaptador = d.DeviceString;
            p.Activa = (d.StateFlags & 1) != 0;      // DISPLAY_DEVICE_ATTACHED_TO_DESKTOP
            p.Principal = (d.StateFlags & 4) != 0;   // DISPLAY_DEVICE_PRIMARY_DEVICE
            p.TieneMonitor = EnumDisplayDevices(d.DeviceName, 0, ref m, 0);
            if (p.Activa) {
                var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(dm);
                if (EnumDisplaySettings(d.DeviceName, ENUM_CURRENT_SETTINGS, ref dm)) {
                    p.X = dm.dmPositionX; p.Ancho = dm.dmPelsWidth;
                }
            }
            lista.Add(p);
        }
        return lista;
    }

    static int Mover(string dispositivo, int x, uint banderas) {
        var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(dm);
        if (!EnumDisplaySettings(dispositivo, ENUM_CURRENT_SETTINGS, ref dm)) return -100;
        dm.dmPositionX = x; dm.dmPositionY = 0; dm.dmFields = DM_POSITION;
        return Cambiar(dispositivo, ref dm, IntPtr.Zero, banderas, IntPtr.Zero);
    }

    // 0 si Windows aceptó los dos cambios y la aplicación final.
    public static int Disponer(string principal, string otra, int xOtra) {
        int r = Mover(principal, 0, CDS_SET_PRIMARY | CDS_UPDATEREGISTRY | CDS_NORESET);
        if (r != 0) return r;
        r = Mover(otra, xOtra, CDS_UPDATEREGISTRY | CDS_NORESET);
        if (r != 0) return r;
        return Aplicar(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero);
    }
}
'@
}

# Solo las salidas con monitor. Windows lista también salidas fantasma: tres de
# la gráfica de Intel y diez del adaptador de Apollo (DISPLAY5 a DISPLAY14),
# siempre presentes, con o sin sesión. La pantalla virtual de verdad es la que
# tiene monitor: aparece al conectar el HP y se va al terminar (medido).
function ConvertTo-Pantallas {
    param($Lista)
    foreach ($p in $Lista) {
        if (-not $p.TieneMonitor) { continue }
        [pscustomobject]@{
            Nombre = $p.Nombre; Virtual = [bool]($p.Adaptador -match 'SudoMaker|Virtual Display')
            Activa = $p.Activa; Principal = $p.Principal; X = $p.X; Ancho = $p.Ancho
        }
    }
}

function Get-Pantallas {
    Initialize-TipoPantallas
    ConvertTo-Pantallas ([NomadPantallas]::Listar())
}

function Invoke-DisplaySwitch {
    param([string]$Modo)
    & (Join-Path $env:windir 'System32\DisplaySwitch.exe') "/$Modo" | Out-Null
}

function Set-Disposicion {
    param([string]$Principal, [string]$Otra, [int]$XOtra)
    Initialize-TipoPantallas
    $r = [NomadPantallas]::Disponer($Principal, $Otra, $XOtra)
    if ($r -ne 0) { Escribir 'AVISO' "Windows rechazó la disposición (código $r)." }
    return ($r -eq 0)
}

function Test-IPLocal {
    param([string]$IP)
    return [bool](Get-NetIPAddress -IPAddress $IP -ErrorAction SilentlyContinue)
}

function Test-Apollo {
    $s = Get-Service -Name ApolloService -ErrorAction SilentlyContinue
    return ($null -ne $s -and $s.Status -eq 'Running')
}

function Wait-Segundos { param([double]$Segundos) Start-Sleep -Milliseconds ([int]($Segundos * 1000)) }

function Start-Navegador { param([string]$Url) Start-Process $Url }

# ===========================================================================
#  LÓGICA
# ===========================================================================

function Get-Virtual { @(Get-Pantallas | Where-Object { $_.Virtual }) | Select-Object -First 1 }
function Get-InternaActiva { @(Get-Pantallas | Where-Object { -not $_.Virtual -and $_.Activa }) | Select-Object -First 1 }

# Repite la comprobación cada segundo hasta el plazo. Devuelve si se cumplió.
function Wait-Condicion {
    param([scriptblock]$Condicion, [int]$Plazo)
    for ($i = 0; $i -lt $Plazo; $i++) {
        if (& $Condicion) { return $true }
        Wait-Segundos 1
    }
    return [bool](& $Condicion)
}

function Test-InternaRestaurada {
    $i = Get-InternaActiva
    return ($null -ne $i -and $i.Principal)
}

# Todo lo que puede fallar sin haber tocado nada va aquí, antes de pedir la
# sesión: así un error nunca deja las pantallas movidas.
function Test-Requisitos {
    foreach ($v in 'HP_SSH', 'EMISOR_IP') {
        if (-not $script:Conf[$v]) { throw "$v está vacía en $($script:ArchivoConf). Ejecuta preparar_windows.ps1." }
    }
    if (-not (Test-IPLocal $script:Conf.EMISOR_IP)) {
        throw "Este equipo no tiene la IP $($script:Conf.EMISOR_IP): ¿Tailscale está conectado? No se ha tocado nada."
    }
    if (-not (Test-Apollo)) {
        throw 'Apollo no está en marcha (servicio ApolloService). Arráncalo desde su icono o con preparar_windows.ps1. No se ha tocado nada.'
    }
    if (Get-Virtual) {
        throw 'Ya hay una sesión activa: la pantalla virtual de Apollo existe. Ciérrala antes con: pantalla-hp off'
    }
    $hp = $script:Conf.HP_SSH
    if ((Invoke-SshHP -Interactivo 'true') -ne 0) {
        throw "No se llega a $hp por ssh. No se ha tocado nada."
    }
    # 1 es de sudo, no de ssh (255) ni del tope (124): ssh ha entrado, pero la
    # regla no permite la instancia. Es un HP con la versión anterior.
    $rc = Invoke-SshHP "sudo -n -l /usr/bin/systemctl start $($script:UHp)"
    if ($rc -eq 1) {
        throw "El sudo de $hp no permite arrancar $($script:UHp) sin contraseña. Si el HP tiene la versión anterior, ejecuta allí: sudo ./scripts/18_pantalla.sh. No se ha tocado nada."
    } elseif ($rc -ne 0) {
        throw "$hp no responde sin preguntas: comprueba con 'ssh-add -l' que la clave está en el agente de Windows. No se ha tocado nada."
    }
}

function Set-Modo {
    param([string]$Modo)
    if ($Modo -eq 'principal') {
        Invoke-DisplaySwitch 'external'
        $ok = Wait-Condicion -Plazo $script:PlazoModo -Condicion {
            $v = Get-Virtual
            (-not (Get-InternaActiva)) -and $null -ne $v -and $v.Principal
        }
        if (-not $ok) { throw 'La pantalla interna no se ha apagado: el modo principal no se ha aplicado.' }
        return
    }
    # Extender: dos escritorios, la virtual como principal porque es la que
    # transmite Apollo, y la interna a su izquierda.
    Invoke-DisplaySwitch 'extend'
    $ok = Wait-Condicion -Plazo $script:PlazoModo -Condicion {
        $v = Get-Virtual
        $null -ne (Get-InternaActiva) -and $null -ne $v -and $v.Activa
    }
    if (-not $ok) { throw 'Windows no ha extendido el escritorio a la pantalla virtual.' }
    $v = Get-Virtual; $i = Get-InternaActiva
    $ancho = if ($i.Ancho) { $i.Ancho } else { 1920 }
    [void](Set-Disposicion $v.Nombre $i.Nombre (-$ancho))
    $ok = Wait-Condicion -Plazo $script:PlazoModo -Condicion {
        $v = Get-Virtual; $i = Get-InternaActiva
        $null -ne $v -and $v.Principal -and $null -ne $i
    }
    if (-not $ok) { throw 'No se ha podido dejar la pantalla virtual como principal.' }
}

function Open-Sesion {
    param([string]$Modo)
    Test-Requisitos
    Escribir 'INFO' "Pidiendo la sesión al HP ($($script:UHp))."
    # La de Fedora se para por si quedó huérfana, y la propia porque 'start'
    # sobre una unidad activa no hace nada. Cada orden va aparte: sudo compara
    # la orden entera.
    $orden = "sudo -n systemctl stop $($script:UHpOtra) ; sudo -n systemctl stop $($script:UHp) ; sudo -n systemctl start $($script:UHp)"
    if ((Invoke-SshHP $orden) -ne 0) {
        [void](Close-Sesion)
        throw "$($script:Conf.HP_SSH) no ha arrancado $($script:UHp)."
    }
    if (-not (Wait-Condicion -Plazo $script:PlazoVirtual -Condicion { $null -ne (Get-Virtual) })) {
        [void](Close-Sesion)
        throw "Apollo no ha creado la pantalla virtual en $($script:PlazoVirtual) s. Comprueba que su aplicación Desktop tiene 'virtual-display' (preparar_windows.ps1) y el registro de Apollo."
    }
    try {
        Set-Modo $Modo
    } catch {
        Escribir 'ERROR' $_.Exception.Message
        [void](Close-Sesion)
        throw 'Se ha cerrado la sesión y restaurado la pantalla interna.'
    }
    Escribir 'OK' "Sesión '$Modo' en marcha. Se cierra con: pantalla-hp off"
}

# Deja el portátil como estaba, aunque el HP no conteste. Primero se pide al HP
# que pare, que es lo que hace a Apollo retirar la pantalla virtual; si no
# contesta, Apollo la retira solo al dejar de verlo. Después se fija la interna
# siempre: 'DisplaySwitch /internal' también recupera un modo principal.
function Close-Sesion {
    if ($script:Conf -and $script:Conf.HP_SSH) {
        $orden = "sudo -n systemctl stop $($script:UHp) ; sudo -n systemctl stop $($script:UHpOtra)"
        if ((Invoke-SshHP $orden) -ne 0) {
            Escribir 'AVISO' "$($script:Conf.HP_SSH) no ha respondido: su sesión se cierra sola al dejar de ver a Apollo."
        }
    } else {
        Escribir 'AVISO' 'Sin configuración: no se ha podido avisar al HP.'
    }
    [void](Wait-Condicion -Plazo $script:PlazoRetirada -Condicion { $null -eq (Get-Virtual) })
    Invoke-DisplaySwitch 'internal'
    if (Wait-Condicion -Plazo $script:PlazoModo -Condicion { Test-InternaRestaurada }) {
        Escribir 'OK' 'Pantalla interna activa y principal.'
        return $true
    }
    Escribir 'ERROR' "La pantalla interna no ha vuelto. Pulsa Win+P y elige 'Solo pantalla de PC'."
    return $false
}

function Get-Estado {
    Escribir 'INFO' "HP: $($script:Conf.HP_SSH). Este equipo: $($script:Conf.EMISOR_IP)."
    if (Test-IPLocal $script:Conf.EMISOR_IP) { Escribir 'OK' 'Tailscale: la IP está en este equipo.' }
    else { Escribir 'AVISO' 'Tailscale: este equipo no tiene la IP configurada.' }
    if (Test-Apollo) { Escribir 'OK' 'Apollo en marcha.' } else { Escribir 'AVISO' 'Apollo no está en marcha.' }
    foreach ($p in @(Get-Pantallas)) {
        $tipo = if ($p.Virtual) { 'virtual' } else { 'interna' }
        Escribir 'INFO' ("{0} ({1}): activa={2} principal={3} x={4}" -f $p.Nombre, $tipo, $p.Activa, $p.Principal, $p.X)
    }
    Escribir 'INFO' 'Sesiones en el HP (windows, fedora):'
    [void](Invoke-SshHP "systemctl is-active $($script:UHp) $($script:UHpOtra)")
    return 0
}

# El PIN lo escribe el usuario en la web de Apollo: su API de PIN pide la sesión
# de la web, y este script no maneja la contraseña de Apollo.
function Invoke-Vincular {
    if (-not (Test-IPLocal $script:Conf.EMISOR_IP)) { throw "Este equipo no tiene la IP $($script:Conf.EMISOR_IP): ¿Tailscale está conectado?" }
    if (-not (Test-Apollo)) { throw 'Apollo no está en marcha (servicio ApolloService).' }
    if (Get-Virtual) { throw 'Hay una sesión activa. Ciérrala antes con: pantalla-hp off' }
    $pin = '{0:D4}' -f (Get-Random -Minimum 0 -Maximum 10000)
    Escribir 'INFO' 'Te pedirá la contraseña de sudo del HP.'
    $rc = Invoke-SshHP -Interactivo "sudo systemctl start --no-block nomad-pantalla-vincular@windows-$pin.service"
    if ($rc -ne 0) { throw 'El HP no ha arrancado la unidad de vínculo.' }
    Start-Navegador $script:UrlPin
    Escribir 'OK' "En la web de Apollo, pestaña 'PIN Pairing', escribe el PIN $pin y pulsa Send. Tienes 90 s."
    return 0
}

function Show-Ayuda {
    Escribir 'USO' @'
Uso: pantalla-hp <orden>

  extender    el HP es un segundo monitor, a la derecha de la pantalla interna
  principal   el HP es la única pantalla: la interna se apaga
  off         cierra la sesión y deja la pantalla interna activa
  estado      muestra Tailscale, Apollo, las pantallas y las sesiones del HP
  vincular    vincula el HP con Apollo (una vez): pide la contraseña de sudo
              del HP y el PIN se escribe en la web de Apollo
  --help      esta ayuda

Configuración: %LOCALAPPDATA%\nomad-pantalla\pantalla-hp.conf
'@
}

# Devuelve el código de salida: 0 bien, 1 error, 2 uso incorrecto.
function Invoke-PantallaHP {
    param([string]$Orden)
    switch ($Orden) {
        { $_ -in '-h', '--help', '/?', 'ayuda' } { Show-Ayuda; return 0 }
        { $_ -in 'extender', 'principal', 'off', 'estado', 'vincular' } { break }
        '' { Escribir 'ERROR' 'Falta la orden.'; Show-Ayuda; return 2 }
        default { Escribir 'ERROR' "Orden desconocida: $Orden"; Show-Ayuda; return 2 }
    }
    try {
        $script:Conf = Read-Conf
    } catch {
        if ($Orden -ne 'off') { Escribir 'ERROR' $_.Exception.Message; return 1 }
        Escribir 'AVISO' $_.Exception.Message
        $script:Conf = $null
    }
    try {
        switch ($Orden) {
            'off'      { if (Close-Sesion) { return 0 } else { return 1 } }
            'estado'   { return (Get-Estado) }
            'vincular' { return (Invoke-Vincular) }
            default    { Open-Sesion $Orden; return 0 }
        }
    } catch {
        Escribir 'ERROR' $_.Exception.Message
        return 1
    }
}

if ($script:Argumentos -contains '-Biblioteca') { return }

$orden = if ($script:Argumentos.Count -gt 0) { [string]$script:Argumentos[0] } else { '' }
exit (Invoke-PantallaHP $orden)
