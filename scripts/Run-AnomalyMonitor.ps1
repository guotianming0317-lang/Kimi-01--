param(
  [string]$HoldingsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "data\holdings.csv"),
  [string]$DataRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) "data\anomaly_monitor"),
  [string]$QuoteDataPath = "",
  [double]$AnomalyThreshold = 30000000,
  [switch]$NoPush
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "HeldStockMonitorShared.ps1")
$sharedPendingPushRoot = Join-Path (Split-Path -Parent $PSScriptRoot) "data\pending_pushes"

$context = New-MonitorContext -DataRoot $DataRoot -LogName "anomaly_push.log"
if (Test-MonitorPaused -PauseFlag (Join-Path (Split-Path -Parent $PSScriptRoot) "data\monitoring_paused.flag")) {
  Write-MonitorLog -LogFile $context.LogFile -Message "paused by project monitoring flag"
  Write-Output "异常监控已暂停。"
  exit 0
}

Write-MonitorLog -LogFile $context.LogFile -Message "start"

try {
  $replayScript = Join-Path $PSScriptRoot "Replay-PendingFeishuPushes.ps1"
  if (Test-Path -LiteralPath $replayScript) {
    Invoke-HiddenPowershellScript -ScriptPath $replayScript -Parameters @{ QueueRoot = $sharedPendingPushRoot } | Out-Null
  }
} catch {
  Write-MonitorLog -LogFile $context.LogFile -Message "pending replay skipped :: $($_.Exception.Message)"
}

$holdings = @(Import-HeldStocks -Path $HoldingsPath)
if (-not $holdings) {
  throw "持仓清单中没有可监控股票。"
}

$previousSnapshotFile = Get-LatestSnapshotFile -SnapshotRoot $context.SnapshotRoot
$valid = @(Get-HeldQuoteRows -Holdings $holdings -QuoteDataPath $QuoteDataPath)
$snapshotRows = @(New-SnapshotRows -Rows $valid)
$snapshotResult = Save-MonitorSnapshot -SnapshotRoot $context.SnapshotRoot -TotalCount $holdings.Count -SnapshotRows $snapshotRows

if (-not $previousSnapshotFile) {
  Write-MonitorLog -LogFile $context.LogFile -Message "seeded first anomaly snapshot $($snapshotResult.SnapshotFile)"
  Write-Output "异常监控首个快照已建立：$($snapshotResult.SnapshotFile)"
  exit 0
}

$previous = Get-Content -LiteralPath $previousSnapshotFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
$previousByCode = @{}
foreach ($r in @($previous.rows)) {
  $previousByCode[[string]$r.code] = $r
}

$anomalies = @()
foreach ($r in $snapshotRows) {
  $code = [string]$r.code
  if (-not $previousByCode.ContainsKey($code)) { continue }
  $delta = (Get-SafeDouble $r.main_flow) - (Get-SafeDouble $previousByCode[$code].main_flow)
  if ([Math]::Abs($delta) -ge $AnomalyThreshold) {
    $anomalies += [pscustomobject]@{
      code = $code
      name = [string]$r.name
      delta = $delta
      flow = Get-SafeDouble $r.main_flow
      pct = $r.pct
      ratio = $r.main_ratio
      super_flow = $r.super_flow
      super_in = $r.super_in
      super_out = $r.super_out
      super_ratio = $r.super_ratio
      large_flow = $r.large_flow
      large_in = $r.large_in
      large_out = $r.large_out
      large_ratio = $r.large_ratio
      medium_flow = $r.medium_flow
      medium_ratio = $r.medium_ratio
      small_flow = $r.small_flow
      small_ratio = $r.small_ratio
      previous_time = [string]$previous.time
      current_time = [string]$snapshotResult.Snapshot.time
    }
  }
}

if (-not $anomalies) {
  Write-MonitorLog -LogFile $context.LogFile -Message "no anomaly at $($snapshotResult.Snapshot.time)"
  Write-Output "未触发异常预警。"
  exit 0
}

$alertLines = New-Object System.Collections.Generic.List[string]
$alertLines.Add("# ⚠️ 主力资金瞬时大额流动")
$alertLines.Add("")
$alertLines.Add("**监控时间：** $($snapshotResult.Snapshot.time)")
$alertLines.Add("**对比区间：** $($previous.time) -> $($snapshotResult.Snapshot.time)")
$alertLines.Add("**触发阈值：** 单只股票较上次快照主力净额变化达到 **$(Format-SignedCny $AnomalyThreshold)**。")
$alertLines.Add("**预警类型：** 瞬时主力资金大额流动。")
$alertLines.Add("**触发数量：** $($anomalies.Count) 只")
$alertLines.Add("")
foreach ($a in ($anomalies | Sort-Object {[Math]::Abs((Get-SafeDouble $_.delta))} -Descending)) {
  $direction = if ((Get-SafeDouble $a.delta) -gt 0) { "瞬时净流入" } else { "瞬时净流出" }
  $flowSegments = @(
    (Format-OrderFlowSegment -Label "特大单" -Flow $a.super_flow -Ratio $a.super_ratio),
    (Format-OrderFlowSegment -Label "大单" -Flow $a.large_flow -Ratio $a.large_ratio),
    (Format-MidSmallFlowSegment -MediumFlow $a.medium_flow -MediumRatio $a.medium_ratio -SmallFlow $a.small_flow -SmallRatio $a.small_ratio)
  ) -join "，"
  $alertLines.Add("- ⚠️ **$($a.name)（$($a.code)）**：$direction **$(Format-ColoredSignedCny $a.delta)**")
  $mainFlowSummary = Get-MainFlowSummary -MainFlow $a.flow -SuperFlow $a.super_flow -SuperIn $a.super_in -SuperOut $a.super_out -LargeFlow $a.large_flow -LargeIn $a.large_in -LargeOut $a.large_out
  $alertLines.Add("  ├ 当前主力净额：**$(Format-ColoredSignedCny $a.flow)**    涨跌幅：**$(Format-ColoredPct $a.pct)**    主力净占比：**$(Format-Pct $a.ratio)**")
  $alertLines.Add("  ├ 资金动向：$flowSegments")
  $alertLines.Add("  └ $mainFlowSummary")
}
$alertLines.Add("")
$alertLines.Add("---")
$alertLines.Add("主力资金为行情服务商估算口径；该预警仅代表相邻快照间资金净额变化达到阈值。")

$alertFile = Join-Path $context.Outbox ("anomaly_alert_{0}.md" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$encoding = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($alertFile, ($alertLines -join "`n"), $encoding)

if ($NoPush) {
  Write-MonitorLog -LogFile $context.LogFile -Message "dry-run generated anomaly $alertFile"
} else {
  try {
    $sendScript = Join-Path $PSScriptRoot "Send-FeishuCard.ps1"
    Invoke-HiddenPowershellScript -ScriptPath $sendScript -Parameters @{
      Title = "⚠️ A股已持股份主力资金瞬时大额流动"
      Template = "orange"
      ContentPath = [string]$alertFile
      QueueRoot = [string]$sharedPendingPushRoot
    } | Out-Null
    Write-MonitorLog -LogFile $context.LogFile -Message "pushed anomaly $alertFile"
  } catch {
    Write-MonitorLog -LogFile $context.LogFile -Message "push failed anomaly $alertFile :: $($_.Exception.Message)"
    Write-Output "异常预警推送失败，已记录日志，等待后续自动补发。"
    exit 0
  }
}

Write-Output "异常预警已生成：$alertFile"
