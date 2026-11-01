
param(
 [string]$InstallDir = "$env:LOCALAPPDATA\DE8",
 [Parameter(Mandatory=$true)][string]$SessionCookiePath,
 [int]$TimeoutSeconds = 240
)
. "$PSScriptRoot\common.ps1"
$paused = $false
try {
 $s = Read-Json (Join-Path $InstallDir 'install-state.json')
 Assert-Server $s.Server
 $cookie = (Get-Content -LiteralPath $SessionCookiePath -Raw).Trim()
 function Cloud([string]$Path,$Body) {
  try {
   $params = @{Uri=($s.Server.TrimEnd('/')+$Path);Headers=@{Cookie=$cookie};TimeoutSec=20}
   if ($null -ne $Body) { $params.Method='Post'; $params.Body=($Body | ConvertTo-Json -Compress); $params.ContentType='application/json' }
   Invoke-RestMethod @params
  } catch { throw 'Cloud verification failed; credentials redacted' }
 }
 function Device { (Cloud '/api/state' $null).agents | Where-Object { $_.id -eq 'de8' } }
 Test-Heartbeat $s.Server $s.TokenPath
 if (@(Get-AgentProcesses $s.AgentPath).Count -ne 1) { throw 'Expected one installed agent' }
 $previous = $null
 for ($i=1; $i -le 5; $i++) {
  $deadline = (Get-Date).AddSeconds(60)
  do {
   $d = Device
   if ($d.status -eq 'offline') { throw 'OFFLINE during five-cycle check' }
   if ($d.lastSeen -and $d.lastSeen -ne $previous) { break }
   if ((Get-Date) -gt $deadline) { throw 'Heartbeat did not advance' }
   Start-Sleep -Seconds 2
  } while ($true)
  $previous = $d.lastSeen
  Write-Host "PASS ONLINE cycle $i/5 lastSeen=$previous"
  Start-Sleep -Seconds 6
 }
 $task = (Cloud '/api/task' @{to='de8';message='DE8_READONLY_DIAGNOSTIC_V1';idempotencyKey=([guid]::NewGuid().ToString())}).event
 if (-not $task.id) { throw 'No task ID returned' }
 $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
 do {
  $entry = $null
  if (Test-Path -LiteralPath $s.JournalPath) {
   $j = Read-Json $s.JournalPath
   $entry = @($j.PSObject.Properties | ForEach-Object { $_.Value } | Where-Object { $_.id -eq $task.id -and $_.ackConfirmed -eq $true -and $_.sent -eq $true -and $_.status -eq 'done' }) | Select-Object -First 1
  }
  $remote = (Cloud '/api/tasks' $null).items | Where-Object { $_.id -eq $task.id }
  if ($entry -and $remote.status -eq 'done' -and $remote.result -eq $entry.result -and $entry.result -match '^hostname=.+; diskCount=\d+$') { break }
  if ((Get-Date) -gt $deadline) { throw 'Task ACK/result not confirmed both locally and by cloud' }
  Start-Sleep -Seconds 3
 } while ($true)
 Write-Host ("PASS ACK + RESULT task=" + $task.id)
 if (Test-Path -LiteralPath $s.PausePath) { throw 'Transport already paused' }
 [IO.File]::WriteAllText($s.PausePath,'verification')
 $paused = $true
 # Allow an already in-flight request to finish before measuring the outage.
 Start-Sleep -Seconds 45
 $before = Device
 if ($before.status -ne 'offline') { throw 'Transport did not go OFFLINE' }
 $outageEnd = (Get-Date).AddSeconds(30)
 do {
  Start-Sleep -Seconds 2
  $sample = Device
  if ($sample.status -ne 'offline' -or $sample.lastSeen -ne $before.lastSeen) { throw 'Outage interrupted' }
 } while ((Get-Date) -lt $outageEnd)
 $after = Device
 if ($before.status -ne 'offline' -or $after.status -ne 'offline' -or $before.lastSeen -ne $after.lastSeen) { throw 'Transport outage not confirmed' }
 Write-Host 'PASS DE8 transport disconnected 30 seconds; cloud OFFLINE'
 Remove-Item -LiteralPath $s.PausePath -Force
 $paused = $false
 $deadline = (Get-Date).AddSeconds(180)
 do {
  $d = Device
  if ($d.status -ne 'offline' -and $d.lastSeen -ne $after.lastSeen) { break }
  if ((Get-Date) -gt $deadline) { throw 'Automatic reconnect timed out' }
  Start-Sleep -Seconds 3
 } while ($true)
 Write-Host 'PASS RECONNECT; PASS ALL'
} catch { Write-Host 'FAIL VERIFY'; Write-Host $_.Exception.Message; exit 1 }
finally { if ($paused) { Remove-Item -LiteralPath $s.PausePath -Force -ErrorAction SilentlyContinue } }
