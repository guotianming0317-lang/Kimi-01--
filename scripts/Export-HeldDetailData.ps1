param(
  [string]$HoldingsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "data\holdings.csv"),
  [string]$DataRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) "data")
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "HeldStockMonitorShared.ps1")

$holdings = @(Import-HeldStocks -Path $HoldingsPath)
if (-not $holdings) {
  throw "No holdings loaded."
}

$detailResult = Get-HeldQuoteDetailFetchResult -Holdings $holdings
$detailMap = $detailResult.Map
$detailDir = Join-Path $DataRoot "detail_cache"
New-Item -ItemType Directory -Force -Path $detailDir | Out-Null

if ($detailResult.Errors.Count -gt 0) {
  $errorFile = Join-Path $detailDir ("held_detail_errors_{0}.txt" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
  @($detailResult.Errors) | Set-Content -LiteralPath $errorFile -Encoding UTF8
  Write-Output "Detail fetch errors saved: $errorFile"
}

if (-not $detailMap.Count) {
  throw "No detail data fetched from Eastmoney."
}

$exportRows = foreach ($holding in $holdings) {
  $code = [string]$holding.Code
  if (-not $detailMap.ContainsKey($code)) { continue }
  $detail = $detailMap[$code]
  [pscustomobject]@{
    code = $code
    name = [string]$holding.Name
    secid = [string]$holding.SecId
    f137 = $detail.f137
    f138 = $detail.f138
    f139 = $detail.f139
    f140 = $detail.f140
    f141 = $detail.f141
    f142 = $detail.f142
    f143 = $detail.f143
    f144 = $detail.f144
    f145 = $detail.f145
    f146 = $detail.f146
    f147 = $detail.f147
    f148 = $detail.f148
    f149 = $detail.f149
  }
}

$detailFile = Join-Path $detailDir ("held_detail_{0}.json" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$exportRows | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $detailFile -Encoding UTF8

Write-Output "Held detail data exported: $detailFile"
Write-Output "Rows: $(@($exportRows).Count)"
