$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$outbox = Join-Path $root "data\outbox"
$snapshotRoot = Join-Path $root "data\snapshots"
$logDir = Join-Path $root "data\logs"
New-Item -ItemType Directory -Force -Path $outbox | Out-Null
New-Item -ItemType Directory -Force -Path $snapshotRoot | Out-Null
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir "fund_push.log"
function Write-Log($message) {
  Add-Content -LiteralPath $logFile -Encoding UTF8 -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $message"
}
Write-Log "start"

$watchFile = "C:\同花顺远航版\bin\users\mx_vm758hg4z\blockstockV3.xml"
if (-not (Test-Path -LiteralPath $watchFile)) {
  throw "自选股文件不存在：$watchFile"
}

$desiredGroups = [ordered]@{
  SEMI_OPTICAL_COMM = @(
    "300308", "300502", "300394", "002281", "603083", "688498", "300570",
    "000988", "601138"
  )
  SEMI_MATERIALS = @(
    "300346", "688126", "688549", "688019", "688146", "300655", "603078",
    "300666", "600183", "002436", "002916", "688519"
  )
  SEMI_EQUIPMENT = @(
    "002371", "688012", "688037", "688072", "688082", "688120", "688409"
  )
  SEMI_TEST = @(
    "688200", "300604", "300567"
  )
  SEMI_PACKAGING = @(
    "600584", "002156", "002185", "688362", "603005", "688216"
  )
  SEMI_DESIGN_EDA_IP = @(
    "603160", "603501", "688380", "688521", "688206", "301269"
  )
  SEMI_FOUNDRY_POWER = @(
    "688981", "688347", "688469", "688234", "688126"
  )
}

function Get-MarketPrefix($code) {
  if ($code -match "^[56]") { return "1" }
  return "0"
}

[xml]$xml = Get-Content -LiteralPath $watchFile -Raw
$items = @()
foreach ($security in $xml.hevo.Block.security) {
  $code = [string]$security.code
  $market = [string]$security.market
  if (-not $code) { continue }
  $prefix = if ($market -eq "USHA") { "1" } elseif ($market -eq "USTM") { "0" } else { Get-MarketPrefix $code }
  $items += [pscustomobject]@{ SecId = "$prefix.$code"; Code = $code }
}
$thsCount = @($items | Sort-Object SecId -Unique).Count
foreach ($code in ($desiredGroups.Values | ForEach-Object { $_ } | Sort-Object -Unique)) {
  $items += [pscustomobject]@{ SecId = "$(Get-MarketPrefix $code).$code"; Code = $code }
}
$items = $items | Sort-Object SecId -Unique
if (-not $items) { throw "自选股文件中没有可监控股票。" }

$fields = "f12,f14,f2,f3,f4,f5,f6,f62,f184,f66,f69,f72,f75,f78,f81,f84,f87,f124"
$secids = ($items.SecId) -join ","
$url = "https://push2.eastmoney.com/api/qt/ulist.np/get?fltt=2&invt=2&fields=$fields&secids=$secids"
$data = Invoke-RestMethod -Uri $url -Headers @{"User-Agent"="Mozilla/5.0";"Referer"="https://quote.eastmoney.com/"} -TimeoutSec 20
$rows = @($data.data.diff)
if (-not $rows) { throw "公开行情接口未返回有效数据。" }

$groupMap = @{}
foreach ($block in $xml.hevo.Block) {
  $name = [string]$block.name
  if (-not $name.StartsWith("SEMI_")) { continue }
  foreach ($security in @($block.security)) {
    $code = [string]$security.code
    if (-not $code) { continue }
    if (-not $groupMap.ContainsKey($name)) {
      $groupMap[$name] = @()
    }
    $groupMap[$name] += $code
  }
}
foreach ($groupName in $desiredGroups.Keys) {
  $groupMap[$groupName] = @($desiredGroups[$groupName] | Sort-Object -Unique)
}

