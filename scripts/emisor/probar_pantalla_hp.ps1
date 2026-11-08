# ===========================================================================
#  nomad_server — pruebas de pantalla-hp.ps1 con dobles
# ===========================================================================
#  Propósito : comprobar el ORDEN de las llamadas de pantalla-hp.ps1 en Windows
#              y el estado en que deja las pantallas, sin tocar las reales.
#  Uso       : powershell.exe -NoProfile -ExecutionPolicy Bypass -File probar_pantalla_hp.ps1
#              Desde WSL:
#              powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w scripts/emisor/probar_pantalla_hp.ps1)"
#  Capítulo  : docs/18_pantalla_extendida.md
#
#  pantalla-hp.ps1 se carga con -Biblioteca: define sus funciones y no ejecuta
#  nada. Después, este archivo sustituye las de bajo nivel (ssh, pantallas,
#  DisplaySwitch, red, Apollo, esperas) por dobles que anotan cada llamada y
#  simulan Windows y el HP. Las de la lógica son las reales.
#
#  El doble de pantallas imita lo medido en la Tarea 2: la virtual aparece al
#  arrancar la sesión en el HP y desaparece al pararla, y Windows vuelve solo a
#  la interna como principal.
#
#  Termina con 0 si todas pasan.
# ===========================================================================
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$Script = Join-Path $PSScriptRoot 'pantalla-hp.ps1'
. $Script -Biblioteca

$script:S = $null

function Initialize-Sim {
    $script:S = @{
        Llamadas         = New-Object System.Collections.Generic.List[string]
        Salida           = New-Object System.Collections.Generic.List[string]
        Pantallas        = New-Object System.Collections.Generic.List[object]
        VirtualAlArrancar = $true
        SshFalla         = $false
        SudoRechaza      = $false
        IP               = $true
        Apollo           = $true
        InternaRebelde   = $false
        Esperas          = 0
    }
    $script:S.Pantallas.Add([pscustomobject]@{
        Nombre = '\\.\DISPLAY1'; Virtual = $false; Activa = $true; Principal = $true; X = 0; Ancho = 1920 })
    $script:Fallos = New-Object System.Collections.Generic.List[string]
}

function Get-Virtual { @($script:S.Pantallas | Where-Object { $_.Virtual }) | Select-Object -First 1 }
function Get-Interna { @($script:S.Pantallas | Where-Object { -not $_.Virtual }) | Select-Object -First 1 }

function Add-VirtualSim {
    $script:S.Pantallas.Add([pscustomobject]@{
        Nombre = '\\.\DISPLAY5'; Virtual = $true; Activa = $true; Principal = $false; X = 1920; Ancho = 1920 })
}

# La sesión ya montada en modo principal: la interna apagada y la virtual sola.
function Set-SesionMontada {
    Add-VirtualSim
    $v = Get-Virtual; $v.Principal = $true; $v.X = 0
    $i = Get-Interna; $i.Activa = $false; $i.Principal = $false
}

# Como Windows al retirar Apollo la pantalla virtual: la interna vuelve sola.
function Remove-VirtualSim {
    $v = Get-Virtual
    if ($v) { [void]$script:S.Pantallas.Remove($v) }
    $i = Get-Interna; $i.Activa = $true; $i.Principal = $true; $i.X = 0
}

# ---------------------------------------------------------------------------
#  Dobles
# ---------------------------------------------------------------------------

function Read-Conf { @{ HP_SSH = 'hp-prueba'; EMISOR_IP = '100.64.0.8' } }

function Escribir { param([string]$Nivel, [string]$Texto) $script:S.Salida.Add("[$Nivel] $Texto") }

