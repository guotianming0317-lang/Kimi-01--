param(
  [string]$HoldingsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "data\holdings.csv"),
  [string]$DataRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) "data"),
  [string]$QuoteDataPath = "",
  [switch]$NoPush
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "HeldStockMonitorShared.ps1")
$sharedPendingPushRoot = Get-SharedPendingPushRoot -DataRoot (Join-Path (Split-Path -Parent $PSScriptRoot) "data") -Scope "fixed_report"

$context = New-MonitorContext -DataRoot $DataRoot -LogName "fund_push.log"
if (Test-MonitorPaused -PauseFlag $context.PauseFlag) {
  Write-MonitorLog -LogFile $context.LogFile -Message "paused by $($context.PauseFlag)"
  Write-Output "监控已暂停：$($context.PauseFlag)"
  exit 0
}

Write-MonitorLog -LogFile $context.LogFile -Message "start"

if (-not $NoPush) {
  try {
    $replayScript = Join-Path $PSScriptRoot "Replay-PendingFeishuPushes.ps1"
    if (Test-Path -LiteralPath $replayScript) {
      Invoke-HiddenPowershellScript -ScriptPath $replayScript -Parameters @{ QueueRoot = $sharedPendingPushRoot } | Out-Null
    }
  } catch {
    Write-MonitorLog -LogFile $context.LogFile -Message "pending replay skipped :: $($_.Exception.Message)"
  }
}

$holdings = @(Import-HeldStocks -Path $HoldingsPath)
if (-not $holdings) {
  throw "持仓清单中没有可监控股票。"
}

$usedFallbackSnapshot = $false
$fallbackReason = ""
$valid = @()
$snapshotRows = @()
$snapshotResult = $null
$snapshot = $null
$reportFallbackReason = ""

try {
  $valid = @(Get-HeldQuoteRows -Holdings $holdings -QuoteDataPath $QuoteDataPath)
  $snapshotRows = @(New-SnapshotRows -Rows $valid)
  $snapshotResult = Save-MonitorSnapshot -SnapshotRoot $context.SnapshotRoot -TotalCount $holdings.Count -SnapshotRows $snapshotRows
  $snapshot = $snapshotResult.Snapshot
} catch {
  $fallbackReason = $_.Exception.Message
  $latestSnapshotFile = Get-LatestSnapshotFile -SnapshotRoot $context.SnapshotRoot
  if ($latestSnapshotFile) {
    $snapshot = Get-Content -LiteralPath $latestSnapshotFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $snapshotRows = @($snapshot.rows)
    $valid = @(Convert-SnapshotRowsToQuoteRows -SnapshotRows $snapshotRows)
    $snapshotResult = [pscustomobject]@{
      Snapshot = $snapshot
      SnapshotFile = $latestSnapshotFile.FullName
      SnapshotDir = $latestSnapshotFile.DirectoryName
    }
    $usedFallbackSnapshot = $true
    Write-MonitorLog -LogFile $context.LogFile -Message "fallback snapshot used $($latestSnapshotFile.FullName) :: $fallbackReason"
  } else {
    Write-MonitorLog -LogFile $context.LogFile -Message "quote failed without snapshot fallback :: $fallbackReason"
  }
}

