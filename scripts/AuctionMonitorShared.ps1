$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "HeldStockMonitorShared.ps1")

function Test-StStockName {
  param(
    [string]$Name = ""
  )

  $text = ([string]$Name).Trim().ToUpperInvariant()
  return ($text.StartsWith("ST") -or $text.StartsWith("*ST"))
}

function Get-AuctionDataRoot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$DataRoot,

    [Parameter(Mandatory = $true)]
    [ValidateSet("open", "close", "after_hours")]
    [string]$Session
  )

  if ($Session -eq "after_hours") {
    return (Join-Path $DataRoot "after_hours_fixed")
  }

  Join-Path $DataRoot ("auction_{0}" -f $Session)
}

function Get-AuctionSessionConfig {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("open", "close", "after_hours")]
    [string]$Session
  )

  if ($Session -eq "open") {
    return [pscustomobject]@{
      Session = "open"
      Name = "开盘集合竞价"
      Title = "A股集合竞价持仓监控"
      PriceLabel = "预计开盘价"
      ChangeSinceLabel = "09:20 后变化"
      Checkpoints = @("0915", "0920", "0923", "092430", "0925", "0926")
      FinalCheckpoint = "0926"
      CompareCheckpoint = "0920"
      TailCheckpoint = "092430"
      TailFinalCheckpoint = "0925"
    }
  }

  if ($Session -eq "after_hours") {
    return [pscustomobject]@{
      Session = "after_hours"
      Name = "盘后固定价格交易"
      Title = "A股持仓盘后固定价格交易监控"
      Checkpoints = @("1530", "1531")
      FinalCheckpoint = "1531"
      CompareCheckpoint = "1500"
      TailCheckpoint = "1530"
      TailFinalCheckpoint = "1530"
    }
  }

  [pscustomobject]@{
    Session = "close"
    Name = "收盘集合竞价"
    Title = "A股持仓收盘集合竞价监控"
    PriceLabel = "预计收盘价"
    ChangeSinceLabel = "14:57 后变化"
    Checkpoints = @("1457", "1459", "1500")
    FinalCheckpoint = "1500"
    CompareCheckpoint = "1457"
    TailCheckpoint = "1459"
    TailFinalCheckpoint = "1500"
  }
}

function Get-AuctionCheckpointDisplay {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Checkpoint
  )

  if ($Checkpoint.Length -eq 4) {
    return "{0}:{1}" -f $Checkpoint.Substring(0, 2), $Checkpoint.Substring(2, 2)
  }
  if ($Checkpoint.Length -eq 6) {
    return "{0}:{1}:{2}" -f $Checkpoint.Substring(0, 2), $Checkpoint.Substring(2, 2), $Checkpoint.Substring(4, 2)
  }
  return $Checkpoint
}

function New-AuctionContext {
  param(
    [Parameter(Mandatory = $true)]
    [string]$DataRoot,

    [Parameter(Mandatory = $true)]
    [ValidateSet("open", "close", "after_hours")]
    [string]$Session
  )

  $root = Get-AuctionDataRoot -DataRoot $DataRoot -Session $Session
  $logName = switch ($Session) {
    "open" { "auction_open.log" }
    "close" { "auction_close.log" }
    default { "after_hours_fixed.log" }
  }
  $context = New-MonitorContext -DataRoot $root -LogName $logName
  $dateDir = Join-Path $context.SnapshotRoot (Get-Date -Format "yyyyMMdd")
  New-Item -ItemType Directory -Force -Path $dateDir | Out-Null
  $pendingScope = switch ($Session) {
    "open" { "auction_open" }
    "close" { "auction_close" }
    default { "after_hours_fixed" }
  }
  $sharedPendingPushRoot = Get-SharedPendingPushRoot -DataRoot $DataRoot -Scope $pendingScope
  $auctionSettingsPath = Join-Path $DataRoot "auction_feishu.settings.yml"
  $cacheDir = Join-Path $root "cache"
  New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
  $dailyMetricsCachePath = Join-Path $cacheDir ("daily_metrics_{0}.json" -f (Get-Date -Format "yyyyMMdd"))

  [pscustomobject]@{
    Root = $root
    SharedDataRoot = $DataRoot
    DataRoot = $context.DataRoot
    Outbox = $context.Outbox
    SnapshotRoot = $context.SnapshotRoot
    SnapshotDateDir = $dateDir
    PendingPushRoot = $sharedPendingPushRoot
    AuctionSettingsPath = $auctionSettingsPath
    DailyMetricsCachePath = $dailyMetricsCachePath
    LogFile = $context.LogFile
    PauseFlag = $context.PauseFlag
  }
}

function ConvertTo-AuctionMetricMap {
  param(
    [AllowNull()]
    [object[]]$Items
  )

  $map = @{}
  foreach ($item in @($Items)) {
    if ($null -eq $item) { continue }
    $code = [string]$item.code
    if (-not $code) { continue }
    $map[$code] = [pscustomobject]@{
      code = $code
      prev_close = Get-SafeDoubleOrNull $item.prev_close
      yesterday_amount = Get-SafeDoubleOrNull $item.yesterday_amount
      avg5_amount = Get-SafeDoubleOrNull $item.avg5_amount
    }
  }
  return $map
}

function Read-AuctionDailyMetricsCache {
  param(
    [string]$Path = ""
  )

  if ((-not $Path) -or (-not (Test-Path -LiteralPath $Path))) {
    return @{}
  }

  try {
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    return ConvertTo-AuctionMetricMap -Items @($raw)
  } catch {
    return @{}
  }
}

function Save-AuctionDailyMetricsCache {
  param(
    [string]$Path = "",

    [hashtable]$MetricMap = @{}
  )

  if ((-not $Path) -or ($MetricMap.Count -eq 0)) {
    return
  }

  $parent = Split-Path -Parent $Path
  if ($parent) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }

  $items = @($MetricMap.GetEnumerator() |
    Sort-Object Name |
    ForEach-Object { $_.Value })
  $items | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Test-AuctionFinalReportExists {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Outbox,

    [Parameter(Mandatory = $true)]
    [ValidateSet("open", "close", "after_hours")]
    [string]$Session,

    [Parameter(Mandatory = $true)]
    [datetime]$CurrentTime
  )

  $prefix = switch ($Session) {
    "open" { "open_auction_report" }
    "close" { "close_auction_report" }
    default { "after_hours_fixed_report" }
  }
  $dateToken = $CurrentTime.ToString("yyyyMMdd")
  $existing = @(Get-ChildItem -LiteralPath $Outbox -Filter ("{0}_{1}_*.md" -f $prefix, $dateToken) -ErrorAction SilentlyContinue)
  return ($existing.Count -gt 0)
}

function Get-AuctionSnapshotFilePath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SnapshotDateDir,

    [Parameter(Mandatory = $true)]
    [ValidateSet("open", "close", "after_hours")]
    [string]$Session,

    [Parameter(Mandatory = $true)]
    [string]$Checkpoint
  )

  Join-Path $SnapshotDateDir ("snapshot_{0}_{1}.json" -f $Session, $Checkpoint)
}

function Get-AuctionSnapshotsForSession {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SnapshotDateDir,

    [Parameter(Mandatory = $true)]
    [ValidateSet("open", "close", "after_hours")]
    [string]$Session
  )

  @(Get-ChildItem -LiteralPath $SnapshotDateDir -Filter ("snapshot_{0}_*.json" -f $Session) -ErrorAction SilentlyContinue |
    Sort-Object Name |
    ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json })
}

function Get-AuctionLimitPct {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Code,

    [string]$Name = ""
  )

  if ($Code.StartsWith("8") -or $Code.StartsWith("4")) {
    return 0.30
  }
  if ($Code.StartsWith("300") -or $Code.StartsWith("688")) {
    return 0.20
  }

  if (Test-StStockName -Name $Name) {
    return 0.10
  }
  return 0.10
}

function Get-AuctionLimitPrice {
  param(
    [Parameter(Mandatory = $true)]
    [double]$PrevClose,

    [Parameter(Mandatory = $true)]
    [double]$LimitPct,

    [Parameter(Mandatory = $true)]
    [ValidateSet("up", "down")]
    [string]$Direction
  )

  $factor = if ($Direction -eq "up") { 1 + $LimitPct } else { 1 - $LimitPct }
  [Math]::Round(($PrevClose * $factor), 2, [MidpointRounding]::AwayFromZero)
}