function Format-CnyWan($value) {
  if ($null -eq $value -or $value -eq "-" -or $value -eq "") { return "--" }
  $num = [double]$value
  if ([Math]::Abs($num) -ge 100000000) { return ("{0:N2}亿元" -f ($num / 100000000)) }
  return ("{0:N2}万元" -f ($num / 10000))
}

function Format-Pct($value) {
  if ($null -eq $value -or $value -eq "-" -or $value -eq "") { return "--" }
  return ("{0:N2}%" -f ([double]$value))
}

function Format-SignedCny($value) {
  if ($null -eq $value -or $value -eq "-" -or $value -eq "") { return "--" }
  $num = [double]$value
  $prefix = if ($num -gt 0) { "+" } else { "" }
  if ([Math]::Abs($num) -ge 100000000) { return ("{0}{1:N2}亿元" -f $prefix, ($num / 100000000)) }
  return ("{0}{1:N2}万元" -f $prefix, ($num / 10000))
}

function New-Bar($value, $maxAbs, $width = 10) {
  if (-not $maxAbs -or $maxAbs -le 0) { return "" }
  $length = [Math]::Max(1, [Math]::Round(([Math]::Abs([double]$value) / $maxAbs) * $width))
  return ("█" * [int]$length)
}

function Format-AbsShare($value, $totalAbs) {
  if (-not $totalAbs -or $totalAbs -le 0) { return "--" }
  return ("{0:N0}%" -f (([Math]::Abs([double]$value) / [double]$totalAbs) * 100))
}

function Get-IntensityLabel($value, $maxAbs) {
  if (-not $maxAbs -or $maxAbs -le 0) { return "强度 --" }
  $ratio = [Math]::Abs([double]$value) / [double]$maxAbs
  if ($ratio -ge 0.8) { return "强度 5/5" }
  if ($ratio -ge 0.6) { return "强度 4/5" }
  if ($ratio -ge 0.4) { return "强度 3/5" }
  if ($ratio -ge 0.2) { return "强度 2/5" }
  return "强度 1/5"
}

function Format-DeltaText($delta) {
  $num = [double]$delta
  if ([Math]::Abs($num) -lt 1000000) { return "基本持平" }
  if ($num -gt 0) { return "改善 $(Format-SignedCny $num)" }
  return "恶化 $(Format-SignedCny $num)"
}

function Get-GroupDisplayName($groupName) {
  switch ($groupName) {
    "SEMI_OPTICAL_COMM" { return "光通讯/光模块" }
    "SEMI_MATERIALS" { return "半导体材料" }
    "SEMI_EQUIPMENT" { return "半导体设备" }
    "SEMI_TEST" { return "测试/量测" }
    "SEMI_PACKAGING" { return "封装" }
    "SEMI_DESIGN_EDA_IP" { return "设计/EDA/IP" }
    "SEMI_FOUNDRY_POWER" { return "晶圆制造/功率" }
    default { return $groupName }
  }
}

$valid = $rows | Where-Object { $_.f12 -and $_.f14 }
$sumFlow = ($valid | Measure-Object -Property f62 -Sum).Sum
$inTop = $valid | Sort-Object {[double]$_.f62} -Descending | Select-Object -First 5
$outTop = $valid | Sort-Object {[double]$_.f62} | Select-Object -First 5
$big = $valid | Where-Object { [Math]::Abs([double]$_.f62) -ge 50000000 -or [Math]::Abs([double]$_.f184) -ge 1.5 } | Sort-Object {[Math]::Abs([double]$_.f62)} -Descending | Select-Object -First 5
$template = if (($big | Where-Object { [Math]::Abs([double]$_.f62) -ge 100000000 -or [Math]::Abs([double]$_.f184) -ge 3 }).Count -gt 0) { "red" } else { "orange" }

$time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$now = Get-Date
$tradeDate = $now.ToString("yyyyMMdd")
$snapshotDir = Join-Path $snapshotRoot $tradeDate
New-Item -ItemType Directory -Force -Path $snapshotDir | Out-Null

