param(
  [string]$HoldingsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "data\holdings.csv"),
  [string]$DataRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) "data"),
  [string]$TradeDate = (Get-Date -Format "yyyy-MM-dd"),
  [string]$AfterHoursDataPath = "",
  [string]$TrendDataPath = "",
  [switch]$Final,
  [switch]$NoPush
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "AuctionMonitorShared.ps1")

function Resolve-AfterHoursDataPath {
  param(
    [string]$PreferredPath,
    [string]$DataRoot
  )

  if ($PreferredPath) {
    return $PreferredPath
  }

  $defaultPath = Join-Path $DataRoot "after_hours_external.latest.json"
  if (Test-Path -LiteralPath $defaultPath) {
    return $defaultPath
  }

  return ""
}

$context = $null
try {
  $sessionConfig = Get-AuctionSessionConfig -Session after_hours
  $context = New-AfterHoursContext -DataRoot $DataRoot -TradeDate $TradeDate
  if (Test-MonitorPaused -PauseFlag $context.PauseFlag) {
    Write-MonitorLog -LogFile $context.LogFile -Message "paused by $($context.PauseFlag)"
    Write-Output ("Monitoring paused: {0}" -f $context.PauseFlag)
    exit 0
  }

  Write-MonitorLog -LogFile $context.LogFile -Message "start after_hours trade_date=$TradeDate"
  $holdings = @(Import-HeldStocks -Path $HoldingsPath)
  if (-not $holdings) {
    throw "No held stocks available for after-hours report."
  }

  $closeSnapshotDir = Join-Path (Join-Path $DataRoot "auction_close\snapshots") ((Get-Date $TradeDate).ToString("yyyyMMdd"))
  $closeSnapshots = @(Get-AuctionSnapshotsForSession -SnapshotDateDir $closeSnapshotDir -Session close)
  $closeSnapshot = @($closeSnapshots | Where-Object { [string]$_.checkpoint -eq "1500" } | Select-Object -Last 1)
  if (-not $closeSnapshot) {
    throw "Closing auction 15:00 snapshot is required before after-hours report."
  }

  $resolvedAfterHoursDataPath = Resolve-AfterHoursDataPath -PreferredPath $AfterHoursDataPath -DataRoot $DataRoot
  $afterHoursDataMap = Get-AfterHoursDataMap -Holdings $holdings -AfterHoursDataPath $resolvedAfterHoursDataPath -TrendDataPath $TrendDataPath
  $assessments = foreach ($holding in $holdings) {
    $closeRow = @($closeSnapshot[0].rows | Where-Object { [string]$_.code -eq [string]$holding.Code } | Select-Object -First 1)[0]
    $afterHoursData = if ($afterHoursDataMap.ContainsKey([string]$holding.Code)) { $afterHoursDataMap[[string]$holding.Code] } else { $null }
    ConvertTo-AfterHoursAssessment -Holding $holding -CloseRow $closeRow -AfterHoursData $afterHoursData
  }

  $reportJson = New-AfterHoursReportJson -TradeDate $TradeDate -Assessments $assessments
  $reportJsonPath = Get-AfterHoursReportJsonPath -DayRoot $context.DayRoot
  $reportJson | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportJsonPath -Encoding UTF8

  $report = New-AfterHoursReportContent -TradeDate $TradeDate -Assessments $assessments
  $reportName = if ($Final) {
    "after_hours_fixed_report_{0}_final.md" -f (Get-Date -Format "yyyyMMdd_HHmmss")
  } else {
    "after_hours_fixed_report_{0}.md" -f (Get-Date -Format "yyyyMMdd_HHmmss")
  }
  $reportPath = Join-Path $context.Outbox $reportName
  $encoding = New-Object System.Text.UTF8Encoding($true)
  [System.IO.File]::WriteAllText($reportPath, $report, $encoding)

  if ($NoPush) {
    Write-MonitorLog -LogFile $context.LogFile -Message "dry-run generated $reportPath"
    Write-Output ("After-hours fixed-price report generated: {0}" -f $reportPath)
    exit 0
  }

  $sendScript = Join-Path $PSScriptRoot "Send-FeishuCard.ps1"
  $icon = [char]::ConvertFromUtf32(0x1F535)
  $title = $icon + "[" + $sessionConfig.Title + "] " + $TradeDate
  $sendParams = @{
    Title = [string]$title
    Template = "blue"
    ContentPath = [string]$reportPath
    QueueRoot = [string]$context.PendingPushRoot
  }
  if (Test-Path -LiteralPath $context.AuctionSettingsPath) {
    $sendParams.SettingsPath = [string]$context.AuctionSettingsPath
  }

  Invoke-HiddenPowershellScript -ScriptPath $sendScript -Parameters $sendParams | Out-Null

  Write-MonitorLog -LogFile $context.LogFile -Message "pushed $reportPath"
  Write-Output ("After-hours fixed-price report generated: {0}" -f $reportPath)
} catch {
  if ($null -eq $context) {
    $context = New-AfterHoursContext -DataRoot $DataRoot -TradeDate $TradeDate
  }
  Write-MonitorLog -LogFile $context.LogFile -Message "error after_hours trade_date=$TradeDate detail=$($_.Exception.Message)"
  throw
}
