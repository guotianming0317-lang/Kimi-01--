$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptsRoot = Join-Path $repoRoot "scripts"
. (Join-Path $scriptsRoot "Holdings.ps1")
. (Join-Path $scriptsRoot "AuctionMonitorShared.ps1")
. (Join-Path $scriptsRoot "TushareAfterHoursShared.ps1")

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
  $path = Join-Path ([System.IO.Path]::GetTempPath()) ("tushare-after-hours-tests_{0}" -f ([guid]::NewGuid().ToString("N")))
  New-Item -ItemType Directory -Force -Path $path | Out-Null
  return $path
}

$testDir = New-TestDir
try {
  Assert-True ((ConvertTo-TushareTsCode -Code "601138") -eq "601138.SH") "Shanghai code should convert to .SH."
  Assert-True ((ConvertTo-TushareTsCode -Code "002594") -eq "002594.SZ") "Shenzhen code should convert to .SZ."
  Assert-True ((ConvertTo-TushareTradeDate -Value "2026-07-07") -eq "20260707") "Trade date should normalize from dashed format."

  @"
TUSHARE_TOKEN=env-token
TUSHARE_ENABLED=true
TUSHARE_TRADE_DATE=2026-07-08
"@ | Set-Content -LiteralPath (Join-Path $testDir ".env") -Encoding UTF8
  @'
{
  "TUSHARE_TOKEN": "json-token",
  "TUSHARE_ENABLED": false,
  "TUSHARE_TRADE_DATE": "20260709"
}
'@ | Set-Content -LiteralPath (Join-Path $testDir "config.json") -Encoding UTF8

  $config = Get-TushareConfig -ProjectRoot $testDir
  Assert-True ($config.token -eq "env-token") ".env token should override config.json token."
  Assert-True ($config.enabled -eq $true) ".env enabled should be honored."
  Assert-True ($config.trade_date -eq "20260708") ".env trade date should normalize correctly."

  $holdingsPath = Join-Path $testDir "holdings.csv"
  @"
Code,Name,PrevCloseMode
002594,BYD,qfq
300346,Nanda,
688126,HSG,
"@ | Set-Content -LiteralPath $holdingsPath -Encoding UTF8
  $holdings = @(Import-HeldStocks -Path $holdingsPath)

  $response = [pscustomobject]@{
    code = 0
    msg = ""
    data = [pscustomobject]@{
      fields = @("ts_code", "trade_date", "close", "after_hours_volume", "after_hours_amount")
      items = @(
        @("002594.SZ", "20260707", 300.12, 123456, 9876543.21),
        @("300346.SZ", "20260707", 45.67, 0, 0),
        @("688126.SH", "20260707", 18.88, $null, $null)
      )
    }
  }

  $items = @(ConvertFrom-TushareDailyResponse -Response $response -Holdings $holdings -TradeDate "20260707" -SourceTime ([datetimeoffset]"2026-07-07T20:30:00+08:00"))
  $byd = @($items | Where-Object code -eq "002594")[0]
  $nda = @($items | Where-Object code -eq "300346")[0]
  $hsg = @($items | Where-Object code -eq "688126")[0]
  Assert-True ($byd.data_status -eq "ok") "Positive after-hours rows should be marked ok."
  Assert-True ([Math]::Abs(($byd.after_hours_amount - 9876543210.0)) -lt 0.001) "After-hours amount should convert from thousand CNY into CNY."
  Assert-True ($nda.data_status -eq "no_after_hours_trade") "Zero after-hours rows should be marked as no trade."
  Assert-True ($hsg.data_status -eq "missing_after_hours_fields") "Null after-hours rows should be marked as missing fields."

  $targetPath = Join-Path $testDir "after_hours_external.latest.json"
  Save-TushareAfterHoursExternalData -Items $items -TargetPath $targetPath | Out-Null
  Assert-True (Test-Path -LiteralPath $targetPath) "Converted Tushare JSON should be saved."

  $map = Get-AfterHoursDataMap -Holdings $holdings -AfterHoursDataPath $targetPath
  Assert-True ($map["002594"].source -eq "tushare") "After-hours map should preserve Tushare source."
  Assert-True ([Math]::Abs(($map["002594"].amount - 9876543210.0)) -lt 0.001) "After-hours map should expose converted CNY amount."
  Assert-True ($map["688126"].supported -eq $false) "Missing after-hours fields should be treated as unsupported."

  $assessmentSample = @(
    [pscustomobject]@{
      code = "002594"
      name = "BYD"
      prev_close_mode = "qfq"
      close_price = 300.12
      after_hours_volume = 123456
      after_hours_amount = 9876543210.0
      after_hours_ratio_regular_pct = 0.88
      after_hours_ratio_total_pct = 0.87
      after_hours_source = "tushare"
      activity_tag = "盘后正常"
      status = "ok"
      observation = "test"
    }
  )
  $content = New-AfterHoursReportContent -TradeDate "2026-07-07" -Assessments $assessmentSample
  $lotUnit = [string][char]0x624B
  Assert-True ($content -match "Tushare Pro") "After-hours report should disclose Tushare Pro as the data source."
  Assert-True ($content.Contains("**123,456** $lotUnit")) "After-hours report should label after-hours volume in lots."

  Write-Output "All Tushare after-hours tests passed."
} finally {
  Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
}
