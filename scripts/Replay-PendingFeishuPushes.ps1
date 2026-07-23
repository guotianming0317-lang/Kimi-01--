param(
  [Parameter(Mandatory = $true)]
  [string]$QueueRoot,

  [string]$SettingsPath = "",

  [datetime]$CurrentTime = (Get-Date),

  [ValidateRange(1, 10)]
  [int]$MaxAttempts = 3,

  [ValidateRange(1, 30)]
  [int]$RetryDelaySeconds = 5
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "HeldStockMonitorShared.ps1")

function Test-IsStaleQueuedPush {
  param(
    [object]$QueueItem,
    [datetime]$Now = (Get-Date)
  )

  $queuedAtText = [string]$QueueItem.queued_at
  if ([string]::IsNullOrWhiteSpace($queuedAtText)) {
    return $false
  }

  $queuedAtOffset = [datetimeoffset]::MinValue
  if (-not [datetimeoffset]::TryParse($queuedAtText, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$queuedAtOffset)) {
    return $false
  }

  $queuedAt = $queuedAtOffset.LocalDateTime

  if ($queuedAt.Date -lt $Now.Date) {
    return $true
  }

  return $false
}

function Lock-QueuedPushFile {
  param(
    [Parameter(Mandatory = $true)]
    [System.IO.FileInfo]$QueueFile
  )

  $processingPath = [System.IO.Path]::ChangeExtension($QueueFile.FullName, ".processing.json")
  try {
    Move-Item -LiteralPath $QueueFile.FullName -Destination $processingPath -ErrorAction Stop
    return Get-Item -LiteralPath $processingPath -ErrorAction Stop
  } catch {
    return $null
  }
}

function Restore-QueuedPushFile {
  param(
    [Parameter(Mandatory = $true)]
    [System.IO.FileInfo]$ProcessingFile
  )

  $queuePath = $ProcessingFile.FullName -replace '\.processing\.json$', '.json'
  Move-Item -LiteralPath $ProcessingFile.FullName -Destination $queuePath -Force
}

if (-not (Test-Path -LiteralPath $QueueRoot)) {
  Write-Output "No pending push queue found."
  exit 0
}

$sendScript = Join-Path $PSScriptRoot "Send-FeishuCard.ps1"
$queueFiles = @(Get-ChildItem -LiteralPath $QueueRoot -Filter "queued_push_*.json" -ErrorAction SilentlyContinue | Sort-Object Name)
if (-not $queueFiles) {
  Write-Output "No pending push items."
  exit 0
}

$replayed = 0
foreach ($queueFile in $queueFiles) {
  $lockedQueueFile = Lock-QueuedPushFile -QueueFile $queueFile
  if ($null -eq $lockedQueueFile) {
    Write-Output ("Skipped busy queued push: {0}" -f $queueFile.Name)
    continue
  }

  $item = Get-Content -LiteralPath $lockedQueueFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  if (Test-IsStaleQueuedPush -QueueItem $item -Now $CurrentTime) {
    Remove-Item -LiteralPath $lockedQueueFile.FullName -Force
    Write-Output ("Dropped stale queued push from previous day: {0}" -f $queueFile.Name)
    continue
  }
  $params = @{
    Title = [string]$item.title
    Template = [string]$item.template
    MaxAttempts = $MaxAttempts
    RetryDelaySeconds = $RetryDelaySeconds
  }

  if ($SettingsPath) {
    $params.SettingsPath = $SettingsPath
  } elseif ($item.settings_path) {
    $params.SettingsPath = [string]$item.settings_path
  }

  if ($item.content_path -and (Test-Path -LiteralPath ([string]$item.content_path))) {
    $params.ContentPath = [string]$item.content_path
  } else {
    $params.Content = [string]$item.content
  }

  try {
    Invoke-HiddenPowershellScript -ScriptPath $sendScript -Parameters $params | Out-Null
    Remove-Item -LiteralPath $lockedQueueFile.FullName -Force
    $replayed++
  } catch {
    if (Test-Path -LiteralPath $lockedQueueFile.FullName) {
      Restore-QueuedPushFile -ProcessingFile $lockedQueueFile
    }
    Write-Output ("Replay failed for {0}: {1}" -f $queueFile.Name, $_.Exception.Message)
    break
  }
}

Write-Output ("Replayed pending pushes: {0}" -f $replayed)
