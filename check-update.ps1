#requires -Version 5.1
[CmdletBinding()]
param(
 [ValidateRange(1,8760)][int]$EveryHours = 24,
 [string]$ManifestUrl = 'https://raw.githubusercontent.com/tngon462/vp3d-de8-installer/main/manifest.json',
 [string]$RuntimeDir = (Join-Path $PSScriptRoot 'runtime'),
 [string]$PackagePath
)
$ErrorActionPreference = 'Stop'
$lock = $null
try {
 New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null
 try {
  $lock = [IO.File]::Open((Join-Path $RuntimeDir 'check-update.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
 } catch [IO.IOException] {
  Write-Output 'SKIPPED: update check already running'
  exit 0
 }
 $statePath = Join-Path $RuntimeDir 'check-update-state.json'
 $now = [DateTimeOffset]::UtcNow
 if (Test-Path -LiteralPath $statePath) {
  $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
  $last = [DateTimeOffset]::Parse($state.lastAttemptUtc)
  if ($last -gt $now) { throw 'Invalid future check time' }
  if (($now - $last).TotalHours -lt $EveryHours) {
   Write-Output 'SKIPPED: interval not elapsed'
   exit 0
  }
 }
 # Gate failed requests too, avoiding hourly retries to an unavailable host.
 @{lastAttemptUtc=$now.ToString('o')} | ConvertTo-Json |
  Set-Content -LiteralPath $statePath -Encoding UTF8
 $uri = $null
 if (-not [Uri]::TryCreate($ManifestUrl, [UriKind]::Absolute, [ref]$uri) -or
     $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Fragment) {
  throw 'Public HTTPS manifest URL required'
 }
 $versionText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION.txt') -Raw
 if ($versionText -notmatch '(?m)^Packaged-version:\s*(\d+\.\d+\.\d+)\s*$') {
  throw 'Invalid local version'
 }
 $current = [Version]$Matches[1]
 [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
 # Read JSON only. No redirects, package download, execution or installation.
 $remote = Invoke-RestMethod -Uri $uri.AbsoluteUri -Method Get -TimeoutSec 20 -MaximumRedirection 0
 # Raw file hosts may serve JSON as text/plain on Windows PowerShell.
 if ($remote -is [string]) { $remote = $remote | ConvertFrom-Json }
 if ($remote.version -notmatch '^\d+\.\d+\.\d+$' -or
     $remote.sha256 -notmatch '^[a-fA-F0-9]{64}$') {
  throw 'Incomplete release manifest'
 }
 $releaseUri = $null
 if (-not [Uri]::TryCreate([string]$remote.url, [UriKind]::Absolute, [ref]$releaseUri) -or
     $releaseUri.Scheme -ne 'https' -or $releaseUri.UserInfo -or $releaseUri.Fragment) {
  throw 'Public HTTPS release URL required'
 }
 $releaseDate = [DateTimeOffset]::Parse([string]$remote.releasedAt)
 if ($null -eq $remote.notes -or $remote.notes -isnot [string]) { throw 'Invalid release notes' }
 $latest = [Version]$remote.version
 $localHash = ''
 if ($PackagePath) {
  $localHash = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash
 } else {
  $localManifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($localManifest.sha256 -match '^[a-fA-F0-9]{64}$') { $localHash = $localManifest.sha256 }
 }
 $hashStatus = 'UNVERIFIED'
 if ($localHash) {
  $hashStatus = 'DIFFERENT'
  if ($localHash -eq $remote.sha256) { $hashStatus = 'MATCH' }
 }
 $status = 'CURRENT'
 if ($latest -gt $current) { $status = 'UPDATE_AVAILABLE' }
 elseif ($latest -lt $current) { $status = 'LOCAL_NEWER' }
 elseif ($hashStatus -eq 'DIFFERENT') { $status = 'PACKAGE_HASH_MISMATCH' }
 $message = '{0}: local={1} remote={2} sha256={3}' -f $status,$current,$latest,$hashStatus
 Write-Output $message
 if ($status -eq 'UPDATE_AVAILABLE') {
  Write-Output ('URL: ' + $releaseUri.AbsoluteUri)
  Write-Output ('SHA256: ' + $remote.sha256.ToLowerInvariant())
 }
 $logPath = Join-Path $RuntimeDir 'check-update.log'
 if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 32768) {
  Get-Content -LiteralPath $logPath -Tail 50 | Set-Content -LiteralPath ($logPath + '.tmp') -Encoding UTF8
  Move-Item -LiteralPath ($logPath + '.tmp') -Destination $logPath -Force
 }
 Add-Content -LiteralPath $logPath -Value ($now.ToString('o') + ' ' + $message) -Encoding UTF8
} catch {
 # HTTP exception text can expose credentials. Keep logs fixed and short.
 Write-Output 'CHECK_FAILED: verify public manifest, local package and runtime permissions'
 if ($lock) {
  try { Add-Content -LiteralPath (Join-Path $RuntimeDir 'check-update.log') -Value ([DateTimeOffset]::UtcNow.ToString('o') + ' CHECK_FAILED') -Encoding UTF8 } catch {}
 }
 exit 1
} finally {
 if ($null -ne $lock) { $lock.Dispose() }
}
