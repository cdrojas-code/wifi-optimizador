#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnostica y optimiza la conexión WiFi en Windows 10/11.

.DESCRIPTION
    Diagnosticar : solo lectura. Revisa adaptadores, drivers, señal, banda, interferencia,
                   pérdida de paquetes, DNS, desconexiones y ahorro de energía. Genera un reporte HTML.
    Optimizar    : guarda un respaldo y aplica (con confirmación) las mejoras detectadas.
                   Requiere administrador; se auto-eleva con UAC.
    Restaurar    : vuelve a la configuración guardada en un respaldo.

.EXAMPLE
    .\WifiOptimizador.ps1                              # menú interactivo
    .\WifiOptimizador.ps1 -Modo Diagnosticar           # solo lectura + reporte
    .\WifiOptimizador.ps1 -Modo Optimizar -Simular     # muestra qué cambiaría, sin tocar nada
    .\WifiOptimizador.ps1 -Modo Optimizar              # aplica mejoras pidiendo confirmación
    .\WifiOptimizador.ps1 -Modo Restaurar              # revierte con el último respaldo
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Diagnosticar', 'Optimizar', 'Restaurar')]
    [string]$Modo = 'Menu',
    [string]$Adaptador,      # limita a un adaptador (nombre o parte del modelo)
    [switch]$SinDrivers,     # no busca ni instala drivers por Windows Update
    [switch]$Forzar,         # responde "sí" a todas las preguntas
    [switch]$Simular,        # muestra los cambios sin aplicarlos
    [string]$Respaldo,       # archivo de respaldo concreto para Restaurar
    [switch]$Pausa           # espera Enter al terminar (uso interno al auto-elevar)
)

$ErrorActionPreference = 'Continue'
$Version = '1.0.0'
$RutaScript = $PSCommandPath
$Raiz = Split-Path -Parent $RutaScript
$DirReportes = Join-Path $Raiz 'reportes'
$DirRespaldos = Join-Path $Raiz 'respaldos'
$DirLogs = Join-Path $Raiz 'logs'
foreach ($d in $DirReportes, $DirRespaldos, $DirLogs) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

$ClaseRed = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'

$EnergiaWifi = [pscustomobject]@{
    Nombre = 'Ahorro de energía del adaptador inalámbrico'
    Accion = 'Poner el adaptador inalámbrico en "Rendimiento máximo" en el plan de energía (con corriente y con batería)'
    Sub    = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'
    Set    = '12bbebe6-58d6-4636-95bb-3217ef867c1a'
}
$EnergiaUsb = [pscustomobject]@{
    Nombre = 'Suspensión selectiva USB'
    Accion = 'Desactivar la suspensión selectiva USB (evita que se apague el adaptador WiFi USB)'
    Sub    = '2a737441-1930-4402-8d77-b2bebba308a3'
    Set    = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
}

# Ajustes avanzados del driver. Se buscan por palabra clave del registro y, si no existe,
# por nombre visible (ES/EN). El valor objetivo se elige por el texto visible.
$AjustesAvanzados = @(
    [pscustomobject]@{
        Id = 'Itinerancia'; Descripcion = 'Agresividad de itinerancia al mínimo'
        Motivo = 'evita que la tarjeta salte entre puntos de acceso y corte la conexión'
        Claves = @('RoamAggressiveness', '*RoamAggressiveness', 'RoamingAggressiveness')
        Nombre = 'itineran|roam.*aggress'; Valor = '^\s*1\.|m[ií]nim|lowest'
    },
    [pscustomobject]@{
        Id = 'Ancho24'; Descripcion = 'Ancho de canal de 2,4 GHz en 20 MHz'
        Motivo = 'reduce interferencias en la banda de 2,4 GHz, que suele estar saturada'
        Claves = @('ChannelWidth24')
        Nombre = '(ancho|width).*2[,.]4|2[,.]4.*(ancho|width)'; Valor = '^\s*20\s*MHz'
    },
    [pscustomobject]@{
        Id = 'MIMO'; Descripcion = 'Ahorro de energía MIMO desactivado'
        Motivo = 'evita que la tarjeta apague antenas para ahorrar energía'
        Claves = @('MIMOPowerSaveMode')
        Nombre = 'MIMO'; Valor = 'No SMPS|sin SMPS'
    },
    [pscustomobject]@{
        Id = 'Banda'; Descripcion = 'Banda preferida: 5 GHz'
        Motivo = 'tu red está disponible en 5 GHz con buena señal: menos interferencia y más velocidad'
        Claves = @('RoamingPreferredBandType', 'PreferBand')
        Nombre = 'banda preferida|preferred band'; Valor = '5\s*GHz'
    }
)

$script:Hallazgos = New-Object System.Collections.Generic.List[object]
$script:DriversPendientes = @()
$script:WuSession = $null

# ---------------------------------------------------------------- utilidades

function Write-Titulo([string]$Texto) { Write-Host ''; Write-Host "== $Texto ==" -ForegroundColor Cyan }
function Write-Bien([string]$Texto) { Write-Host "  [OK] $Texto" -ForegroundColor Green }
function Write-Alerta([string]$Texto) { Write-Host "  [!]  $Texto" -ForegroundColor Yellow }
function Write-Fallo([string]$Texto) { Write-Host "  [X]  $Texto" -ForegroundColor Red }
function Write-Dato([string]$Texto) { Write-Host "       $Texto" -ForegroundColor Gray }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Confirm-Accion([string]$Pregunta) {
    if ($Forzar) { return $true }
    $r = Read-Host "  $Pregunta [S/n]"
    return ("$r" -notmatch '^\s*n')
}