function Invoke-SshHP {
    param([string]$Orden, [switch]$Interactivo)
    $tipo = if ($Interactivo) { 'ssh-t' } else { 'ssh' }
    $script:S.Llamadas.Add("$tipo $Orden")
    if ($script:S.SshFalla) { return 255 }
    if ($script:S.SudoRechaza -and $Orden -like 'sudo -n -l*') { return 1 }
    if ($Orden -like '*systemctl is-active*') {
        if (Get-Virtual) { return 0 } else { return 3 }
    }
    if ($Orden -like '*stop nomad-pantalla@windows.service*') { Remove-VirtualSim }
    if ($Orden -like '*start nomad-pantalla@windows.service*' -and $script:S.VirtualAlArrancar) { Add-VirtualSim }
    return 0
}

function Get-Pantallas { $script:S.Pantallas.ToArray() }

function Invoke-DisplaySwitch {
    param([string]$Modo)
    $script:S.Llamadas.Add("displayswitch $Modo")
    $v = Get-Virtual; $i = Get-Interna
    switch ($Modo) {
        'extend'   { $i.Activa = $true; if ($v) { $v.Activa = $true } }
        'external' {
            if ($v) { $v.Activa = $true; $v.Principal = $true; $v.X = 0 }
            if (-not $script:S.InternaRebelde) { $i.Activa = $false; $i.Principal = $false }
        }
        'internal' {
            if ($v) { $v.Activa = $false; $v.Principal = $false }
            $i.Activa = $true; $i.Principal = $true; $i.X = 0
        }
    }
}

function Set-Disposicion {
    param([string]$Principal, [string]$Otra, [int]$XOtra)
    $script:S.Llamadas.Add("disposicion $Principal $Otra $XOtra")
    foreach ($p in $script:S.Pantallas) {
        if ($p.Nombre -eq $Principal) { $p.Principal = $true; $p.X = 0 }
        elseif ($p.Nombre -eq $Otra) { $p.Principal = $false; $p.X = $XOtra }
    }
    return $true
}

function Test-IPLocal { param([string]$IP) $script:S.Llamadas.Add("ip $IP"); $script:S.IP }
function Test-Apollo { $script:S.Apollo }
function Wait-Segundos { param([double]$Segundos) $script:S.Esperas++ }
function Start-Navegador { param([string]$Url) $script:S.Llamadas.Add("navegador $Url") }

# ---------------------------------------------------------------------------
#  Comprobaciones
# ---------------------------------------------------------------------------

function Fallar { param([string]$Texto) $script:Fallos.Add($Texto) }

function Linea { param([string]$Texto)
    for ($n = 0; $n -lt $script:S.Llamadas.Count; $n++) {
        if ($script:S.Llamadas[$n].Contains($Texto)) { return $n + 1 }
    }
    return 0
}
function Hay { param([string]$T) if ((Linea $T) -eq 0) { Fallar "falta la llamada: $T" } }
function NoHay { param([string]$T) if ((Linea $T) -ne 0) { Fallar "no debía haber: $T" } }
function Antes { param([string]$A, [string]$B)
    $a = Linea $A; $b = Linea $B
    if ($a -eq 0 -or $b -eq 0 -or $a -ge $b) { Fallar "'$A' (línea $a) debe ir antes que '$B' (línea $b)" }
}
function Dice { param([string]$T)
    if (-not (($script:S.Salida -join "`n").Contains($T))) { Fallar "la salida no dice: $T" }
}
function RcEs { param($Rc, [int]$Esperado) if ($Rc -ne $Esperado) { Fallar "código de salida $Rc, se esperaba $Esperado" } }
function RcNoCero { param($Rc) if ($Rc -eq 0) { Fallar 'debía terminar con error y terminó con 0' } }

function InternaRestaurada {
    $i = Get-Interna
    if (-not $i.Activa -or -not $i.Principal) { Fallar "la interna no está activa y principal (activa=$($i.Activa) principal=$($i.Principal))" }
}
function PantallasIntactas {
    NoHay 'displayswitch'
    NoHay 'disposicion'
    NoHay 'sudo -n systemctl start nomad-pantalla@windows.service'
}

