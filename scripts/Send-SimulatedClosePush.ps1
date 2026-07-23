param(
  [string]$SnapshotPath = (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "data\snapshots\$(Get-Date -Format 'yyyyMMdd')") "snapshot_150003.json"),
  [string]$HoldingsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "data\holdings.csv"),
  [string]$DataRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) "data"),
  [string]$DetailDataPath = "",
  [switch]$NoPush
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "HeldStockMonitorShared.ps1")

function U {
  param([Parameter(Mandatory = $true)][string]$Text)
  [regex]::Replace($Text, "\\u([0-9a-fA-F]{4})", {
    param($m)
    [char][int]::Parse($m.Groups[1].Value, [System.Globalization.NumberStyles]::HexNumber)
  })
}

function Get-DetailMapFromFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Detail data file not found: $Path"
  }

  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
  $map = @{}
  foreach ($item in @($raw)) {
    if (-not $item.code) { continue }
    $map[[string]$item.code] = [pscustomobject]@{
      f137 = $item.f137
      f138 = $item.f138
      f139 = $item.f139
      f140 = $item.f140
      f141 = $item.f141
      f142 = $item.f142
      f143 = $item.f143
      f144 = $item.f144
      f145 = $item.f145
      f146 = $item.f146
      f147 = $item.f147
      f148 = $item.f148
      f149 = $item.f149
    }
  }
  return $map
}

$holdings = @(Import-HeldStocks -Path $HoldingsPath)
if (-not $holdings) {
  throw "No holdings loaded."
}

if (-not (Test-Path -LiteralPath $SnapshotPath)) {
  throw "Snapshot file not found: $SnapshotPath"
}

$snapshot = Get-Content -LiteralPath $SnapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json
$heldCodes = @($holdings | Select-Object -ExpandProperty Code)
$valid = @(
  Convert-SnapshotRowsToQuoteRows -SnapshotRows @($snapshot.rows) |
    Where-Object { $heldCodes -contains ([string]$_.f12) } |
    Sort-Object { Get-SafeDouble $_.f62 } -Descending
)

$detailMap = @{}
$detailSourceText = U '\u672a\u8865\u5145\u4e3b\u529b\u603b\u6d41\u5165/\u603b\u6d41\u51fa\u8be6\u60c5'
if ($DetailDataPath) {
  $detailMap = Get-DetailMapFromFile -Path $DetailDataPath
  $detailSourceText = U '\u5df2\u4f7f\u7528\u672c\u5730\u8be6\u60c5\u6587\u4ef6\u8865\u5145\u4e3b\u529b\u603b\u6d41\u5165/\u603b\u6d41\u51fa'
} else {
  $detailResult = Get-HeldQuoteDetailFetchResult -Holdings $holdings
  $detailMap = $detailResult.Map
  if ($detailMap.Count -gt 0) {
    $detailSourceText = (U '\u5df2\u4f7f\u7528\u4e1c\u8d22\u5b9e\u65f6\u8be6\u60c5\u8865\u5145\u4e3b\u529b\u603b\u6d41\u5165/\u603b\u6d41\u51fa\uff08{0}/{1}\uff09') -f $detailMap.Count, $holdings.Count
  } elseif ($detailResult.Errors.Count -gt 0) {
    $detailSourceText = (U '\u672a\u8865\u5145\u4e3b\u529b\u603b\u6d41\u5165/\u603b\u6d41\u51fa\uff1b\u9996\u4e2a\u9519\u8bef\uff1a{0}') -f $detailResult.Errors[0]
  }
}

if ($detailMap.Count -gt 0) {
  Merge-HeldQuoteDetailFields -Rows $valid -DetailMap $detailMap
}

