$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptsRoot = Join-Path $repoRoot "scripts"
. (Join-Path $scriptsRoot "Holdings.ps1")
. (Join-Path $scriptsRoot "AuctionMonitorShared.ps1")

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Message
  )

  if (-not $Condition) {
    throw $Message
  }
}

function U {
  param([string]$Text)
  [regex]::Replace($Text, "\\u([0-9a-fA-F]{4})", {
    param($m)
    [char][int]::Parse($m.Groups[1].Value, [System.Globalization.NumberStyles]::HexNumber)
  })
}

function New-TestDir {
  $path = Join-Path ([System.IO.Path]::GetTempPath()) ("auction-tests_{0}" -f ([guid]::NewGuid().ToString("N")))
  New-Item -ItemType Directory -Force -Path $path | Out-Null
  return $path
}

$testDir = New-TestDir
try {
  $holdingsPath = Join-Path $testDir "holdings.csv"
  @"
Code,Name,FocusLevel,PrevCloseMode
300346,Nanda,high,qfq
300783,Squirrels,,
"@ | Set-Content -LiteralPath $holdingsPath -Encoding UTF8

  $holdings = @(Import-HeldStocks -Path $holdingsPath)
  Assert-True (($holdings | Where-Object Code -eq "300346").FocusLevel -eq "high") "Focus level high should be supported."
  Assert-True (($holdings | Where-Object Code -eq "300783").FocusLevel -eq "normal") "Missing focus level should default to normal."
  Assert-True (($holdings | Where-Object Code -eq "300346").PrevCloseMode -eq "qfq") "Prev close mode qfq should be supported."
  Assert-True ((Get-AuctionLimitPct -Code "600001" -Name (U 'ST\u6d4b\u8bd5')) -eq 0.10) "Main-board ST stocks should use 10% limits under the new rule."
  Assert-True ((Get-AuctionLimitPct -Code "300001" -Name (U 'ST\u521b\u4e1a')) -eq 0.20) "ChiNext ST stocks should keep 20% limits."
  Assert-True ((Get-AuctionLimitPct -Code "830001" -Name (U '\u5317\u4ea4\u6240\u6837\u672c')) -eq 0.30) "Beijing exchange stocks should use their exchange limit rule."

  $openPushNotBefore = Get-AuctionPushNotBeforeTime -SessionConfig (Get-AuctionSessionConfig -Session open) -TradeDate ([datetime]"2026-07-01 09:26:00")
  $closePushNotBefore = Get-AuctionPushNotBeforeTime -SessionConfig (Get-AuctionSessionConfig -Session close) -TradeDate ([datetime]"2026-07-01 15:00:00")
  Assert-True ($openPushNotBefore.ToString("HH:mm:ss") -eq "09:26:00") "Opening auction push should stay at the final checkpoint."
  Assert-True ($closePushNotBefore.ToString("HH:mm:ss") -eq "15:01:00") "Closing auction push should be deferred to 15:01."

  $dailyMetricsPath = Join-Path $testDir "daily_metrics.json"
  @"
[
  { "code": "300346", "prev_close": 10.00, "yesterday_amount": 10000000, "avg5_amount": 20000000 },
  { "code": "300783", "prev_close": 20.00, "yesterday_amount": 12000000, "avg5_amount": 30000000 }
]
"@ | Set-Content -LiteralPath $dailyMetricsPath -Encoding UTF8

  $openDataRoot = Join-Path $testDir "open_data"
  $openFixtures = @{
    "0915" = @(
      @{ code = "300346"; f43 = 10.10; f47 = 100000; f48 = 200000; f60 = 10.00; f192 = 5.0; f50 = 1.2 },
      @{ code = "300783"; f43 = 19.70; f47 = 120000; f48 = 150000; f60 = 20.00; f192 = -3.0; f50 = 0.9 }
    )
    "0920" = @(
      @{ code = "300346"; f43 = 10.20; f47 = 140000; f48 = 300000; f60 = 10.00; f192 = 8.0; f50 = 1.5 },
      @{ code = "300783"; f43 = 19.60; f47 = 150000; f48 = 220000; f60 = 20.00; f192 = -5.0; f50 = 0.8 }
    )
    "0923" = @(
      @{ code = "300346"; f43 = 10.28; f47 = 180000; f48 = 500000; f60 = 10.00; f192 = 10.0; f50 = 1.8 },
      @{ code = "300783"; f43 = 19.45; f47 = 160000; f48 = 300000; f60 = 20.00; f192 = -8.0; f50 = 0.7 }
    )
    "092430" = @(
      @{ code = "300346"; f43 = 10.30; f47 = 220000; f48 = 700000; f60 = 10.00; f192 = 12.0; f50 = 2.0 },
      @{ code = "300783"; f43 = 19.42; f47 = 180000; f48 = 360000; f60 = 20.00; f192 = -10.0; f50 = 0.6 }
    )
    "0925" = @(
      @{ code = "300346"; f43 = 10.45; f47 = 260000; f48 = 900000; f60 = 10.00; f192 = 15.0; f50 = 2.2 },
      @{ code = "300783"; f43 = 19.20; f47 = 220000; f48 = 500000; f60 = 20.00; f192 = -15.0; f50 = 0.5 }
    )
    "0926" = @(
      @{ code = "300346"; f43 = 10.42; f47 = 265000; f48 = 920000; f60 = 10.00; f192 = 14.0; f50 = 2.1 },
      @{ code = "300783"; f43 = 19.18; f47 = 225000; f48 = 520000; f60 = 20.00; f192 = -16.0; f50 = 0.5 }
    )
  }

  foreach ($checkpoint in $openFixtures.Keys) {
    $quotePath = Join-Path $testDir ("open_{0}.json" -f $checkpoint)
    ($openFixtures[$checkpoint] | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $quotePath -Encoding UTF8
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "Run-AuctionMonitor.ps1") `
      -HoldingsPath $holdingsPath `
      -DataRoot $openDataRoot `
      -Session open `
      -Checkpoint $checkpoint `
      -QuoteDataPath $quotePath `
      -DailyMetricsPath $dailyMetricsPath `
      -NoPush | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Opening auction runner failed at checkpoint $checkpoint with exit code $LASTEXITCODE"
    }
  }

  $openSnapshotDir = Join-Path $openDataRoot ("auction_open\snapshots\{0}" -f (Get-Date -Format "yyyyMMdd"))
  $openSnapshots = @(Get-ChildItem -LiteralPath $openSnapshotDir -Filter "snapshot_open_*.json")
  Assert-True ($openSnapshots.Count -eq 6) "Opening auction should save all 6 snapshots."
  $openReportFile = Get-ChildItem -LiteralPath (Join-Path $openDataRoot "auction_open\outbox") -Filter "open_auction_report_*.md" | Select-Object -First 1
  Assert-True ($null -ne $openReportFile) "09:26 should generate the opening auction report."
  $openReport = Get-Content -LiteralPath $openReportFile.FullName -Raw -Encoding UTF8
  Assert-True ($openReport -match "09:20") "Opening report should include the comparison checkpoint."
  Assert-True ($openReport -match "10.42") "Opening report should include the final opening price."

  $closeDataRoot = Join-Path $testDir "close_data"
  $closeFixtures = @{
    "1457" = @(
      @{ code = "300346"; f43 = 10.30; f47 = 300000; f48 = 400000; f60 = 10.00; f192 = 5.0; f50 = 1.0 },
      @{ code = "300783"; f43 = 19.70; f47 = 260000; f48 = 300000; f60 = 20.00; f192 = -5.0; f50 = 0.6 }
    )
    "1459" = @(
      @{ code = "300346"; f43 = 10.34; f47 = 320000; f48 = 520000; f60 = 10.00; f192 = 7.0; f50 = 1.1 },
      @{ code = "300783"; f43 = 19.55; f47 = 300000; f48 = 420000; f60 = 20.00; f192 = -7.0; f50 = 0.5 }
    )
    "1500" = @(
      @{ code = "300346"; f43 = 10.48; f47 = 380000; f48 = 880000; f60 = 10.00; f192 = 12.0; f50 = 1.4 },
      @{ code = "300783"; f43 = 19.20; f47 = 360000; f48 = 650000; f60 = 20.00; f192 = -12.0; f50 = 0.4 }
    )
  }

  $closeTrendPath = Join-Path $testDir "close_trends.json"
  @"
[
  {
    "code": "300346",
    "bars": [
      { "time": "09:30", "open": 10.00, "close": 10.05, "high": 10.08, "low": 9.98, "volume": 100000, "amount": 1005000, "avg_price": 10.05 },
      { "time": "14:57", "open": 10.28, "close": 10.30, "high": 10.31, "low": 10.27, "volume": 300000, "amount": 400000, "avg_price": 10.20 },
      { "time": "14:59", "open": 10.32, "close": 10.34, "high": 10.35, "low": 10.31, "volume": 320000, "amount": 520000, "avg_price": 10.22 },
      { "time": "15:00", "open": 10.46, "close": 10.48, "high": 10.50, "low": 10.45, "volume": 380000, "amount": 880000, "avg_price": 10.25 },
      { "time": "15:05", "open": 10.48, "close": 10.48, "high": 10.48, "low": 10.48, "volume": 50000, "amount": 524000, "avg_price": 10.48 },
      { "time": "15:30", "open": 10.48, "close": 10.48, "high": 10.48, "low": 10.48, "volume": 20000, "amount": 209600, "avg_price": 10.48 }
    ]
  },
  {
    "code": "300783",
    "bars": [
      { "time": "09:30", "open": 20.00, "close": 19.95, "high": 20.02, "low": 19.90, "volume": 120000, "amount": 2394000, "avg_price": 19.95 },
      { "time": "14:57", "open": 19.68, "close": 19.70, "high": 19.72, "low": 19.66, "volume": 260000, "amount": 300000, "avg_price": 19.82 },
      { "time": "14:59", "open": 19.56, "close": 19.55, "high": 19.57, "low": 19.50, "volume": 300000, "amount": 420000, "avg_price": 19.78 },
      { "time": "15:00", "open": 19.22, "close": 19.20, "high": 19.23, "low": 19.18, "volume": 360000, "amount": 650000, "avg_price": 19.70 },
      { "time": "15:05", "open": 19.20, "close": 19.20, "high": 19.20, "low": 19.20, "volume": 0, "amount": 0, "avg_price": 19.20 },
      { "time": "15:30", "open": 19.20, "close": 19.20, "high": 19.20, "low": 19.20, "volume": 0, "amount": 0, "avg_price": 19.20 }
    ]
  }
]
"@ | Set-Content -LiteralPath $closeTrendPath -Encoding UTF8

  foreach ($checkpoint in $closeFixtures.Keys) {
    $quotePath = Join-Path $testDir ("close_{0}.json" -f $checkpoint)
    ($closeFixtures[$checkpoint] | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $quotePath -Encoding UTF8
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "Run-AuctionMonitor.ps1") `
      -HoldingsPath $holdingsPath `
      -DataRoot $closeDataRoot `
      -Session close `
      -Checkpoint $checkpoint `
      -QuoteDataPath $quotePath `
      -DailyMetricsPath $dailyMetricsPath `
      -TrendDataPath $closeTrendPath `
      -NoPush | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Closing auction runner failed at checkpoint $checkpoint with exit code $LASTEXITCODE"
    }
  }

  $closeSnapshotDir = Join-Path $closeDataRoot ("auction_close\snapshots\{0}" -f (Get-Date -Format "yyyyMMdd"))
  $closeSnapshots = @(Get-ChildItem -LiteralPath $closeSnapshotDir -Filter "snapshot_close_*.json")
  Assert-True ($closeSnapshots.Count -eq 3) "Closing auction should save 3 snapshots."
  $closeReportFile = Get-ChildItem -LiteralPath (Join-Path $closeDataRoot "auction_close\outbox") -Filter "close_auction_report_*.md" | Select-Object -First 1
  Assert-True ($null -ne $closeReportFile) "15:00 should generate the closing auction report."
  $closeReport = Get-Content -LiteralPath $closeReportFile.FullName -Raw -Encoding UTF8
  Assert-True ($closeReport -match [regex]::Escape((U '14:57\u4ef7\u683c'))) "Closing report should show the 14:57 price field."
  Assert-True ($closeReport -match [regex]::Escape((U '15:00\u6536\u76d8\u4ef7'))) "Closing report should use the new close-auction field layout."
  Assert-True ($closeReport -match [regex]::Escape((U '14:57\u201415:00\u6210\u4ea4\u989d'))) "Closing report should show the isolated closing auction amount."
  Assert-True ($closeReport -match [regex]::Escape((U '\u6536\u76d8\u7ade\u4ef7\u6210\u4ea4\u989d\u5360\u5e38\u89c4\u4ea4\u6613\u6210\u4ea4\u989d\u6bd4\u4f8b'))) "Closing report should compare the closing auction amount against regular-session amount."
  Assert-True ($closeReport -match [regex]::Escape((U '15:05\u201415:30\u76d8\u540e\u56fa\u5b9a\u4ef7\u683c\u4ea4\u6613\u4e0d\u6539\u53d8\u5f53\u65e5\u6536\u76d8\u4ef7'))) "Closing report should include the fixed footer note."

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "Run-AfterHoursFixedPriceReport.ps1") `
    -HoldingsPath $holdingsPath `
    -DataRoot $closeDataRoot `
    -TradeDate (Get-Date -Format "yyyy-MM-dd") `
    -TrendDataPath $closeTrendPath `
    -NoPush | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "After-hours fixed-price runner should generate the after-hours report."
  }
  $afterHoursReportFile = Get-ChildItem -LiteralPath (Join-Path $closeDataRoot "after_hours_fixed\outbox") -Filter "after_hours_fixed_report_*.md" | Select-Object -First 1
  Assert-True ($null -ne $afterHoursReportFile) "15:31 should generate an after-hours fixed-price report."
  $afterHoursReport = Get-Content -LiteralPath $afterHoursReportFile.FullName -Raw -Encoding UTF8
  Assert-True ($afterHoursReport -match [regex]::Escape((U '15:05\u201415:30\u76d8\u540e\u6210\u4ea4\u989d'))) "After-hours report should show the after-hours traded amount."
  Assert-True ($afterHoursReport -match [regex]::Escape((U '\u76d8\u540e\u6d3b\u8dc3\u5ea6\u6807\u7b7e'))) "After-hours report should show the after-hours activity label."
  Assert-True ($afterHoursReport -match [regex]::Escape((U '\u65e0\u76d8\u540e\u6210\u4ea4'))) "After-hours report should mark stocks with no after-hours trade."

  $missingCloseAssessment = ConvertTo-AfterHoursAssessment `
    -Holding ([pscustomobject]@{ Code = "002594"; Name = "BYD"; PrevCloseMode = "qfq" }) `
    -CloseRow ([pscustomobject]@{ code = "002594"; status = "data_missing"; auction_price = $null; auction_amount = $null }) `
    -AfterHoursData ([pscustomobject]@{ source = "test_provider"; supported = $false; volume = $null; amount = $null })
  Assert-True ($missingCloseAssessment.status -eq "data_missing") "Missing close-auction fields should not be mislabeled as halted."
  Assert-True ($missingCloseAssessment.activity_tag -eq (U '\u6536\u76d8\u6570\u636e\u7f3a\u5931')) "Missing close-auction fields should be labeled as close-data missing."

  $externalAfterHoursPath = Join-Path $testDir "after_hours_external.json"
  @"
[
  { "code": "300346", "source": "external_probe", "supported": true, "volume": 70000, "amount": 733600 },
  { "code": "300783", "source": "external_probe", "supported": true, "volume": 0, "amount": 0 }
]
"@ | Set-Content -LiteralPath $externalAfterHoursPath -Encoding UTF8
  $externalAfterHoursRoot = Join-Path $testDir "after_hours_external_data"
  $externalCloseSnapshotDir = Join-Path $externalAfterHoursRoot ("auction_close\snapshots\{0}" -f (Get-Date -Format "yyyyMMdd"))
  New-Item -ItemType Directory -Force -Path $externalCloseSnapshotDir | Out-Null
  Get-ChildItem -LiteralPath $closeSnapshotDir -Filter "snapshot_close_*.json" | Copy-Item -Destination $externalCloseSnapshotDir -Force
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "Run-AfterHoursFixedPriceReport.ps1") `
    -HoldingsPath $holdingsPath `
    -DataRoot $externalAfterHoursRoot `
    -TradeDate (Get-Date -Format "yyyy-MM-dd") `
    -AfterHoursDataPath $externalAfterHoursPath `
    -NoPush | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "After-hours fixed-price runner should accept an external after-hours data file."
  }
  $externalAfterHoursReportFile = Get-ChildItem -LiteralPath (Join-Path $externalAfterHoursRoot "after_hours_fixed\outbox") -Filter "after_hours_fixed_report_*.md" | Select-Object -First 1
  $externalAfterHoursReport = Get-Content -LiteralPath $externalAfterHoursReportFile.FullName -Raw -Encoding UTF8
  Assert-True ($externalAfterHoursReport -match "73.36万元") "External after-hours data should flow through the report."

  $catchupRoot = Join-Path $testDir "catchup_data"
  $catchupQuotePath = Join-Path $testDir "catchup_open.json"
  @(
    @{ code = "300346"; f43 = 10.35; f47 = 240000; f48 = 760000; f60 = 10.00; f192 = 13.0; f50 = 2.0 },
    @{ code = "300783"; f43 = 19.35; f47 = 210000; f48 = 440000; f60 = 20.00; f192 = -13.0; f50 = 0.5 }
  ) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $catchupQuotePath -Encoding UTF8

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "Run-AuctionCatchUp.ps1") `
    -HoldingsPath $holdingsPath `
    -DataRoot $catchupRoot `
    -Session open `
    -QuoteDataPath $catchupQuotePath `
    -DailyMetricsPath $dailyMetricsPath `
    -CurrentTime ([datetime]"2026-07-01 09:24:35") `
    -NoPush | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Auction catch-up runner should backfill opening checkpoints before 09:25."
  }

  $catchupOpenDir = Join-Path $catchupRoot ("auction_open\snapshots\{0}" -f (Get-Date -Format "yyyyMMdd"))
  $catchupSnapshotsBeforeFinal = @(Get-ChildItem -LiteralPath $catchupOpenDir -Filter "snapshot_open_*.json")
  Assert-True ($catchupSnapshotsBeforeFinal.Count -eq 4) "Catch-up before 09:25 should backfill 4 opening checkpoints."
  $catchup0915 = Get-Content -LiteralPath (Join-Path $catchupOpenDir "snapshot_open_0915.json") -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-True ([string]$catchup0915.capture_mode -eq "catchup") "Catch-up snapshots should be marked as catchup."

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "Run-AuctionCatchUp.ps1") `
    -HoldingsPath $holdingsPath `
    -DataRoot $catchupRoot `
    -Session open `
    -QuoteDataPath $catchupQuotePath `
    -DailyMetricsPath $dailyMetricsPath `
    -CurrentTime ([datetime]"2026-07-01 09:26:05") `
    -NoPush | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Auction catch-up runner should finish the opening report at 09:26."
  }

  $catchupReportFile = Get-ChildItem -LiteralPath (Join-Path $catchupRoot "auction_open\outbox") -Filter "open_auction_catchup_report_*.md" | Select-Object -First 1
  Assert-True ($null -ne $catchupReportFile) "Catch-up final run should generate a catch-up report."
  $catchupReport = Get-Content -LiteralPath $catchupReportFile.FullName -Raw -Encoding UTF8
  Assert-True (-not ($catchupReport -match "09:15")) "Formal catch-up reports should not expose preview-style recovered checkpoint notes."

  $closeCatchupRoot = Join-Path $testDir "close_catchup_data"
  foreach ($checkpoint in @("1457", "1459", "1500")) {
    $quotePath = Join-Path $testDir ("close_{0}.json" -f $checkpoint)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "Run-AuctionMonitor.ps1") `
      -HoldingsPath $holdingsPath `
      -DataRoot $closeCatchupRoot `
      -Session close `
      -Checkpoint $checkpoint `
      -QuoteDataPath $quotePath `
      -DailyMetricsPath $dailyMetricsPath `
      -TrendDataPath $closeTrendPath `
      -NoPush | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "Closing auction dry-run runner failed at checkpoint $checkpoint for close catch-up deferral test."
    }
  }

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "Run-AuctionCatchUp.ps1") `
    -HoldingsPath $holdingsPath `
    -DataRoot $closeCatchupRoot `
    -Session close `
    -QuoteDataPath (Join-Path $testDir "close_1500.json") `
    -DailyMetricsPath $dailyMetricsPath `
    -TrendDataPath $closeTrendPath `
    -CurrentTime ([datetime]"2026-07-01 15:00:03") | Out-Null
  $closeCatchupReports = @(Get-ChildItem -LiteralPath (Join-Path $closeCatchupRoot "auction_close\outbox") -Filter "close_auction_catchup_report_*.md" -ErrorAction SilentlyContinue)
  Assert-True ($closeCatchupReports.Count -eq 0) "Closing auction catch-up should not push before 15:01."

  $originalInvokeEastmoneyJson = ${function:Invoke-EastmoneyJson}
  try {
    $cacheOnlyRoot = Join-Path $testDir "cache_only_data"
    $cacheOnlyContext = New-AuctionContext -DataRoot $cacheOnlyRoot -Session open
    $seedMap = ConvertTo-AuctionMetricMap -Items @(
      [pscustomobject]@{ code = "300346"; prev_close = 10.00; yesterday_amount = 10000000; avg5_amount = 20000000 },
      [pscustomobject]@{ code = "300783"; prev_close = 20.00; yesterday_amount = 12000000; avg5_amount = 30000000 }
    )
    Save-AuctionDailyMetricsCache -Path $cacheOnlyContext.DailyMetricsCachePath -MetricMap $seedMap
    Set-Item -Path function:Invoke-EastmoneyJson -Value {
      param([string]$Uri)
      throw "simulated eastmoney outage"
    }

    $cacheFallbackRows = @(Get-AuctionQuoteRows `
      -Holdings $holdings `
      -QuoteDataPath (Join-Path $testDir "open_0920.json") `
      -CachePath $cacheOnlyContext.DailyMetricsCachePath)
    Assert-True ($cacheFallbackRows.Count -eq 2) "Cached daily metrics should keep auction rows available during eastmoney outage."
    $cacheFallbackQfq = @($cacheFallbackRows | Where-Object code -eq "300346")[0]
    Assert-True ($null -ne $cacheFallbackQfq.prev_close) "QFQ holdings should reuse cached prev close during outage."
    Assert-True ([Math]::Abs(($cacheFallbackQfq.reference_amount_ratio_pct - 1.5)) -lt 0.01) "Cached avg5 amount should continue to support amount ratio calculation."

    $noCacheRows = @(Get-AuctionQuoteRows `
      -Holdings $holdings `
      -QuoteDataPath (Join-Path $testDir "open_0920.json"))
    Assert-True ($noCacheRows.Count -eq 2) "Auction quote rows should still render without cached daily metrics."
    $noCacheQfq = @($noCacheRows | Where-Object code -eq "300346")[0]
    $noCacheRaw = @($noCacheRows | Where-Object code -eq "300783")[0]
    Assert-True ($null -eq $noCacheQfq.prev_close) "QFQ holdings may miss prev close without cache, but should not abort the report."
    Assert-True ([Math]::Abs(($noCacheRaw.prev_close - 20.0)) -lt 0.0001) "Non-QFQ holdings should still fall back to quote prev close when daily metrics are unavailable."
  } finally {
    Set-Item -Path function:Invoke-EastmoneyJson -Value $originalInvokeEastmoneyJson
  }

  Write-Output "All auction monitor tests passed."
} finally {
  if (Test-Path -LiteralPath $testDir) {
    Remove-Item -LiteralPath $testDir -Recurse -Force
  }
}