function Get-AuctionDailyMetricsMap {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Holdings,

    [string]$DailyMetricsPath = "",

    [string]$CachePath = ""
  )

  if ($DailyMetricsPath) {
    $raw = Get-Content -LiteralPath $DailyMetricsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $map = ConvertTo-AuctionMetricMap -Items @($raw)
    Save-AuctionDailyMetricsCache -Path $CachePath -MetricMap $map
    return $map
  }

  $cachedMap = Read-AuctionDailyMetricsCache -Path $CachePath
  if (($cachedMap.Count -gt 0) -and ($cachedMap.Count -ge $Holdings.Count)) {
    return $cachedMap
  }

  $map = @{}
  $historyEndpointAvailable = $true
  foreach ($holding in $Holdings) {
    $code = [string]$holding.Code
    if ($cachedMap.ContainsKey($code)) {
      $map[$code] = $cachedMap[$code]
    }

    if (-not $historyEndpointAvailable) {
      continue
    }

    try {
      $uri = "https://push2his.eastmoney.com/api/qt/stock/kline/get?secid=$($holding.SecId)&fields1=f1,f2,f3,f4,f5,f6&fields2=f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61&klt=101&fqt=1&end=20500101&lmt=6"
      $response = Invoke-EastmoneyJson -Uri $uri -MaxAttempts 1 -RetryDelaySeconds 1
      $klines = @($response.data.klines)
      if ($klines.Count -lt 2) { continue }

      $parsed = @($klines | ForEach-Object {
        $parts = [string]$_ -split ","
        [pscustomobject]@{
          date = $parts[0]
          open = Get-SafeDouble $parts[1]
          close = Get-SafeDouble $parts[2]
          volume = Get-SafeDouble $parts[5]
          amount = Get-SafeDouble $parts[6]
        }
      })

      $yesterday = $parsed | Select-Object -Last 2 | Select-Object -First 1
      $recent = @($parsed | Select-Object -Last ([Math]::Min(5, $parsed.Count)))
      $avgAmount = if ($recent.Count -gt 0) {
        ($recent | Measure-Object -Property amount -Average).Average
      } else {
        $null
      }

      $map[$code] = [pscustomobject]@{
        code = $code
        prev_close = if ($yesterday) { $yesterday.close } else { $null }
        yesterday_amount = if ($yesterday) { $yesterday.amount } else { $null }
        avg5_amount = $avgAmount
      }
    } catch {
      $historyEndpointAvailable = $false
      if (-not $map.ContainsKey($code)) {
        continue
      }
    }
  }

  Save-AuctionDailyMetricsCache -Path $CachePath -MetricMap $map
  return $map
}

function Convert-AuctionQuotePayloadToRow {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Payload,

    [Parameter(Mandatory = $true)]
    [object]$Holding,

    [Parameter(Mandatory = $true)]
    [object]$DailyMetric,

    [Parameter(Mandatory = $true)]
    [datetime]$Timestamp
  )

  $code = [string]$Holding.Code
  $prevCloseMode = [string]$Holding.PrevCloseMode
  $prevClose = if ($prevCloseMode -eq "qfq") { $null } else { Get-SafeDoubleOrNull $Payload.f60 }
  if ($null -eq $prevClose) {
    $prevClose = Get-SafeDoubleOrNull $DailyMetric.prev_close
  }

  $auctionPrice = Get-SafeDoubleOrNull $Payload.f43
  $auctionPct = if (($null -ne $auctionPrice) -and ($null -ne $prevClose) -and ($prevClose -ne 0)) {
    (($auctionPrice - $prevClose) / $prevClose) * 100
  } else {
    $null
  }

  $limitPct = Get-AuctionLimitPct -Code $code -Name ([string]$Holding.Name)
  $limitUp = if ($null -ne $prevClose) { Get-AuctionLimitPrice -PrevClose $prevClose -LimitPct $limitPct -Direction "up" } else { $null }
  $limitDown = if ($null -ne $prevClose) { Get-AuctionLimitPrice -PrevClose $prevClose -LimitPct $limitPct -Direction "down" } else { $null }
  $distUpPct = if (($null -ne $auctionPrice) -and ($null -ne $limitUp) -and ($limitUp -ne 0)) { (($limitUp - $auctionPrice) / $limitUp) * 100 } else { $null }
  $distDownPct = if (($null -ne $auctionPrice) -and ($null -ne $limitDown) -and ($limitDown -ne 0)) { (($auctionPrice - $limitDown) / $limitDown) * 100 } else { $null }

  $auctionAmount = Get-SafeDoubleOrNull $Payload.f48
  $yesterdayAmount = Get-SafeDoubleOrNull $DailyMetric.yesterday_amount
  $avg5Amount = Get-SafeDoubleOrNull $DailyMetric.avg5_amount
  $referenceAmount = if (($null -ne $avg5Amount) -and ($avg5Amount -gt 0)) { $avg5Amount } else { $yesterdayAmount }
  $referenceLabel = if (($null -ne $avg5Amount) -and ($avg5Amount -gt 0)) { "近5日平均成交额" } elseif (($null -ne $yesterdayAmount) -and ($yesterdayAmount -gt 0)) { "昨日成交额" } else { "" }
  $auctionAmountRatio = if (($null -ne $auctionAmount) -and ($null -ne $referenceAmount) -and ($referenceAmount -gt 0)) {
    ($auctionAmount / $referenceAmount) * 100
  } else {
    $null
  }

  [pscustomobject]@{
    code = $code
    name = [string]$Holding.Name
    focus_level = [string]$Holding.FocusLevel
    prev_close_mode = $prevCloseMode
    prev_close = $prevClose
    auction_price = $auctionPrice
    auction_pct = $auctionPct
    auction_volume = Get-SafeDoubleOrNull $Payload.f47
    auction_amount = $auctionAmount
    buy1_price = Get-SafeDoubleOrNull $Payload.f31
    buy1_volume = Get-SafeDoubleOrNull $Payload.f32
    sell1_price = Get-SafeDoubleOrNull $Payload.f33
    sell1_volume = Get-SafeDoubleOrNull $Payload.f34
    wei_ratio = Get-SafeDoubleOrNull $Payload.f192
    liang_ratio = Get-SafeDoubleOrNull $Payload.f50
    is_limit_up = (($null -ne $auctionPrice) -and ($null -ne $limitUp) -and ($auctionPrice -ge $limitUp))
    is_limit_down = (($null -ne $auctionPrice) -and ($null -ne $limitDown) -and ($auctionPrice -le $limitDown))
    distance_to_limit_up_pct = $distUpPct
    distance_to_limit_down_pct = $distDownPct
    limit_up_price = $limitUp
    limit_down_price = $limitDown
    timestamp = $Timestamp.ToString("yyyy-MM-dd HH:mm:ss")
    yesterday_amount = $yesterdayAmount
    avg5_amount = $avg5Amount
    reference_amount_ratio_pct = $auctionAmountRatio
    reference_amount_label = $referenceLabel
    status = if ($null -eq $auctionPrice) { "data_missing" } else { "ok" }
  }
}

function Get-AuctionQuoteRows {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Holdings,

    [datetime]$Timestamp = (Get-Date),

    [string]$QuoteDataPath = "",

    [string]$DailyMetricsPath = "",

    [string]$CachePath = ""
  )

  $dailyMap = Get-AuctionDailyMetricsMap -Holdings $Holdings -DailyMetricsPath $DailyMetricsPath -CachePath $CachePath
  $rawMap = @{}

  if ($QuoteDataPath) {
    $raw = Get-Content -LiteralPath $QuoteDataPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($item in @($raw)) {
      $rawMap[[string]$item.code] = $item
    }
  } else {
    $fields = "f31,f32,f33,f34,f43,f47,f48,f50,f51,f52,f57,f58,f60,f192"
    foreach ($holding in $Holdings) {
      $uri = "https://push2.eastmoney.com/api/qt/stock/get?fltt=2&invt=2&secid=$($holding.SecId)&fields=$fields"
      try {
        $response = Invoke-EastmoneyJson -Uri $uri
        $rawMap[[string]$holding.Code] = if ($response.data) { $response.data } else { [pscustomobject]@{} }
      } catch {
        $rawMap[[string]$holding.Code] = [pscustomobject]@{}
      }
    }
  }

  $rows = foreach ($holding in $Holdings) {
    $code = [string]$holding.Code
    if (-not $rawMap.ContainsKey($code)) { continue }
    $dailyMetric = if ($dailyMap.ContainsKey($code)) { $dailyMap[$code] } else { [pscustomobject]@{} }
    Convert-AuctionQuotePayloadToRow -Payload $rawMap[$code] -Holding $holding -DailyMetric $dailyMetric -Timestamp $Timestamp
  }

  @($rows)
}