$sumFlow = Get-SafeSum -Items $valid -PropertyName "f62"
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add((U '**\u6a21\u62df\u6536\u76d8\u8865\u53d1**'))
$lines.Add(((U '\u2139\ufe0f\u3010\u6a21\u62df\u3011\u672c\u6761\u6d88\u606f\u4f7f\u7528 **{0}** \u6536\u76d8\u5feb\u7167\u751f\u6210\u3002') -f $snapshot.time))
$lines.Add(((U '\u2139\ufe0f\u3010\u6570\u636e\u3011\u672c\u6b21\u76d1\u63a7\u6301\u6709\u80a1\u7968 **{0}** \u53ea\uff0c\u5feb\u7167\u5339\u914d **{1}** \u53ea\u3002') -f $holdings.Count, $valid.Count))
$lines.Add(((U '\u2139\ufe0f\u3010\u8be6\u60c5\u3011{0}\u3002') -f $detailSourceText))
$lines.Add((U '**\u89e6\u53d1\u539f\u56e0\uff1a** \u624b\u52a8\u8865\u8dd1 15:00 \u6536\u76d8\u63a8\u9001\u3002'))
$lines.Add(((U '\u2139\ufe0f\u3010\u6570\u636e\u3011\u6301\u80a1\u8303\u56f4\u5408\u8ba1\u4e3b\u529b\u51c0\u989d\uff1a**{0}**\u3002') -f (Format-CnyWan $sumFlow)))
$lines.Add("")
$lines.Add("---")
$lines.Add((U '**\u5b8c\u6574\u6301\u6709\u5217\u8868\uff08\u6309\u4e3b\u529b\u51c0\u989d\u4ece\u6d41\u5165\u5230\u6d41\u51fa\u6392\u5e8f\uff09**'))

foreach ($r in $valid) {
  $dir = if ((Get-SafeDouble $r.f62) -ge 0) { U '\u51c0\u6d41\u5165' } else { U '\u51c0\u6d41\u51fa' }
  $flowSegments = @(
    (Format-OrderFlowSegment -Label (U '\u7279\u5927\u5355') -Flow $r.f66 -Ratio $r.f69),
    (Format-OrderFlowSegment -Label (U '\u5927\u5355') -Flow $r.f72 -Ratio $r.f75),
    (Format-MidSmallFlowSegment -MediumFlow $r.f78 -MediumRatio $r.f81 -SmallFlow $r.f84 -SmallRatio $r.f87)
  ) -join (U '\uff0c')
  $mainFlowSummary = Get-MainFlowSummary -MainFlow $r.f62 -SuperFlow $r.f66 -SuperIn $r.f138 -SuperOut $r.f139 -LargeFlow $r.f72 -LargeIn $r.f141 -LargeOut $r.f142
  $lines.Add(((U '- {0} **{1}\uff08{2}\uff09**') -f $dir, $r.f14, $r.f12))
  $lines.Add(((U '  \u251c \u4e3b\u529b\u51c0\u989d\uff1a**{0}**    \u6da8\u8dcc\u5e45\uff1a**{1}**') -f (Format-ColoredSignedCny $r.f62), (Format-ColoredPct $r.f3)))
  $lines.Add(((U '  \u251c \u8d44\u91d1\u52a8\u5411\uff1a{0}') -f $flowSegments))
  $lines.Add(((U '  \u2514 {0}') -f $mainFlowSummary))
}

$lines.Add("")
$lines.Add("---")
$lines.Add((U '## \u98ce\u9669\u63d0\u793a'))
$lines.Add((U '\u672c\u6761\u4e3a\u624b\u52a8\u8865\u8dd1\u6d88\u606f\uff1b\u4e3b\u529b\u8d44\u91d1\u4e3a\u884c\u60c5\u670d\u52a1\u5546\u4f30\u7b97\u53e3\u5f84\uff0c\u4e0d\u4ee3\u8868\u673a\u6784\u771f\u5b9e\u8d26\u6237\u4ea4\u6613\u3002'))

$outbox = Join-Path $DataRoot "outbox"
New-Item -ItemType Directory -Force -Path $outbox | Out-Null
$reportFile = Join-Path $outbox ("simulated_close_push_{0}.md" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$encoding = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($reportFile, ($lines -join "`n"), $encoding)

if ($NoPush) {
  Write-Output ((U '\u6a21\u62df\u6536\u76d8\u8865\u53d1\u5df2\u751f\u6210\uff1a{0}') -f $reportFile)
  exit 0
}

$sharedPendingPushRoot = Get-SharedPendingPushRoot -DataRoot (Join-Path (Split-Path -Parent $PSScriptRoot) "data") -Scope "auction_close"
Invoke-HiddenPowershellScript -ScriptPath (Join-Path $PSScriptRoot "Send-FeishuCard.ps1") -Parameters @{
  Title = (U 'A\u80a1\u5df2\u6301\u80a1\u4efd\u8d44\u91d1\u52a8\u5411\u76d1\u63a7\uff5c15:00\u6536\u76d8\u8865\u53d1')
  Template = "blue"
  ContentPath = $reportFile
  QueueRoot = $sharedPendingPushRoot
} | Out-Null

Write-Output ((U '\u6a21\u62df\u6536\u76d8\u8865\u53d1\u5df2\u53d1\u9001\uff1a{0}') -f $reportFile)
