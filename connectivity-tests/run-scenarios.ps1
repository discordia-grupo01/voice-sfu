# Ejecutar en PowerShell COMO ADMINISTRADOR, en la carpeta con webrtc-check.mjs
#   $env:LIVEKIT_URL="wss://TU-PROYECTO.livekit.cloud"; $env:LIVEKIT_TOKEN="eyJ..."
#   .\run-scenarios.ps1                 # todos
#   .\run-scenarios.ps1 -Scenario 4     # uno solo
# Las reglas se limitan al .exe del navegador (no afectan al resto de la PC) y se borran al terminar.
#Requires -RunAsAdministrator
param(
  [ValidateSet('1','3','4','5','7')][string[]]$Scenario = @('1','3','4','5','7'),
  [ValidateSet('chrome','msedge')][string]$Browser = 'chrome'
)
 
$paths = @{
  chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe")
  msedge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")
}
$exe = $paths[$Browser] | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $exe) { throw "No encontré $Browser" }
$env:BROWSER = $Browser
$prefix = 'webrtc-test'
 
function Add-Block($name, $proto, $ports) {
  New-NetFirewallRule -DisplayName "$prefix-$name" -Direction Outbound -Action Block `
    -Program $exe -Protocol $proto -RemotePort ($ports -split ',') | Out-Null
}
function Clear-Rules { Get-NetFirewallRule -DisplayName "$prefix-*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule }
 
# UDP bloqueado salvo 53 (Chrome puede resolver DNS por su cuenta)
function Block-Udp   { Add-Block 'udp'  'UDP' '1-52,54-65535' }
function Block-Tcp7881 { Add-Block 'tcp7881' 'TCP' '7881' }
# Solo TCP 443 permitido (simula firewall corporativo estricto)
function Block-AllBut443 { Block-Udp; Add-Block 'tcp-not-443' 'TCP' '1-442,444-65535' }
 
$results = @()
function Run-Check($label, $expect, $extra = @()) {
  Write-Host "`n=== $label (expect=$expect) ===" -ForegroundColor Cyan
  node webrtc-check.mjs "--expect=$expect" @extra
  $script:results += [pscustomobject]@{ Escenario = $label; Esperado = $expect; Exit = $LASTEXITCODE }
}
 
try {
  Clear-Rules
  foreach ($s in $Scenario) {
    switch ($s) {
      '1' { Run-Check '1 red abierta' 'udp' }
      '3' { Block-Udp; Run-Check '3 sin UDP' 'not-udp'; Clear-Rules }
      '4' { Block-Udp; Block-Tcp7881; Run-Check '4 TURN/TLS' 'tls'; Clear-Rules }
      '5' { Block-AllBut443; Run-Check '5 solo 443' 'tls'; Clear-Rules }
      '7' {
        Write-Host "`n=== 7 UDP se corta a mitad de llamada ===" -ForegroundColor Cyan
        $env:HOLD = '40'
        $log = Join-Path $env:TEMP 'webrtc-s7.log'
        $p = Start-Process node -ArgumentList 'webrtc-check.mjs','--expect=not-udp' -NoNewWindow -PassThru -RedirectStandardOutput $log
        $null = $p.Handle
        Start-Sleep -Seconds 8
        Block-Udp; Block-Tcp7881
        $p.WaitForExit()
        Get-Content $log
        $results += [pscustomobject]@{ Escenario = '7 corte UDP'; Esperado = 'not-udp'; Exit = $p.ExitCode }
        Remove-Item Env:HOLD; Clear-Rules
      }
    }
  }
} finally { Clear-Rules }
 
$results | ForEach-Object { $_ | Add-Member Estado ($(if ($_.Exit -eq 0) {'PASS'} else {'FAIL'})) -PassThru } | Format-Table -AutoSize