function Get-AuctionTrendMap {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Holdings,

    [string]$TrendDataPath = ""
  )

  $map = @{}
  if ($TrendDataPath) {
    $raw = Get-Content -LiteralPath $TrendDataPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($item in @($raw)) {
      $map[[string]$item.code] = @($item.bars)
    }
    return $map
  }

  foreach ($holding in $Holdings) {
    try {
      $uri = "https://push2his.eastmoney.com/api/qt/stock/trends2/get?secid=$($holding.SecId)&fields1=f1,f2,f3,f4,f5,f6&fields2=f51,f52,f53,f54,f55,f56,f57,f58&iscr=0&ndays=1"
      $response = Invoke-EastmoneyJson -Uri $uri -MaxAttempts 1 -RetryDelaySeconds 1
      $bars = @()
      foreach ($line in @($response.data.trends)) {
        $parts = [string]$line -split ","
        if ($parts.Count -lt 7) { continue }
        $bars += [pscustomobject]@{
          time = ([datetime]$parts[0]).ToString("HH:mm")
          open = Get-SafeDoubleOrNull $parts[1]
          close = Get-SafeDoubleOrNull $parts[2]
          high = Get-SafeDoubleOrNull $parts[3]
          low = Get-SafeDoubleOrNull $parts[4]
          volume = Get-SafeDoubleOrNull $parts[5]
          amount = Get-SafeDoubleOrNull $parts[6]
          avg_price = if ($parts.Count -ge 8) { Get-SafeDoubleOrNull $parts[7] } else { $null }
        }
      }
      $map[[string]$holding.Code] = @($bars)
    } catch {
      $map[[string]$holding.Code] = @()
    }
  }

  return $map
}

function Get-ApproxAuctionVwap {
  param(
    [AllowNull()]$Amount,
    [AllowNull()]$Volume,
    [AllowNull()]$ReferencePrice
  )

  $amountValue = Get-SafeDoubleOrNull $Amount
  $volumeValue = Get-SafeDoubleOrNull $Volume
  $referenceValue = Get-SafeDoubleOrNull $ReferencePrice
  if (($null -eq $amountValue) -or ($null -eq $volumeValue) -or ($volumeValue -le 0)) {
    return $null
  }

  $vwap = $amountValue / $volumeValue
  if (($null -ne $referenceValue) -and ($referenceValue -gt 0) -and ($vwap -gt ($referenceValue * 20))) {
    $vwap = $amountValue / ($volumeValue * 100.0)
  }

  if (($null -ne $referenceValue) -and ($referenceValue -gt 0) -and ($vwap -gt ($referenceValue * 20))) {
    return $null
  }

  return $vwap
}

function Get-AuctionBarsInWindow {
  param(
    [object[]]$Bars,
    [string]$StartTime,
    [string]$EndTime
  )

  @($Bars | Where-Object {
    ([string]$_.time -ge $StartTime) -and ([string]$_.time -le $EndTime)
  })
}

function Get-AuctionCloseTrendMetrics {
  param(
    [object[]]$Bars,
    [AllowNull()]$ClosePrice
  )

  $regularBars = @(Get-AuctionBarsInWindow -Bars $Bars -StartTime "09:30" -EndTime "15:00")
  if ($regularBars.Count -eq 0) {
    return [pscustomobject]@{
      vwap = $null
      day_high = $null
      day_low = $null
      regular_amount = $null
    }
  }

  $dayHigh = ($regularBars | Measure-Object -Property high -Maximum).Maximum
  $dayLow = ($regularBars | Measure-Object -Property low -Minimum).Minimum
  $lastWithAvg = @($regularBars | Where-Object { $null -ne $_.avg_price } | Select-Object -Last 1)
  $vwap = if ($lastWithAvg.Count -gt 0) {
    Get-SafeDoubleOrNull $lastWithAvg[0].avg_price
  } else {
    $amountSum = ($regularBars | Measure-Object -Property amount -Sum).Sum
    $volumeSum = ($regularBars | Measure-Object -Property volume -Sum).Sum
    Get-ApproxAuctionVwap -Amount $amountSum -Volume $volumeSum -ReferencePrice $ClosePrice
  }
  $regularAmount = ($regularBars | Measure-Object -Property amount -Sum).Sum

  [pscustomobject]@{
    vwap = Get-SafeDoubleOrNull $vwap
    day_high = Get-SafeDoubleOrNull $dayHigh
    day_low = Get-SafeDoubleOrNull $dayLow
    regular_amount = Get-SafeDoubleOrNull $regularAmount
  }
}

function Get-AuctionAfterHoursMetrics {
  param(
    [object[]]$Bars
  )

  $afterHoursBars = @(Get-AuctionBarsInWindow -Bars $Bars -StartTime "15:05" -EndTime "15:30")
  if ($afterHoursBars.Count -eq 0) {
    return [pscustomobject]@{
      supported = $false
      volume = $null
      amount = $null
    }
  }

  [pscustomobject]@{
    supported = $true
    volume = Get-SafeDoubleOrNull (($afterHoursBars | Measure-Object -Property volume -Sum).Sum)
    amount = Get-SafeDoubleOrNull (($afterHoursBars | Measure-Object -Property amount -Sum).Sum)
  }
}

function Get-AfterHoursDataMap {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Holdings,

    [string]$AfterHoursDataPath = "",

    [string]$TrendDataPath = ""
  )

  $map = @{}
  if ($AfterHoursDataPath) {
    $raw = Get-Content -LiteralPath $AfterHoursDataPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($item in @($raw)) {
      $code = [string]$item.code
      if (-not $code) { continue }
      $dataStatus = if ($item.PSObject.Properties.Name -contains "data_status") { [string]$item.data_status } else { "" }
      $supported = $true
      if ($item.PSObject.Properties.Name -contains "supported") {
        $supported = [bool]$item.supported
      } elseif ($dataStatus -eq "missing_after_hours_fields") {
        $supported = $false
      }
      $volume = if ($item.PSObject.Properties.Name -contains "after_hours_volume") { $item.after_hours_volume } else { $item.volume }
      $amount = if ($item.PSObject.Properties.Name -contains "after_hours_amount") { $item.after_hours_amount } else { $item.amount }
      $map[$code] = [pscustomobject]@{
        source = if ($item.PSObject.Properties.Name -contains "source" -and $item.source) { [string]$item.source } else { "external_after_hours_file" }
        supported = $supported
        volume = Get-SafeDoubleOrNull $volume
        amount = Get-SafeDoubleOrNull $amount
      }
    }
    return $map
  }

  $trendMap = Get-AuctionTrendMap -Holdings $Holdings -TrendDataPath $TrendDataPath
  foreach ($holding in $Holdings) {
    $code = [string]$holding.Code
    $bars = if ($trendMap.ContainsKey($code)) { @($trendMap[$code]) } else { @() }
    $metrics = Get-AuctionAfterHoursMetrics -Bars $bars
    $map[$code] = [pscustomobject]@{
      source = "eastmoney_trends2"
      supported = [bool]$metrics.supported
      volume = Get-SafeDoubleOrNull $metrics.volume
      amount = Get-SafeDoubleOrNull $metrics.amount
    }
  }
  return $map
}

function Save-AuctionSnapshot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SnapshotPath,

    [Parameter(Mandatory = $true)]
    [ValidateSet("open", "close")]
    [string]$Session,

    [Parameter(Mandatory = $true)]
    [string]$Checkpoint,

    [Parameter(Mandatory = $true)]
    [object[]]$Rows,

    [ValidateSet("scheduled", "catchup")]
    [string]$CaptureMode = "scheduled"
  )

  $snapshot = [pscustomobject]@{
    session = $Session
    checkpoint = $Checkpoint
    checkpoint_display = Get-AuctionCheckpointDisplay -Checkpoint $Checkpoint
    time = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    capture_mode = $CaptureMode
    rows = $Rows
  }
  $snapshot | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $SnapshotPath -Encoding UTF8
  return $snapshot
}

function Get-AuctionCheckpointDateTime {
  param(
    [Parameter(Mandatory = $true)]
    [datetime]$TradeDate,

    [Parameter(Mandatory = $true)]
    [string]$Checkpoint
  )

  $display = Get-AuctionCheckpointDisplay -Checkpoint $Checkpoint
  $format = if ($display.Length -eq 5) { "yyyy-MM-dd HH:mm" } else { "yyyy-MM-dd HH:mm:ss" }
  [datetime]::ParseExact(
    ("{0} {1}" -f $TradeDate.ToString("yyyy-MM-dd"), $display),
    $format,
    [System.Globalization.CultureInfo]::InvariantCulture
  )
}

function Get-AuctionPushNotBeforeTime {
  param(
    [Parameter(Mandatory = $true)]
    [object]$SessionConfig,

    [Parameter(Mandatory = $true)]
    [datetime]$TradeDate
  )

  if ([string]$SessionConfig.Session -eq "close") {
    return [datetime]::ParseExact(
      ("{0} 15:01:00" -f $TradeDate.ToString("yyyy-MM-dd")),
      "yyyy-MM-dd HH:mm:ss",
      [System.Globalization.CultureInfo]::InvariantCulture
    )
  }

  return Get-AuctionCheckpointDateTime -TradeDate $TradeDate -Checkpoint $SessionConfig.FinalCheckpoint
}