$ORDEN_ARRANQUE = 'sudo -n systemctl stop nomad-pantalla@fedora.service ; sudo -n systemctl stop nomad-pantalla@windows.service ; sudo -n systemctl start nomad-pantalla@windows.service'

# ---------------------------------------------------------------------------
#  Arranque
# ---------------------------------------------------------------------------

function Prueba-ExtenderParaLasDosInstanciasYArrancaWindows {
    $rc = Invoke-PantallaHP 'extender'
    RcEs $rc 0
    Hay "ssh $ORDEN_ARRANQUE"
    $v = Get-Virtual; $i = Get-Interna
    if (-not $v) { Fallar 'no hay pantalla virtual'; return }
    if (-not $v.Principal -or $v.X -ne 0) { Fallar "la virtual no es la principal en 0: principal=$($v.Principal) x=$($v.X)" }
    if (-not $i.Activa -or $i.X -ne -1920) { Fallar "la interna no está a la izquierda: activa=$($i.Activa) x=$($i.X)" }
}

function Prueba-ExtenderAplicaElModoSiempre {
    # Windows recuerda disposiciones, pero no se confía en ello.
    $rc = Invoke-PantallaHP 'extender'
    RcEs $rc 0
    Antes "ssh $ORDEN_ARRANQUE" 'displayswitch extend'
    Antes 'displayswitch extend' 'disposicion \\.\DISPLAY5 \\.\DISPLAY1 -1920'
}

function Prueba-PrincipalApagaLaInternaYLoConfirma {
    $rc = Invoke-PantallaHP 'principal'
    RcEs $rc 0
    Antes "ssh $ORDEN_ARRANQUE" 'displayswitch external'
    $i = Get-Interna
    if ($i.Activa) { Fallar 'la interna sigue encendida' }
    if (-not (Get-Virtual).Principal) { Fallar 'la virtual no es la principal' }
}

function Prueba-PrincipalConInternaQueNoSeApagaRestaura {
    $script:S.InternaRebelde = $true
    $rc = Invoke-PantallaHP 'principal'
    RcNoCero $rc
    Hay 'stop nomad-pantalla@windows.service'
    Antes 'displayswitch external' 'displayswitch internal'
    InternaRestaurada
    Dice 'interna'
}

function Prueba-VirtualQueNoApareceRestauraYFalla {
    $script:S.VirtualAlArrancar = $false
    $rc = Invoke-PantallaHP 'extender'
    RcNoCero $rc
    NoHay 'displayswitch extend'
    NoHay 'disposicion'
    Antes "ssh $ORDEN_ARRANQUE" 'ssh sudo -n systemctl stop nomad-pantalla@windows.service'
    InternaRestaurada
    Dice 'Apollo'
}

function Prueba-SinIPDeTailscaleNoTocaNada {
    $script:S.IP = $false
    $rc = Invoke-PantallaHP 'extender'
    RcNoCero $rc
    Hay 'ip 100.64.0.8'
    NoHay 'ssh'
    PantallasIntactas
    Dice 'Tailscale'
}

function Prueba-ApolloParadoNoTocaNada {
    $script:S.Apollo = $false
    $rc = Invoke-PantallaHP 'extender'
    RcNoCero $rc
    PantallasIntactas
    Dice 'Apollo'
}

function Prueba-HPInaccesibleAntesDeEmpezarNoTocaNada {
    $script:S.SshFalla = $true
    $rc = Invoke-PantallaHP 'extender'
    RcNoCero $rc
    PantallasIntactas
    Dice 'hp-prueba'
}

function Prueba-SudoersAntiguoPideEjecutar18Pantalla {
    $script:S.SudoRechaza = $true
    $rc = Invoke-PantallaHP 'principal'
    RcNoCero $rc
    Hay 'ssh sudo -n -l /usr/bin/systemctl start nomad-pantalla@windows.service'
    Dice '18_pantalla.sh'
    PantallasIntactas
}