$snapshotRows = @($valid | ForEach-Object {
  [pscustomobject]@{
    code = [string]$_.f12
    name = [string]$_.f14
    price = $_.f2
    pct = $_.f3
    main_flow = $_.f62
    main_ratio = $_.f184
  }
})
$groupSnapshot = @{}
foreach ($groupName in $groupMap.Keys) {
  $codes = @($groupMap[$groupName] | Sort-Object -Unique)
  $groupRows = @($valid | Where-Object { $codes -contains ([string]$_.f12) })
  $groupSnapshot[$groupName] = [pscustomobject]@{
    count = $groupRows.Count
    main_flow = ($groupRows | Measure-Object -Property f62 -Sum).Sum
  }
}
$snapshot = [pscustomobject]@{
  time = $time
  trade_date = $tradeDate
  total_count = $items.Count
  valid_count = $valid.Count
  total_main_flow = $sumFlow
  groups = $groupSnapshot
  rows = $snapshotRows
}
$snapshotFile = Join-Path $snapshotDir ("snapshot_{0}.json" -f $now.ToString("HHmmss"))
$snapshot | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $snapshotFile -Encoding UTF8

$isCloseReport = ($now.Hour -ge 15)
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("**核心结论**")
$lines.Add("ℹ️【数据】本次监控读取同花顺自选股 **$thsCount** 只，合并半导体产业链池后监控 **$($items.Count)** 只，公开行情返回 **$($valid.Count)** 只，数据时间 **$time**。")
if ($valid.Count -lt $items.Count) {
  $lines.Add("ℹ️【说明】少量股票可能因停牌、接口暂未返回或行情服务商字段缺失而未进入本次统计。")
}
$lines.Add("**触发原因：** 定时资金监控运行。")
$lines.Add("ℹ️【数据】监控范围合计主力净额：**$(Format-CnyWan $sumFlow)**。")
if ($big.Count -gt 0) {
  $first = $big | Select-Object -First 1
  $direction = if ([double]$first.f62 -ge 0) { "🔴净流入" } else { "🟢净流出" }
  $lines.Add("⚠️【关注】最大异动：**$($first.f14)（$($first.f12)）** $direction **$(Format-CnyWan $first.f62)**，主力净占比 **$(Format-Pct $first.f184)**。")
  $lines.Add("**触发原因：** 主力净额或主力净占比达到关注阈值。")
}
$lines.Add("")
$lines.Add("---")
$lines.Add("**流入前5**")
foreach ($r in $inTop) {
  $lines.Add("- 🔴 **$($r.f14)（$($r.f12)）**：主力净额 **$(Format-CnyWan $r.f62)**，主力净占比 **$(Format-Pct $r.f184)**，涨跌幅 **$(Format-Pct $r.f3)**")
}
$lines.Add("")
$lines.Add("**流出前5**")
foreach ($r in $outTop) {
  $lines.Add("- 🟢 **$($r.f14)（$($r.f12)）**：主力净额 **$(Format-CnyWan $r.f62)**，主力净占比 **$(Format-Pct $r.f184)**，涨跌幅 **$(Format-Pct $r.f3)**")
}
$lines.Add("")
$lines.Add("**异动项目**")
if ($big.Count -gt 0) {
  foreach ($r in $big) {
    $tag = if ([Math]::Abs([double]$r.f62) -ge 100000000 -or [Math]::Abs([double]$r.f184) -ge 3) { "🚨【重大】" } else { "⚠️【关注】" }
    $dir = if ([double]$r.f62 -ge 0) { "🔴净流入" } else { "🟢净流出" }
    $lines.Add("- $tag **$($r.f14)（$($r.f12)）** $dir **$(Format-CnyWan $r.f62)**，主力净占比 **$(Format-Pct $r.f184)**，涨跌幅 **$(Format-Pct $r.f3)**")
  }
} else {
  $lines.Add("- ℹ️【数据】本次补跑未发现达到关注阈值的大额异动。")
}