function Get-AuctionEligibleCheckpoints {
  param(
    [Parameter(Mandatory = $true)]
    [object]$SessionConfig,

    [Parameter(Mandatory = $true)]
    [datetime]$CurrentTime
  )

  $eligible = New-Object System.Collections.Generic.List[string]
  foreach ($checkpoint in @($SessionConfig.Checkpoints)) {
    $checkpointTime = Get-AuctionCheckpointDateTime -TradeDate $CurrentTime.Date -Checkpoint $checkpoint
    if ($CurrentTime -ge $checkpointTime) {
      $eligible.Add($checkpoint)
    }
  }
  return @($eligible)
}

function Get-AuctionMissingCheckpoints {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SnapshotDateDir,

    [Parameter(Mandatory = $true)]
    [object]$SessionConfig,

    [Parameter(Mandatory = $true)]
    [datetime]$CurrentTime
  )

  $snapshots = @(Get-AuctionSnapshotsForSession -SnapshotDateDir $SnapshotDateDir -Session $SessionConfig.Session)
  $existing = @{}
  foreach ($snapshot in $snapshots) {
    $existing[[string]$snapshot.checkpoint] = $true
  }

  $missing = New-Object System.Collections.Generic.List[string]
  foreach ($checkpoint in @(Get-AuctionEligibleCheckpoints -SessionConfig $SessionConfig -CurrentTime $CurrentTime)) {
    if (-not $existing.ContainsKey($checkpoint)) {
      $missing.Add($checkpoint)
    }
  }
  return @($missing)
}

function Find-AuctionRow {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Snapshots,

    [Parameter(Mandatory = $true)]
    [string]$Checkpoint,

    [Parameter(Mandatory = $true)]
    [string]$Code
  )

  $snapshot = @($Snapshots | Where-Object { [string]$_.checkpoint -eq $Checkpoint } | Select-Object -Last 1)
  if (-not $snapshot) { return $null }
  @($snapshot[0].rows | Where-Object { [string]$_.code -eq $Code } | Select-Object -First 1)[0]
}

function Get-AuctionStateTags {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Row,

    [Parameter(Mandatory = $true)]
    [object[]]$Snapshots,

    [Parameter(Mandatory = $true)]
    [object]$SessionConfig
  )

  $tags = New-Object System.Collections.Generic.List[string]
  if ([string]$Row.status -eq "data_missing" -or (($null -eq $Row.auction_price) -and ($null -eq $Row.prev_close))) {
    return @("data_missing")
  }
  if ([string]$SessionConfig.Session -eq "close") {
    $compareRow = Find-AuctionRow -Snapshots $Snapshots -Checkpoint $SessionConfig.CompareCheckpoint -Code $Row.code
    $closePrice = Get-SafeDoubleOrNull $Row.auction_price
    $startPrice = if ($null -ne $compareRow) { Get-SafeDoubleOrNull $compareRow.auction_price } else { $null }
    $deltaPct = if (($null -ne $closePrice) -and ($null -ne $startPrice) -and ($startPrice -ne 0)) {
      (($closePrice - $startPrice) / $startPrice) * 100
    } else {
      $null
    }

    if ($Row.is_limit_up) {
      $tags.Add("close_limit_up")
    } elseif (($null -ne $Row.distance_to_limit_up_pct) -and ($Row.distance_to_limit_up_pct -le 1)) {
      $tags.Add("near_limit_up")
    }

    if ($Row.is_limit_down) {
      $tags.Add("close_limit_down")
    } elseif (($null -ne $Row.distance_to_limit_down_pct) -and ($Row.distance_to_limit_down_pct -le 1)) {
      $tags.Add("near_limit_down")
    }

    if (($null -ne $deltaPct) -and ($deltaPct -ge 0.5)) {
      $tags.Add("late_rush_close")
    } elseif (($null -ne $deltaPct) -and ($deltaPct -le -0.5)) {
      $tags.Add("late_drop_close")
    }

    $nearHigh = [bool]$Row.close_near_day_high
    $nearLow = [bool]$Row.close_near_day_low
    $closeVsVwap = [string]$Row.close_vs_vwap_position
    if ($nearHigh -or ($closeVsVwap -eq "above")) {
      $tags.Add("strong_close")
    } elseif ($nearLow -or ($closeVsVwap -eq "below")) {
      $tags.Add("weak_close")
    }

    if ($tags.Count -eq 0) {
      $tags.Add("stable_close")
    }

    return @($tags)
  }

  $pct = Get-SafeDoubleOrNull $Row.auction_pct
  if ($null -ne $pct) {
    if ($pct -ge 8) { $tags.Add("extreme_gap_up") }
    elseif ($pct -ge 5) { $tags.Add("clear_gap_up") }
    elseif ($pct -ge 3) { $tags.Add("strong_gap_up") }
    elseif ($pct -gt 0.5) { $tags.Add("gap_up") }
    elseif ($pct -le -8) { $tags.Add("extreme_gap_down") }
    elseif ($pct -le -5) { $tags.Add("clear_gap_down") }
    elseif ($pct -le -3) { $tags.Add("weak_gap_down") }
    elseif ($pct -lt -0.5) { $tags.Add("gap_down") }
  }

  $ratio = Get-SafeDoubleOrNull $Row.reference_amount_ratio_pct
  if ($null -ne $ratio) {
    if ($ratio -ge 5) { $tags.Add("extreme_volume") }
    elseif ($ratio -ge 3) { $tags.Add("clear_volume") }
    elseif ($ratio -ge 1) { $tags.Add("light_volume") }
  }

  if ($Row.is_limit_up) {
    $tags.Add("auction_limit_up")
  } elseif (($null -ne $Row.distance_to_limit_up_pct) -and ($Row.distance_to_limit_up_pct -le 1)) {
    $tags.Add("near_limit_up")
  }

  if ($Row.is_limit_down) {
    $tags.Add("auction_limit_down")
  } elseif (($null -ne $Row.distance_to_limit_down_pct) -and ($Row.distance_to_limit_down_pct -le 1)) {
    $tags.Add("near_limit_down")
  }

  $compareRow = Find-AuctionRow -Snapshots $Snapshots -Checkpoint $SessionConfig.CompareCheckpoint -Code $Row.code
  if ($null -ne $compareRow) {
    $priceDeltaPct = $null
    if (($null -ne $Row.auction_price) -and ($null -ne $compareRow.auction_price) -and ($compareRow.auction_price -ne 0)) {
      $priceDeltaPct = (($Row.auction_price - $compareRow.auction_price) / $compareRow.auction_price) * 100
    }

    if (($null -ne $priceDeltaPct) -and ($priceDeltaPct -ge 0.5)) {
      $tags.Add("auction_strengthening")
    } elseif (($null -ne $priceDeltaPct) -and ($priceDeltaPct -le -0.5)) {
      $tags.Add("auction_weakening")
    }

    if (($null -ne $Row.auction_amount) -and ($null -ne $compareRow.auction_amount) -and ($Row.auction_amount -gt $compareRow.auction_amount * 1.1)) {
      $tags.Add("support_strengthening")
    }
  }

  $tailRow = Find-AuctionRow -Snapshots $Snapshots -Checkpoint $SessionConfig.TailCheckpoint -Code $Row.code
  $tailFinalRow = Find-AuctionRow -Snapshots $Snapshots -Checkpoint $SessionConfig.TailFinalCheckpoint -Code $Row.code
  if (($null -ne $tailRow) -and ($null -ne $tailFinalRow) -and ($null -ne $tailRow.auction_price) -and ($tailRow.auction_price -ne 0) -and ($null -ne $tailFinalRow.auction_price)) {
    $tailPct = (($tailFinalRow.auction_price - $tailRow.auction_price) / $tailRow.auction_price) * 100
    if ($tailPct -ge 1) {
      $tags.Add($(if ($SessionConfig.Session -eq "open") { "late_rush_open" } else { "late_rush_close" }))
    } elseif ($tailPct -le -1) {
      $tags.Add($(if ($SessionConfig.Session -eq "open") { "late_drop_open" } else { "late_drop_close" }))
    }
  }

  if ($tags.Count -eq 0) {
    $tags.Add("normal")
  }

  return @($tags)
}