function Start-Elevado([string]$ModoDestino) {
    $argumentos = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$RutaScript`"", '-Modo', $ModoDestino, '-Pausa')
    if ($Adaptador) { $argumentos += @('-Adaptador', "`"$Adaptador`"") }
    if ($SinDrivers) { $argumentos += '-SinDrivers' }
    if ($Forzar) { $argumentos += '-Forzar' }
    if ($Respaldo) { $argumentos += @('-Respaldo', "`"$Respaldo`"") }
    Write-Alerta 'Se necesitan permisos de administrador. Windows va a pedir autorización (UAC).'
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $argumentos -ErrorAction Stop
        Write-Bien 'Se abrió una ventana de administrador para continuar.'
    } catch {
        Write-Fallo 'No se concedieron los permisos de administrador. No se hizo ningún cambio.'
    }
}

# Ejecuta un cambio (o solo lo muestra en modo -Simular).
function Invoke-Cambio([string]$Texto, [scriptblock]$Accion) {
    if ($Simular) { Write-Host "  [SIM] $Texto" -ForegroundColor Magenta; return $true }
    try {
        & $Accion | Out-Null
        Write-Bien $Texto
        return $true
    } catch {
        Write-Fallo "${Texto}: $($_.Exception.Message)"
        return $false
    }
}

function Add-Hallazgo([string]$Nivel, [string]$Tema, [string]$Detalle, [string]$Recomendacion = '') {
    $script:Hallazgos.Add([pscustomobject]@{
            Nivel = $Nivel; Tema = $Tema; Detalle = $Detalle; 'Recomendación' = $Recomendacion
        })
    switch ($Nivel) {
        'Crítico' { Write-Fallo "${Tema}: $Detalle" }
        'Advertencia' { Write-Alerta "${Tema}: $Detalle" }
        'OK' { Write-Bien "${Tema}: $Detalle" }
        default { Write-Dato "${Tema}: $Detalle" }
    }
}

# ---------------------------------------------------------------- lectura del sistema

function Get-AdaptadoresWifi {
    $lista = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
            ($_.NdisPhysicalMedium -eq 9 -or $_.InterfaceDescription -match 'Wireless|Wi-?Fi|WLAN|802\.11') -and
            $_.InterfaceDescription -notmatch 'Virtual|Direct|Bluetooth'
        })
    if ($Adaptador) {
        $lista = @($lista | Where-Object { $_.Name -like $Adaptador -or $_.InterfaceDescription -like "*$Adaptador*" })
    }
    return , $lista
}

function Get-DescripcionBase([string]$Descripcion) { ($Descripcion -replace '\s*#\d+$', '').Trim() }

function Get-EstadoWlan {
    $salida = (netsh wlan show interfaces) | Out-String
    $bloqueado = ($salida -match 'ubicaci|location') -and ($salida -match 'denegado|denied|error 5|elevaci|elevation')
    $interfaces = New-Object System.Collections.Generic.List[object]
    $actual = $null
    foreach ($linea in ($salida -split "`r?`n")) {
        if ($linea -notmatch '^\s*([^:]+?)\s*:\s*(.*?)\s*$') { continue }
        $k = $Matches[1].Trim(); $v = $Matches[2].Trim()
        if ($k -match '^(Nombre|Name)$') {
            $actual = [pscustomobject]@{ Nombre = $v; Descripcion = ''; Estado = ''; SSID = ''; BSSID = ''; Banda = ''; Canal = ''; Radio = ''; Senal = 0; Rx = ''; Tx = '' }
            $interfaces.Add($actual)
            continue
        }
        if (-not $actual) { continue }
        switch -Regex ($k) {
            '^(Descripci|Description)' { $actual.Descripcion = $v }
            '^(Estado|State)$' { $actual.Estado = $v }
            '^SSID$' { $actual.SSID = $v }
            'BSSID' { $actual.BSSID = $v }
            '^(Banda|Band)$' { $actual.Banda = $v }
            '^(Canal|Channel)$' { $actual.Canal = $v }
            '^(Tipo de radio|Radio type)$' { $actual.Radio = $v }
            '^(Se.{1,2}al|Signal)$' { $actual.Senal = [int]("0" + ($v -replace '[^\d]', '')) }
            '^(Velocidad de recep|Receive rate)' { $actual.Rx = $v }
            '^(Velocidad de trans|Transmit rate)' { $actual.Tx = $v }
        }
    }
    [pscustomobject]@{ Bloqueado = $bloqueado; Interfaces = $interfaces.ToArray() }
}

function Get-RedesCercanas {
    $salida = netsh wlan show networks mode=bssid
    $redes = New-Object System.Collections.Generic.List[object]
    $ssid = ''; $actual = $null
    foreach ($linea in $salida) {
        if ($linea -match '^\s*SSID\s+\d+\s*:\s*(.*)$') { $ssid = $Matches[1].Trim(); continue }
        if ($linea -match '^\s*BSSID\s+\d+\s*:\s*(.*)$') {
            $actual = [pscustomobject]@{ SSID = $ssid; BSSID = $Matches[1].Trim(); Senal = 0; Banda = ''; Canal = 0; Radio = '' }
            $redes.Add($actual)
            continue
        }
        if (-not $actual) { continue }
        if ($linea -match '^\s*(Se.{1,2}al|Signal)\s*:\s*(\d+)') { $actual.Senal = [int]$Matches[2] }
        elseif ($linea -match '^\s*(Banda|Band)\s*:\s*(.+)$') { $actual.Banda = $Matches[2].Trim() }
        elseif ($linea -match '^\s*(Canal|Channel)\s*:\s*(\d+)') { $actual.Canal = [int]$Matches[2] }
        elseif ($linea -match '^\s*(Tipo de radio|Radio type)\s*:\s*(.+)$') { $actual.Radio = $Matches[2].Trim() }
    }
    return , $redes.ToArray()
}

function Get-TipoBanda([string]$Texto, [int]$Canal) {
    if ($Texto -match '^\s*2') { return '2.4' }
    if ($Texto -match '^\s*5') { return '5' }
    if ($Texto -match '^\s*6') { return '6' }
    if ($Canal -ge 1 -and $Canal -le 14) { return '2.4' }
    return '5'
}

function Get-MejorCanal24($Redes, [string]$PropioSSID) {
    $mejor = 1; $menor = [double]::MaxValue
    foreach ($ch in 1, 6, 11) {
        $carga = ($Redes | Where-Object {
                $_.SSID -ne $PropioSSID -and (Get-TipoBanda $_.Banda $_.Canal) -eq '2.4' -and [math]::Abs($_.Canal - $ch) -le 4
            } | Measure-Object -Property Senal -Sum).Sum
        if (-not $carga) { $carga = 0 }
        if ($carga -lt $menor) { $menor = $carga; $mejor = $ch }
    }
    return $mejor
}

function Test-Ping([string]$Destino, [int]$Cantidad, [string]$Nombre) {
    $r = @(Test-Connection -ComputerName $Destino -Count $Cantidad -ErrorAction SilentlyContinue)
    $ok = $r.Count
    $min = $null; $med = $null; $max = $null
    if ($ok -gt 0) {
        $m = $r | Measure-Object -Property ResponseTime -Minimum -Maximum -Average
        $min = $m.Minimum; $max = $m.Maximum; $med = [math]::Round($m.Average, 1)
    }
    [pscustomobject]@{
        Prueba = $Nombre; Destino = $Destino; Enviados = $Cantidad; Recibidos = $ok
        Perdida = [math]::Round(100 * ($Cantidad - $ok) / $Cantidad, 1); Min = $min; Media = $med; Max = $max
    }
}

function Get-DatoEvento($Datos, [string]$Nombre) {
    ($Datos | Where-Object { $_.Name -eq $Nombre } | Select-Object -First 1).'#text'
}

function Get-Desconexiones([int]$Horas = 24) {
    try {
        $eventos = Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-WLAN-AutoConfig/Operational'; Id = 8003; StartTime = (Get-Date).AddHours(-$Horas)
        } -ErrorAction Stop
    } catch { return , @() }
    $lista = foreach ($e in $eventos) {
        $datos = ([xml]$e.ToXml()).Event.EventData.Data
        [pscustomobject]@{
            Fecha     = $e.TimeCreated
            Adaptador = Get-DatoEvento $datos 'InterfaceDescription'
            SSID      = Get-DatoEvento $datos 'SSID'
            Motivo    = Get-DatoEvento $datos 'Reason'
        }
    }
    return , @($lista)
}

function Get-ClaveRegistroAdaptador($Nic) {
    Get-ChildItem $ClaseRed -ErrorAction SilentlyContinue | Where-Object {
        (Get-ItemProperty $_.PSPath -Name NetCfgInstanceId -ErrorAction SilentlyContinue).NetCfgInstanceId -eq $Nic.InterfaceGuid
    } | Select-Object -First 1
}

function Get-PnPCapabilities($Nic) {
    $clave = Get-ClaveRegistroAdaptador $Nic
    if (-not $clave) { return $null }
    (Get-ItemProperty $clave.PSPath -Name PnPCapabilities -ErrorAction SilentlyContinue).PnPCapabilities
}

function Get-ValorEnergia($Cfg) {
    $out = powercfg /query SCHEME_CURRENT $Cfg.Sub $Cfg.Set
    $hex = @($out | Select-String ':\s*0x([0-9a-fA-F]+)\s*$' | ForEach-Object {
            [Convert]::ToInt32($_.Matches[0].Groups[1].Value, 16)
        })
    if ($hex.Count -ge 2) { return [pscustomobject]@{ AC = $hex[0]; DC = $hex[1] } }
    return $null
}

function Get-TextoEnergiaWifi([int]$Valor) {
    switch ($Valor) { 0 { 'rendimiento máximo' } 1 { 'ahorro bajo' } 2 { 'ahorro medio' } 3 { 'ahorro máximo' } default { "valor $Valor" } }
}

function Find-PropiedadAvanzada($Ajuste, $Props) {
    $p = $Props | Where-Object { $Ajuste.Claves -contains $_.RegistryKeyword } | Select-Object -First 1
    if (-not $p) { $p = $Props | Where-Object { $_.DisplayName -and $_.DisplayName -match $Ajuste.Nombre } | Select-Object -First 1 }
    if (-not $p -or -not $p.ValidDisplayValues) { return $null }
    $idx = -1
    for ($i = 0; $i -lt $p.ValidDisplayValues.Count; $i++) {
        if ($p.ValidDisplayValues[$i] -match $Ajuste.Valor) { $idx = $i; break }
    }
    if ($idx -lt 0) { return $null }
    [pscustomobject]@{
        Keyword = $p.RegistryKeyword
        Actual = ($p.RegistryValue -join ','); ActualTexto = $p.DisplayValue
        Objetivo = [string]$p.ValidRegistryValues[$idx]; ObjetivoTexto = $p.ValidDisplayValues[$idx]
    }
}

function Get-DriversPendientes($Nics) {
    try {
        $script:WuSession = New-Object -ComObject Microsoft.Update.Session
        $resultado = $script:WuSession.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Driver'")
    } catch {
        Write-Alerta "No se pudo consultar Windows Update: $($_.Exception.Message)"
        return , @()
    }
    $modelos = @($Nics | ForEach-Object { Get-DescripcionBase $_.InterfaceDescription })
    $lista = @()
    foreach ($u in $resultado.Updates) {
        $m = [string]$u.DriverModel
        if (-not $m) { continue }
        foreach ($mod in $modelos) {
            if ($m -eq $mod -or $m.Contains($mod) -or $mod.Contains($m)) { $lista += $u; break }
        }
    }
    return , $lista
}

function Install-DriversPendientes($Updates) {
    $coleccion = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $Updates) {
        if (-not $u.EulaAccepted) { $u.AcceptEula() }
        [void]$coleccion.Add($u)
    }
    Write-Dato 'Descargando...'
    $descarga = $script:WuSession.CreateUpdateDownloader()
    $descarga.Updates = $coleccion
    [void]$descarga.Download()
    Write-Dato 'Instalando...'
    $instalador = $script:WuSession.CreateUpdateInstaller()
    $instalador.Updates = $coleccion
    return $instalador.Install()
}

# ---------------------------------------------------------------- reporte HTML

function ConvertTo-TextoHtml($Texto) { [System.Net.WebUtility]::HtmlEncode([string]$Texto) }

function Get-ClaseNivel([string]$Nivel) {
    switch ($Nivel) { 'Crítico' { 'crit' } 'Advertencia' { 'warn' } 'OK' { 'ok' } default { 'info' } }
}

function New-TablaHtml($Filas, [string[]]$Columnas) {
    $Filas = @($Filas)
    if ($Filas.Count -eq 0) { return '<p class="vacio">Sin datos.</p>' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="tabla"><table><thead><tr>')
    foreach ($c in $Columnas) { [void]$sb.Append("<th>$(ConvertTo-TextoHtml $c)</th>") }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($f in $Filas) {
        [void]$sb.Append('<tr>')
        foreach ($c in $Columnas) {
            $v = $f.$c
            if ($c -eq 'Nivel') {
                [void]$sb.Append("<td><span class=`"nivel $(Get-ClaseNivel $v)`">$(ConvertTo-TextoHtml $v)</span></td>")
            } else {
                [void]$sb.Append("<td>$(ConvertTo-TextoHtml $v)</td>")
            }
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table></div>')
    return $sb.ToString()
}

function New-Reporte($Ctx) {
    $archivo = Join-Path $DirReportes ("diagnostico-{0}-{1}.html" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $orden = @{ 'Crítico' = 0; 'Advertencia' = 1; 'Info' = 2; 'OK' = 3 }
    $h = @($Ctx.Hallazgos | Sort-Object { $orden[$_.Nivel] })
    $crit = @($h | Where-Object Nivel -eq 'Crítico').Count
    $adv = @($h | Where-Object Nivel -eq 'Advertencia').Count
    $ok = @($h | Where-Object Nivel -eq 'OK').Count

    $tHallazgos = New-TablaHtml $h @('Nivel', 'Tema', 'Detalle', 'Recomendación')

    $tAdaptadores = New-TablaHtml (@($Ctx.Adaptadores) | ForEach-Object {
            [pscustomobject]@{
                Nombre = $_.Name; Modelo = $_.InterfaceDescription
                Tipo = $(if ($_.PnPDeviceID -like 'USB*') { 'USB' } else { 'Interno' })
                Estado = [string]$_.Status; Velocidad = $_.LinkSpeed
                Driver = $_.DriverVersion; 'Fecha del driver' = $_.DriverDate
            }
        }) @('Nombre', 'Modelo', 'Tipo', 'Estado', 'Velocidad', 'Driver', 'Fecha del driver')

    $conexiones = @()
    if ($Ctx.Wlan) {
        $conexiones = @($Ctx.Wlan.Interfaces | Where-Object { $_.SSID } | ForEach-Object {
                [pscustomobject]@{
                    Adaptador = $_.Descripcion; Red = $_.SSID; 'Punto de acceso' = $_.BSSID; Banda = $_.Banda; Canal = $_.Canal
                    'Tipo de radio' = $_.Radio; 'Señal' = "$($_.Senal) %"; 'Velocidad (Mbps)' = "$($_.Rx) / $($_.Tx)"
                }
            })
    }
    $tConexion = New-TablaHtml $conexiones @('Adaptador', 'Red', 'Punto de acceso', 'Banda', 'Canal', 'Tipo de radio', 'Señal', 'Velocidad (Mbps)')

    $tPruebas = New-TablaHtml (@($Ctx.Pruebas) | ForEach-Object {
            [pscustomobject]@{
                Prueba = $_.Prueba; Destino = $_.Destino; Enviados = $_.Enviados; Recibidos = $_.Recibidos
                'Pérdida' = "$($_.Perdida) %"; 'Mín (ms)' = $_.Min; 'Media (ms)' = $_.Media; 'Máx (ms)' = $_.Max
            }
        }) @('Prueba', 'Destino', 'Enviados', 'Recibidos', 'Pérdida', 'Mín (ms)', 'Media (ms)', 'Máx (ms)')

    $tDescResumen = New-TablaHtml (@($Ctx.Desconexiones) | Group-Object Adaptador, Motivo | Sort-Object Count -Descending | ForEach-Object {
            [pscustomobject]@{ Adaptador = $_.Group[0].Adaptador; Motivo = $_.Group[0].Motivo; Cantidad = $_.Count }
        }) @('Adaptador', 'Motivo', 'Cantidad')

    $tDescUltimas = New-TablaHtml (@($Ctx.Desconexiones) | Select-Object -First 20 | ForEach-Object {
            [pscustomobject]@{ Fecha = $_.Fecha.ToString('dd/MM HH:mm:ss'); Adaptador = $_.Adaptador; Red = $_.SSID; Motivo = $_.Motivo }
        }) @('Fecha', 'Adaptador', 'Red', 'Motivo')

    $tRedes = New-TablaHtml (@($Ctx.Redes) | Sort-Object { Get-TipoBanda $_.Banda $_.Canal }, Canal, { - $_.Senal } | ForEach-Object {
            [pscustomobject]@{
                Red = $(if ($_.SSID) { $_.SSID } else { '(oculta)' }); Banda = $_.Banda; Canal = $_.Canal
                'Señal' = "$($_.Senal) %"; 'Tipo de radio' = $_.Radio; 'Punto de acceso' = $_.BSSID
            }
        }) @('Red', 'Banda', 'Canal', 'Señal', 'Tipo de radio', 'Punto de acceso')

    $tDrivers = New-TablaHtml $Ctx.Drivers @('Driver', 'Dispositivo', 'Fecha')

    $eq = $Ctx.Equipo
    $fecha = $Ctx.Fecha.ToString('dd/MM/yyyy HH:mm')
    $html = @"
<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Diagnóstico WiFi - $(ConvertTo-TextoHtml $eq.Nombre)</title>
<style>
:root{--bg:#f6f7f9;--card:#fff;--txt:#1d2330;--sub:#5b6474;--borde:#e3e6eb;--crit:#c62828;--warn:#b26a00;--ok:#2e7d32;--info:#455a64}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--txt);font:15px/1.5 "Segoe UI",system-ui,sans-serif}
main{max-width:1100px;margin:0 auto;padding:24px 16px 48px}h1{margin:0 0 4px;font-size:26px}h2{font-size:18px;margin:32px 0 10px}
.sub{color:var(--sub);margin:0}.resumen{display:flex;gap:12px;flex-wrap:wrap;margin:20px 0}
.caja{background:var(--card);border:1px solid var(--borde);border-radius:10px;padding:12px 18px;min-width:140px}
.caja b{display:block;font-size:26px}.caja.crit b{color:var(--crit)}.caja.warn b{color:var(--warn)}.caja.ok b{color:var(--ok)}
.tabla{overflow-x:auto;background:var(--card);border:1px solid var(--borde);border-radius:10px}
table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:8px 12px;border-bottom:1px solid var(--borde);vertical-align:top}
th{font-size:13px;color:var(--sub);font-weight:600;background:#fafbfc}tr:last-child td{border-bottom:0}
.nivel{display:inline-block;padding:2px 8px;border-radius:999px;font-size:12px;font-weight:600;color:#fff;white-space:nowrap}
.nivel.crit{background:var(--crit)}.nivel.warn{background:var(--warn)}.nivel.ok{background:var(--ok)}.nivel.info{background:var(--info)}
.vacio{color:var(--sub);font-style:italic}footer{margin-top:40px;color:var(--sub);font-size:13px}
</style></head><body><main>
<h1>Diagnóstico WiFi</h1>
<p class="sub">$(ConvertTo-TextoHtml "$($eq.Nombre) · $($eq.Fabricante) $($eq.Modelo) · $($eq.Sistema) · BIOS $($eq.BIOS)")</p>
<p class="sub">$fecha</p>
<div class="resumen">
<div class="caja crit"><b>$crit</b>Críticos</div>
<div class="caja warn"><b>$adv</b>Advertencias</div>
<div class="caja ok"><b>$ok</b>Correctos</div>
</div>
<h2>Hallazgos y recomendaciones</h2>$tHallazgos
<h2>Adaptadores WiFi</h2>$tAdaptadores
<h2>Conexión actual</h2>$tConexion
<h2>Pruebas de conexión</h2>$tPruebas
<h2>Desconexiones en las últimas 24 horas</h2>$tDescResumen
<h2>Últimas desconexiones</h2>$tDescUltimas
<h2>Drivers disponibles en Windows Update</h2>$tDrivers
<h2>Redes cercanas</h2>$tRedes
<footer>Generado por WiFi Optimizador v$Version</footer>
</main></body></html>
"@
    Set-Content -Path $archivo -Value $html -Encoding UTF8
    return $archivo
}

# ---------------------------------------------------------------- diagnóstico

function Invoke-Diagnostico {
    param([switch]$Rapido, [switch]$SinReporte, [switch]$SinBuscarDrivers)

    $script:Hallazgos.Clear()
    $ctx = [ordered]@{
        Fecha = Get-Date; Equipo = $null; Adaptadores = @(); Wlan = $null; Redes = @(); Pruebas = @()
        Desconexiones = @(); Drivers = @(); Recomendar5GHz = $false; Hallazgos = @()
    }

    Write-Titulo 'Equipo'
    $cs = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    $bios = Get-CimInstance Win32_BIOS
    $modelo = $cs.Model
    if ($cs.Manufacturer -match 'LENOVO' -and $cs.SystemFamily) { $modelo = "$($cs.SystemFamily) ($($cs.Model))" }
    $ctx.Equipo = [pscustomobject]@{ Nombre = $env:COMPUTERNAME; Fabricante = $cs.Manufacturer; Modelo = $modelo; Sistema = $os.Caption; BIOS = $bios.SMBIOSBIOSVersion }
    Write-Dato "$($cs.Manufacturer) $modelo | $($os.Caption) | BIOS $($bios.SMBIOSBIOSVersion)"

    # --- adaptadores
    Write-Titulo 'Adaptadores WiFi'
    $nics = Get-AdaptadoresWifi
    $ctx.Adaptadores = $nics
    if ($nics.Count -eq 0) {
        Add-Hallazgo 'Crítico' 'Adaptador' 'No se encontró ningún adaptador WiFi.' 'Revisa en el Administrador de dispositivos si la tarjeta aparece o tiene un error.'
        $ctx.Hallazgos = $script:Hallazgos.ToArray()
        return [pscustomobject]$ctx
    }
    foreach ($n in $nics) {
        $tipo = if ($n.PnPDeviceID -like 'USB*') { 'USB' } else { 'Interno' }
        Write-Dato ("{0} | {1} | {2} | {3} | driver {4} ({5})" -f $n.Name, $n.InterfaceDescription, $tipo, $n.Status, $n.DriverVersion, $n.DriverDate)
        if ($n.Status -eq 'Disabled') {
            Add-Hallazgo 'Advertencia' "Adaptador $($n.Name)" "$($n.InterfaceDescription) está deshabilitado." 'Habilítalo si es la tarjeta que quieres usar (lo hace el modo Optimizar).'
        }
        $fecha = $null
        try { $fecha = [datetime]$n.DriverDate } catch { }
        if ($fecha) {
            $anios = [math]::Floor(((Get-Date) - $fecha).TotalDays / 365)
            if ($anios -ge 5) {
                Add-Hallazgo 'Advertencia' "Driver $($n.Name)" "El driver es de $($n.DriverDate) ($anios años)." 'Busca un driver más nuevo (el modo Optimizar lo intenta por Windows Update o el fabricante del equipo).'
            }
        }
    }

    # --- conexión y señal
    Write-Titulo 'Conexión actual'
    $wlan = Get-EstadoWlan
    if ($wlan.Bloqueado) {
        Add-Hallazgo 'Advertencia' 'Permiso de ubicación' 'Windows no deja leer la señal, la banda ni las redes cercanas.' 'En Configuración > Privacidad y seguridad > Ubicación, activa "Servicios de ubicación", "Permitir que las aplicaciones accedan a la ubicación" y "Permitir que las aplicaciones de escritorio accedan a la ubicación".'
        if (-not $Forzar -and (Confirm-Accion '¿Abrir ahora la configuración de ubicación?')) {
            Start-Process 'ms-settings:privacy-location'
            Read-Host '  Activa los tres permisos y pulsa Enter para reintentar' | Out-Null
            $wlan = Get-EstadoWlan
            if (-not $wlan.Bloqueado) {
                $script:Hallazgos.RemoveAt($script:Hallazgos.Count - 1)
                Write-Bien 'Permiso de ubicación concedido.'
            }
        }
    }
    $ctx.Wlan = $wlan
    $conectadas = @($wlan.Interfaces | Where-Object { $_.SSID })

    if (-not $wlan.Bloqueado) {
        if ($conectadas.Count -eq 0) {
            Add-Hallazgo 'Crítico' 'Conexión' 'Ningún adaptador WiFi está conectado a una red.' 'Conéctate a la red y vuelve a ejecutar el diagnóstico.'
        }
        foreach ($c in $conectadas) {
            Write-Dato ("{0}: {1} | {2} canal {3} | {4} | señal {5} % | {6} Mbps" -f $c.Nombre, $c.SSID, $c.Banda, $c.Canal, $c.Radio, $c.Senal, $c.Rx)
            if ($c.Senal -lt 40) {
                Add-Hallazgo 'Crítico' 'Señal' "Señal muy débil ($($c.Senal) %) en $($c.Nombre)." 'Acércate al router, agrega un repetidor/mesh o usa un adaptador con antena externa.'
            } elseif ($c.Senal -lt 60) {
                Add-Hallazgo 'Advertencia' 'Señal' "Señal regular ($($c.Senal) %) en $($c.Nombre)." 'Puede causar cortes. Mejora la ubicación del router o agrega un repetidor.'
            } else {
                Add-Hallazgo 'OK' 'Señal' "Señal buena ($($c.Senal) %) en $($c.Nombre)."
            }
        }

        Write-Titulo 'Redes cercanas'
        $redes = Get-RedesCercanas
        $ctx.Redes = @($redes)
        Write-Dato "$($redes.Count) puntos de acceso visibles."
        foreach ($c in $conectadas) {
            $canal = [int]("0" + ($c.Canal -replace '[^\d]', ''))
            $banda = Get-TipoBanda $c.Banda $canal
            if ($banda -eq '2.4') {
                $alt5 = $redes | Where-Object { $_.SSID -eq $c.SSID -and (Get-TipoBanda $_.Banda $_.Canal) -eq '5' } |
                    Sort-Object Senal -Descending | Select-Object -First 1
                if ($alt5 -and $alt5.Senal -ge 50) {
                    $ctx.Recomendar5GHz = $true
                    Add-Hallazgo 'Advertencia' 'Banda' "Conectado en 2,4 GHz, pero la misma red está disponible en 5 GHz con $($alt5.Senal) % de señal (canal $($alt5.Canal))." 'Configurar la tarjeta para preferir 5 GHz (lo hace el modo Optimizar).'
                }
                $vecinas = @($redes | Where-Object {
                        $_.SSID -ne $c.SSID -and (Get-TipoBanda $_.Banda $_.Canal) -eq '2.4' -and [math]::Abs($_.Canal - $canal) -le 4
                    })
                if ($vecinas.Count -ge 3) {
                    $mejor = Get-MejorCanal24 $redes $c.SSID
                    $rec = if ($mejor -ne $canal) { "Usa 5 GHz si es posible, o cambia el canal de 2,4 GHz del router al $mejor (el menos ocupado)." } else { 'Usa 5 GHz si es posible; el canal actual ya es el menos ocupado.' }
                    Add-Hallazgo 'Advertencia' 'Interferencia' "$($vecinas.Count) redes vecinas usan canales que se superponen con el canal $canal." $rec
                } else {
                    Add-Hallazgo 'OK' 'Interferencia' "Pocas redes vecinas cerca del canal $canal ($($vecinas.Count))."
                }
            } elseif ($banda -eq '5') {
                $mismo = @($redes | Where-Object { $_.SSID -ne $c.SSID -and $_.Canal -eq $canal })
                Add-Hallazgo 'OK' 'Banda' "Conectado en 5 GHz (canal $canal, $($mismo.Count) redes vecinas en el mismo canal)."
            }
        }
    }

    # --- pruebas
    Write-Titulo 'Pruebas de conexión'
    $nPing = if ($Rapido) { 10 } else { 20 }
    $indices = @($nics | ForEach-Object { $_.ifIndex })
    $ipcfg = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
        Where-Object { $_.IPv4DefaultGateway -and ($indices -contains $_.InterfaceIndex) } | Select-Object -First 1
    if ($ipcfg) {
        $gw = @($ipcfg.IPv4DefaultGateway)[0].NextHop
        Write-Dato "Probando el router ($gw) con $nPing paquetes..."
        $pr = Test-Ping $gw $nPing 'Router'
        Write-Dato "Probando internet (1.1.1.1)..."
        $pi = Test-Ping '1.1.1.1' $nPing 'Internet'
        $ctx.Pruebas = @($pr, $pi)

        if ($pr.Perdida -ge 5) {
            Add-Hallazgo 'Crítico' 'Enlace con el router' "Se pierde el $($pr.Perdida) % de los paquetes hacia el router." 'Es un problema del enlace inalámbrico: interferencia, ahorro de energía, driver o compatibilidad con el router.'
        } elseif ($pr.Perdida -gt 0) {
            Add-Hallazgo 'Advertencia' 'Enlace con el router' "Se pierde el $($pr.Perdida) % de los paquetes hacia el router."
        } elseif ($pr.Max -gt 50) {
            Add-Hallazgo 'Advertencia' 'Enlace con el router' "Sin pérdida, pero la latencia es inestable (máx. $($pr.Max) ms)." 'Suele indicar interferencia o ahorro de energía del adaptador.'
        } else {
            Add-Hallazgo 'OK' 'Enlace con el router' "0 % de pérdida, $($pr.Media) ms de media."
        }

        if ($pi.Perdida -ge 5 -and $pr.Perdida -lt 5) {
            Add-Hallazgo 'Crítico' 'Internet' "Se pierde el $($pi.Perdida) % de los paquetes hacia internet, pero el router responde bien." 'El problema está en el router o en el proveedor de internet, no en el WiFi de la PC.'
        } elseif ($pi.Recibidos -eq 0) {
            Add-Hallazgo 'Crítico' 'Internet' 'No hay respuesta de internet.' 'Revisa el router y el servicio del proveedor.'
        } else {
            Add-Hallazgo 'OK' 'Internet' "$($pi.Perdida) % de pérdida, $($pi.Media) ms de media."
        }

        try {
            Resolve-DnsName 'www.microsoft.com' -DnsOnly -ErrorAction Stop | Out-Null
            Add-Hallazgo 'OK' 'DNS' 'La resolución de nombres funciona.'
        } catch {
            Add-Hallazgo 'Crítico' 'DNS' 'No se pudo resolver www.microsoft.com.' 'Prueba con otros servidores DNS (por ejemplo 1.1.1.1 y 8.8.8.8).'
        }
        try {
            $w = Invoke-WebRequest 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 10
            if ($w.Content -match 'Microsoft Connect Test') { Add-Hallazgo 'OK' 'Navegación' 'La navegación web funciona.' }
            else { Add-Hallazgo 'Advertencia' 'Navegación' 'La respuesta web no es la esperada.' 'Puede haber un portal cautivo (hotel, oficina) o un proxy.' }
        } catch {
            Add-Hallazgo 'Crítico' 'Navegación' 'No se pudo abrir una página web de prueba.' 'Revisa proxy, firewall o portal cautivo.'
        }
    } else {
        Add-Hallazgo 'Crítico' 'Red' 'El WiFi no tiene puerta de enlace (no obtuvo dirección IP del router).' 'Revisa la contraseña de la red y reinicia el router o el adaptador.'
    }

    # --- desconexiones
    Write-Titulo 'Desconexiones (últimas 24 h)'
    $desc = Get-Desconexiones 24
    $ctx.Desconexiones = @($desc)
    foreach ($n in $nics) {
        $base = Get-DescripcionBase $n.InterfaceDescription
        $propias = @($desc | Where-Object { $_.Adaptador -and $_.Adaptador.StartsWith($base) })
        # Manuales: el usuario desconectó, cambió de red, o se reinició/deshabilitó el adaptador.
        $patronManual = 'usuario|user|nueva conexi|new connection|estado de operaci|operat\w* state'
        $reales = @($propias | Where-Object { $_.Motivo -notmatch $patronManual })
        $manuales = $propias.Count - $reales.Count
        $texto = "$($reales.Count) caídas reales en $($n.Name)"
        if ($manuales -gt 0) { $texto += " (más $manuales por el usuario o por reinicios del adaptador, que no cuentan)" }
        if ($reales.Count -ge 10) {
            $motivo = ($reales | Group-Object Motivo | Sort-Object Count -Descending | Select-Object -First 1).Name
            Add-Hallazgo 'Crítico' 'Desconexiones' "$texto. Motivo más común: $motivo" 'Aplica el modo Optimizar: driver, ahorro de energía, itinerancia y banda.'
        } elseif ($reales.Count -ge 3) {
            Add-Hallazgo 'Advertencia' 'Desconexiones' "$texto." 'Aplica el modo Optimizar y vuelve a revisar en unas horas.'
        } else {
            Add-Hallazgo 'OK' 'Desconexiones' "$texto."
        }
    }

    # --- energía
    Write-Titulo 'Ahorro de energía'
    foreach ($n in $nics) {
        $pnp = Get-PnPCapabilities $n
        if ($pnp -eq 24) {
            Add-Hallazgo 'OK' 'Energía' "Windows no puede apagar $($n.Name) para ahorrar energía."
        } else {
            Add-Hallazgo 'Advertencia' 'Energía' "Windows puede apagar $($n.Name) para ahorrar energía." 'Desactivarlo (lo hace el modo Optimizar).'
        }
    }
    $vw = Get-ValorEnergia $EnergiaWifi
    if ($vw) {
        if ($vw.AC -eq 0 -and $vw.DC -eq 0) {
            Add-Hallazgo 'OK' 'Plan de energía' 'El adaptador inalámbrico está en rendimiento máximo.'
        } else {
            Add-Hallazgo 'Advertencia' 'Plan de energía' "El plan limita el WiFi (con corriente: $(Get-TextoEnergiaWifi $vw.AC); con batería: $(Get-TextoEnergiaWifi $vw.DC))." 'Ponerlo en rendimiento máximo (lo hace el modo Optimizar).'
        }
    }
    if (@($nics | Where-Object { $_.PnPDeviceID -like 'USB*' }).Count -gt 0) {
        $vu = Get-ValorEnergia $EnergiaUsb
        if ($vu -and ($vu.AC -ne 0 -or $vu.DC -ne 0)) {
            Add-Hallazgo 'Advertencia' 'USB' 'La suspensión selectiva USB está activada y hay un adaptador WiFi USB.' 'Desactivarla (lo hace el modo Optimizar).'
        } elseif ($vu) {
            Add-Hallazgo 'OK' 'USB' 'La suspensión selectiva USB está desactivada.'
        }
    }

    # --- drivers
    if (-not $SinBuscarDrivers -and -not $SinDrivers) {
        Write-Titulo 'Drivers en Windows Update'
        Write-Dato 'Buscando (puede tardar un minuto)...'
        $script:DriversPendientes = Get-DriversPendientes $nics
        $ctx.Drivers = @($script:DriversPendientes | ForEach-Object {
                [pscustomobject]@{ Driver = $_.Title; Dispositivo = $_.DriverModel; Fecha = ([datetime]$_.DriverVerDate).ToString('dd/MM/yyyy') }
            })
        if ($ctx.Drivers.Count -gt 0) {
            foreach ($d in $ctx.Drivers) {
                Add-Hallazgo 'Advertencia' 'Driver disponible' "$($d.Dispositivo): $($d.Driver)" 'Instalarlo (lo hace el modo Optimizar).'
            }
        } else {
            Add-Hallazgo 'OK' 'Drivers' 'No hay drivers WiFi nuevos en Windows Update.'
        }
    }

    # --- resumen
    $ctx.Hallazgos = $script:Hallazgos.ToArray()
    $crit = @($ctx.Hallazgos | Where-Object Nivel -eq 'Crítico').Count
    $adv = @($ctx.Hallazgos | Where-Object Nivel -eq 'Advertencia').Count
    Write-Titulo 'Resumen'
    if ($crit + $adv -eq 0) { Write-Bien 'No se encontraron problemas.' }
    else { Write-Host "  $crit críticos, $adv advertencias." -ForegroundColor Yellow }

    $resultado = [pscustomobject]$ctx
    if (-not $SinReporte) {
        $ruta = New-Reporte $resultado
        Write-Bien "Reporte guardado en: $ruta"
        if (-not $Forzar -and (Confirm-Accion '¿Abrir el reporte?')) { Invoke-Item $ruta }
    }
    return $resultado
}

# ---------------------------------------------------------------- respaldo

function New-Respaldo($Nics) {
    $adaptadores = foreach ($n in $Nics) {
        $props = @(Get-NetAdapterAdvancedProperty -Name $n.Name -ErrorAction SilentlyContinue)
        $lista = foreach ($aj in $AjustesAvanzados) {
            $f = Find-PropiedadAvanzada $aj $props
            if ($f) { [pscustomobject]@{ Keyword = $f.Keyword; Valor = $f.Actual; Texto = $f.ActualTexto } }
        }
        [pscustomobject]@{
            Nombre = $n.Name; Descripcion = $n.InterfaceDescription; Guid = $n.InterfaceGuid; Estado = [string]$n.Status
            DriverVersion = $n.DriverVersion; PnPCapabilities = (Get-PnPCapabilities $n); Propiedades = @($lista)
        }
    }
    $energia = foreach ($cfg in $EnergiaWifi, $EnergiaUsb) {
        $v = Get-ValorEnergia $cfg
        if ($v) { [pscustomobject]@{ Nombre = $cfg.Nombre; Sub = $cfg.Sub; Set = $cfg.Set; AC = $v.AC; DC = $v.DC } }
    }
    $datos = [pscustomobject]@{
        Fecha = (Get-Date).ToString('s'); Equipo = $env:COMPUTERNAME; Version = $Version
        Adaptadores = @($adaptadores); Energia = @($energia)
    }
    $prefijo = if ($Simular) { 'simulacion' } else { 'respaldo' }
    $archivo = Join-Path $DirRespaldos ("{0}-{1}-{2}.json" -f $prefijo, $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $datos | ConvertTo-Json -Depth 6 | Set-Content -Path $archivo -Encoding UTF8
    return $archivo
}

# ---------------------------------------------------------------- optimización

function Invoke-Optimizacion {
    if (-not $Simular -and -not (Test-Admin)) { Start-Elevado 'Optimizar'; return }
    if ($Simular) { Write-Host "`n  MODO SIMULACIÓN: se muestran los cambios, pero no se aplica ninguno." -ForegroundColor Magenta }

    Write-Host "`n  Primero, un diagnóstico rápido para decidir qué cambiar." -ForegroundColor White
    $ctx = Invoke-Diagnostico -Rapido -SinReporte
    $nics = @($ctx.Adaptadores)
    if ($nics.Count -eq 0) { return }

    Write-Titulo 'Respaldo'
    $archivoResp = New-Respaldo $nics
    Write-Bien "Configuración actual guardada en: $archivoResp"

    $cambios = New-Object System.Collections.Generic.List[string]
    $reiniciarAdaptador = @{}
    $reiniciarPc = $false

    # 1. adaptadores deshabilitados
    Write-Titulo '1. Adaptadores deshabilitados'
    $deshabilitados = @($nics | Where-Object { $_.Status -eq 'Disabled' })
    if ($deshabilitados.Count -eq 0) { Write-Bien 'Ninguno.' }
    foreach ($n in $deshabilitados) {
        if (Confirm-Accion "¿Habilitar $($n.Name) ($($n.InterfaceDescription))?") {
            if (Invoke-Cambio "Habilitado $($n.Name)" { Enable-NetAdapter -Name $n.Name -Confirm:$false -ErrorAction Stop }) {
                $cambios.Add("Habilitado $($n.Name)")
            }
        }
    }

    # 2. drivers
    Write-Titulo '2. Drivers'
    if ($SinDrivers) {
        Write-Dato 'Omitido (-SinDrivers).'
    } elseif (@($script:DriversPendientes).Count -eq 0) {
        Write-Bien 'No hay drivers WiFi nuevos en Windows Update.'
    } else {
        foreach ($u in $script:DriversPendientes) { Write-Dato "$($u.DriverModel): $($u.Title)" }
        if (Confirm-Accion '¿Instalar estos drivers? (el WiFi puede cortarse unos segundos)') {
            if ($Simular) {
                Write-Host '  [SIM] Instalar drivers de Windows Update' -ForegroundColor Magenta
            } else {
                try {
                    $r = Install-DriversPendientes $script:DriversPendientes
                    if ($r.ResultCode -eq 2 -or $r.ResultCode -eq 3) {
                        Write-Bien 'Drivers instalados.'
                        $cambios.Add('Drivers actualizados desde Windows Update')
                        if ($r.RebootRequired) { $reiniciarPc = $true }
                    } else {
                        Write-Fallo "La instalación terminó con código $($r.ResultCode)."
                    }
                } catch {
                    Write-Fallo "Error al instalar drivers: $($_.Exception.Message)"
                }
                Start-Sleep -Seconds 10
                $nics = @($nics | ForEach-Object { $g = $_.InterfaceGuid; Get-NetAdapter | Where-Object { $_.InterfaceGuid -eq $g } })
            }
        }
    }

    # 3. ajustes avanzados
    Write-Titulo '3. Ajustes avanzados del adaptador'
    foreach ($n in $nics) {
        Write-Host "  $($n.Name) - $($n.InterfaceDescription)" -ForegroundColor White
        $props = @(Get-NetAdapterAdvancedProperty -Name $n.Name -ErrorAction SilentlyContinue)
        foreach ($aj in $AjustesAvanzados) {
            $f = Find-PropiedadAvanzada $aj $props
            if (-not $f) { Write-Dato "$($aj.Descripcion): no disponible en este adaptador."; continue }
            if ($f.Actual -eq $f.Objetivo) { Write-Bien "$($aj.Descripcion): ya estaba configurado."; continue }
            if ($aj.Id -eq 'Banda' -and -not $ctx.Recomendar5GHz) {
                Write-Dato 'Banda preferida: sin cambios (no estás en 2,4 GHz con tu red disponible en 5 GHz con buena señal).'
                continue
            }
            Write-Dato "Motivo: $($aj.Motivo)."
            if (Confirm-Accion "$($aj.Descripcion) ('$($f.ActualTexto)' -> '$($f.ObjetivoTexto)')?") {
                $ok = Invoke-Cambio "$($n.Name): $($aj.Descripcion)" {
                    Set-NetAdapterAdvancedProperty -Name $n.Name -RegistryKeyword $f.Keyword -RegistryValue $f.Objetivo -NoRestart -ErrorAction Stop
                }
                if ($ok) { $cambios.Add("$($n.Name): $($aj.Descripcion)"); $reiniciarAdaptador[$n.Name] = $true }
            }
        }
    }

    # 4. apagado por ahorro de energía
    Write-Titulo '4. Apagado del adaptador por ahorro de energía'
    foreach ($n in $nics) {
        $clave = Get-ClaveRegistroAdaptador $n
        if (-not $clave) { Write-Alerta "No se encontró la clave de registro de $($n.Name)."; continue }
        $pnp = (Get-ItemProperty $clave.PSPath -Name PnPCapabilities -ErrorAction SilentlyContinue).PnPCapabilities
        if ($pnp -eq 24) { Write-Bien "$($n.Name): ya estaba desactivado."; continue }
        if (Confirm-Accion "¿Impedir que Windows apague $($n.Name) para ahorrar energía?") {
            $ok = Invoke-Cambio "$($n.Name): Windows ya no puede apagarlo para ahorrar energía" {
                Set-ItemProperty -Path $clave.PSPath -Name PnPCapabilities -Value 24 -Type DWord -ErrorAction Stop
            }
            if ($ok) { $cambios.Add("$($n.Name): sin apagado por ahorro de energía"); $reiniciarAdaptador[$n.Name] = $true; $reiniciarPc = $true }
        }
    }

    # 5. plan de energía
    Write-Titulo '5. Plan de energía'
    $configs = @($EnergiaWifi)
    if (@($nics | Where-Object { $_.PnPDeviceID -like 'USB*' }).Count -gt 0) { $configs += $EnergiaUsb }
    foreach ($cfg in $configs) {
        $v = Get-ValorEnergia $cfg
        if (-not $v) { Write-Dato "$($cfg.Nombre): no disponible en este equipo."; continue }
        if ($v.AC -eq 0 -and $v.DC -eq 0) { Write-Bien "$($cfg.Nombre): ya estaba configurado."; continue }
        if (Confirm-Accion "¿$($cfg.Accion)?") {
            $ok = Invoke-Cambio $cfg.Accion {
                powercfg /setacvalueindex SCHEME_CURRENT $cfg.Sub $cfg.Set 0
                powercfg /setdcvalueindex SCHEME_CURRENT $cfg.Sub $cfg.Set 0
                powercfg /setactive SCHEME_CURRENT
                if ($LASTEXITCODE -ne 0) { throw "powercfg devolvió $LASTEXITCODE" }
            }
            if ($ok) { $cambios.Add($cfg.Accion) }
        }
    }

    # 6. aplicar
    if ($reiniciarAdaptador.Count -gt 0) {
        Write-Titulo '6. Aplicando cambios'
        foreach ($nombre in @($reiniciarAdaptador.Keys)) {
            $estado = (Get-NetAdapter -Name $nombre -ErrorAction SilentlyContinue).Status
            if ($estado -and $estado -ne 'Disabled') {
                [void](Invoke-Cambio "Reiniciado $nombre (el WiFi se corta unos segundos)" { Restart-NetAdapter -Name $nombre -Confirm:$false -ErrorAction Stop })
            }
        }
        if (-not $Simular) { Start-Sleep -Seconds 20 }
    }

    Write-Titulo 'Resumen'
    if ($cambios.Count -eq 0) { Write-Bien 'No hizo falta cambiar nada.' }
    else { foreach ($c in $cambios) { Write-Bien $c } }
    if (-not $Simular) {
        Write-Dato "Para deshacer: modo Restaurar (usa $archivoResp)."
        Write-Dato 'Los drivers no se revierten con Restaurar: usa "Revertir al controlador anterior" en el Administrador de dispositivos.'
        if ($reiniciarPc) { Write-Alerta 'Reinicia la PC para que todos los cambios queden aplicados.' }
        if ($cambios.Count -gt 0 -and (Confirm-Accion '¿Ejecutar un diagnóstico de verificación ahora?')) {
            $null = Invoke-Diagnostico -SinBuscarDrivers
        }
    }
}

# ---------------------------------------------------------------- restauración

function Invoke-Restauracion {
    if (-not $Simular -and -not (Test-Admin)) { Start-Elevado 'Restaurar'; return }

    $archivo = $Respaldo
    if (-not $archivo) {
        $ultimo = Get-ChildItem $DirRespaldos -Filter 'respaldo-*.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $ultimo) { Write-Fallo 'No hay respaldos guardados.'; return }
        $archivo = $ultimo.FullName
    }
    if (-not (Test-Path $archivo)) { Write-Fallo "No existe el archivo $archivo."; return }

    $d = Get-Content $archivo -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Titulo 'Restaurar configuración'
    Write-Dato "Respaldo: $archivo"
    Write-Dato "Fecha: $($d.Fecha) | Equipo: $($d.Equipo)"
    if ($d.Equipo -ne $env:COMPUTERNAME) {
        Write-Alerta 'Este respaldo es de otro equipo.'
        if (-not (Confirm-Accion '¿Continuar igualmente?')) { return }
    }
    if (-not (Confirm-Accion '¿Restaurar esta configuración?')) { return }

    foreach ($a in @($d.Adaptadores)) {
        $n = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceGuid -eq $a.Guid } | Select-Object -First 1
        if (-not $n) { Write-Alerta "No se encontró el adaptador $($a.Nombre)."; continue }
        foreach ($p in @($a.Propiedades)) {
            [void](Invoke-Cambio "$($n.Name): $($p.Keyword) = $($p.Texto)" {
                    Set-NetAdapterAdvancedProperty -Name $n.Name -RegistryKeyword $p.Keyword -RegistryValue $p.Valor -NoRestart -ErrorAction Stop
                })
        }
        $clave = Get-ClaveRegistroAdaptador $n
        if ($clave) {
            [void](Invoke-Cambio "$($n.Name): ahorro de energía como estaba" {
                    if ($null -eq $a.PnPCapabilities) { Remove-ItemProperty -Path $clave.PSPath -Name PnPCapabilities -ErrorAction SilentlyContinue }
                    else { Set-ItemProperty -Path $clave.PSPath -Name PnPCapabilities -Value ([int]$a.PnPCapabilities) -Type DWord -ErrorAction Stop }
                })
        }
        if ($a.Estado -eq 'Disabled' -and $n.Status -ne 'Disabled' -and (Confirm-Accion "$($n.Name) estaba deshabilitado. ¿Deshabilitarlo de nuevo?")) {
            [void](Invoke-Cambio "Deshabilitado $($n.Name)" { Disable-NetAdapter -Name $n.Name -Confirm:$false -ErrorAction Stop })
            continue
        }
        if ($n.Status -ne 'Disabled') {
            [void](Invoke-Cambio "Reiniciado $($n.Name)" { Restart-NetAdapter -Name $n.Name -Confirm:$false -ErrorAction Stop })
        }
    }
    foreach ($e in @($d.Energia)) {
        [void](Invoke-Cambio "$($e.Nombre) como estaba" {
                powercfg /setacvalueindex SCHEME_CURRENT $e.Sub $e.Set $e.AC
                powercfg /setdcvalueindex SCHEME_CURRENT $e.Sub $e.Set $e.DC
                powercfg /setactive SCHEME_CURRENT
            })
    }
    if (-not $Simular) { Write-Alerta 'Reinicia la PC para completar la restauración.' }
}

# ---------------------------------------------------------------- menú

function Show-Menu {
    while ($true) {
        Write-Host ''
        Write-Host '  ==================================' -ForegroundColor Cyan
        Write-Host "    WiFi Optimizador v$Version" -ForegroundColor Cyan
        Write-Host '  ==================================' -ForegroundColor Cyan
        Write-Host '   1. Diagnosticar (solo lectura, genera un reporte)'
        Write-Host '   2. Optimizar (pide permisos de administrador)'
        Write-Host '   3. Simular optimización (no cambia nada)'
        Write-Host '   4. Restaurar la configuración anterior'
        Write-Host '   5. Abrir la carpeta de reportes'
        Write-Host '   0. Salir'
        $op = Read-Host '  Elige una opción'
        switch ("$op".Trim()) {
            '1' { $null = Invoke-Diagnostico }
            '2' { Invoke-Optimizacion }
            '3' { $script:Simular = $true; Invoke-Optimizacion; $script:Simular = $false }
            '4' { Invoke-Restauracion }
            '5' { Invoke-Item $DirReportes }
            '0' { return }
            default { Write-Alerta 'Opción no válida.' }
        }
    }
}

# ---------------------------------------------------------------- inicio

$log = Join-Path $DirLogs ("{0}-{1}.log" -f $Modo.ToLower(), (Get-Date -Format 'yyyyMMdd-HHmmss'))
try { Start-Transcript -Path $log -Force | Out-Null } catch { }
Write-Host "WiFi Optimizador v$Version" -ForegroundColor Cyan
try {
    switch ($Modo) {
        'Diagnosticar' { $null = Invoke-Diagnostico }
        'Optimizar' { Invoke-Optimizacion }
        'Restaurar' { Invoke-Restauracion }
        default { Show-Menu }
    }
} finally {
    try { Stop-Transcript | Out-Null } catch { }
    if ($Pausa) { Read-Host 'Pulsa Enter para cerrar' | Out-Null }
}