function Prueba-ComprobacionesAntesDeArrancar {
    $rc = Invoke-PantallaHP 'extender'
    RcEs $rc 0
    Antes 'ip 100.64.0.8' 'ssh sudo -n -l'
    Antes 'ssh sudo -n -l' "ssh $ORDEN_ARRANQUE"
}

# La lista real de Windows sin sesión (2026-11-07): la interna, tres salidas
# fantasma de Intel y diez del adaptador de Apollo, todas sin monitor. Con
# sesión, DISPLAY5 tiene monitor.
function New-ListaReal {
    param([switch]$ConSesion)
    $lista = @([pscustomobject]@{ Nombre = '\\.\DISPLAY1'; Adaptador = 'Intel(R) Iris(R) Xe Graphics'; Activa = $true; Principal = $true; TieneMonitor = $true; X = 0; Ancho = 1920 })
    foreach ($n in 2..4) {
        $lista += [pscustomobject]@{ Nombre = "\\.\DISPLAY$n"; Adaptador = 'Intel(R) Iris(R) Xe Graphics'; Activa = $false; Principal = $false; TieneMonitor = $false; X = 0; Ancho = 0 }
    }
    foreach ($n in 5..14) {
        $monitor = $ConSesion -and $n -eq 5
        $lista += [pscustomobject]@{ Nombre = "\\.\DISPLAY$n"; Adaptador = 'SudoMaker Virtual Display Adapter'; Activa = $monitor; Principal = $false; TieneMonitor = $monitor; X = 1920; Ancho = 1920 }
    }
    return $lista
}

function Prueba-SalidasFantasmaDeApolloNoSonUnaSesion {
    $p = @(ConvertTo-Pantallas (New-ListaReal))
    if ($p.Count -ne 1) { Fallar "se esperaba solo la interna, hay $($p.Count): $(($p | ForEach-Object { $_.Nombre }) -join ' ')"; return }
    if ($p[0].Virtual) { Fallar 'la interna sale como virtual' }
}

function Prueba-LaVirtualConMonitorSiEsUnaSesion {
    $p = @(ConvertTo-Pantallas (New-ListaReal -ConSesion))
    $v = @($p | Where-Object { $_.Virtual })
    if ($v.Count -ne 1 -or $v[0].Nombre -ne '\\.\DISPLAY5') { Fallar "virtual inesperada: $(($v | ForEach-Object { $_.Nombre }) -join ' ')" }
}

function Prueba-SesionActivaSeRechaza {
    Set-SesionMontada
    $rc = Invoke-PantallaHP 'extender'
    RcNoCero $rc
    NoHay 'sudo -n systemctl start nomad-pantalla@windows.service'
    NoHay 'displayswitch'
    Dice 'pantalla-hp off'
}

# ---------------------------------------------------------------------------
#  Parada
# ---------------------------------------------------------------------------

function Prueba-OffParaLasDosInstanciasYRestaura {
    Set-SesionMontada
    $rc = Invoke-PantallaHP 'off'
    RcEs $rc 0
    Hay 'ssh sudo -n systemctl stop nomad-pantalla@windows.service ; sudo -n systemctl stop nomad-pantalla@fedora.service'
    InternaRestaurada
    if (Get-Virtual) {
        if ((Get-Virtual).Activa) { Fallar 'la virtual sigue activa' }
    }
}

function Prueba-OffRestauraAunqueElSshFalle {
    Set-SesionMontada
    $script:S.SshFalla = $true
    $rc = Invoke-PantallaHP 'off'
    RcEs $rc 0
    Hay 'displayswitch internal'
    InternaRestaurada
    Dice 'hp-prueba'
}

function Prueba-OffSinSesionNoFalla {
    $rc = Invoke-PantallaHP 'off'
    RcEs $rc 0
    InternaRestaurada
}

