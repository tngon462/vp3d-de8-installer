param(
  [Parameter(Mandatory=$true)][string]$Server,
  [Parameter(Mandatory=$true)][string]$TokenPath,
  [int]$IntervalSeconds = 6,
  [int]$TaskTimeoutSeconds = 300,
  [int]$PosIdleSeconds = 45,
  [string]$JournalPath,
  [string]$PausePath,
  [switch]$Probe
)

$ErrorActionPreference = 'Stop'

if ($Server -notmatch '^https://[a-zA-Z0-9.-]+/?$') {
  throw 'Server phai la HTTPS cloud (khong dung IP LAN)'
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not (Test-Path -LiteralPath $TokenPath -PathType Leaf)) {
  throw "Khong thay file token: $TokenPath"
}
$token = (Get-Content -LiteralPath $TokenPath -Raw).Trim()
if ($token.Length -lt 32) { throw "Token khong hop le" }

$base = $Server.TrimEnd('/')
$headers = @{ Authorization = "Bearer $token" }
$state = @{ status = 'idle' }
if (-not $JournalPath) { $JournalPath = Join-Path (Split-Path -Parent $TokenPath) 'task-journal.json' }
$journal = @{}
if (Test-Path -LiteralPath $JournalPath) {
  # Fail closed on corrupt state: never silently discard execution history.
  $saved = Get-Content -LiteralPath $JournalPath -Raw | ConvertFrom-Json
  foreach ($p in $saved.PSObject.Properties) { $journal[$p.Name] = $p.Value }
}
function Save-Journal {
  $tmp = $JournalPath + '.tmp'
  [IO.File]::WriteAllText($tmp, ($journal | ConvertTo-Json -Depth 8), [Text.Encoding]::UTF8)
  Move-Item -LiteralPath $tmp -Destination $JournalPath -Force
}
# One process per token/journal. Prevent simultaneous agents from racing the ledger.
$lock = [IO.File]::Open(($JournalPath + '.lock'), 'OpenOrCreate', 'ReadWrite', 'None')

# ---------- do thoi gian khong thao tac (chi doc) ----------
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class TngonIdle {
  [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
  public static uint Seconds() {
    LASTINPUTINFO li = new LASTINPUTINFO();
    li.cbSize = (uint)Marshal.SizeOf(li);
    if (!GetLastInputInfo(ref li)) return 0;
    return (uint)((Environment.TickCount - (int)li.dwTime) / 1000);
  }
}
"@ -ErrorAction SilentlyContinue

function Get-IdleSeconds {
  try { return [int][TngonIdle]::Seconds() } catch { return 999 }
}

# ---------- tim Hermes CLI ----------
function Find-Hermes {
  $c = Get-Command hermes -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $cands = @(
    (Join-Path $env:LOCALAPPDATA 'hermes\hermes-agent\.hermes\bin\hermes.exe'),
    (Join-Path $env:USERPROFILE 'AppData\Local\hermes\hermes-agent\.hermes\bin\hermes.exe'),
    'C:\Program Files\Hermes\hermes.exe'
  )
  foreach ($p in $cands) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
  return $null
}
$hermes = Find-Hermes

# ---------- goi API Đệ 16 ----------
function Invoke-DeviceApi([string]$Path, [hashtable]$Payload) {
  if (-not $Payload.requestId) {
    $identity = [guid]::NewGuid().ToString()
    if ($Path -match '/(ack|result)$') { $identity = "$Path|$($Payload.id)|$($Payload.attempt)" }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $Payload.requestId = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity)))).Replace('-','').ToLower() } finally { $sha.Dispose() }
  }
  if ($PausePath -and (Test-Path -LiteralPath $PausePath)) { throw 'DE8 transport paused' }
  $json = ($Payload | ConvertTo-Json -Compress)
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $deadline = (Get-Date).AddSeconds(40)
  do {
    $answer = Invoke-RestMethod -Uri ($base + $Path) -Method Post -Headers $headers -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 15
    if (-not $answer.pending) { if ($answer.ok -ne $true) { throw 'Server did not confirm request' }; return $answer }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  throw 'Bridge timeout'
}

