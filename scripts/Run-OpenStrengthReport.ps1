param(
  [string]$HoldingsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "data\holdings.csv"),
  [string]$DataRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) "data"),
  [string]$TradeDate = (Get-Date -Format "yyyy-MM-dd"),
  [switch]$NoPush
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "OpenStrengthMonitorShared.ps1")

$context = New-OpenStrengthContext -DataRoot $DataRoot -TradeDate $TradeDate
if (Test-MonitorPaused -PauseFlag $context.PauseFlag) {
  Write-MonitorLog -LogFile $context.LogFile -Message "paused by $($context.PauseFlag)"
  Write-Output ("Monitoring paused: {0}" -f $context.PauseFlag)
  exit 0
}

Write-MonitorLog -LogFile $context.LogFile -Message "start report trade_date=$TradeDate"
$holdings = @(Import-HeldStocks -Path $HoldingsPath)
if (-not $holdings) {
  throw "No held stocks available for open-strength report."
}

$auctionPayload = Read-OpenStrengthPayload -Path (Get-OpenStrengthSnapshotPath -DayRoot $context.DayRoot -Checkpoint "0925")
$openPayload = Read-OpenStrengthPayload -Path (Get-OpenStrengthSnapshotPath -DayRoot $context.DayRoot -Checkpoint "0930")
$snapshotPayload = Read-OpenStrengthPayload -Path (Get-OpenStrengthSnapshotPath -DayRoot $context.DayRoot -Checkpoint "0940")

$assessments = foreach ($holding in $holdings) {
  $auctionRow = Find-OpenStrengthRow -Payload $auctionPayload -Code $holding.Code
  $openRow = Find-OpenStrengthRow -Payload $openPayload -Code $holding.Code
  $snapshotRow = Find-OpenStrengthRow -Payload $snapshotPayload -Code $holding.Code

  ConvertTo-OpenStrengthAssessment `
    -Holding $holding `
    -AuctionRow $auctionRow `
    -OpenRow $openRow `
    -SnapshotRow $snapshotRow
}

$orderedAssessments = @($assessments | Sort-Object reminder_priority, { - (Get-SafeDouble $_.score) }, name)
$reportJson = New-OpenStrengthReportJson -TradeDate $TradeDate -Assessments $orderedAssessments
$reportJsonPath = Get-OpenStrengthSnapshotPath -DayRoot $context.DayRoot -Checkpoint "report"
$reportJson | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportJsonPath -Encoding UTF8

$reportText = New-OpenStrengthReportContent -TradeDate $TradeDate -Assessments $orderedAssessments
$reportPath = Join-Path $context.Outbox ("open_strength_report_{0}.md" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$encoding = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($reportPath, $reportText, $encoding)

if ($NoPush) {
  Write-MonitorLog -LogFile $context.LogFile -Message "dry-run generated $reportPath"
  Write-Output ("Open strength report generated: {0}" -f $reportPath)
  exit 0
}

$sendScript = Join-Path $PSScriptRoot "Send-FeishuCard.ps1"
$icon = [char]::ConvertFromUtf32(0x1F7E3)
$title = $icon + "[" + (U '\u0041\u80a1\u6301\u4ed39:40\u5f00\u76d8\u627f\u63a5\u5206\u6790') + "] " + $TradeDate
$sendParams = @{
  Title = [string]$title
  Template = "blue"
  ContentPath = [string]$reportPath
  QueueRoot = [string]$context.PendingPushRoot
}
if (Test-Path -LiteralPath $context.SettingsPath) {
  $sendParams.SettingsPath = [string]$context.SettingsPath
}
Invoke-HiddenPowershellScript -ScriptPath $sendScript -Parameters $sendParams | Out-Null

Write-MonitorLog -LogFile $context.LogFile -Message "pushed $reportPath"
Write-Output ("Open strength report generated: {0}" -f $reportPath)