$lines.Add("")
$lines.Add("---")
$lines.Add("**产业链分组资金概览**")
$groupNowItems = @()
foreach ($groupName in $groupMap.Keys) {
  $codes = @($groupMap[$groupName] | Sort-Object -Unique)
  $groupRows = @($valid | Where-Object { $codes -contains ([string]$_.f12) })
  $groupFlow = ($groupRows | Measure-Object -Property f62 -Sum).Sum
  $leader = $groupRows | Sort-Object {[Math]::Abs([double]$_.f62)} -Descending | Select-Object -First 1
  $groupNowItems += [pscustomobject]@{
    Name = $groupName
    DisplayName = Get-GroupDisplayName $groupName
    Count = $groupRows.Count
    Flow = [double]$groupFlow
    Leader = $leader
  }
}
$maxGroupNow = ($groupNowItems | ForEach-Object { [Math]::Abs([double]$_.Flow) } | Measure-Object -Maximum).Maximum
$totalGroupAbsNow = ($groupNowItems | ForEach-Object { [Math]::Abs([double]$_.Flow) } | Measure-Object -Sum).Sum
$rank = 1
foreach ($g in ($groupNowItems | Sort-Object {[Math]::Abs([double]$_.Flow)} -Descending)) {
  $tag = if ([double]$g.Flow -ge 0) { "🔴" } else { "🟢" }
  $leaderText = ""
  if ($g.Leader) {
    $leaderText = "，异动代表：**$($g.Leader.f14)（$($g.Leader.f12)）** $(Format-CnyWan $g.Leader.f62)"
  }
  $share = Format-AbsShare $g.Flow $totalGroupAbsNow
  $intensity = Get-IntensityLabel $g.Flow $maxGroupNow
  $lines.Add("- **$rank. $($g.DisplayName)**：覆盖 **$($g.Count)** 只，$tag **$(Format-SignedCny $g.Flow)**，占比 **$share**，$intensity$leaderText")
  $rank += 1
}

