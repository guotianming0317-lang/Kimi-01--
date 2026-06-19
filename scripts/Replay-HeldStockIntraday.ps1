param(
  [string]$TradeDate = (Get-Date -Format "yyyyMMdd"),
  [string]$HoldingsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "data\holdings.csv"),
  [string]$DataRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) "data")
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Holdings.ps1")

$holdings = @(Import-HeldStocks -Path $HoldingsPath)
$heldCodes = @($holdings | Select-Object -ExpandProperty Code)
$snapshotDir = Join-Path $DataRoot "snapshots\$TradeDate"
if (-not (Test-Path -LiteralPath $snapshotDir)) {
  throw "没有找到 $TradeDate 的快照目录：$snapshotDir"
}

$snapshots = @(Get-ChildItem -LiteralPath $snapshotDir -Filter "snapshot_*.json" |
  Sort-Object Name |
  ForEach-Object {
    $s = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $rows = @($s.rows | Where-Object { $heldCodes -contains ([string]$_.code) })
    $flow = ($rows | Measure-Object -Property main_flow -Sum).Sum
    [pscustomobject]@{
      File = $_.Name
      Time = [datetime]$s.time
      TimeText = [string]$s.time
      Count = $rows.Count
      Flow = [double]$flow
      Rows = $rows
    }
  })

if (-not $snapshots) {
  throw "没有找到 $TradeDate 的资金快照。"
}

function Format-SignedCny($value) {
  $num = [double]$value
  $prefix = if ($num -gt 0) { "+" } else { "" }
  if ([Math]::Abs($num) -ge 100000000) {
    return ("{0}{1:N2}亿元" -f $prefix, ($num / 100000000))
  }
  return ("{0}{1:N2}万元" -f $prefix, ($num / 10000))
}

function Format-Pct($value) {
  if ($null -eq $value -or $value -eq "-" -or $value -eq "") { return "--" }
  return ("{0:N2}%" -f ([double]$value))
}

function Format-ColoredPct($value) {
  if ($null -eq $value -or $value -eq "-" -or $value -eq "") { return "--" }
  $num = [double]$value
  $text = "{0:N2}%" -f $num
  if ($num -gt 0) {
    return "<font color=`"red`">$text</font>"
  }
  if ($num -lt 0) {
    return "<font color=`"green`">$text</font>"
  }
  return "<font color=`"grey`">$text</font>"
}

$first = $snapshots | Select-Object -First 1
$latest = $snapshots | Select-Object -Last 1
$outbox = Join-Path $DataRoot "outbox"
New-Item -ItemType Directory -Force -Path $outbox | Out-Null

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# 已持仓股票日内资金回放（$TradeDate）")
$lines.Add("")
$lines.Add("**数据范围：** 本地留存快照 $($snapshots.Count) 个，覆盖 $($first.Time.ToString('HH:mm:ss')) 至 $($latest.Time.ToString('HH:mm:ss'))。")
$lines.Add("**监控范围：** 仅筛选 data/holdings.csv 中的 $($holdings.Count) 只已持仓股票；最新快照实际匹配 $($latest.Count) 只。")
$lines.Add("**说明：** 当前项目本地没有上午与午后早盘快照；以下为可用快照回放，不等同完整 09:30-15:00 全日逐分钟数据。")
$lines.Add("")
$lines.Add("## 合计主力净额路径")

$previous = $null
foreach ($s in $snapshots) {
  $delta = if ($null -eq $previous) { "起点" } else { "较前次 $(Format-SignedCny ($s.Flow - [double]$previous))" }
  $lines.Add("- **$($s.Time.ToString('HH:mm'))**：**$(Format-SignedCny $s.Flow)**，$delta")
  $previous = $s.Flow
}

$lines.Add("")
$lines.Add("## 最新快照持仓明细")
foreach ($r in (@($latest.Rows) | Sort-Object {[Math]::Abs([double]$_.main_flow)} -Descending)) {
  $lines.Add("- **$($r.name)（$($r.code)）**：主力净额 **$(Format-SignedCny $r.main_flow)**，涨跌幅 **$(Format-ColoredPct $r.pct)**，主力净占比 **$(Format-Pct $r.main_ratio)**")
}

$firstByCode = @{}
foreach ($r in @($first.Rows)) {
  $firstByCode[[string]$r.code] = $r
}
$changes = @()
foreach ($r in @($latest.Rows)) {
  $code = [string]$r.code
  if (-not $firstByCode.ContainsKey($code)) { continue }
  $changes += [pscustomobject]@{
    code = $code
    name = [string]$r.name
    delta = ([double]$r.main_flow - [double]$firstByCode[$code].main_flow)
    flow = [double]$r.main_flow
  }
}

$lines.Add("")
$lines.Add("## 区间变化")
foreach ($r in ($changes | Sort-Object delta -Descending)) {
  $lines.Add("- **$($r.name)（$($r.code)）**：区间变化 **$(Format-SignedCny $r.delta)**，最新净额 **$(Format-SignedCny $r.flow)**")
}

$encoding = New-Object System.Text.UTF8Encoding($true)
$reportFile = Join-Path $outbox ("held_intraday_replay_{0}_{1}.md" -f $TradeDate, (Get-Date -Format "HHmmss"))
[System.IO.File]::WriteAllText($reportFile, ($lines -join "`n"), $encoding)

$flat = foreach ($s in $snapshots) {
  foreach ($r in @($s.Rows)) {
    [pscustomobject]@{
      time = $s.TimeText
      code = $r.code
      name = $r.name
      price = $r.price
      pct = $r.pct
      main_flow = $r.main_flow
      main_ratio = $r.main_ratio
    }
  }
}
$csvFile = Join-Path $DataRoot ("held_intraday_replay_{0}.csv" -f $TradeDate)
$flat | Export-Csv -LiteralPath $csvFile -NoTypeInformation -Encoding UTF8

Write-Output "Report: $reportFile"
Write-Output "CSV: $csvFile"
Write-Output "Snapshots: $($snapshots.Count)"
Write-Output "Window: $($first.Time.ToString('HH:mm:ss'))-$($latest.Time.ToString('HH:mm:ss'))"
Write-Output "Latest held flow: $(Format-SignedCny $latest.Flow)"
