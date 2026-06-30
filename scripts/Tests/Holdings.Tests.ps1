$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptsRoot = Join-Path $repoRoot "scripts"
. (Join-Path $scriptsRoot "Holdings.ps1")
. (Join-Path $scriptsRoot "FeishuCardShared.ps1")

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
  $path = Join-Path ([System.IO.Path]::GetTempPath()) ("held-stock-tests_{0}" -f ([guid]::NewGuid().ToString("N")))
  New-Item -ItemType Directory -Force -Path $path | Out-Null
  return $path
}

$testDir = New-TestDir
try {
  $holdingsPath = Join-Path $testDir "holdings.csv"
  @"
Code,Name
002594,比亚迪
600021,上海电力
002594,比亚迪
688126,沪硅产业
"@ | Set-Content -LiteralPath $holdingsPath -Encoding UTF8

  $holdings = @(Import-HeldStocks -Path $holdingsPath)
  Assert-True ($holdings.Count -eq 3) "持仓清单应该按股票代码去重。"
  Assert-True (($holdings | Where-Object Code -eq "002594").SecId -eq "0.002594") "深市股票应使用 0 前缀。"
  Assert-True (($holdings | Where-Object Code -eq "600021").SecId -eq "1.600021") "沪市股票应使用 1 前缀。"
  Assert-True (($holdings | Where-Object Code -eq "688126").ThsMarket -eq "USHA") "科创板应写入同花顺沪市 market。"

  $shortSpecs = @(New-FeishuMessageSpecs -Title "测试标题" -Content "第一段`n第二段")
  Assert-True ($shortSpecs.Count -eq 1) "短消息应保持为单条飞书推送。"
  Assert-True ($shortSpecs[0].Title -eq "测试标题") "单条飞书推送标题不应追加分段序号。"

  $longLine = ("A" * 2800)
  $longContent = @($longLine, $longLine, $longLine, $longLine, $longLine) -join "`n"
  $longSpecs = @(New-FeishuMessageSpecs -Title "长消息测试" -Content $longContent)
  Assert-True ($longSpecs.Count -ge 2) "超长消息应拆成多条飞书推送。"
  Assert-True ($longSpecs[0].Title -match "\(1/") "拆分后的第一条标题应带分段序号。"
  Assert-True ($longSpecs[1].Title -match "\(2/") "拆分后的第二条标题应带分段序号。"
  Assert-True ($longSpecs[0].Elements.Count -gt 0) "拆分后的消息应包含卡片内容。"

  . (Join-Path $scriptsRoot "HeldStockMonitorShared.ps1")
  $context = New-MonitorContext -DataRoot (Join-Path $testDir "monitor_context")
  Assert-True (Test-Path -LiteralPath $context.PendingPushRoot) "监控上下文应创建待补发队列目录。"
  $hiddenCommandResult = Invoke-HiddenConsoleCommand -FilePath "powershell.exe" -Arguments @("-NoProfile", "-Command", "Write-Output 'stdout-ok'; [Console]::Error.WriteLine('stderr-ok')")
  Assert-True ($hiddenCommandResult.ExitCode -eq 0) "隐藏子进程执行应成功。"
  Assert-True ($hiddenCommandResult.StdOut -match "stdout-ok") "隐藏子进程应能捕获标准输出。"
  Assert-True ($hiddenCommandResult.StdErr -match "stderr-ok") "隐藏子进程应能捕获标准错误。"
  Assert-True ($null -eq (Get-SafeDoubleOrNull "-")) "短横线应被视为缺失值，而不是数字。"
  Assert-True ((Get-SafeDouble "-" 99) -eq 99) "缺失值在需要时应回退到默认数值。"
  Assert-True ((Format-MidSmallFlowSegment -MediumFlow "-" -MediumRatio "-" -SmallFlow 1200000 -SmallRatio 0.35) -match "\+120.00万元</font> / 0.35%") "中小单聚合时遇到短横线不应抛错。"

  $quotePath = Join-Path $testDir "quotes.json"
  @"
{
  "data": {
    "diff": [
      { "f12": "002594", "f14": "比亚迪", "f2": 89.64, "f3": -1.30, "f62": -562198848, "f184": -18.63 },
      { "f12": "600021", "f14": "上海电力", "f2": 17.46, "f3": -0.46, "f62": -137829782, "f184": -11.43, "f66": -80000000, "f69": -6.50, "f72": -57829782, "f75": -4.93, "f78": 5000000, "f81": 0.40, "f84": -2000000, "f87": -0.15, "f138": 120000000, "f139": 200000000, "f141": 90000000, "f142": 147829782 },
      { "f12": "688126", "f14": "沪硅产业", "f2": 31.05, "f3": 0.54, "f62": 322785232, "f184": 5.04, "f66": 200000000, "f69": 3.10, "f72": 122785232, "f75": 1.94, "f78": -40000000, "f81": -0.62, "f84": -15000000, "f87": -0.23, "f138": 350000000, "f139": 150000000, "f141": 222785232, "f142": 100000000 },
      { "f12": "002281", "f14": "光迅科技", "f2": 230.01, "f3": 2.01, "f62": -1690252304, "f184": -12.97, "f66": -900000000, "f69": -7.10, "f72": -790252304, "f75": -5.87, "f78": 120000000, "f81": 0.80, "f84": -30000000, "f87": -0.20 }
    ]
  }
}
"@ | Set-Content -LiteralPath $quotePath -Encoding UTF8

  $dataRoot = Join-Path $testDir "data"
  $tradeDate = Get-Date -Format "yyyyMMdd"
  $snapshotDir = Join-Path $dataRoot "snapshots\$tradeDate"
  New-Item -ItemType Directory -Force -Path $snapshotDir | Out-Null
  $previousSnapshot = [pscustomobject]@{
    time = (Get-Date).AddMinutes(-15).ToString("yyyy-MM-dd HH:mm:ss")
    trade_date = $tradeDate
    total_count = 3
    valid_count = 3
    total_main_flow = -217198630
    rows = @(
      [pscustomobject]@{ code = "002594"; name = "比亚迪"; price = 89.64; pct = -1.30; main_flow = -200000000; main_ratio = -8.00 },
      [pscustomobject]@{ code = "600021"; name = "上海电力"; price = 17.46; pct = -0.46; main_flow = 2801412; main_ratio = 0.20 },
      [pscustomobject]@{ code = "688126"; name = "沪硅产业"; price = 31.05; pct = 0.54; main_flow = -20000000; main_ratio = -0.30 }
    )
  }
  $previousSnapshot | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $snapshotDir "snapshot_000001.json") -Encoding UTF8

  $runner = Join-Path $scriptsRoot "Run-FormalReplayPush.ps1"
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner `
    -HoldingsPath $holdingsPath `
    -DataRoot $dataRoot `
    -QuoteDataPath $quotePath `
    -NoPush | Out-Null

  if ($LASTEXITCODE -ne 0) {
    throw "运行持仓报告脚本失败，退出码 $LASTEXITCODE"
  }

  $reportFile = Get-ChildItem -LiteralPath (Join-Path $dataRoot "outbox") -Filter "*.md" |
    Where-Object { $_.Name -notlike "anomaly_alert_*" } |
    Select-Object -First 1
  Assert-True ($null -ne $reportFile) "测试应生成一份报告。"
  $report = Get-Content -LiteralPath $reportFile.FullName -Raw -Encoding UTF8
  Assert-True ($report -match "仅监控已持有股票 \*\*3\*\* 只") "报告应明确只监控已持仓股票。"
  Assert-True ($report -match "比亚迪") "报告应包含持仓股票。"
  Assert-True ($report -match "完整持有列表") "固定监控报告应展示完整持有列表。"
  Assert-True ($report -match "资金动向") "固定监控报告应展示资金动向。"
  Assert-True ($report -match "特大单") "固定监控报告应包含特大单。"
  Assert-True ($report -match "大单") "固定监控报告应包含大单。"
  Assert-True ($report -match "中小单") "固定监控报告应包含中小单。"
  Assert-True ($report -match "沪硅产业（688126）") "固定监控报告应展示持仓股票标题行。"
  Assert-True ($report -match "├ 主力净额：") "固定监控报告应将主力净额拆到独立明细行。"
  Assert-True ($report -match "涨跌幅：") "固定监控报告应在主力净额明细行中展示涨跌幅。"
  Assert-True ($report -match "<font color=""red"">\+3.23亿元</font>") "固定监控报告应将净流入金额标为红色。"
  Assert-True ($report -match "<font color=""red"">0.54%</font>") "固定监控报告应将上涨涨跌幅标为红色。"
  Assert-True ($report -match "资金动向：特大单 \*\*<font color=""red"">\+2.00亿元</font> / 3.10%\*\*，大单 \*\*<font color=""red"">\+1.23亿元</font> / 1.94%\*\*，中小单 \*\*<font color=""green"">-5,500.00万元</font> / -0.85%\*\*") "固定监控报告应正确展示各档资金动向。"
  Assert-True ($report -match "主力总流入：\*\*<font color=""red"">5.73亿元</font>\*\*.*主力总流出：\*\*<font color=""green"">2.50亿元</font>\*\*") "固定监控报告应展示真实主力总流入和主力总流出。"
  Assert-True ((Get-MainFlowSummary -MainFlow 83252700 -SuperFlow 0 -SuperIn 0 -SuperOut 2 -LargeFlow $null -LargeIn $null -LargeOut 88.12) -eq "主力总流入：**--** ｜ 主力总流出：**--**") "不满足基础反推条件的总流入/总流出应视为无效数据。"
  Assert-True ((Get-MainFlowSummary -MainFlow 1991437 -SuperFlow 0 -SuperIn "-" -SuperOut "-" -LargeFlow 1991437 -LargeIn 13883780 -LargeOut 11892343) -match "1,388.38万元.*1,189.23万元") "特大单双缺失且净额为零时，应能回推出 0/0 并保留总流入总流出。"
  Assert-True ((Get-MainFlowSummary -MainFlow -1864014 -SuperFlow -1033045 -SuperIn "-" -SuperOut 1033045 -LargeFlow -830969 -LargeIn 3588341 -LargeOut 4419310) -match "358.83万元.*545.24万元") "单侧缺失时应可结合净额反推主力总流入总流出。"
  Assert-True ($report -match "上海电力（600021）") "固定监控报告应包含上海电力。"
  Assert-True ($report -match "<font color=""green"">-1.38亿元</font>") "固定监控报告应将净流出标为绿色。"
  Assert-True ($report.IndexOf("沪硅产业") -lt $report.IndexOf("上海电力")) "完整持有列表应按主力净额从流入到流出排序。"
  Assert-True ($report.IndexOf("上海电力") -lt $report.IndexOf("比亚迪")) "完整持有列表应按主力净额从流入到流出排序。"
  Assert-True ($report -match '<font color="green">-1.30%</font>') "下跌涨跌幅应标为绿色。"
  Assert-True ($report -match '<font color="red">0.54%</font>') "上涨涨跌幅应标为红色。"
  Assert-True ($report -notmatch "流入前5") "固定监控报告不应再使用流入前5。"
  Assert-True ($report -notmatch "流出前5") "固定监控报告不应再使用流出前5。"
  Assert-True ($report -notmatch "异动项目") "固定监控报告不应再包含异动项目。"
  Assert-True ($report -notmatch "光迅科技") "报告不应包含非持仓股票。"
  Assert-True ($report -notmatch "半导体产业链") "报告不应再使用旧半导体池口径。"

  $alertFile = Get-ChildItem -LiteralPath (Join-Path $dataRoot "outbox") -Filter "anomaly_alert_*.md" -ErrorAction SilentlyContinue | Select-Object -First 1
  Assert-True ($null -eq $alertFile) "固定监控报告不应再直接生成异常预警。"

  $anomalyRoot = Join-Path $testDir "anomaly_data"
  $anomalyRunner = Join-Path $scriptsRoot "Run-AnomalyMonitor.ps1"
  $anomalySnapshotDir = Join-Path $anomalyRoot "snapshots\$tradeDate"
  New-Item -ItemType Directory -Force -Path $anomalySnapshotDir | Out-Null
  $previousSnapshot | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $anomalySnapshotDir "snapshot_000001.json") -Encoding UTF8
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $anomalyRunner `
    -HoldingsPath $holdingsPath `
    -DataRoot $anomalyRoot `
    -QuoteDataPath $quotePath `
    -NoPush | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "运行异常监控脚本检测失败，退出码 $LASTEXITCODE"
  }

  $alertFile = Get-ChildItem -LiteralPath (Join-Path $anomalyRoot "outbox") -Filter "anomaly_alert_*.md" | Select-Object -First 1
  Assert-True ($null -ne $alertFile) "超过阈值的瞬时资金变化应生成独立预警。"
  $alert = Get-Content -LiteralPath $alertFile.FullName -Raw -Encoding UTF8
  Assert-True ($alert -match "⚠️") "独立预警标题应包含黄色感叹号警示图标。"
  Assert-True ($alert -match "沪硅产业") "独立预警应包含触发股票。"
  Assert-True ($alert -match "瞬时主力资金") "独立预警应说明瞬时资金变化。"
  Assert-True ($alert -match "当前主力净额：\*\*<font color=""red"">\+3.23亿元</font>\*\*") "独立预警应将当前净流入标为红色。"
  Assert-True ($alert -match "├ 当前主力净额：") "独立预警应将核心数值拆到独立明细行。"
  Assert-True ($alert -match "特大单 \*\*<font color=""red"">\+2.00亿元</font> / 3.10%\*\*") "独立预警应包含特大单资金动向。"
  Assert-True ($alert -match "大单 \*\*<font color=""red"">\+1.23亿元</font> / 1.94%\*\*") "独立预警应包含大单资金动向。"
  Assert-True ($alert -match "中小单 \*\*<font color=""green"">-5,500.00万元</font> / -0.85%\*\*") "独立预警应包含中小单资金动向。"
  Assert-True ($alert -match "资金动向：特大单 \*\*<font color=""red"">\+2.00亿元</font> / 3.10%\*\*，大单 \*\*<font color=""red"">\+1.23亿元</font> / 1.94%\*\*，中小单 \*\*<font color=""green"">-5,500.00万元</font> / -0.85%\*\*") "独立预警应包含拆行后的资金动向。"
  Assert-True ($alert -match "主力总流入：\*\*<font color=""red"">5.73亿元</font>\*\*.*主力总流出：\*\*<font color=""green"">2.50亿元</font>\*\*") "独立预警应展示真实主力总流入和主力总流出。"

  $snapshotFile = Get-ChildItem -LiteralPath (Join-Path $dataRoot "snapshots") -Recurse -Filter "snapshot_*.json" | Select-Object -First 1
  Assert-True ($null -ne $snapshotFile) "测试应生成资金快照。"
  $snapshot = Get-Content -LiteralPath $snapshotFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-True ([int]$snapshot.total_count -eq 3) "快照总数应等于持仓清单数量。"
  Assert-True (@($snapshot.rows | Where-Object code -eq "002281").Count -eq 0) "快照不应包含非持仓股票。"

  $fallbackRoot = Join-Path $testDir "fallback_data"
  $fallbackSnapshotDir = Join-Path $fallbackRoot "snapshots\$tradeDate"
  New-Item -ItemType Directory -Force -Path $fallbackSnapshotDir | Out-Null
  $previousSnapshot | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $fallbackSnapshotDir "snapshot_000001.json") -Encoding UTF8
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner `
    -HoldingsPath $holdingsPath `
    -DataRoot $fallbackRoot `
    -QuoteDataPath (Join-Path $testDir "missing_quotes.json") `
    -NoPush | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "运行降级报告脚本失败，退出码 $LASTEXITCODE"
  }
  $fallbackReportFile = Get-ChildItem -LiteralPath (Join-Path $fallbackRoot "outbox") -Filter "*.md" |
    Where-Object { $_.Name -notlike "anomaly_alert_*" } |
    Select-Object -First 1
  Assert-True ($null -ne $fallbackReportFile) "主行情失败且存在快照时应生成降级报告。"
  $fallbackReport = Get-Content -LiteralPath $fallbackReportFile.FullName -Raw -Encoding UTF8
  Assert-True ($fallbackReport -match "【降级】") "降级报告应明确标注已回退到最近快照。"
  Assert-True ($fallbackReport -match "比亚迪") "降级报告应仍然包含快照中的持仓数据。"

  $sanitizedError = Get-UserFriendlyReportError 'Eastmoney request failed after 3 attempts: 基础连接已经关闭: 连接被意外关闭。; curl fallback: 传入的对象无效，应为“:”或“}”。 (190): {"rc":0,"data":{"diff":[{"f14":"姣斾簹杩?"}]}}'
  Assert-True ($sanitizedError -eq "连接被远端中断。；curl 兜底失败：返回内容解析失败。") "用户可见错误信息应去掉原始乱码载荷。"

  $dashQuotePath = Join-Path $testDir "dash_quotes.json"
  @"
{
  "data": {
    "diff": [
      { "f12": "002594", "f14": "比亚迪", "f2": 89.64, "f3": -1.30, "f62": "-", "f184": "-", "f66": "-", "f69": "-", "f72": "-", "f75": "-", "f78": "-", "f81": "-", "f84": "-", "f87": "-" },
      { "f12": "600021", "f14": "上海电力", "f2": 17.46, "f3": -0.46, "f62": -137829782, "f184": -11.43, "f66": -80000000, "f69": -6.50, "f72": -57829782, "f75": -4.93, "f78": 5000000, "f81": 0.40, "f84": "-", "f87": "-" },
      { "f12": "688126", "f14": "沪硅产业", "f2": 31.05, "f3": 0.54, "f62": 322785232, "f184": 5.04, "f66": 200000000, "f69": 3.10, "f72": 122785232, "f75": 1.94, "f78": "-", "f81": "-", "f84": -15000000, "f87": -0.23 }
    ]
  }
}
"@ | Set-Content -LiteralPath $dashQuotePath -Encoding UTF8
  $dashRoot = Join-Path $testDir "dash_data"
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner `
    -HoldingsPath $holdingsPath `
    -DataRoot $dashRoot `
    -QuoteDataPath $dashQuotePath `
    -NoPush | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "短横线行情数据不应导致固定报告脚本失败，退出码 $LASTEXITCODE"
  }
  $dashReportFile = Get-ChildItem -LiteralPath (Join-Path $dashRoot "outbox") -Filter "*.md" |
    Where-Object { $_.Name -notlike "anomaly_alert_*" } |
    Select-Object -First 1
  Assert-True ($null -ne $dashReportFile) "短横线行情数据场景仍应生成报告。"
  $dashReport = Get-Content -LiteralPath $dashReportFile.FullName -Raw -Encoding UTF8
  Assert-True ($dashReport -match "比亚迪") "短横线行情数据场景仍应保留对应股票。"

  $noSnapshotRoot = Join-Path $testDir "no_snapshot_data"
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner `
    -HoldingsPath $holdingsPath `
    -DataRoot $noSnapshotRoot `
    -QuoteDataPath (Join-Path $testDir "missing_quotes_again.json") `
    -NoPush | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "无快照且主行情失败时，脚本也应生成接口异常说明，退出码 $LASTEXITCODE"
  }
  $noSnapshotReportFile = Get-ChildItem -LiteralPath (Join-Path $noSnapshotRoot "outbox") -Filter "*.md" |
    Where-Object { $_.Name -notlike "anomaly_alert_*" } |
    Select-Object -First 1
  Assert-True ($null -ne $noSnapshotReportFile) "无快照且主行情失败时应生成接口异常说明。"
  $noSnapshotReport = Get-Content -LiteralPath $noSnapshotReportFile.FullName -Raw -Encoding UTF8
  Assert-True ($noSnapshotReport -match "【异常】本次未获取到有效行情，且没有可用快照回退") "无快照场景应明确说明本次是接口异常说明。"
  Assert-True ($noSnapshotReport -match "持仓范围合计主力净额：\*\*--\*\*") "无快照场景不应伪造主力净额。"

  $simulatedRoot = Join-Path $testDir "simulated_data"
  $simulatedSnapshotDir = Join-Path $simulatedRoot "snapshots\$tradeDate"
  New-Item -ItemType Directory -Force -Path $simulatedSnapshotDir | Out-Null
  $simulatedSnapshot = [pscustomobject]@{
    time = "$((Get-Date).ToString('yyyy-MM-dd')) 15:00:03"
    trade_date = $tradeDate
    total_count = 3
    valid_count = 3
    total_main_flow = -217198630
    rows = @(
      [pscustomobject]@{ code = "688126"; name = "沪硅产业"; price = 31.05; pct = 0.54; main_flow = 322785232; main_ratio = 5.04; super_flow = 200000000; super_ratio = 3.10; large_flow = 122785232; large_ratio = 1.94; medium_flow = -40000000; medium_ratio = -0.62; small_flow = -15000000; small_ratio = -0.23 },
      [pscustomobject]@{ code = "600021"; name = "上海电力"; price = 17.46; pct = -0.46; main_flow = -137829782; main_ratio = -11.43; super_flow = -80000000; super_ratio = -6.50; large_flow = -57829782; large_ratio = -4.93; medium_flow = 5000000; medium_ratio = 0.40; small_flow = -2000000; small_ratio = -0.15 },
      [pscustomobject]@{ code = "002594"; name = "比亚迪"; price = 89.64; pct = -1.30; main_flow = -562198848; main_ratio = -18.63; super_flow = -300000000; super_ratio = -10.00; large_flow = -262198848; large_ratio = -8.63; medium_flow = 150000000; medium_ratio = 5.00; small_flow = 120000000; small_ratio = 3.63 }
    )
  }
  $simulatedSnapshotPath = Join-Path $simulatedSnapshotDir "snapshot_150003.json"
  $simulatedSnapshot | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $simulatedSnapshotPath -Encoding UTF8

  $detailPath = Join-Path $testDir "detail.json"
  @"