if ($isCloseReport) {
  $snapshots = @(Get-ChildItem -LiteralPath $snapshotDir -Filter "snapshot_*.json" -ErrorAction SilentlyContinue |
    Sort-Object Name |
    ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json })

  if ($snapshots.Count -gt 0) {
    $firstSnapshot = $snapshots | Select-Object -First 1
    $lastSnapshot = $snapshots | Select-Object -Last 1
    $firstFlow = [double]$firstSnapshot.total_main_flow
    $lastFlow = [double]$lastSnapshot.total_main_flow
    $flowChange = $lastFlow - $firstFlow

    $lines.Add("")
    $lines.Add("---")
    $lines.Add("**收盘全天资金分析**")
    $lines.Add("ℹ️【数据】今日累计记录 **$($snapshots.Count)** 个资金快照，首个快照 **$($firstSnapshot.time)**，收盘快照 **$($lastSnapshot.time)**。")
    $lines.Add("ℹ️【数据】合计主力净额从 **$(Format-SignedCny $firstFlow)** 变化至 **$(Format-SignedCny $lastFlow)**，日内变化 **$(Format-SignedCny $flowChange)**。")

    $lines.Add("")
    $lines.Add("**合计净额路径**")
    $previousFlow = $null
    foreach ($s in $snapshots) {
      $flow = [double]$s.total_main_flow
      $tag = if ($flow -ge 0) { "🔴" } else { "🟢" }
      $label = ([datetime]$s.time).ToString("HH:mm")
      $deltaText = if ($null -eq $previousFlow) { "起点" } else { Format-DeltaText ($flow - [double]$previousFlow) }
      $lines.Add("- **$label**：$tag **$(Format-SignedCny $flow)**，$deltaText")
      $previousFlow = $flow
    }

    $lines.Add("")
    $lines.Add("**产业链分组资金排名**")
    $groupItems = @()
    foreach ($groupName in $groupMap.Keys) {
      $groupValue = 0
      if ($lastSnapshot.groups.PSObject.Properties.Name -contains $groupName) {
        $groupValue = [double]$lastSnapshot.groups.$groupName.main_flow
      }
      $groupItems += [pscustomobject]@{ Name = $groupName; Flow = $groupValue }
    }
    $maxGroup = ($groupItems | ForEach-Object { [Math]::Abs([double]$_.Flow) } | Measure-Object -Maximum).Maximum
    $totalGroupAbs = ($groupItems | ForEach-Object { [Math]::Abs([double]$_.Flow) } | Measure-Object -Sum).Sum
    $rank = 1
    foreach ($g in ($groupItems | Sort-Object {[Math]::Abs([double]$_.Flow)} -Descending)) {
      $tag = if ([double]$g.Flow -ge 0) { "🔴" } else { "🟢" }
      $share = Format-AbsShare $g.Flow $totalGroupAbs
      $intensity = Get-IntensityLabel $g.Flow $maxGroup
      $lines.Add("- **$rank. $(Get-GroupDisplayName $g.Name)**：$tag **$(Format-SignedCny $g.Flow)**，占比 **$share**，$intensity")
      $rank += 1
    }

    $firstByCode = @{}
    foreach ($r in @($firstSnapshot.rows)) {
      $firstByCode[[string]$r.code] = $r
    }
    $changes = @()
    foreach ($r in @($lastSnapshot.rows)) {
      $code = [string]$r.code
      if (-not $firstByCode.ContainsKey($code)) { continue }
      $delta = [double]$r.main_flow - [double]$firstByCode[$code].main_flow
      $changes += [pscustomobject]@{
        code = $code
        name = [string]$r.name
        delta = $delta
        flow = [double]$r.main_flow
      }
    }
    $lines.Add("")
    $lines.Add("**日内改善前5**")
    foreach ($r in ($changes | Sort-Object delta -Descending | Select-Object -First 5)) {
      $lines.Add("- 🔴 **$($r.name)（$($r.code)）**：日内变化 **$(Format-SignedCny $r.delta)**，收盘净额 **$(Format-SignedCny $r.flow)**")
    }
    $lines.Add("")
    $lines.Add("**日内恶化前5**")
    foreach ($r in ($changes | Sort-Object delta | Select-Object -First 5)) {
      $lines.Add("- 🟢 **$($r.name)（$($r.code)）**：日内变化 **$(Format-SignedCny $r.delta)**，收盘净额 **$(Format-SignedCny $r.flow)**")
    }
  }
}
$lines.Add("")
$lines.Add("---")
$lines.Add("## 风险提示")
$lines.Add("主力资金为行情服务商估算口径，不代表机构真实账户交易；公开接口与同花顺口径可能不同。本报告仅作监控提示，不构成个性化投资建议或买卖指令。")

$report = $lines -join "`n"
$filePrefix = if ($isCloseReport) { "close_report" } else { "formal_replay" }
$file = Join-Path $outbox ("{0}_{1}.md" -f $filePrefix, (Get-Date -Format "yyyyMMdd_HHmmss"))
$encoding = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($file, $report, $encoding)

$title = if ($isCloseReport) { "A股半导体与主力资金监控｜收盘资金分析" } else { "A股半导体与主力资金监控｜资金报告" }
try {
  $sendScript = Join-Path $PSScriptRoot "Send-FeishuCard.ps1"
  $powershell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
  & $powershell -NoProfile -ExecutionPolicy Bypass -File $sendScript `
    -Title ([string]$title) `
    -Template ([string]$template) `
    -ContentPath ([string]$file)
  if ($LASTEXITCODE -ne 0) {
    throw "Feishu sender exited with code $LASTEXITCODE"
  }
  Write-Log "pushed $file"
} catch {
  Write-Log "push failed $file :: $($_.Exception.Message)"
  throw
}
Write-Output "资金报告已推送：$file"
