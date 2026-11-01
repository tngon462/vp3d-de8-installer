
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Assert-Server([string]$Server) {
 if ($Server -notmatch '^https://[a-zA-Z0-9.-]+/?$') { throw 'HTTPS origin required' }
}
function Read-Json([string]$Path) { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
function Write-Json($Value,[string]$Path) {
 $tmp = $Path + '.tmp'
 $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tmp -Encoding UTF8
 Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Get-AgentProcesses([string]$Path) {
 $escaped = [regex]::Escape([IO.Path]::GetFullPath($Path))
 @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
  $_.CommandLine -match ('(?i)-File\s+"?' + $escaped + '(?:"|\s|$)')
 })
}
function Stop-Agent([string]$Path) {
 foreach ($proc in @(Get-AgentProcesses $Path)) {
  Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
  Wait-Process -Id $proc.ProcessId -Timeout 15 -ErrorAction SilentlyContinue
 }
 if (@(Get-AgentProcesses $Path).Count -ne 0) { throw 'Agent still running' }
}
function Start-Agent($State) {
 foreach ($v in @($State.AgentPath,$State.Server,$State.TokenPath,$State.JournalPath,$State.PausePath)) {
  if ($v -match '["\r\n]') { throw 'Unsafe argument' }
 }
 $argsLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $State.AgentPath + '" -Server "' + $State.Server + '" -TokenPath "' + $State.TokenPath + '" -JournalPath "' + $State.JournalPath + '" -PausePath "' + $State.PausePath + '"'
 $proc = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $argsLine -WindowStyle Hidden -PassThru
 Start-Sleep -Seconds 3
 if ($proc.HasExited) { throw 'Agent exited during startup' }
 return $proc.Id
}
function Test-Heartbeat([string]$Server,[string]$TokenPath) {
 Assert-Server $Server
 if (-not (Test-Path -LiteralPath $TokenPath -PathType Leaf)) { throw 'Device key file missing' }
 $key = (Get-Content -LiteralPath $TokenPath -Raw).Trim()
 if ($key.Length -lt 32) { throw 'Device key too short' }
 $sha = [Security.Cryptography.SHA256]::Create()
 try { $id = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([guid]::NewGuid().ToString())))).Replace('-','').ToLower() } finally { $sha.Dispose() }
 $body = @{requestId=$id;device='de8';mode='agent';posBusy=$true;status='idle'} | ConvertTo-Json -Compress
 $deadline = (Get-Date).AddSeconds(90)
 do {
  try { $r = Invoke-RestMethod -Uri ($Server.TrimEnd('/') + '/api/device/de8/heartbeat') -Method Post -Headers @{Authorization=('Bearer ' + $key)} -ContentType 'application/json' -Body $body -TimeoutSec 15 }
  catch { throw 'Heartbeat failed (HTTP/auth/network); key redacted' }
  if (-not $r.pending) {
   if ($r.ok -ne $true) { throw 'Heartbeat not confirmed' }
   return
  }
  Start-Sleep -Seconds 2
 } while ((Get-Date) -lt $deadline)
 throw 'Heartbeat bridge timeout; HTTP 202 is not ONLINE'
}
