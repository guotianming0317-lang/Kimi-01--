param(
  [string]$HoldingsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "data\holdings.csv"),
  [string]$DataRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) "data"),
  [ValidateSet("open", "close")]
  [string]$Session = "open",
  [string]$Checkpoint = "",
  [string]$QuoteDataPath = "",
  [string]$DailyMetricsPath = "",
  [string]$TrendDataPath = "",
  [switch]$NoPush
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "AuctionMonitorShared.ps1")
$context = $null
try {
  if (-not $Checkpoint) {
    throw "Checkpoint is required, for example 0926 or 1500."
  }

  $sessionConfig = Get-AuctionSessionConfig -Session $Session
  if ($sessionConfig.Checkpoints -notcontains $Checkpoint) {
    throw ("Unsupported checkpoint: {0}" -f $Checkpoint)
  }

  $context = New-AuctionContext -DataRoot $DataRoot -Session $Session
  if (Test-MonitorPaused -PauseFlag $context.PauseFlag) {
    Write-MonitorLog -LogFile $context.LogFile -Message "paused by $($context.PauseFlag)"
    Write-Output ("Monitoring paused: {0}" -f $context.PauseFlag)
    exit 0
  }

  Write-MonitorLog -LogFile $context.LogFile -Message "start $Session checkpoint=$Checkpoint"
  $holdings = @(Import-HeldStocks -Path $HoldingsPath)
  if (-not $holdings) {
    throw "No held stocks available for auction monitoring."
  }

  $rows = @(Get-AuctionQuoteRows -Holdings $holdings -QuoteDataPath $QuoteDataPath -DailyMetricsPath $DailyMetricsPath -CachePath $context.DailyMetricsCachePath)
  $snapshotPath = Get-AuctionSnapshotFilePath -SnapshotDateDir $context.SnapshotDateDir -Session $Session -Checkpoint $Checkpoint
  $snapshot = Save-AuctionSnapshot -SnapshotPath $snapshotPath -Session $Session -Checkpoint $Checkpoint -Rows $rows -CaptureMode "scheduled"
  Write-MonitorLog -LogFile $context.LogFile -Message "snapshot saved $snapshotPath rows=$($rows.Count)"

  if ($Checkpoint -ne $sessionConfig.FinalCheckpoint) {
    Write-Output ("Auction snapshot saved: {0}" -f $snapshotPath)
    exit 0
  }

  $snapshots = @(Get-AuctionSnapshotsForSession -SnapshotDateDir $context.SnapshotDateDir -Session $Session)
  $finalRows = @($snapshot.rows)
  $trendMap = if ($Session -eq "close") { Get-AuctionTrendMap -Holdings $holdings -TrendDataPath $TrendDataPath } else { @{} }
  $assessments = foreach ($row in $finalRows) {
    $trendBars = if ($trendMap.ContainsKey([string]$row.code)) { @($trendMap[[string]$row.code]) } else { @() }
    ConvertTo-AuctionAssessment -Row $row -Snapshots $snapshots -SessionConfig $sessionConfig -TrendBars $trendBars
  }
  $orderedAssessments = @($assessments | Sort-Object reminder_priority, { - $_.score }, name)
  $tradeDate = Get-Date -Format "yyyy-MM-dd"
  $report = New-AuctionReportContent -TradeDate $tradeDate -SessionConfig $sessionConfig -Snapshots $snapshots -Assessments $orderedAssessments

  $prefix = if ($Session -eq "open") { "open_auction_report" } else { "close_auction_report" }
  $reportPath = Join-Path $context.Outbox ("{0}_{1}.md" -f $prefix, (Get-Date -Format "yyyyMMdd_HHmmss"))
  $encoding = New-Object System.Text.UTF8Encoding($true)
  [System.IO.File]::WriteAllText($reportPath, $report, $encoding)

  if ($NoPush) {
    Write-MonitorLog -LogFile $context.LogFile -Message "dry-run generated $reportPath"
  } else {
    $pushNotBefore = Get-AuctionPushNotBeforeTime -SessionConfig $sessionConfig -TradeDate (Get-Date)
    if ((Get-Date) -lt $pushNotBefore) {
      $delaySeconds = [Math]::Max(0, [int][Math]::Ceiling(($pushNotBefore - (Get-Date)).TotalSeconds))
      if ($delaySeconds -gt 0) {
        Write-MonitorLog -LogFile $context.LogFile -Message "delay push $Session checkpoint=$Checkpoint until=$($pushNotBefore.ToString('HH:mm:ss')) wait_seconds=$delaySeconds"
        Start-Sleep -Seconds $delaySeconds
      }
    }
    $sendScript = Join-Path $PSScriptRoot "Send-FeishuCard.ps1"
    $icon = [char]::ConvertFromUtf32(0x1F7E3)
    $title = $icon + "[" + $sessionConfig.Title + "] " + $tradeDate
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
    Write-MonitorLog -LogFile $context.LogFile -Message "pushed $reportPath"
  }

  Write-Output ("Auction report generated: {0}" -f $reportPath)
} catch {
  if ($null -eq $context) {
    $context = New-AuctionContext -DataRoot $DataRoot -Session $Session
  }
  Write-MonitorLog -LogFile $context.LogFile -Message "error $Session checkpoint=$Checkpoint detail=$($_.Exception.Message)"
  throw
}
