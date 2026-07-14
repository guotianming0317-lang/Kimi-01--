param(
  [string]$HoldingsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "data\holdings.csv"),
  [string]$DataRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) "data"),
  [ValidateSet("0925", "0930", "0940")]
  [string]$Checkpoint = "0925",
  [string]$QuoteDataPath = "",
  [string]$DailyMetricsPath = "",
  [string]$TrendDataPath = "",
  [switch]$NoPush
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "OpenStrengthMonitorShared.ps1")

$tradeDate = Get-Date -Format "yyyy-MM-dd"
$context = New-OpenStrengthContext -DataRoot $DataRoot -TradeDate $tradeDate
if (Test-MonitorPaused -PauseFlag $context.PauseFlag) {
  Write-MonitorLog -LogFile $context.LogFile -Message "paused by $($context.PauseFlag)"
  Write-Output ("Monitoring paused: {0}" -f $context.PauseFlag)
  exit 0
}

Write-MonitorLog -LogFile $context.LogFile -Message "start capture checkpoint=$Checkpoint"
$holdings = @(Import-HeldStocks -Path $HoldingsPath)
if (-not $holdings) {
  throw "No held stocks available for open-strength monitoring."
}

$auctionMetricsCachePath = Join-Path (Join-Path $DataRoot "auction_open\cache") ("daily_metrics_{0}.json" -f ((Get-Date).ToString("yyyyMMdd")))

$rows = @(Get-OpenStrengthCaptureRows `
  -Checkpoint $Checkpoint `
  -Holdings $holdings `
  -QuoteDataPath $QuoteDataPath `
  -DailyMetricsPath $DailyMetricsPath `
  -CachePath $auctionMetricsCachePath `
  -TrendDataPath $TrendDataPath)

$targetPath = Get-OpenStrengthSnapshotPath -DayRoot $context.DayRoot -Checkpoint $Checkpoint
Save-OpenStrengthPayload -Path $targetPath -Checkpoint $Checkpoint -Rows $rows | Out-Null
Write-MonitorLog -LogFile $context.LogFile -Message "saved $targetPath rows=$($rows.Count)"
Write-Output ("Open strength snapshot saved: {0}" -f $targetPath)
