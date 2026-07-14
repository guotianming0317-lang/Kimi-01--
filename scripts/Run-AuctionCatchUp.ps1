param(
  [string]$HoldingsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "data\holdings.csv"),
  [string]$DataRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) "data"),
  [ValidateSet("open", "close")]
  [string]$Session = "open",
  [string]$QuoteDataPath = "",
  [string]$DailyMetricsPath = "",
  [string]$TrendDataPath = "",
  [datetime]$CurrentTime = (Get-Date),
  [switch]$NoPush
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "AuctionMonitorShared.ps1")

$context = $null
try {
  $sessionConfig = Get-AuctionSessionConfig -Session $Session
  $context = New-AuctionContext -DataRoot $DataRoot -Session $Session
  if (Test-MonitorPaused -PauseFlag $context.PauseFlag) {
    Write-MonitorLog -LogFile $context.LogFile -Message "paused by $($context.PauseFlag)"
    Write-Output ("Monitoring paused: {0}" -f $context.PauseFlag)
    exit 0
  }

  Write-MonitorLog -LogFile $context.LogFile -Message "catchup start $Session current_time=$($CurrentTime.ToString('HH:mm:ss'))"
  $holdings = @(Import-HeldStocks -Path $HoldingsPath)
  if (-not $holdings) {
    throw "No held stocks available for auction catch-up."
  }

  $eligible = @(Get-AuctionEligibleCheckpoints -SessionConfig $sessionConfig -CurrentTime $CurrentTime)
  if ($eligible.Count -eq 0) {
    Write-MonitorLog -LogFile $context.LogFile -Message "catchup skipped $Session current_time=$($CurrentTime.ToString('HH:mm:ss')) no eligible checkpoints"
    Write-Output "No eligible auction checkpoints yet."
    exit 0
  }

  $missing = @(Get-AuctionMissingCheckpoints -SnapshotDateDir $context.SnapshotDateDir -SessionConfig $sessionConfig -CurrentTime $CurrentTime)
  if ($missing.Count -eq 0) {
    Write-MonitorLog -LogFile $context.LogFile -Message "catchup skipped $Session current_time=$($CurrentTime.ToString('HH:mm:ss')) nothing missing"
    Write-Output "No missing auction checkpoints."
    exit 0
  }

  $rows = @(Get-AuctionQuoteRows -Holdings $holdings -Timestamp $CurrentTime -QuoteDataPath $QuoteDataPath -DailyMetricsPath $DailyMetricsPath -CachePath $context.DailyMetricsCachePath)
  foreach ($checkpoint in $missing) {
    $snapshotPath = Get-AuctionSnapshotFilePath -SnapshotDateDir $context.SnapshotDateDir -Session $Session -Checkpoint $checkpoint
    Save-AuctionSnapshot -SnapshotPath $snapshotPath -Session $Session -Checkpoint $checkpoint -Rows $rows -CaptureMode "catchup" | Out-Null
    Write-MonitorLog -LogFile $context.LogFile -Message "catchup snapshot saved $snapshotPath rows=$($rows.Count)"
  }

  if ($missing -notcontains $sessionConfig.FinalCheckpoint) {
    Write-Output ("Catch-up snapshots saved: {0}" -f ($missing -join ", "))
    exit 0
  }

  if (Test-AuctionFinalReportExists -Outbox $context.Outbox -Session $Session -CurrentTime $CurrentTime) {
    Write-MonitorLog -LogFile $context.LogFile -Message "catchup final push skipped $Session current_time=$($CurrentTime.ToString('HH:mm:ss')) existing final report detected"
    Write-Output "Final auction report already exists; catch-up push skipped."
    exit 0
  }

  $snapshots = @(Get-AuctionSnapshotsForSession -SnapshotDateDir $context.SnapshotDateDir -Session $Session)
  $finalSnapshot = @($snapshots | Where-Object { [string]$_.checkpoint -eq $sessionConfig.FinalCheckpoint } | Select-Object -Last 1)
  if (-not $finalSnapshot) {
    throw "Final checkpoint snapshot missing after catch-up."
  }

  $trendMap = if ($Session -eq "close") { Get-AuctionTrendMap -Holdings $holdings -TrendDataPath $TrendDataPath } else { @{} }
  $assessments = foreach ($row in @($finalSnapshot[0].rows)) {
    $trendBars = if ($trendMap.ContainsKey([string]$row.code)) { @($trendMap[[string]$row.code]) } else { @() }
    ConvertTo-AuctionAssessment -Row $row -Snapshots $snapshots -SessionConfig $sessionConfig -TrendBars $trendBars
  }
  $orderedAssessments = @($assessments | Sort-Object reminder_priority, { - $_.score }, name)
  $tradeDate = $CurrentTime.ToString("yyyy-MM-dd")
  $report = New-AuctionReportContent -TradeDate $tradeDate -SessionConfig $sessionConfig -Snapshots $snapshots -Assessments $orderedAssessments

  $prefix = if ($Session -eq "open") { "open_auction_catchup_report" } else { "close_auction_catchup_report" }
  $reportPath = Join-Path $context.Outbox ("{0}_{1}.md" -f $prefix, (Get-Date -Format "yyyyMMdd_HHmmss"))
  $encoding = New-Object System.Text.UTF8Encoding($true)
  [System.IO.File]::WriteAllText($reportPath, $report, $encoding)

  if ($NoPush) {
    Write-MonitorLog -LogFile $context.LogFile -Message "catchup dry-run generated $reportPath"
  } else {
    $pushNotBefore = Get-AuctionPushNotBeforeTime -SessionConfig $sessionConfig -TradeDate $CurrentTime
    if ($CurrentTime -lt $pushNotBefore) {
      Write-MonitorLog -LogFile $context.LogFile -Message "catchup push deferred $Session current_time=$($CurrentTime.ToString('HH:mm:ss')) push_not_before=$($pushNotBefore.ToString('HH:mm:ss'))"
      Write-Output ("Catch-up report generated but push deferred until {0}" -f $pushNotBefore.ToString("HH:mm:ss"))
      exit 0
    }
    $sendScript = Join-Path $PSScriptRoot "Send-FeishuCard.ps1"
    $icon = [char]::ConvertFromUtf32(0x1F7E3)
    $title = $icon + "[" + $sessionConfig.Title + "补跑] " + $tradeDate
    $sendParams = @{
      Title = [string]$title
      Template = "purple"
      ContentPath = [string]$reportPath
      QueueRoot = [string]$context.PendingPushRoot
    }
    if (Test-Path -LiteralPath $context.AuctionSettingsPath) {
      $sendParams.SettingsPath = [string]$context.AuctionSettingsPath
    }
    Invoke-HiddenPowershellScript -ScriptPath $sendScript -Parameters $sendParams | Out-Null
    Write-MonitorLog -LogFile $context.LogFile -Message "catchup pushed $reportPath"
  }

  Write-Output ("Auction catch-up report generated: {0}" -f $reportPath)
} catch {
  if ($null -eq $context) {
    $context = New-AuctionContext -DataRoot $DataRoot -Session $Session
  }
  Write-MonitorLog -LogFile $context.LogFile -Message "catchup error $Session current_time=$($CurrentTime.ToString('HH:mm:ss')) detail=$($_.Exception.Message)"
  throw
}