function Get-AuctionStrengthScore {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Row,

    [Parameter(Mandatory = $true)]
    [string[]]$Tags
  )

  if (($Tags -contains "late_rush_close") -or ($Tags -contains "strong_close") -or ($Tags -contains "late_drop_close") -or ($Tags -contains "weak_close") -or ($Tags -contains "stable_close")) {
    $score = 50
    if ($Tags -contains "late_rush_close") { $score += 20 }
    if ($Tags -contains "strong_close") { $score += 15 }
    if ($Tags -contains "late_drop_close") { $score -= 20 }
    if ($Tags -contains "weak_close") { $score -= 15 }
    if ($Tags -contains "close_limit_up") { $score += 20 }
    if ($Tags -contains "near_limit_up") { $score += 10 }
    if ($Tags -contains "close_limit_down") { $score -= 20 }
    if ($Tags -contains "near_limit_down") { $score -= 10 }
    return [Math]::Max(0, [Math]::Min(100, [Math]::Round($score, 0)))
  }

  if ($Tags -contains "data_missing") {
    return 0
  }

  $score = 50
  $pct = Get-SafeDoubleOrNull $Row.auction_pct
  if ($null -ne $pct) {
    if ($pct -ge 8) { $score += 25 }
    elseif ($pct -ge 5) { $score += 18 }
    elseif ($pct -ge 3) { $score += 12 }
    elseif ($pct -gt 0) { $score += 5 }
    elseif ($pct -le -8) { $score -= 25 }
    elseif ($pct -le -5) { $score -= 18 }
    elseif ($pct -le -3) { $score -= 12 }
    elseif ($pct -lt 0) { $score -= 5 }
  }

  $ratio = Get-SafeDoubleOrNull $Row.reference_amount_ratio_pct
  if ($null -ne $ratio) {
    if ($ratio -ge 5) { $score += 20 }
    elseif ($ratio -ge 3) { $score += 12 }
    elseif ($ratio -ge 1) { $score += 5 }
  }

  if ($Tags -contains "auction_limit_up") { $score += 20 }
  elseif ($Tags -contains "near_limit_up") { $score += 10 }
  if ($Tags -contains "auction_limit_down") { $score -= 20 }
  elseif ($Tags -contains "near_limit_down") { $score -= 10 }
  if (($Tags -contains "auction_strengthening") -or ($Tags -contains "support_strengthening")) { $score += 8 }
  if ($Tags -contains "auction_weakening") { $score -= 8 }
  if (($Tags -contains "late_rush_open") -or ($Tags -contains "late_rush_close")) { $score += 12 }
  if (($Tags -contains "late_drop_open") -or ($Tags -contains "late_drop_close")) { $score -= 12 }

  return [Math]::Max(0, [Math]::Min(100, [Math]::Round($score, 0)))
}

function Get-AuctionObservationText {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Tags
  )

  if ($Tags -contains "late_rush_close") {
    return "收盘集合竞价阶段出现抢筹，说明尾盘资金承接偏强，可继续观察次日开盘承接。"
  }
  if ($Tags -contains "late_drop_close") {
    return "收盘集合竞价阶段出现砸盘，说明尾盘抛压偏重，需留意次日是否继续走弱。"
  }
  if ($Tags -contains "strong_close") {
    return "收盘价靠近日内强势区域，尾盘表现偏强，可继续观察次日是否延续。"
  }
  if ($Tags -contains "weak_close") {
    return "收盘价落在日内偏弱区域，尾盘资金承接一般，需留意次日是否继续承压。"
  }
  if ($Tags -contains "stable_close") {
    return "尾盘集合竞价整体平稳，暂未观察到明显抢筹或砸盘。"
  }
  if ($Tags -contains "data_missing") {
    return "竞价关键字段未完整返回，建议稍后人工复核。"
  }
  if ($Tags -contains "auction_limit_up") {
    return "竞价直接封板，重点观察开盘后封单稳定性和是否出现炸板。"
  }
  if ($Tags -contains "near_limit_up") {
    return "已经逼近涨停，重点看开盘后能否顺势上板。"
  }
  if (($Tags -contains "volume_gap_up") -or (($Tags -contains "strong_gap_up") -and ($Tags -contains "clear_volume")) -or (($Tags -contains "strong_gap_up") -and ($Tags -contains "extreme_volume"))) {
    return "高开放量，优先观察开盘后承接是否持续。"
  }
  if (($Tags -contains "strong_gap_up") -or ($Tags -contains "extreme_gap_up")) {
    return "竞价偏强，留意开盘后是否继续上攻。"
  }
  if (($Tags -contains "late_rush_open") -or ($Tags -contains "late_rush_close")) {
    return "尾段资金明显抢筹，留意开盘后是否继续放量上冲。"
  }
  if (($Tags -contains "auction_weakening") -or ($Tags -contains "late_drop_open") -or ($Tags -contains "late_drop_close")) {
    return "临近结束明显转弱，注意开盘后是否继续回落。"
  }
  if ($Tags -contains "auction_limit_down") {
    return "竞价跌停偏弱，先观察开盘后是否有资金撬板。"
  }
  if ($Tags -contains "near_limit_down") {
    return "已经接近跌停，注意开盘后是否继续被按压。"
  }
  if (($Tags -contains "auction_limit_down") -or ($Tags -contains "near_limit_down") -or ($Tags -contains "extreme_gap_down") -or ($Tags -contains "weak_gap_down")) {
    return "低开偏弱，注意是否存在利空或资金持续流出。"
  }
  if (($Tags -contains "clear_volume") -or ($Tags -contains "extreme_volume")) {
    return "量能放大但方向还不够明确，先看开盘后的资金选择。"
  }
  return "竞价整体平稳，暂时没有明显异常。"
}

function Get-AuctionPriorityOrder {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Tags
  )

  $priorityMap = @(
    "close_limit_up",
    "auction_limit_up",
    "near_limit_up",
    "late_rush_close",
    "strong_close",
    "volume_gap_up",
    "extreme_gap_up",
    "clear_gap_up",
    "strong_gap_up",
    "late_rush_open",
    "late_rush_close",
    "extreme_volume",
    "clear_volume",
    "extreme_gap_down",
    "near_limit_down",
    "close_limit_down",
    "auction_limit_down",
    "weak_close",
    "stable_close",
    "auction_weakening",
    "late_drop_open",
    "late_drop_close",
    "weak_gap_down",
    "clear_gap_down"
  )

  for ($i = 0; $i -lt $priorityMap.Count; $i++) {
    if ($Tags -contains $priorityMap[$i]) {
      return $i
    }
  }
  return 999
}