[
  { "code": "688126", "f138": 350000000, "f139": 150000000, "f141": 222785232, "f142": 100000000 },
  { "code": "600021", "f138": 120000000, "f139": 200000000, "f141": 90000000, "f142": 147829782 },
  { "code": "002594", "f138": 180000000, "f139": 480000000, "f141": 120000000, "f142": 382198848 }
]
"@ | Set-Content -LiteralPath $detailPath -Encoding UTF8

  $simulatedRunner = Join-Path $scriptsRoot "Send-SimulatedClosePush.ps1"
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $simulatedRunner `
    -SnapshotPath $simulatedSnapshotPath `
    -HoldingsPath $holdingsPath `
    -DataRoot $simulatedRoot `
    -DetailDataPath $detailPath `
    -NoPush | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "运行模拟收盘补发脚本失败，退出码 $LASTEXITCODE"
  }
  $simulatedReportFile = Get-ChildItem -LiteralPath (Join-Path $simulatedRoot "outbox") -Filter "simulated_close_push_*.md" | Select-Object -First 1
  Assert-True ($null -ne $simulatedReportFile) "模拟收盘补发应生成一份报告。"
  $simulatedReport = Get-Content -LiteralPath $simulatedReportFile.FullName -Raw -Encoding UTF8
  Assert-True ($simulatedReport -match "已使用本地详情文件补充主力总流入/总流出|已使用东财实时详情补充主力总流入/总流出") "模拟收盘补发应标注详情来源。"
  Assert-True ($simulatedReport -match "主力总流入：\*\*<font color=""red"">5.73亿元</font>\*\*.*主力总流出：\*\*<font color=""green"">2.50亿元</font>\*\*") "模拟收盘补发应展示补齐后的真实主力总流入和主力总流出。"

  Write-Output "All holdings tests passed."
} finally {
  if (Test-Path -LiteralPath $testDir) {
    Remove-Item -LiteralPath $testDir -Recurse -Force
  }
}
