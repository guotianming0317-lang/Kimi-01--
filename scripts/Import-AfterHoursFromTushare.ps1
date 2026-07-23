param(
  [string]$HoldingsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "data\holdings.csv"),
  [string]$DataRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) "data"),
  [string]$TradeDate = "",
  [string]$Token = "",
  [string]$TargetPath = "",
  [string]$EnvPath = "",
  [string]$ConfigPath = "",
  [switch]$NoReport
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "TushareAfterHoursShared.ps1")
. (Join-Path $PSScriptRoot "HeldStockMonitorShared.ps1")

if (-not $TargetPath) {
  $TargetPath = Join-Path $DataRoot "after_hours_external.latest.json"
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$config = Get-TushareConfig -ProjectRoot $projectRoot -EnvPath $EnvPath -ConfigPath $ConfigPath
if (-not $Token) {
  $Token = [string]$config.token
}
if (-not $TradeDate) {
  $TradeDate = if ($config.trade_date) { [string]$config.trade_date } else { Get-Date -Format "yyyyMMdd" }
}
$TradeDate = ConvertTo-TushareTradeDate -Value $TradeDate

if (-not $config.enabled -and -not [Environment]::GetEnvironmentVariable("TUSHARE_ENABLED") -and -not $PSBoundParameters.ContainsKey("Token")) {
  Write-Output "Tushare import skipped: TUSHARE_ENABLED is not enabled."
  exit 0
}

if (-not $Token) {
  throw "Tushare token not configured. Set TUSHARE_TOKEN in .env, config.json, or pass -Token."
}

$holdings = @(Import-HeldStocks -Path $HoldingsPath)
if (-not $holdings) {
  throw "No holdings found for Tushare import."
}

$cacheDir = Join-Path $DataRoot "after_hours_fixed\cache"
New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
$rawPath = Join-Path $cacheDir ("tushare_daily_{0}.json" -f $TradeDate)

$sourceTime = [datetimeoffset]::Now
$items = $null
try {
  $response = Invoke-TushareDailyRequest -Token $Token -TradeDate $TradeDate
  if (($response.PSObject.Properties.Name -contains "code") -and ([int]$response.code -ne 0)) {
    $message = if ($response.PSObject.Properties.Name -contains "msg") { [string]$response.msg } else { "unknown Tushare error" }
    throw "Tushare returned code $($response.code): $message"
  }
  $encoding = New-Object System.Text.UTF8Encoding($true)
  [System.IO.File]::WriteAllText($rawPath, ($response | ConvertTo-Json -Depth 10), $encoding)
  $items = @(ConvertFrom-TushareDailyResponse -Response $response -Holdings $holdings -TradeDate $TradeDate -SourceTime $sourceTime)
} catch {
  Write-Warning ("Tushare import request failed: {0}" -f $_.Exception.Message)
  $items = foreach ($holding in $holdings) {
    [pscustomobject]@{
      code = [string]$holding.Code
      name = [string]$holding.Name
      market = if ([string]$holding.Code -like "6*") { "SH" } else { "SZ" }
      trade_date = $TradeDate
      close = $null
      after_hours_volume = 0
      after_hours_amount = 0
      source = "tushare"
      source_time = $sourceTime.ToString("yyyy-MM-ddTHH:mm:sszzz")
      data_status = "api_error"
    }
  }
}

$savedPath = Save-TushareAfterHoursExternalData -Items $items -TargetPath $TargetPath
Write-Output ("Tushare after-hours data saved: {0}" -f $savedPath)

if ($NoReport) {
  exit 0
}

$reportScript = Join-Path $PSScriptRoot "Run-AfterHoursFixedPriceReport.ps1"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $reportScript `
  -HoldingsPath $HoldingsPath `
  -DataRoot $DataRoot `
  -TradeDate ([datetime]::ParseExact($TradeDate, "yyyyMMdd", [System.Globalization.CultureInfo]::InvariantCulture).ToString("yyyy-MM-dd")) `
  -AfterHoursDataPath $savedPath `
  -Final

if ($LASTEXITCODE -ne 0) {
  Write-Warning "Tushare import completed, but final after-hours report generation failed."
}