function ConvertTo-AuctionAssessment {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Row,

    [Parameter(Mandatory = $true)]
    [object[]]$Snapshots,

    [Parameter(Mandatory = $true)]
    [object]$SessionConfig,

    [object[]]$TrendBars = @()
  )

  if ([string]$SessionConfig.Session -eq "close") {
    $compareRow = Find-AuctionRow -Snapshots $Snapshots -Checkpoint $SessionConfig.CompareCheckpoint -Code $Row.code
    $startPrice = if ($null -ne $compareRow) { Get-SafeDoubleOrNull $compareRow.auction_price } else { $null }
    $closePrice = Get-SafeDoubleOrNull $Row.auction_price
    $closingAuctionPct = if (($null -ne $startPrice) -and ($null -ne $closePrice) -and ($startPrice -ne 0)) {
      (($closePrice - $startPrice) / $startPrice) * 100
    } else {
      $null
    }
    $regularAmount = Get-SafeDoubleOrNull $Row.auction_amount
    $startAmount = if ($null -ne $compareRow) { Get-SafeDoubleOrNull $compareRow.auction_amount } else { $null }
    $closingAuctionAmount = if (($null -ne $regularAmount) -and ($null -ne $startAmount)) {
      [Math]::Max(0, ($regularAmount - $startAmount))
    } else {
      $null
    }
    $closingAuctionAmountRatioPct = if (($null -ne $closingAuctionAmount) -and ($null -ne $regularAmount) -and ($regularAmount -gt 0)) {
      ($closingAuctionAmount / $regularAmount) * 100
    } else {
      $null
    }
    $trendMetrics = Get-AuctionCloseTrendMetrics -Bars $TrendBars -ClosePrice $closePrice
    $dayHigh = Get-SafeDoubleOrNull $trendMetrics.day_high
    $dayLow = Get-SafeDoubleOrNull $trendMetrics.day_low
    $vwap = Get-SafeDoubleOrNull $trendMetrics.vwap
    $closeVsVwapPosition = if (($null -ne $closePrice) -and ($null -ne $vwap)) {
      if ($closePrice -gt $vwap) { "above" } elseif ($closePrice -lt $vwap) { "below" } else { "at" }
    } else {
      "unknown"
    }
    $closeNearHigh = (($null -ne $closePrice) -and ($null -ne $dayHigh) -and ($dayHigh -gt 0) -and ($closePrice -ge ($dayHigh * 0.99)))
    $closeNearLow = (($null -ne $closePrice) -and ($null -ne $dayLow) -and ($dayLow -gt 0) -and ($closePrice -le ($dayLow * 1.01)))

    $closeRow = [pscustomobject]@{}
    foreach ($property in $Row.PSObject.Properties) {
      $closeRow | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
    }
    $closeRow | Add-Member -NotePropertyName close_1457_price -NotePropertyValue $startPrice -Force
    $closeRow | Add-Member -NotePropertyName close_1500_price -NotePropertyValue $closePrice -Force
    $closeRow | Add-Member -NotePropertyName closing_auction_pct -NotePropertyValue $closingAuctionPct -Force
    $closeRow | Add-Member -NotePropertyName regular_session_amount -NotePropertyValue $regularAmount -Force
    $closeRow | Add-Member -NotePropertyName closing_auction_amount -NotePropertyValue $closingAuctionAmount -Force
    $closeRow | Add-Member -NotePropertyName closing_auction_amount_ratio_pct -NotePropertyValue $closingAuctionAmountRatioPct -Force
    $closeRow | Add-Member -NotePropertyName day_vwap -NotePropertyValue $vwap -Force
    $closeRow | Add-Member -NotePropertyName close_vs_vwap_position -NotePropertyValue $closeVsVwapPosition -Force
    $closeRow | Add-Member -NotePropertyName close_near_day_high -NotePropertyValue $closeNearHigh -Force
    $closeRow | Add-Member -NotePropertyName close_near_day_low -NotePropertyValue $closeNearLow -Force
    $closeRow | Add-Member -NotePropertyName day_high -NotePropertyValue $dayHigh -Force
    $closeRow | Add-Member -NotePropertyName day_low -NotePropertyValue $dayLow -Force

    $tags = New-Object System.Collections.Generic.List[string]
    foreach ($tag in @(Get-AuctionStateTags -Row $closeRow -Snapshots $Snapshots -SessionConfig $SessionConfig)) {
      $tags.Add($tag)
    }
    $score = Get-AuctionStrengthScore -Row $closeRow -Tags @($tags)
    $priorityOrder = Get-AuctionPriorityOrder -Tags @($tags)
    $focusBoost = if ([string]$Row.focus_level -eq "high") { 0.5 } else { 0 }

    return [pscustomobject]@{
      code = $Row.code
      name = $Row.name
      focus_level = $Row.focus_level
      prev_close_mode = $Row.prev_close_mode
      auction_price = $closePrice
      auction_pct = $closingAuctionPct
      auction_amount = $closingAuctionAmount
      auction_amount_ratio_pct = $closingAuctionAmountRatioPct
      auction_amount_ratio_label = "常规交易成交额"
      change_text = if ($null -eq $startPrice) { "缺少 14:57 价格" } elseif ($null -eq $closingAuctionPct) { "缺少可比价格" } elseif ($closingAuctionPct -ge 0.5) { "价格增强" } elseif ($closingAuctionPct -le -0.5) { "价格转弱" } else { "价格基本持平" }
      score = $score
      tags = @($tags)
      observation = Get-AuctionObservationText -Tags @($tags)
      priority_order = $priorityOrder
      reminder_priority = ($priorityOrder - $focusBoost)
      row = $closeRow
    }
  }

  $tags = New-Object System.Collections.Generic.List[string]
  foreach ($tag in @(Get-AuctionStateTags -Row $Row -Snapshots $Snapshots -SessionConfig $SessionConfig)) {
    $tags.Add($tag)
  }
  if (($tags -contains "gap_up") -and (($tags -contains "clear_volume") -or ($tags -contains "extreme_volume"))) {
    $tags.Add("volume_gap_up")
  }

  $score = Get-AuctionStrengthScore -Row $Row -Tags @($tags)
  $changeSource = Find-AuctionRow -Snapshots $Snapshots -Checkpoint $SessionConfig.CompareCheckpoint -Code $Row.code
  $changeText = if ($null -eq $changeSource) {
    "缺少早段对比快照"
  } else {
    $deltaPct = if (($null -ne $Row.auction_price) -and ($null -ne $changeSource.auction_price) -and ($changeSource.auction_price -ne 0)) {
      (($Row.auction_price - $changeSource.auction_price) / $changeSource.auction_price) * 100
    } else {
      $null
    }
    if ($null -eq $deltaPct) {
      "缺少可比价格"
    } elseif ($deltaPct -ge 0.5) {
      "价格增强"
    } elseif ($deltaPct -le -0.5) {
      "价格转弱"
    } else {
      "价格基本持平"
    }
  }

  $priorityOrder = Get-AuctionPriorityOrder -Tags @($tags)
  $focusBoost = if ([string]$Row.focus_level -eq "high") { 0.5 } else { 0 }
  [pscustomobject]@{
    code = $Row.code
    name = $Row.name
    focus_level = $Row.focus_level
    prev_close_mode = $Row.prev_close_mode
    auction_price = $Row.auction_price
    auction_pct = $Row.auction_pct
    auction_amount = $Row.auction_amount
    auction_amount_ratio_pct = $Row.reference_amount_ratio_pct
    auction_amount_ratio_label = $Row.reference_amount_label
    change_text = $changeText
    score = $score
    tags = @($tags)
    observation = Get-AuctionObservationText -Tags @($tags)
    priority_order = $priorityOrder
    reminder_priority = ($priorityOrder - $focusBoost)
    row = $Row
  }
}