function Send-Heartbeat([bool]$PosBusy, [string]$Status) {
    $null = Invoke-DeviceApi '/api/device/de8/heartbeat' @{
      device = 'de8'; mode = 'agent'; posBusy = $PosBusy; status = $Status
    }
}

# ---------- thuc thi ----------
function Invoke-HermesTask([string]$Prompt, [int]$TimeoutSec) {
  if (-not $hermes) { throw "Khong tim thay Hermes CLI tren may nay" }
  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    # Prompt phải là MỘT tham số duy nhất: tự bọc nháy và bỏ xuống dòng.
    $flat = ($Prompt -replace '\r?\n', ' ').Replace('"', "'")
    $argLine = '-z "' + $flat + '"'
    $p = Start-Process -FilePath $hermes -ArgumentList $argLine `
      -PassThru -RedirectStandardOutput $tmp -RedirectStandardError ($tmp + '.err') `
      -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not $p.HasExited) {
      if ((Get-Date) -gt $deadline) {
        try { $p.Kill() } catch {}
        throw "Hermes qua thoi gian cho phep ($TimeoutSec giay)"
      }
      # Giữ heartbeat trong lúc chạy lâu để VP 3D không thấy Đệ 8 offline.
      try { Send-Heartbeat ([bool]$script:posBusy) 'working' } catch {}
      Start-Sleep -Seconds 5
    }
    $p.Refresh()
    $exit = $p.ExitCode
    $out = (Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
    if (($null -ne $exit) -and ($exit -ne 0) -and [string]::IsNullOrWhiteSpace($out)) {
      $err = (Get-Content -LiteralPath ($tmp + '.err') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
      throw (("{0}" -f ($(if ($err) { $err } else { 'hermes exit ' + $exit }))).Trim())
    }
    return (($out -as [string]).Trim())
  } finally {
    Remove-Item -LiteralPath $tmp, ($tmp + '.err') -Force -ErrorAction SilentlyContinue
  }
}

# Du phong khi may chua co Hermes: chi doc may, khong doi trang thai.
function Invoke-LocalReadOnly([string]$Message) {
  $m = $Message.ToLower()
  if ($m -match 'hostname|tên máy|ten may') { return (hostname) }
  if ($m -match 'phiên bản windows|windows version|version windows') {
    return ((Get-CimInstance Win32_OperatingSystem).Caption + ' ' + (Get-CimInstance Win32_OperatingSystem).Version)
  }
  if ($m -match 'dung lượng|ổ đĩa|disk|free space') {
    return ((Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3") | ForEach-Object {
      '{0} {1}GB con {2}GB' -f $_.DeviceID, [math]::Round($_.Size/1GB,1), [math]::Round($_.FreeSpace/1GB,1)
    }) -join '; '
  }
  if ($m -match 'tiến trình|process') {
    return ((Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 |
      ForEach-Object { '{0} ({1}MB)' -f $_.ProcessName, [math]::Round($_.WorkingSet64/1MB,0) }) -join '; ')
  }
  if ($m -match 'uptime|hoạt động bao lâu|thời gian hoạt động') {
    $os = Get-CimInstance Win32_OperatingSystem
    return ('Uptime: ' + [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1) + ' gio')
  }
  throw "Nhiệm vụ này cần Hermes trên Đệ 8 (chưa cài). Chỉ hỗ trợ: hostname, phiên bản Windows, dung lượng ổ, tiến trình, uptime."
}

