
param(
 [Parameter(Mandatory=$true)][string]$Server,
 [string]$InstallDir = "$env:LOCALAPPDATA\DE8",
 [Parameter(Mandatory=$true)][string]$TokenPath
)
. "$PSScriptRoot\common.ps1"
try {
 Assert-Server $Server
 $InstallDir = [IO.Path]::GetFullPath($InstallDir)
 $TokenPath = (Resolve-Path -LiteralPath $TokenPath).Path
 $source = Join-Path $PSScriptRoot 'de8-agent.ps1'
 $expected = (Get-Content -LiteralPath "$PSScriptRoot\agent.sha256" -Raw).Trim()
 if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $expected) { throw 'Package SHA256 mismatch' }
 Test-Heartbeat $Server $TokenPath
 New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
 $target = Join-Path $InstallDir 'de8-agent.ps1'
 $meta = Join-Path $InstallDir 'install-state.json'
 if (Test-Path -LiteralPath $meta) { throw 'Existing managed install: rollback before reinstall' }
 $old = @(Get-AgentProcesses $target)
 if ($old.Count -gt 1) { throw 'Multiple old agents; resolve before install' }
 $backup = Join-Path $InstallDir ('backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
 New-Item -ItemType Directory -Path $backup | Out-Null
 $state = @{AgentPath=$target;Server=$Server;TokenPath=$TokenPath;JournalPath=(Join-Path $InstallDir 'task-journal.json');PausePath=(Join-Path $InstallDir 'transport.pause');Backup=$backup;HadAgent=(Test-Path -LiteralPath $target);OldCommandLine=$null;OldHash=$null}
 if ($old.Count) { $state.OldCommandLine = $old[0].CommandLine }
 if ($state.HadAgent) {
  Copy-Item -LiteralPath $target -Destination "$backup\de8-agent.ps1"
  $state.OldHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
 }
 Write-Json $state $meta
 Stop-Agent $target
 Copy-Item -LiteralPath $source -Destination $target -Force
 if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $expected) { throw 'Installed SHA256 mismatch' }
 $null = Start-Agent $state
 Write-Host "PASS INSTALL SHA256=$expected; backup=$backup"
} catch {
 Write-Host 'FAIL INSTALL: see local error; run rollback if install-state.json exists'
 Write-Host $_.Exception.Message
 exit 1
}