function New-AuctionReportContent {
  param(
    [Parameter(Mandatory = $true)]
    [string]$TradeDate,

    [Parameter(Mandatory = $true)]
    [object]$SessionConfig,

    [Parameter(Mandatory = $true)]
    [object[]]$Snapshots,

    [Parameter(Mandatory = $true)]
    [object[]]$Assessments,

    [bool]$IncludeCatchupNote = $false
  )

  if ([string]$SessionConfig.Session -eq "close") {
    $rushCount = @($Assessments | Where-Object { $_.tags -contains "late_rush_close" }).Count
    $dropCount = @($Assessments | Where-Object { $_.tags -contains "late_drop_close" }).Count
    $strongCount = @($Assessments | Where-Object { $_.tags -contains "strong_close" }).Count
    $weakCount = @($Assessments | Where-Object { $_.tags -contains "weak_close" }).Count

    $lines = New-Object System.Collections.Generic.List[string]
    $catchupSnapshots = @($Snapshots | Where-Object { [string]$_.capture_mode -eq "catchup" })
    $lines.Add("# $($SessionConfig.Title)｜$TradeDate")
    $lines.Add("")
    $lines.Add("> 当前场景：**尾盘集合竞价监控**")
    $lines.Add("")
    $lines.Add("> 说明：本报告只分析 **14:57—15:00** 的收盘集合竞价，不包含 **15:05—15:30** 盘后固定价格交易。")
    $lines.Add("")
    if ($IncludeCatchupNote -and $catchupSnapshots.Count -gt 0) {
      $checkpoints = @($catchupSnapshots | ForEach-Object { [string]$_.checkpoint_display })
      $lines.Add("> 补跑说明：$($checkpoints -join '、') 的快照为补跑近似值。")
      $lines.Add("")
    }
    $lines.Add("## 总览")
    $lines.Add("- 持仓股票数量：**$($Assessments.Count)**")
    $lines.Add("- 尾盘抢筹数量：**$rushCount**")
    $lines.Add("- 尾盘砸盘数量：**$dropCount**")
    $lines.Add("- 强势收盘数量：**$strongCount**")
    $lines.Add("- 弱势收盘数量：**$weakCount**")
    $lines.Add("")
    $lines.Add("## 单股详情")

    foreach ($item in ($Assessments | Sort-Object reminder_priority, { - $_.score }, name)) {
      $row = $item.row
      $stockLabel = Format-AuctionStockLabel -Name $item.name -Code $item.code -PrevCloseMode $item.prev_close_mode
      $lines.Add("- $stockLabel")
      $lines.Add("  - 14:57价格：**$(if ($null -ne $row.close_1457_price) { '{0:N2}' -f $row.close_1457_price } else { '--' })**")
      $lines.Add("  - 15:00收盘价：**$(if ($null -ne $row.close_1500_price) { '{0:N2}' -f $row.close_1500_price } else { '--' })**")
      $lines.Add("  - 收盘竞价涨跌幅：**$(Format-ColoredPct $row.closing_auction_pct)**")
      $lines.Add("  - 14:57—15:00成交额：**$(Format-CnyWan $row.closing_auction_amount)**")
      $lines.Add("  - 收盘竞价成交额占常规交易成交额比例：**$(Format-Pct $row.closing_auction_amount_ratio_pct)**")
      $lines.Add("  - 收盘价相对日内VWAP位置：**$(switch ([string]$row.close_vs_vwap_position) { 'above' { '高于VWAP' } 'below' { '低于VWAP' } 'at' { '贴近VWAP' } default { '数据缺失' } })**")
      $lines.Add("  - 收盘价是否接近日内高点：**$(if ($row.close_near_day_high) { '是' } else { '否' })**")
      $lines.Add("  - 收盘价是否接近日内低点：**$(if ($row.close_near_day_low) { '是' } else { '否' })**")
      $lines.Add("  - 是否涨停：**$(if ($row.is_limit_up) { '是' } else { '否' })**")
      $lines.Add("  - 是否跌停：**$(if ($row.is_limit_down) { '是' } else { '否' })**")
      $lines.Add("  - 状态标签：**$((Convert-AuctionTagsToText -Tags $item.tags) -join '、')**")
      $lines.Add("  - 观察提示：$($item.observation)")
    }

    $lines.Add("")
    $lines.Add("仅供交易观察，不构成投资建议。15:05—15:30盘后固定价格交易不改变当日收盘价，应与14:57—15:00收盘集合竞价分开分析。")
    return ($lines -join "`n")
  }

  $strong = @($Assessments | Where-Object { $_.score -ge 65 })
  $weak = @($Assessments | Where-Object { $_.score -le 35 })
  $abnormalVolume = @($Assessments | Where-Object { ($_.tags -contains "extreme_volume") -or ($_.tags -contains "clear_volume") })
  $limitWatch = @($Assessments | Where-Object { ($_.tags -contains "auction_limit_up") -or ($_.tags -contains "near_limit_up") -or ($_.tags -contains "auction_limit_down") -or ($_.tags -contains "near_limit_down") })

  $lines = New-Object System.Collections.Generic.List[string]
  $catchupSnapshots = @($Snapshots | Where-Object { [string]$_.capture_mode -eq "catchup" })
  $lines.Add("# $($SessionConfig.Title)｜$TradeDate")
  $lines.Add("")
  $sessionText = if ($SessionConfig.Session -eq "open") { "开盘集合竞价监控" } else { "尾盘集合竞价监控" }
  $lines.Add("> 当前场景：**$sessionText**")
  $lines.Add("")
  if ($IncludeCatchupNote -and $catchupSnapshots.Count -gt 0) {
    $checkpoints = @($catchupSnapshots | ForEach-Object { [string]$_.checkpoint_display })
    $lines.Add("> 说明：$($checkpoints -join '、') 的快照为补跑近似值，采集时间晚于原始检查点，仅用于尽量恢复监控链路。")
    $lines.Add("")
  }
  $lines.Add("## 总览")
  $lines.Add("- 持仓股票数量：**$($Assessments.Count)**")
  $lines.Add("- 强势股票数量：**$($strong.Count)**")
  $lines.Add("- 弱势股票数量：**$($weak.Count)**")
  $lines.Add("- 异常放量股票数量：**$($abnormalVolume.Count)**")
  $lines.Add("- 接近涨停/跌停股票数量：**$($limitWatch.Count)**")
  $lines.Add("")
  $lines.Add("## 重点提醒")
  foreach ($item in ($Assessments | Sort-Object reminder_priority, { - $_.score }, name)) {
    if ($item.priority_order -ge 999) { continue }
    $stockLabel = Format-AuctionStockLabel -Name $item.name -Code $item.code -PrevCloseMode $item.prev_close_mode
    $lines.Add("- $stockLabel：$((Convert-AuctionTagsToText -Tags $item.tags) -join '、')，强度评分 $(Format-AuctionScore $item.score)")
  }
  if (-not @($Assessments | Where-Object { $_.priority_order -lt 999 })) {
    $lines.Add("- 暂无明显竞价异常，整体以正常波动为主。")
  }
  $lines.Add("")
  $lines.Add("## 单股详情")

  foreach ($item in ($Assessments | Sort-Object reminder_priority, { - $_.score }, name)) {
    $row = $item.row
    $ratioLabel = if ($row.reference_amount_label) { $row.reference_amount_label } else { "参考成交额" }
    $priceText = if ($null -ne $row.auction_price) { '{0:N2}' -f $row.auction_price } else { '--' }
    $stockLabel = Format-AuctionStockLabel -Name $item.name -Code $item.code -PrevCloseMode $item.prev_close_mode
    $lines.Add("- $stockLabel")
    $lines.Add("  - $($SessionConfig.PriceLabel)：**$priceText**")
    $lines.Add("  - 预计涨跌幅：**$(Format-ColoredPct $row.auction_pct)**")
    $lines.Add("  - 竞价成交额：**$(Format-CnyWan $row.auction_amount)**")
    $lines.Add("  - 竞价成交额占${ratioLabel}比例：**$(Format-Pct $row.reference_amount_ratio_pct)**")
    $lines.Add("  - $($SessionConfig.ChangeSinceLabel)：**$($item.change_text)**")
    $lines.Add("  - 强度评分：$(Format-AuctionScore $item.score)")
    $lines.Add("  - 状态标签：**$((Convert-AuctionTagsToText -Tags $item.tags) -join '、')**")
    $lines.Add("  - 操作提示：$($item.observation)")
  }

  if ([string]$SessionConfig.Session -eq "close") {
    $lines.Add("")
    $lines.Add("仅供交易观察，不构成投资建议。15:05—15:30盘后固定价格交易不改变当日收盘价，应与14:57—15:00收盘集合竞价分开分析。")
  }

  return ($lines -join "`n")
}

function Convert-AuctionTagsToText {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Tags
  )

  $map = @{
    close_limit_up = "涨停收盘"
    close_limit_down = "跌停收盘"
    strong_close = "强势收盘"
    weak_close = "弱势收盘"
    stable_close = "尾盘平稳"
    extreme_gap_up = "异常高开"
    clear_gap_up = "明显高开"
    strong_gap_up = "强势高开"
    gap_up = "高开"
    extreme_gap_down = "异常低开"
    clear_gap_down = "明显低开"
    weak_gap_down = "弱势低开"
    gap_down = "低开"
    extreme_volume = "异常放量"
    clear_volume = "明显放量"
    light_volume = "轻微放量"
    auction_limit_up = "竞价涨停"
    near_limit_up = "接近涨停"
    auction_limit_down = "竞价跌停"
    near_limit_down = "接近跌停"
    auction_strengthening = "竞价增强"
    auction_weakening = "竞价转弱"
    support_strengthening = "资金承接增强"
    late_rush_open = "尾段抢筹"
    late_rush_close = "尾盘抢筹"
    late_drop_open = "尾段砸盘"
    late_drop_close = "尾盘砸盘"
    normal = "正常波动"
    volume_gap_up = "放量高开"
    data_missing = "行情数据缺失"
  }

  @($Tags | ForEach-Object {
    if ($map.ContainsKey($_)) { $map[$_] } else { $_ }
  })
}

function Format-AuctionScore {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Score
  )

  $scoreValue = [int](Get-SafeDouble $Score)
  $color = if ($scoreValue -ge 80) {
    "red"
  } elseif ($scoreValue -ge 50) {
    "orange"
  } else {
    "green"
  }

  "**<font color=""$color"">$scoreValue</font>**"
}

function Format-AuctionStockLabel {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [string]$Code,

    [string]$PrevCloseMode = ""
  )

  $stockText = "**<font color=""purple"">$Name（$Code）</font>**"
  if ([string]$PrevCloseMode -eq "qfq") {
    return $stockText + "**<font color=""blue"">〔前复权〕</font>**"
  }

  return $stockText
}

function New-AfterHoursContext {
  param(
    [Parameter(Mandatory = $true)]
    [string]$DataRoot,

    [string]$TradeDate = (Get-Date -Format "yyyy-MM-dd")
  )

  $context = New-AuctionContext -DataRoot $DataRoot -Session after_hours
  $dayRoot = Join-Path $DataRoot $TradeDate
  New-Item -ItemType Directory -Force -Path $dayRoot | Out-Null

  [pscustomobject]@{
    Root = $context.Root
    Outbox = $context.Outbox
    LogFile = $context.LogFile
    PauseFlag = $context.PauseFlag
    PendingPushRoot = $context.PendingPushRoot
    AuctionSettingsPath = $context.AuctionSettingsPath
    SnapshotDateDir = $context.SnapshotDateDir
    TradeDate = $TradeDate
    DayRoot = $dayRoot
  }
}

function Get-AfterHoursReportJsonPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$DayRoot
  )

  Join-Path $DayRoot "after_hours_fixed_report.json"
}