$sumFlow = Get-SafeSum -Items $valid -PropertyName "f62"
$heldList = @($valid | Sort-Object { Get-SafeDouble $_.f62 } -Descending)
$sumFlowDisplay = if ($valid.Count -gt 0) { Format-CnyWan $sumFlow } else { "--" }
$time = if ($snapshot) { [string]$snapshot.time } else { (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }
$isCloseReport = ((Get-Date).Hour -ge 15)
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("**核心结论**")
$lines.Add("ℹ️【数据】本次仅监控已持有股票 **$($holdings.Count)** 只，行情返回 **$($valid.Count)** 只，数据时间 **$time**。")
$lines.Add("ℹ️【来源】股票账户不依赖同花顺登录；持仓名单来自本项目 `data/holdings.csv`，行情数据按原自动化链路拉取。")
if ($usedFallbackSnapshot) {
  $reportFallbackReason = Get-UserFriendlyReportError -Message $fallbackReason
  $lines.Add("ℹ️【降级】实时行情接口暂时不可用，以下内容回退到最近一次成功快照 **$time**。原因：$reportFallbackReason")
}
if ((-not $usedFallbackSnapshot) -and (-not $valid)) {
  $reportFallbackReason = Get-UserFriendlyReportError -Message $fallbackReason
  $lines.Add("⚠️【异常】本次未获取到有效行情，且没有可用快照回退。原因：$reportFallbackReason")
}
if ($valid.Count -lt $holdings.Count) {
  $heldCodes = @($holdings | Select-Object -ExpandProperty Code)
  $missing = @($heldCodes | Where-Object { @($valid | Select-Object -ExpandProperty f12) -notcontains $_ })
  $lines.Add("ℹ️【说明】未返回行情的持仓：**$($missing -join '、')**，可能因停牌、接口暂未返回或字段缺失。")
}
$lines.Add("**触发原因：** 定时资金监控运行。")
$lines.Add("ℹ️【数据】持仓范围合计主力净额：**$sumFlowDisplay**。")
$lines.Add("")
if ($valid.Count -gt 0) {
  $lines.Add("---")
  $lines.Add("**完整持有列表（按主力净额从流入到流出排序）**")
  foreach ($r in $heldList) {
    $dir = if ((Get-SafeDouble $r.f62) -ge 0) { "🔴净流入" } else { "🟢净流出" }
    $flowSegments = @(
      (Format-OrderFlowSegment -Label "特大单" -Flow $r.f66 -Ratio $r.f69),
      (Format-OrderFlowSegment -Label "大单" -Flow $r.f72 -Ratio $r.f75),
      (Format-MidSmallFlowSegment -MediumFlow $r.f78 -MediumRatio $r.f81 -SmallFlow $r.f84 -SmallRatio $r.f87)
    ) -join "，"
    $lines.Add("- $dir **$($r.f14)（$($r.f12)）**")
    $lines.Add("  ├ 主力净额：**$(Format-ColoredSignedCny $r.f62)**    涨跌幅：**$(Format-ColoredPct $r.f3)**")
    $mainFlowSummary = Get-MainFlowSummary -MainFlow $r.f62 -SuperFlow $r.f66 -SuperIn $r.f138 -SuperOut $r.f139 -LargeFlow $r.f72 -LargeIn $r.f141 -LargeOut $r.f142
    $lines.Add("  ├ 资金动向：$flowSegments")
    $lines.Add("  └ $mainFlowSummary")
  }
}

if ($isCloseReport -and $snapshotResult) {
  $snapshots = @(Get-ChildItem -LiteralPath $snapshotResult.SnapshotDir -Filter "snapshot_*.json" -ErrorAction SilentlyContinue |
    Sort-Object Name |
    ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json })

  if ($snapshots.Count -gt 0) {
    $firstSnapshot = $snapshots | Select-Object -First 1
    $lastSnapshot = $snapshots | Select-Object -Last 1
    $firstFlow = Get-SafeDouble $firstSnapshot.total_main_flow
    $lastFlow = Get-SafeDouble $lastSnapshot.total_main_flow
    $flowChange = $lastFlow - $firstFlow

    $lines.Add("")
    $lines.Add("---")
    $lines.Add("**收盘全天资金分析**")
    $lines.Add("ℹ️【数据】今日累计记录 **$($snapshots.Count)** 个持仓资金快照，首个快照 **$($firstSnapshot.time)**，收盘快照 **$($lastSnapshot.time)**。")
    $lines.Add("ℹ️【数据】持仓合计主力净额从 **$(Format-SignedCny $firstFlow)** 变化至 **$(Format-SignedCny $lastFlow)**，日内变化 **$(Format-SignedCny $flowChange)**。")

    $lines.Add("")
    $lines.Add("**合计净额路径**")
    $previousFlow = $null
    foreach ($s in $snapshots) {
      $flow = Get-SafeDouble $s.total_main_flow
      $tag = if ($flow -ge 0) { "🔴" } else { "🟢" }
      $label = ([datetime]$s.time).ToString("HH:mm")
      $deltaText = if ($null -eq $previousFlow) { "起点" } else { Format-DeltaText ($flow - (Get-SafeDouble $previousFlow)) }
      $lines.Add("- **$label**：$tag **$(Format-SignedCny $flow)**，$deltaText")
      $previousFlow = $flow
    }

    $firstByCode = @{}
    foreach ($r in @($firstSnapshot.rows)) {
      $firstByCode[[string]$r.code] = $r
    }
    $changes = @()
    foreach ($r in @($lastSnapshot.rows)) {
      $code = [string]$r.code
      if (-not $firstByCode.ContainsKey($code)) { continue }
      $delta = (Get-SafeDouble $r.main_flow) - (Get-SafeDouble $firstByCode[$code].main_flow)
      $changes += [pscustomobject]@{
        code = $code
        name = [string]$r.name
        delta = $delta
        flow = Get-SafeDouble $r.main_flow
      }
    }
    $lines.Add("")
    $lines.Add("**日内持仓变化（从改善到恶化）**")
    foreach ($r in ($changes | Sort-Object delta -Descending)) {
      $tag = if ((Get-SafeDouble $r.delta) -ge 0) { "🔴" } else { "🟢" }
      $lines.Add("- $tag **$($r.name)（$($r.code)）**：日内变化 **$(Format-SignedCny $r.delta)**，最新净额 **$(Format-SignedCny $r.flow)**")
    }
  }
}

$lines.Add("")
$lines.Add("---")
$lines.Add("## 风险提示")
$lines.Add("主力资金为行情服务商估算口径，不代表机构真实账户交易；行情接口与交易账户持仓可能存在时间差。本报告仅作监控提示，不构成个性化投资建议或买卖指令。")

$report = $lines -join "`n"
$filePrefix = if ($isCloseReport) { "close_report" } else { "formal_replay" }
$file = Join-Path $context.Outbox ("{0}_{1}.md" -f $filePrefix, (Get-Date -Format "yyyyMMdd_HHmmss"))
$encoding = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($file, $report, $encoding)

$title = if ($isCloseReport) { "A股已持股份资金动向监控｜收盘资金分析" } else { "A股已持股份资金动向监控｜资金报告" }
$template = "blue"
if ((-not $usedFallbackSnapshot) -and (-not $valid)) {
  $title = "A股已持股份资金动向监控｜接口异常说明"
  $template = "orange"
}
if ($NoPush) {
  Write-MonitorLog -LogFile $context.LogFile -Message "dry-run generated $file"
} else {
  try {
    $sendScript = Join-Path $PSScriptRoot "Send-FeishuCard.ps1"
    Invoke-HiddenPowershellScript -ScriptPath $sendScript -Parameters @{
      Title = [string]$title
      Template = [string]$template
      ContentPath = [string]$file
      QueueRoot = [string]$sharedPendingPushRoot
    } | Out-Null
    Write-MonitorLog -LogFile $context.LogFile -Message "pushed $file"
  } catch {
    Write-MonitorLog -LogFile $context.LogFile -Message "push failed $file :: $($_.Exception.Message)"
    Write-Output "资金报告推送失败，已记录日志，等待后续自动补发。"
    exit 0
  }
}

Write-Output "资金报告已生成：$file"
