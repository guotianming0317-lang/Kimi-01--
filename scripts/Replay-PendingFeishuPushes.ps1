param(
  [Parameter(Mandatory = $true)]
  [string]$QueueRoot,

  [string]$SettingsPath = "",

  [ValidateRange(1, 10)]
  [int]$MaxAttempts = 3,

  [ValidateRange(1, 30)]
  [int]$RetryDelaySeconds = 5
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "HeldStockMonitorShared.ps1")

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
  $item = Get-Content -LiteralPath $queueFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
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
    Remove-Item -LiteralPath $queueFile.FullName -Force
    $replayed++
  } catch {
    Write-Output ("Replay failed for {0}: {1}" -f $queueFile.Name, $_.Exception.Message)
    break
  }
}

Write-Output ("Replayed pending pushes: {0}" -f $replayed)
