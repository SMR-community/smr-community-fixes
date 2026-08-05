<#
.SYNOPSIS
    Capture the Paradox Mods routes, then finish pdx_client.py automatically.

.DESCRIPTION
    Installs mitmproxy if needed, trusts its CA, points Windows at the proxy,
    and waits while you upload the mod once from the game's Mod Editor. On exit
    it restores your proxy settings and fills in the ROUTES table.

    Run it from an elevated PowerShell - trusting a CA needs admin.

    The capture records method, path and body field names only. Values are
    redacted by capture_routes.py, so your password never reaches a file.
#>
[CmdletBinding()]
param(
    [int]$Port = 8080,
    [int]$TimeoutMinutes = 20
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) { throw "Run this from an elevated PowerShell - trusting the CA needs admin." }

# 1. mitmproxy
if (-not (python -c "import importlib.util as u; print(1 if u.find_spec('mitmproxy') else 0)") -eq '1') {
    Write-Host "installing mitmproxy..."
    python -m pip install --quiet mitmproxy
}

# 2. Start it once so it generates its CA, then trust that CA.
$confdir = Join-Path $env:USERPROFILE ".mitmproxy"
$cert = Join-Path $confdir "mitmproxy-ca-cert.cer"
if (-not (Test-Path $cert)) {
    Write-Host "generating mitmproxy CA..."
    $seed = Start-Process -PassThru -WindowStyle Hidden mitmdump -ArgumentList "--listen-port $Port"
    while (-not (Test-Path $cert)) { Start-Sleep -Milliseconds 300 }
    Stop-Process -Id $seed.Id -Force
}
Write-Host "trusting mitmproxy CA in the machine root store..."
Import-Certificate -FilePath $cert -CertStoreLocation Cert:\LocalMachine\Root | Out-Null

# 3. Remember the current proxy so it can be put back.
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$saved = Get-ItemProperty -Path $key
$savedEnable = $saved.ProxyEnable
$savedServer = $saved.ProxyServer

try {
    Set-ItemProperty -Path $key -Name ProxyServer -Value "127.0.0.1:$Port"
    Set-ItemProperty -Path $key -Name ProxyEnable -Value 1
    Write-Host "proxy on. Now:"
    Write-Host "  1. start the game"
    Write-Host "  2. open the Mod Editor and upload SMR Community Fixes once"
    Write-Host "  3. come back here and press Ctrl+C when the upload finishes"
    Write-Host ""

    $addon = Join-Path $here "capture_routes.py"
    & mitmdump -s $addon --listen-port $Port --set confdir=$confdir
}
finally {
    Set-ItemProperty -Path $key -Name ProxyEnable -Value $savedEnable
    if ($savedServer) { Set-ItemProperty -Path $key -Name ProxyServer -Value $savedServer }
    Write-Host "`nproxy restored."

    $routes = Join-Path $here "routes.json"
    if (Test-Path $routes) {
        Write-Host "filling in the routes...`n"
        python (Join-Path $here "finish_routes.py")
    }
    else {
        Write-Host "no routes.json was written - no API traffic was seen."
        Write-Host "The game may bypass the system proxy; if so capture with a transparent proxy instead."
    }
}
