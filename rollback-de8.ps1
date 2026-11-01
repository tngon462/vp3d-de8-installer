
param([string]$InstallDir = "$env:LOCALAPPDATA\DE8")
. "$PSScriptRoot\common.ps1"
try {
 $meta = Join-Path $InstallDir 'install-state.json'
 $s = Read-Json $meta
 if ([IO.Path]::GetFullPath($s.AgentPath) -ne [IO.Path]::GetFullPath((Join-Path $InstallDir 'de8-agent.ps1'))) { throw 'Invalid install state path' }
 if ($s.HadAgent -and (Get-FileHash -LiteralPath "$($s.Backup)\de8-agent.ps1" -Algorithm SHA256).Hash -ne $s.OldHash) { throw 'Backup SHA256 mismatch' }
 Stop-Agent $s.AgentPath
 if ($s.HadAgent) {
  Copy-Item -LiteralPath "$($s.Backup)\de8-agent.ps1" -Destination $s.AgentPath -Force
  if ((Get-FileHash -LiteralPath $s.AgentPath -Algorithm SHA256).Hash -ne $s.OldHash) { throw 'Restore hash mismatch' }
  if ($s.OldCommandLine) {
   # Preserve original invocation, only after confirming it targets the restored file.
   $argsLine = $s.OldCommandLine -replace '^\s*(?:"[^"]+"|\S+)\s*',''
   $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $argsLine -WindowStyle Hidden -PassThru
   Start-Sleep -Seconds 3
   if ($p.HasExited -or @(Get-AgentProcesses $s.AgentPath).Count -ne 1) { throw 'Restored agent failed to start' }
   Write-Host 'PASS ROLLBACK: old SHA256 restored; old process running (ONLINE requires old transport check)'
  } else { Write-Host 'PASS ROLLBACK: old SHA256 restored; originally stopped, remains stopped' }
 } else {
  Remove-Item -LiteralPath $s.AgentPath -Force
  Write-Host 'PASS ROLLBACK: new agent removed; no previous agent'
 }
 Move-Item -LiteralPath $meta -Destination (Join-Path $s.Backup 'rolled-back-state.json') -Force
} catch { Write-Host 'FAIL ROLLBACK'; Write-Host $_.Exception.Message; exit 1 }