function Prueba-OffNoEsperaSinFin {
    # La virtual no se va sola: tras el plazo se fuerza la interna igualmente.
    Set-SesionMontada
    $script:S.SshFalla = $true
    $rc = Invoke-PantallaHP 'off'
    RcEs $rc 0
    if ($script:S.Esperas -gt 60) { Fallar "esperó $($script:S.Esperas) veces" }
    InternaRestaurada
}

# ---------------------------------------------------------------------------
#  Estado, vínculo y argumentos
# ---------------------------------------------------------------------------

function Prueba-EstadoNoTocaPantallas {
    $rc = Invoke-PantallaHP 'estado'
    RcEs $rc 0
    PantallasIntactas
    NoHay 'systemctl stop'
}

function Prueba-VincularLanzaLaUnidadYAbreLaWeb {
    $rc = Invoke-PantallaHP 'vincular'
    RcEs $rc 0
    $linea = @($script:S.Llamadas | Where-Object { $_ -like 'ssh-t *vincular@*' }) | Select-Object -First 1
    if (-not $linea) { Fallar 'no lanzó la unidad de vínculo con ssh -t'; return }
    if ($linea -notmatch 'nomad-pantalla-vincular@windows-(\d{4})\.service') { Fallar "vínculo inesperado: $linea"; return }
    $pin = $Matches[1]
    Hay 'navegador https://localhost:47990/pin'
    Dice $pin
}

function Prueba-VincularConSesionActivaSeRechaza {
    Set-SesionMontada
    $rc = Invoke-PantallaHP 'vincular'
    RcNoCero $rc
    NoHay 'vincular@'
}

function Prueba-ArgumentoDesconocidoMuestraAyudaYSaleCon2 {
    $rc = Invoke-PantallaHP 'apagar'
    RcEs $rc 2
    Dice 'Uso'
    PantallasIntactas
    NoHay 'ssh'
}

function Prueba-SinArgumentoMuestraAyudaYSaleCon2 {
    $rc = Invoke-PantallaHP ''
    RcEs $rc 2
    Dice 'Uso'
}

function Prueba-AyudaSaleCon0 {
    $rc = Invoke-PantallaHP '--help'
    RcEs $rc 0
    Dice 'Uso'
}

function Prueba-SshSinPreguntasEnElCodigo {
    $texto = Get-Content -Raw -Encoding UTF8 $Script
    if (-not $texto.Contains('BatchMode=yes')) { Fallar 'el ssh no usa BatchMode' }
    if (-not $texto.Contains('ConnectTimeout=5')) { Fallar 'el ssh no usa ConnectTimeout=5' }
}

function Prueba-ArchivosConBOM {
    foreach ($f in @($Script, (Join-Path $PSScriptRoot 'preparar_windows.ps1'), $PSCommandPath)) {
        if (-not (Test-Path $f)) { Fallar "no existe $f"; continue }
        $b = [System.IO.File]::ReadAllBytes($f)
        if ($b.Length -lt 3 -or $b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF) { Fallar "$f no empieza por BOM" }
    }
}

# ---------------------------------------------------------------------------
#  Ejecución
# ---------------------------------------------------------------------------

$pasan = 0; $fallan = 0; $nombres = @()
$pruebas = Get-ChildItem function: | Where-Object { $_.Name -like 'Prueba-*' } | Sort-Object Name
foreach ($p in $pruebas) {
    Initialize-Sim
    Write-Output "- $($p.Name)"
    try { & $p.Name } catch { Fallar "la prueba ha terminado con error: $($_.Exception.Message)" }
    if ($script:Fallos.Count -eq 0) {
        $pasan++
    } else {
        $fallan++; $nombres += $p.Name
        foreach ($f in $script:Fallos) { Write-Output "    FALLA: $f" }
        foreach ($l in @($script:S.Salida | Select-Object -Last 4)) { Write-Output "      | $l" }
    }
}
Write-Output ''
Write-Output "Pasan: $pasan. Fallan: $fallan."
if ($fallan -gt 0) {
    foreach ($n in $nombres) { Write-Output "  $n" }
    exit 1
}
exit 0
