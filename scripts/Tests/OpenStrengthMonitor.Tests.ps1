$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptsRoot = Join-Path $repoRoot "scripts"

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Message
  )

  if (-not $Condition) {
    throw $Message
  }
}

function New-TestDir {
  $path = Join-Path ([System.IO.Path]::GetTempPath()) ("open-strength-tests_{0}" -f ([guid]::NewGuid().ToString("N")))
  New-Item -ItemType Directory -Force -Path $path | Out-Null
  return $path
}

$testDir = New-TestDir
try {
  $holdingsPath = Join-Path $testDir "holdings.csv"
  @"
Code,Name,FocusLevel,PrevCloseMode
300346,Nanda,high,
300783,Squirrels,,
"@ | Set-Content -LiteralPath $holdingsPath -Encoding UTF8

  $dailyMetricsPath = Join-Path $testDir "daily_metrics.json"
  @"
[
  { "code": "300346", "prev_close": 10.00, "yesterday_amount": 10000000, "avg5_amount": 20000000 },
  { "code": "300783", "prev_close": 20.00, "yesterday_amount": 12000000, "avg5_amount": 30000000 }
]
"@ | Set-Content -LiteralPath $dailyMetricsPath -Encoding UTF8

  $dataRoot = Join-Path $testDir "data"
  New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null
  @"
webhook_url: "https://example.test/hook"
"@ | Set-Content -LiteralPath (Join-Path $dataRoot "auction_feishu.settings.yml") -Encoding UTF8

  $auction0925Path = Join-Path $testDir "auction_0925_quote.json"
  @"
[
  { "code": "300346", "f31": 10.44, "f32": 220000, "f33": 10.45, "f34": 240000, "f43": 10.45, "f47": 260000, "f48": 900000, "f50": 2.2, "f60": 10.00, "f57": "300346", "f58": "Nanda" },
  { "code": "300783", "f31": 19.18, "f32": 180000, "f33": 19.20, "f34": 190000, "f43": 19.20, "f47": 220000, "f48": 500000, "f50": 0.5, "f60": 20.00, "f57": "300783", "f58": "Squirrels" }
]
"@ | Set-Content -LiteralPath $auction0925Path -Encoding UTF8

  $open0930Path = Join-Path $testDir "open_0930_quote.json"
  @"
[
  { "code": "300346", "f31": 10.39, "f32": 200000, "f33": 10.40, "f34": 210000, "f43": 10.40, "f44": 10.42, "f45": 10.38, "f46": 10.40, "f47": 300000, "f48": 1500000, "f60": 10.00, "f57": "300346", "f58": "Nanda" },
  { "code": "300783", "f31": 19.19, "f32": 160000, "f33": 19.20, "f34": 170000, "f43": 19.20, "f44": 19.25, "f45": 19.18, "f46": 19.20, "f47": 240000, "f48": 1100000, "f60": 20.00, "f57": "300783", "f58": "Squirrels" }
]
"@ | Set-Content -LiteralPath $open0930Path -Encoding UTF8

  $snapshot0940QuotePath = Join-Path $testDir "snapshot_0940_quote.json"
  @"
[
  { "code": "300346", "f31": 10.54, "f32": 260000, "f33": 10.55, "f34": 240000, "f43": 10.55, "f44": 10.66, "f45": 10.37, "f46": 10.40, "f47": 900000, "f48": 1200000, "f60": 10.00, "f57": "300346", "f58": "Nanda" },
  { "code": "300783", "f31": 19.91, "f32": 210000, "f33": 19.92, "f34": 200000, "f43": 19.92, "f44": 19.95, "f45": 19.18, "f46": 19.20, "f47": 750000, "f48": 1000000, "f60": 20.00, "f57": "300783", "f58": "Squirrels" }
]
"@ | Set-Content -LiteralPath $snapshot0940QuotePath -Encoding UTF8

  $trend0940Path = Join-Path $testDir "snapshot_0940_trends.json"
  @"
[
  {
    "code": "300346",
    "bars": [
      { "time": "09:30", "open": 10.40, "close": 10.42, "high": 10.45, "low": 10.39, "volume": 150000, "amount": 1563000 },
      { "time": "09:31", "open": 10.42, "close": 10.48, "high": 10.50, "low": 10.41, "volume": 160000, "amount": 1672000 },
      { "time": "09:35", "open": 10.48, "close": 10.58, "high": 10.60, "low": 10.47, "volume": 220000, "amount": 2321000 },
      { "time": "09:40", "open": 10.58, "close": 10.55, "high": 10.66, "low": 10.54, "volume": 250000, "amount": 2640000 }
    ]
  },
  {
    "code": "300783",
    "bars": [
      { "time": "09:30", "open": 19.20, "close": 19.15, "high": 19.22, "low": 19.10, "volume": 120000, "amount": 2295000 },
      { "time": "09:32", "open": 19.15, "close": 19.40, "high": 19.42, "low": 19.12, "volume": 180000, "amount": 3480000 },
      { "time": "09:36", "open": 19.40, "close": 19.70, "high": 19.74, "low": 19.38, "volume": 230000, "amount": 4510000 },
      { "time": "09:40", "open": 19.70, "close": 19.92, "high": 19.95, "low": 19.68, "volume": 260000, "amount": 5170000 }
    ]
  }
]
"@ | Set-Content -LiteralPath $trend0940Path -Encoding UTF8

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "Run-OpenStrengthCapture.ps1") `
    -HoldingsPath $holdingsPath `
    -DataRoot $dataRoot `
    -Checkpoint 0925 `
    -QuoteDataPath $auction0925Path `
    -DailyMetricsPath $dailyMetricsPath `
    -NoPush | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "09:25 capture should succeed." }

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "Run-OpenStrengthCapture.ps1") `
    -HoldingsPath $holdingsPath `
    -DataRoot $dataRoot `
    -Checkpoint 0930 `
    -QuoteDataPath $open0930Path `
    -DailyMetricsPath $dailyMetricsPath `
    -NoPush | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "09:30 capture should succeed." }

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "Run-OpenStrengthCapture.ps1") `
    -HoldingsPath $holdingsPath `
    -DataRoot $dataRoot `
    -Checkpoint 0940 `
    -QuoteDataPath $snapshot0940QuotePath `
    -TrendDataPath $trend0940Path `
    -DailyMetricsPath $dailyMetricsPath `
    -NoPush | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "09:40 capture should succeed." }

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "Run-OpenStrengthReport.ps1") `
    -HoldingsPath $holdingsPath `
    -DataRoot $dataRoot `
    -TradeDate (Get-Date -Format "yyyy-MM-dd") `
    -NoPush | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "09:41 report generation should succeed." }

  $dayRoot = Join-Path $dataRoot (Get-Date -Format "yyyy-MM-dd")
  $auctionFile = Join-Path $dayRoot "auction_0925.json"
  $openFile = Join-Path $dayRoot "open_0930.json"
  $snapshotFile = Join-Path $dayRoot "snapshot_0940.json"
  $reportJsonFile = Join-Path $dayRoot "open_strength_report.json"

  Assert-True (Test-Path -LiteralPath $auctionFile) "09:25 should save auction_0925.json."
  Assert-True (Test-Path -LiteralPath $openFile) "09:30 should save open_0930.json."
  Assert-True (Test-Path -LiteralPath $snapshotFile) "09:40 should save snapshot_0940.json."
  Assert-True (Test-Path -LiteralPath $reportJsonFile) "09:41 should save open_strength_report.json."

  $reportMd = Get-ChildItem -LiteralPath (Join-Path $dataRoot "open_strength\outbox") -Filter "open_strength_report_*.md" | Select-Object -First 1
  Assert-True ($null -ne $reportMd) "09:41 should generate a markdown report for Feishu."
  $reportText = Get-Content -LiteralPath $reportMd.FullName -Raw -Encoding UTF8
  Assert-True ($reportText -match "9:40") "Report should include 9:40."
  Assert-True ($reportText -match "VWAP") "Report should mention VWAP."
  Assert-True ($reportText -match "10.55") "Report should include the strong stock price."
  Assert-True ($reportText -match "19.92") "Report should include the repair stock price."
  Assert-True ($reportText -match "300346") "Report should include stock codes."

  $reportJson = Get-Content -LiteralPath $reportJsonFile -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-True ($reportJson.summary.holdings_count -eq 2) "Structured report should include holdings count."
  Assert-True ($reportJson.summary.strong_count -ge 1) "Structured report should summarize strong openings."
  Assert-True ($reportJson.summary.low_open_repair_count -eq 1) "Structured report should summarize one low-open repair case."
  Assert-True (@($reportJson.assessments | Where-Object { $_.current_vs_open_pct -ge 1 }).Count -ge 2) "Structured report should preserve recovery/strength metrics."
  Assert-True (@($reportJson.assessments | Where-Object { $_.amount_ratio_pct -ge 20 }).Count -ge 1) "Structured report should preserve amount ratio metrics."

  Write-Output "All open strength monitor tests passed."
} finally {
  if (Test-Path -LiteralPath $testDir) {
    Remove-Item -LiteralPath $testDir -Recurse -Force
  }
}