function Invoke-Task([string]$Message) {
  if ($Message -eq 'DE8_READONLY_DIAGNOSTIC_V1') { return ('hostname=' + [Environment]::MachineName + '; diskCount=' + @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3").Count) }
  if ($hermes) { return (Invoke-HermesTask $Message $TaskTimeoutSeconds) }
  return (Invoke-LocalReadOnly $Message)
}

# ---------- che do kiem tra ----------
if ($Probe) {
  $os = Get-CimInstance Win32_OperatingSystem
  [PSCustomObject]@{
    May            = $env:COMPUTERNAME
    Windows        = $os.Caption + ' ' + $os.Version
    NguoiDung      = $env:USERNAME
    QuyenAdmin     = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    HermesCLI      = $(if ($hermes) { $hermes } else { 'KHONG THAY' })
    TokenPath      = $TokenPath
    TokenDoDai     = $token.Length
    Server         = $base
    IdleGiay       = Get-IdleSeconds
    PosDangBan     = ((Get-IdleSeconds) -lt $PosIdleSeconds)
  } | Format-List
  return
}

Write-Host ("DE8 agent khoi dong. Server=$base Hermes=" + $(if ($hermes) { $hermes } else { 'khong co (che do doc may)' }))

$current = 'idle'
$failures = 0
while ($true) {
  $idle = Get-IdleSeconds
  $posBusy = ($idle -lt $PosIdleSeconds)
  try {
    Send-Heartbeat $posBusy $current
    # Retry completion delivery before asking for more work.
    foreach ($key in @($journal.Keys)) {
      $entry = $journal[$key]
      if ($entry.status -eq 'started') {
        $journal[$key] = @{ id=$entry.id; attempt=$entry.attempt; status='error'; result='Agent restarted after execution began; not rerun automatically.'; sent=$false }
        Save-Journal
        $entry = $journal[$key]
      }
      if (-not $entry.sent) {
        $null = Invoke-DeviceApi '/api/device/de8/result' @{ id=$entry.id; attempt=$entry.attempt; status=$entry.status; result=$entry.result }
        $journal[$key] = @{ id=$entry.id; attempt=$entry.attempt; status=$entry.status; result=$entry.result; sent=$true }
        Save-Journal
      }
    }
    $r = Invoke-DeviceApi '/api/device/de8/poll' @{ device = 'de8'; posBusy = $posBusy }
    foreach ($t in @($r.items)) {
      if (-not $t) { continue }
      # Chan lan 2: viec cham POS ma may dang ban thi bo qua, nhip sau nhan lai.
      if ($t.posTouch -and $posBusy) { continue }
      $attempt = [int]$t.attempt
      if ($attempt -lt 1) { throw 'Task missing attempt' }
      $key = "$($t.id):$attempt"
      if ($journal.ContainsKey($key)) { continue }
      $null = Invoke-DeviceApi '/api/device/de8/ack' @{ id=$t.id; attempt=$attempt }
      $journal[$key] = @{ id=$t.id; attempt=$attempt; status='started'; ackConfirmed=$true; sent=$false }
      Save-Journal
      Write-Host ("[{0}] nhan {1}: {2}" -f (Get-Date -Format 'HH:mm:ss'), $t.id, $t.message.Substring(0, [Math]::Min(70, $t.message.Length)))
      $current = 'working'
      $script:posBusy = $posBusy
      try { Send-Heartbeat $posBusy $current } catch {}
      $status = 'done'; $result = ''
      try { $result = Invoke-Task $t.message }
      catch { $status = 'error'; $result = "Loi: " + $_.Exception.Message }
      if ($result.Length -gt 1800) { $result = $result.Substring(0, 1800) + '...' }
      $journal[$key] = @{ id=$t.id; attempt=$attempt; status=$status; result=$result; ackConfirmed=$true; sent=$false }
      Save-Journal
      try {
        $null = Invoke-DeviceApi '/api/device/de8/result' @{ id = $t.id; attempt=$attempt; status = $status; result = $result }
        $journal[$key].sent = $true
        Save-Journal
        Write-Host ("[{0}] {1} {2}" -f (Get-Date -Format 'HH:mm:ss'), $status.ToUpper(), $t.id)
      } catch {
        Write-Warning ("khong gui duoc ket qua: " + $_.Exception.Message)
      }
      $current = 'idle'
      Send-Heartbeat $posBusy $current
    }
    $failures = 0
  } catch {
    $failures = [Math]::Min(6, $failures + 1)
    Write-Warning ("poll loi: " + $_.Exception.Message)
  }
  $delay = [Math]::Min(60, $IntervalSeconds * [Math]::Pow(2, $failures))
  Start-Sleep -Milliseconds ([int]($delay * 1000) + (Get-Random -Minimum 0 -Maximum 1000))
}