function ConvertTo-AfterHoursAssessment {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Holding,

    [AllowNull()]$CloseRow,

    [AllowNull()]$AfterHoursData
  )

  $closePrice = if ($null -ne $CloseRow) { Get-SafeDoubleOrNull $CloseRow.auction_price } else { $null }
  $regularAmount = if ($null -ne $CloseRow) { Get-SafeDoubleOrNull $CloseRow.auction_amount } else { $null }
  $afterMetrics = if ($null -ne $AfterHoursData) {
    [pscustomobject]@{
      source = if ($AfterHoursData.PSObject.Properties.Name -contains "source" -and $AfterHoursData.source) { [string]$AfterHoursData.source } else { "unknown" }
      supported = if ($AfterHoursData.PSObject.Properties.Name -contains "supported") { [bool]$AfterHoursData.supported } else { $true }
      volume = Get-SafeDoubleOrNull $AfterHoursData.volume
      amount = Get-SafeDoubleOrNull $AfterHoursData.amount
    }
  } else {
    [pscustomobject]@{
      source = "unknown"
      supported = $false
      volume = $null
      amount = $null
    }
  }

  $status = "ok"
  $activityTag = "盘后正常"
  $observation = "盘后固定价格交易整体平稳。"
  $afterHoursAmount = Get-SafeDoubleOrNull $afterMetrics.amount
  $afterHoursVolume = Get-SafeDoubleOrNull $afterMetrics.volume
  $afterHoursSource = [string]$afterMetrics.source

  $closeStatus = if ($null -ne $CloseRow) { [string]$CloseRow.status } else { "" }

  if ($null -eq $CloseRow) {
    $status = "data_missing"
    $activityTag = "收盘快照缺失"
    $observation = "未找到 15:00 收盘集合竞价快照，暂时无法判断盘后固定价格交易。"
  } elseif ($null -eq $closePrice) {
    if ($closeStatus -eq "halted") {
      $status = "halted"
      $activityTag = "停牌"
      $observation = "个股当日停牌，未参与收盘集合竞价与盘后固定价格交易。"
    } else {
      $status = "data_missing"
      $activityTag = "收盘数据缺失"
      $observation = "15:00 收盘集合竞价关键字段缺失，暂时无法准确判断盘后固定价格交易。"
    }
  } elseif (-not $afterMetrics.supported) {
    $status = "unsupported"
    $activityTag = "数据源暂不支持盘后固定价格交易数据"
    $observation = "当前数据源未返回 15:05—15:30 盘后固定价格交易明细。"
  } elseif ((($null -eq $afterHoursAmount) -or ($afterHoursAmount -le 0)) -and (($null -eq $afterHoursVolume) -or ($afterHoursVolume -le 0))) {
    $status = "no_trade"
    $activityTag = "无盘后成交"
    $observation = "盘后固定价格交易阶段未观察到明显成交。"
  } else {
    $ratioRegular = if (($null -ne $afterHoursAmount) -and ($null -ne $regularAmount) -and ($regularAmount -gt 0)) {
      ($afterHoursAmount / $regularAmount) * 100
    } else {
      $null
    }

    if (($null -ne $ratioRegular) -and ($ratioRegular -lt 0.5)) {
      $activityTag = "盘后不活跃"
      $observation = "盘后成交较少，对全天资金格局影响有限。"
    } elseif (($null -ne $ratioRegular) -and ($ratioRegular -le 1.5)) {
      $activityTag = "盘后正常"
      $observation = "盘后成交处于常规水平，可结合次日开盘继续观察。"
    } elseif (($null -ne $ratioRegular) -and ($ratioRegular -le 3.0)) {
      $activityTag = "盘后较活跃"
      $observation = "盘后成交相对活跃，留意是否对应公告或资金异动。"
    } elseif ($null -ne $ratioRegular) {
      $activityTag = "盘后异常活跃"
      $observation = "盘后固定价格交易明显活跃，建议结合消息面与次日竞价重点观察。"
    }
  }

  $totalDayAmount = if (($null -ne $regularAmount) -or ($null -ne $afterHoursAmount)) {
    (Get-SafeDouble $regularAmount) + (Get-SafeDouble $afterHoursAmount)
  } else {
    $null
  }
  $ratioRegular = if (($null -ne $afterHoursAmount) -and ($null -ne $regularAmount) -and ($regularAmount -gt 0)) {
    ($afterHoursAmount / $regularAmount) * 100
  } else {
    $null
  }
  $ratioTotal = if (($null -ne $afterHoursAmount) -and ($null -ne $totalDayAmount) -and ($totalDayAmount -gt 0)) {
    ($afterHoursAmount / $totalDayAmount) * 100
  } else {
    $null
  }

  [pscustomobject]@{
    code = [string]$Holding.Code
    name = [string]$Holding.Name
    prev_close_mode = [string]$Holding.PrevCloseMode
    close_price = $closePrice
    regular_session_amount = $regularAmount
    after_hours_volume = $afterHoursVolume
    after_hours_amount = $afterHoursAmount
    total_day_amount = $totalDayAmount
    after_hours_ratio_regular_pct = $ratioRegular
    after_hours_ratio_total_pct = $ratioTotal
    after_hours_source = $afterHoursSource
    activity_tag = $activityTag
    record_date = $null
    status = $status
    observation = $observation
  }
}

function New-AfterHoursReportJson {
  param(
    [Parameter(Mandatory = $true)]
    [string]$TradeDate,

    [Parameter(Mandatory = $true)]
    [object[]]$Assessments
  )

  [pscustomobject]@{
    trade_date = $TradeDate
    generated_at = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    assessments = @($Assessments)
  }
}

function New-AfterHoursReportContent {
  param(
    [Parameter(Mandatory = $true)]
    [string]$TradeDate,

    [Parameter(Mandatory = $true)]
    [object[]]$Assessments
  )

  $inactiveCount = @($Assessments | Where-Object { $_.activity_tag -eq "盘后不活跃" }).Count
  $activeCount = @($Assessments | Where-Object { $_.activity_tag -eq "盘后较活跃" }).Count
  $veryActiveCount = @($Assessments | Where-Object { $_.activity_tag -eq "盘后异常活跃" }).Count
  $unsupportedCount = @($Assessments | Where-Object { $_.status -eq "unsupported" }).Count
  $sourceLabels = @(
    $Assessments |
      Select-Object -ExpandProperty after_hours_source -Unique |
      Where-Object { $_ }
  )
  $sourceDisplay = if ($sourceLabels -contains "tushare") {
    "Tushare Pro"
  } elseif ($sourceLabels -contains "eastmoney_trends2") {
    "东方财富"
  } else {
    (($sourceLabels | ForEach-Object {
      if ($_ -eq "external_after_hours_file") { "外部盘后数据文件" } else { [string]$_ }
    }) -join " / ")
  }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("# A股持仓盘后固定价格交易监控｜$TradeDate")
  $lines.Add("")
  $lines.Add("> 当前场景：**15:05—15:30 盘后固定价格交易监控**")
  $lines.Add("")
  $lines.Add("> 说明：本报告仅分析 **15:05—15:30** 盘后固定价格交易活跃度，不改变 **15:00** 收盘价。")
  if ($sourceDisplay) {
    $lines.Add("")
    $lines.Add("> 盘后数据来源：**$sourceDisplay**")
  }
  $lines.Add("")
  $lines.Add("## 总览")
  $lines.Add("- 持仓股票数量：**$($Assessments.Count)**")
  $lines.Add("- 盘后不活跃数量：**$inactiveCount**")
  $lines.Add("- 盘后较活跃数量：**$activeCount**")
  $lines.Add("- 盘后异常活跃数量：**$veryActiveCount**")
  $lines.Add("- 数据暂不支持数量：**$unsupportedCount**")
  $lines.Add("")
  $lines.Add("## 单股详情")

  foreach ($item in $Assessments) {
    $stockLabel = Format-AuctionStockLabel -Name $item.name -Code $item.code -PrevCloseMode $item.prev_close_mode
    $lines.Add("- $stockLabel")
    $lines.Add("  - 15:00收盘价：**$(if ($null -ne $item.close_price) { '{0:N2}' -f $item.close_price } else { '--' })**")
    $lines.Add("  - 15:05—15:30盘后成交量：**$(if ($null -ne $item.after_hours_volume) { '{0:N0}' -f $item.after_hours_volume } else { '--' })** 手")
    $lines.Add("  - 15:05—15:30盘后成交额：**$(Format-CnyWan $item.after_hours_amount)**")
    $lines.Add("  - 盘后成交额占常规交易成交额比例：**$(Format-Pct $item.after_hours_ratio_regular_pct)**")
    $lines.Add("  - 盘后成交额占全天合计成交额比例：**$(Format-Pct $item.after_hours_ratio_total_pct)**")
    $lines.Add("  - 盘后活跃度标签：**$($item.activity_tag)**")
    $lines.Add("  - 是否为股权登记日：**数据源暂未提供**")
    $lines.Add("  - 观察提示：$($item.observation)")
  }

  $lines.Add("")
  $lines.Add("仅供交易观察，不构成投资建议。15:05—15:30盘后固定价格交易不改变当日收盘价，应与14:57—15:00收盘集合竞价分开分析。")
  return ($lines -join "`n")
}
