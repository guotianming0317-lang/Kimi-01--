$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "AuctionMonitorShared.ps1")

function U {
  param([Parameter(Mandatory = $true)][string]$Text)
  [regex]::Replace($Text, "\\u([0-9a-fA-F]{4})", {
    param($m)
    [char][int]::Parse($m.Groups[1].Value, [System.Globalization.NumberStyles]::HexNumber)
  })
}

function New-OpenStrengthContext {
  param(
    [Parameter(Mandatory = $true)]
    [string]$DataRoot,

    [string]$TradeDate = (Get-Date -Format "yyyy-MM-dd")
  )

  $runtimeRoot = Join-Path $DataRoot "open_strength"
  $context = New-MonitorContext -DataRoot $runtimeRoot -LogName "open_strength.log"
  $dayRoot = Join-Path $DataRoot $TradeDate
  New-Item -ItemType Directory -Force -Path $dayRoot | Out-Null
  $sharedPendingPushRoot = Get-SharedPendingPushRoot -DataRoot $DataRoot -Scope "open_strength"
  $settingsPath = Join-Path $DataRoot "auction_feishu.settings.yml"
  if (-not (Test-Path -LiteralPath $settingsPath)) {
    $projectSettingsPath = Join-Path (Split-Path -Parent $PSScriptRoot) "data\auction_feishu.settings.yml"
    if (Test-Path -LiteralPath $projectSettingsPath) {
      $settingsPath = $projectSettingsPath
    }
  }

  [pscustomobject]@{
    RuntimeRoot = $runtimeRoot
    Outbox = $context.Outbox
    LogFile = $context.LogFile
    PauseFlag = $context.PauseFlag
    PendingPushRoot = $sharedPendingPushRoot
    SettingsPath = $settingsPath
    DayRoot = $dayRoot
    TradeDate = $TradeDate
  }
}

function Get-OpenStrengthSnapshotPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$DayRoot,

    [Parameter(Mandatory = $true)]
    [ValidateSet("0925", "0930", "0940", "report")]
    [string]$Checkpoint
  )

  switch ($Checkpoint) {
    "0925" { return (Join-Path $DayRoot "auction_0925.json") }
    "0930" { return (Join-Path $DayRoot "open_0930.json") }
    "0940" { return (Join-Path $DayRoot "snapshot_0940.json") }
    "report" { return (Join-Path $DayRoot "open_strength_report.json") }
  }
}

function Save-OpenStrengthPayload {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string]$Checkpoint,

    [Parameter(Mandatory = $true)]
    [object[]]$Rows
  )

  $payload = [pscustomobject]@{
    checkpoint = $Checkpoint
    time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    rows = @($Rows)
  }
  $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
  return $payload
}

function Read-OpenStrengthPayload {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }
  Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-OpenStrengthQuoteMap {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Holdings,

    [string]$QuoteDataPath = ""
  )

  $map = @{}
  if ($QuoteDataPath) {
    $raw = Get-Content -LiteralPath $QuoteDataPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($item in @($raw)) {
      $map[[string]$item.code] = $item
    }
    return $map
  }

  $fields = "f31,f32,f33,f34,f43,f44,f45,f46,f47,f48,f57,f58,f60"
  foreach ($holding in $Holdings) {
    try {
      $uri = "https://push2.eastmoney.com/api/qt/stock/get?fltt=2&invt=2&secid=$($holding.SecId)&fields=$fields"
      $response = Invoke-EastmoneyJson -Uri $uri
      if ($response.data) {
        $map[[string]$holding.Code] = $response.data
      }
    } catch {
      # Keep the pipeline alive for partial data.
    }
  }

  return $map
}

function Get-OpenStrengthTrendMap {
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
      $response = Invoke-EastmoneyJson -Uri $uri
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

function Get-OpenStrengthReferenceAmount {
  param(
    [Parameter(Mandatory = $true)]
    [object]$DailyMetric
  )

  $avg5 = Get-SafeDoubleOrNull $DailyMetric.avg5_amount
  if (($null -ne $avg5) -and ($avg5 -gt 0)) {
    return [pscustomobject]@{ Label = "avg5"; Value = $avg5 }
  }

  $yesterday = Get-SafeDoubleOrNull $DailyMetric.yesterday_amount
  if (($null -ne $yesterday) -and ($yesterday -gt 0)) {
    return [pscustomobject]@{ Label = "yesterday"; Value = $yesterday }
  }

  return [pscustomobject]@{ Label = ""; Value = $null }
}

function Get-ApproxVwap {
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
  return $vwap
}

function Get-OpenStrengthRangeMetrics {
  param(
    [object[]]$Bars,
    [AllowNull()]$CurrentPrice
  )

  $windowBars = @($Bars | Where-Object { ([string]$_.time -ge "09:30") -and ([string]$_.time -le "09:40") })
  if ($windowBars.Count -eq 0) {
    return [pscustomobject]@{
      high = $null
      low = $null
      volume = $null
      amount = $null
      vwap = $null
      delayed = $true
    }
  }

  $highValues = @($windowBars | ForEach-Object { Get-SafeDoubleOrNull $_.high } | Where-Object { $null -ne $_ })
  $lowValues = @($windowBars | ForEach-Object { Get-SafeDoubleOrNull $_.low } | Where-Object { $null -ne $_ })
  $high = if ($highValues.Count -gt 0) { ($highValues | Measure-Object -Maximum).Maximum } else { $null }
  $low = if ($lowValues.Count -gt 0) { ($lowValues | Measure-Object -Minimum).Minimum } else { $null }
  $volume = @($windowBars | ForEach-Object { Get-SafeDouble $_.volume } | Measure-Object -Sum).Sum
  $amount = @($windowBars | ForEach-Object { Get-SafeDouble $_.amount } | Measure-Object -Sum).Sum
  $latestBar = @($windowBars | Select-Object -Last 1)[0]
  $avgPrice = if (($null -ne $latestBar) -and ($null -ne (Get-SafeDoubleOrNull $latestBar.avg_price))) {
    Get-SafeDoubleOrNull $latestBar.avg_price
  } else {
    Get-ApproxVwap -Amount $amount -Volume $volume -ReferencePrice $CurrentPrice
  }

  [pscustomobject]@{
    high = $high
    low = $low
    volume = $volume
    amount = $amount
    vwap = $avgPrice
    delayed = $false
  }
}

function New-OpenStrength0925Row {
  param(
    [Parameter(Mandatory = $true)]$Holding,
    $Payload,
    [Parameter(Mandatory = $true)]$DailyMetric,
    [Parameter(Mandatory = $true)][datetime]$Timestamp
  )

  $prevClose = Get-SafeDoubleOrNull $Payload.f60
  if (($null -eq $prevClose) -and ($null -ne $DailyMetric)) {
    $prevClose = Get-SafeDoubleOrNull $DailyMetric.prev_close
  }
  $auctionPrice = Get-SafeDoubleOrNull $Payload.f43
  $auctionPct = if (($null -ne $auctionPrice) -and ($null -ne $prevClose) -and ($prevClose -ne 0)) {
    (($auctionPrice - $prevClose) / $prevClose) * 100
  } else {
    $null
  }

  [pscustomobject]@{
    code = [string]$Holding.Code
    name = [string]$Holding.Name
    prev_close_mode = [string]$Holding.PrevCloseMode
    prev_close = $prevClose
    auction_price = $auctionPrice
    auction_volume = Get-SafeDoubleOrNull $Payload.f47
    auction_amount = Get-SafeDoubleOrNull $Payload.f48
    auction_pct = $auctionPct
    timestamp = $Timestamp.ToString("yyyy-MM-dd HH:mm:ss")
    status = if ($null -eq $auctionPrice) { "data_missing" } else { "ok" }
  }
}

function New-OpenStrength0930Row {
  param(
    [Parameter(Mandatory = $true)]$Holding,
    $Payload,
    [Parameter(Mandatory = $true)]$DailyMetric,
    [object[]]$Bars = @(),
    [Parameter(Mandatory = $true)][datetime]$Timestamp
  )

  $prevClose = Get-SafeDoubleOrNull $Payload.f60
  if (($null -eq $prevClose) -and ($null -ne $DailyMetric)) {
    $prevClose = Get-SafeDoubleOrNull $DailyMetric.prev_close
  }
  $openPrice = Get-SafeDoubleOrNull $Payload.f46
  if ($null -eq $openPrice) {
    $openBar = @($Bars | Where-Object { [string]$_.time -eq "09:30" } | Select-Object -First 1)[0]
    if ($null -ne $openBar) {
      $openPrice = Get-SafeDoubleOrNull $openBar.open
      if ($null -eq $openPrice) {
        $openPrice = Get-SafeDoubleOrNull $openBar.close
      }
    }
  }
  $openPct = if (($null -ne $openPrice) -and ($null -ne $prevClose) -and ($prevClose -ne 0)) {
    (($openPrice - $prevClose) / $prevClose) * 100
  } else {
    $null
  }
  $status = "ok"
  if ($null -eq $openPrice) {
    $status = if ($null -ne $prevClose) { "halted" } else { "data_missing" }
  }

  [pscustomobject]@{
    code = [string]$Holding.Code
    name = [string]$Holding.Name
    prev_close_mode = [string]$Holding.PrevCloseMode
    prev_close = $prevClose
    open_price = $openPrice
    open_pct = $openPct
    timestamp = $Timestamp.ToString("yyyy-MM-dd HH:mm:ss")
    status = $status
  }
}

function New-OpenStrength0940Row {
  param(
    [Parameter(Mandatory = $true)]$Holding,
    $Payload,
    [Parameter(Mandatory = $true)]$DailyMetric,
    [object[]]$Bars = @(),
    [Parameter(Mandatory = $true)][datetime]$Timestamp
  )

  $prevClose = Get-SafeDoubleOrNull $Payload.f60
  if (($null -eq $prevClose) -and ($null -ne $DailyMetric)) {
    $prevClose = Get-SafeDoubleOrNull $DailyMetric.prev_close
  }
  $currentPrice = Get-SafeDoubleOrNull $Payload.f43
  $rangeMetrics = Get-OpenStrengthRangeMetrics -Bars $Bars -CurrentPrice $currentPrice
  if ($null -eq $currentPrice) {
    $latestBar = @($Bars | Where-Object { ([string]$_.time -ge "09:30") -and ([string]$_.time -le "09:40") } | Select-Object -Last 1)[0]
    if ($null -ne $latestBar) {
      $currentPrice = Get-SafeDoubleOrNull $latestBar.close
      if ($null -eq $currentPrice) {
        $currentPrice = Get-SafeDoubleOrNull $latestBar.open
      }
    }
  }
  $reference = Get-OpenStrengthReferenceAmount -DailyMetric $DailyMetric
  $amountRatio = if (($null -ne $rangeMetrics.amount) -and ($null -ne $reference.Value) -and ($reference.Value -gt 0)) {
    ($rangeMetrics.amount / $reference.Value) * 100
  } else {
    $null
  }
  $dayPct = if (($null -ne $currentPrice) -and ($null -ne $prevClose) -and ($prevClose -ne 0)) {
    (($currentPrice - $prevClose) / $prevClose) * 100
  } else {
    $null
  }
  $status = "ok"
  if ($null -eq $currentPrice) {
    $status = if ($null -ne $prevClose) { "halted" } else { "data_missing" }
  }

  [pscustomobject]@{
    code = [string]$Holding.Code
    name = [string]$Holding.Name
    prev_close_mode = [string]$Holding.PrevCloseMode
    prev_close = $prevClose
    current_price = $currentPrice
    day_pct = $dayPct
    high_0930_0940 = $rangeMetrics.high
    low_0930_0940 = $rangeMetrics.low
    volume_0930_0940 = $rangeMetrics.volume
    amount_0930_0940 = $rangeMetrics.amount
    vwap_0940 = $rangeMetrics.vwap
    delayed = $rangeMetrics.delayed
    buy1_price = Get-SafeDoubleOrNull $Payload.f31
    buy1_volume = Get-SafeDoubleOrNull $Payload.f32
    sell1_price = Get-SafeDoubleOrNull $Payload.f33
    sell1_volume = Get-SafeDoubleOrNull $Payload.f34
    reference_amount_label = $reference.Label
    reference_amount_ratio_pct = $amountRatio
    timestamp = $Timestamp.ToString("yyyy-MM-dd HH:mm:ss")
    status = $status
  }
}

function Get-OpenStrengthCaptureRows {
  param(
    [Parameter(Mandatory = $true)][ValidateSet("0925", "0930", "0940")][string]$Checkpoint,
    [Parameter(Mandatory = $true)][object[]]$Holdings,
    [datetime]$Timestamp = (Get-Date),
    [string]$QuoteDataPath = "",
    [string]$DailyMetricsPath = "",
    [string]$CachePath = "",
    [string]$TrendDataPath = ""
  )

  $dailyMap = Get-AuctionDailyMetricsMap -Holdings $Holdings -DailyMetricsPath $DailyMetricsPath -CachePath $CachePath
  $quoteMap = Get-OpenStrengthQuoteMap -Holdings $Holdings -QuoteDataPath $QuoteDataPath
  $trendMap = if (($Checkpoint -eq "0930") -or ($Checkpoint -eq "0940")) { Get-OpenStrengthTrendMap -Holdings $Holdings -TrendDataPath $TrendDataPath } else { @{} }

  $rows = foreach ($holding in $Holdings) {
    $code = [string]$holding.Code
    $dailyMetric = if ($dailyMap.ContainsKey($code)) { $dailyMap[$code] } else { [pscustomobject]@{} }
    $payload = if ($quoteMap.ContainsKey($code)) { $quoteMap[$code] } else { [pscustomobject]@{} }
    switch ($Checkpoint) {
      "0925" { New-OpenStrength0925Row -Holding $holding -Payload $payload -DailyMetric $dailyMetric -Timestamp $Timestamp }
      "0930" {
        $bars = if ($trendMap.ContainsKey($code)) { @($trendMap[$code]) } else { @() }
        New-OpenStrength0930Row -Holding $holding -Payload $payload -DailyMetric $dailyMetric -Bars $bars -Timestamp $Timestamp
      }
      "0940" {
        $bars = if ($trendMap.ContainsKey($code)) { @($trendMap[$code]) } else { @() }
        New-OpenStrength0940Row -Holding $holding -Payload $payload -DailyMetric $dailyMetric -Bars $bars -Timestamp $Timestamp
      }
    }
  }

  return @($rows)
}

function Find-OpenStrengthRow {
  param(
    [AllowNull()]$Payload,
    [Parameter(Mandatory = $true)][string]$Code
  )

  if ($null -eq $Payload) { return $null }
  @($Payload.rows | Where-Object { [string]$_.code -eq $Code } | Select-Object -First 1)[0]
}

function Get-OpenStrengthPrimaryTag {
  param(
    [AllowNull()]$OpenRow,
    [AllowNull()]$SnapshotRow
  )

  if (($null -eq $SnapshotRow) -or ([string]$SnapshotRow.status -eq "data_missing")) { return "data_missing" }
  if (([string]$SnapshotRow.status -eq "halted") -or (([string]$OpenRow.status -eq "halted"))) { return "halted" }

  $openPct = Get-SafeDoubleOrNull $OpenRow.open_pct
  $currentPrice = Get-SafeDoubleOrNull $SnapshotRow.current_price
  $openPrice = Get-SafeDoubleOrNull $OpenRow.open_price
  $changeVsOpen = if (($null -ne $currentPrice) -and ($null -ne $openPrice) -and ($openPrice -ne 0)) {
    (($currentPrice - $openPrice) / $openPrice) * 100
  } else {
    $null
  }
  $changeVsPrev = Get-SafeDoubleOrNull $SnapshotRow.day_pct
  $amountRatio = Get-SafeDoubleOrNull $SnapshotRow.reference_amount_ratio_pct

  if (($null -ne $openPct) -and ($openPct -ge 3) -and ($null -ne $changeVsOpen) -and ($changeVsOpen -ge 1) -and ($null -ne $amountRatio) -and ($amountRatio -ge 5)) { return "volume_gap_up_strong" }
  if (($null -ne $openPct) -and ($openPct -ge 3) -and ($null -ne $currentPrice) -and ($null -ne $openPrice) -and ($currentPrice -ge $openPrice) -and ($null -ne $amountRatio) -and ($amountRatio -ge 3)) { return "gap_up_hold" }
  if (($null -ne $openPct) -and ($openPct -ge 5) -and ($null -ne $changeVsOpen) -and ($changeVsOpen -le -2)) { return "gap_up_clear_weakening" }
  if (($null -ne $openPct) -and ($openPct -ge 3) -and ($null -ne $currentPrice) -and ($null -ne $openPrice) -and ($currentPrice -lt $openPrice)) { return "gap_up_pullback" }
  if (($null -ne $openPct) -and ($openPct -le -3) -and ($null -ne $changeVsPrev) -and ($changeVsPrev -ge -0.5)) { return "low_open_strong_repair" }
  if (($null -ne $openPct) -and ($openPct -le -2) -and ($null -ne $currentPrice) -and ($null -ne $openPrice) -and ($currentPrice -gt $openPrice) -and ($null -ne $changeVsOpen) -and ($changeVsOpen -ge 1)) { return "low_open_repair" }
  if (($null -ne $changeVsOpen) -and ($changeVsOpen -le -2) -and ($null -ne $amountRatio) -and ($amountRatio -ge 5)) { return "volume_drop" }
  if (($null -ne $openPct) -and ($openPct -le -2) -and ($null -ne $currentPrice) -and ($null -ne $openPrice) -and ($currentPrice -lt $openPrice)) { return "low_open_weaken" }
  return "normal"
}

function Get-OpenStrengthScore {
  param(
    [AllowNull()]$OpenRow,
    [AllowNull()]$SnapshotRow,
    [Parameter(Mandatory = $true)][string]$PrimaryTag
  )

  if (($PrimaryTag -eq "halted") -or ($PrimaryTag -eq "data_missing")) {
    return $null
  }

  $score = 50
  $currentPrice = Get-SafeDoubleOrNull $SnapshotRow.current_price
  $openPrice = Get-SafeDoubleOrNull $OpenRow.open_price
  $changeVsOpen = if (($null -ne $currentPrice) -and ($null -ne $openPrice) -and ($openPrice -ne 0)) {
    (($currentPrice - $openPrice) / $openPrice) * 100
  } else {
    $null
  }
  $amountRatio = Get-SafeDoubleOrNull $SnapshotRow.reference_amount_ratio_pct
  $vwap = Get-SafeDoubleOrNull $SnapshotRow.vwap_0940
  $changeVsPrev = Get-SafeDoubleOrNull $SnapshotRow.day_pct
  $openPct = Get-SafeDoubleOrNull $OpenRow.open_pct

  if (($null -ne $currentPrice) -and ($null -ne $openPrice)) {
    if ($currentPrice -gt $openPrice) { $score += 10 }
    elseif ($currentPrice -lt $openPrice) { $score -= 10 }
  }
  if ($null -ne $changeVsOpen) {
    if ($changeVsOpen -ge 1) { $score += 10 }
    if ($changeVsOpen -ge 2) { $score += 10 }
    if ($changeVsOpen -le -1) { $score -= 10 }
    if ($changeVsOpen -le -2) { $score -= 10 }
  }
  if ($null -ne $amountRatio) {
    if ($amountRatio -ge 3) { $score += 8 }
    if ($amountRatio -ge 5) { $score += 8 }
  }
  if (($null -ne $currentPrice) -and ($null -ne $vwap)) {
    if ($currentPrice -ge $vwap) { $score += 8 } else { $score -= 8 }
  }
  if (($null -ne $openPct) -and ($openPct -le -3) -and ($null -ne $changeVsPrev) -and ($changeVsPrev -ge -0.5)) { $score += 10 }
  if ($PrimaryTag -eq "volume_drop") { $score -= 15 }
  if (($null -ne $openPct) -and ($openPct -ge 3) -and ($null -ne $currentPrice) -and ($null -ne $openPrice) -and ($currentPrice -lt $openPrice)) { $score -= 12 }

  return [Math]::Max(0, [Math]::Min(100, [Math]::Round($score, 0)))
}

function Get-OpenStrengthScoreBand {
  param([AllowNull()]$Score)

  $value = Get-SafeDoubleOrNull $Score
  if ($null -eq $value) { return "unknown" }
  if ($value -ge 80) { return "strong" }
  if ($value -ge 65) { return "supportive" }
  if ($value -ge 50) { return "normal" }
  if ($value -ge 35) { return "weak" }
  return "very_weak"
}

function Get-OpenStrengthPriority {
  param([Parameter(Mandatory = $true)][string]$PrimaryTag)

  $order = @(
    "volume_gap_up_strong",
    "gap_up_hold",
    "low_open_strong_repair",
    "gap_up_clear_weakening",
    "volume_drop",
    "low_open_weaken",
    "gap_up_pullback",
    "low_open_repair",
    "normal",
    "halted",
    "data_missing"
  )

  for ($i = 0; $i -lt $order.Count; $i++) {
    if ($PrimaryTag -eq $order[$i]) { return $i }
  }
  return 999
}

function Convert-OpenStrengthTagToText {
  param([Parameter(Mandatory = $true)][string]$Tag)

  $map = @{
    volume_gap_up_strong = (U '\u653e\u91cf\u9ad8\u5f00\u8d70\u5f3a')
    gap_up_hold = (U '\u9ad8\u5f00\u5ef6\u7eed')
    gap_up_pullback = (U '\u9ad8\u5f00\u56de\u843d')
    gap_up_clear_weakening = (U '\u9ad8\u5f00\u660e\u663e\u8f6c\u5f31')
    low_open_repair = (U '\u4f4e\u5f00\u4fee\u590d')
    low_open_strong_repair = (U '\u4f4e\u5f00\u5f3a\u4fee\u590d')
    low_open_weaken = (U '\u4f4e\u5f00\u7ee7\u7eed\u8d70\u5f31')
    volume_drop = (U '\u653e\u91cf\u4e0b\u8dcc')
    normal = (U '\u6b63\u5e38\u6ce2\u52a8')
    halted = (U '\u505c\u724c')
    data_missing = (U '\u884c\u60c5\u6570\u636e\u7f3a\u5931')
  }
  if ($map.ContainsKey($Tag)) { return $map[$Tag] }
  return $Tag
}

function Convert-OpenStrengthBandToText {
  param([Parameter(Mandatory = $true)][string]$Band)

  $map = @{
    strong = (U '\u5f00\u76d8\u5f3a\u52bf')
    supportive = (U '\u627f\u63a5\u8f83\u5f3a')
    normal = (U '\u6b63\u5e38')
    weak = (U '\u504f\u5f31')
    very_weak = (U '\u660e\u663e\u5f31\u52bf')
    unknown = '--'
  }
  if ($map.ContainsKey($Band)) { return $map[$Band] }
  return $Band
}

function Get-OpenStrengthObservation {
  param([Parameter(Mandatory = $true)][string]$PrimaryTag)

  switch ($PrimaryTag) {
    "volume_gap_up_strong" { return (U '\u9ad8\u5f00\u540e\u7ee7\u7eed\u8d70\u5f3a\uff0c\u6ce8\u610f\u89c2\u5bdf10:00\u524d\u662f\u5426\u7ef4\u6301\u653e\u91cf\u4e0a\u653b\u3002') }
    "gap_up_hold" { return (U '\u9ad8\u5f00\u540e\u7ee7\u7eed\u7ad9\u4e0a\u5f00\u76d8\u4ef7\uff0c\u5f00\u76d8\u627f\u63a5\u8f83\u5f3a\uff0c\u53ef\u89c2\u5bdf10:00\u524d\u662f\u5426\u7ee7\u7eed\u7ef4\u6301\u5f3a\u52bf\u3002') }
    "gap_up_pullback" { return (U '\u9ad8\u5f00\u540e\u56de\u843d\u81f3\u5f00\u76d8\u4ef7\u4e0b\u65b9\uff0c\u8bf4\u660e\u7ade\u4ef7\u5f3a\u5ea6\u672a\u80fd\u5ef6\u7eed\uff0c\u6ce8\u610f\u51b2\u9ad8\u56de\u843d\u98ce\u9669\u3002') }
    "gap_up_clear_weakening" { return (U '\u9ad8\u5f00\u540e\u5feb\u901f\u8f6c\u5f31\uff0c\u6ce8\u610f\u5f00\u76d8\u5f3a\u52bf\u662f\u5426\u5df2\u88ab\u8d44\u91d1\u5151\u73b0\u3002') }
    "low_open_repair" { return (U '\u4f4e\u5f00\u540e\u5feb\u901f\u4fee\u590d\uff0c\u8bf4\u660e\u5f00\u76d8\u6709\u8d44\u91d1\u627f\u63a5\uff0c\u7ee7\u7eed\u89c2\u5bdf\u662f\u5426\u80fd\u6536\u590d\u6628\u6536\u4ef7\u3002') }
    "low_open_strong_repair" { return (U '\u4f4e\u5f00\u540e\u8fc5\u901f\u4fee\u590d\u5230\u6628\u6536\u9644\u8fd1\uff0c\u8bf4\u660e\u627f\u63a5\u8f83\u5f3a\uff0c\u7ee7\u7eed\u89c2\u5bdf\u80fd\u5426\u8f6c\u5f3a\u3002') }
    "low_open_weaken" { return (U '\u4f4e\u5f00\u540e\u7ee7\u7eed\u8d70\u5f31\uff0c\u6ce8\u610f\u662f\u5426\u5b58\u5728\u5229\u7a7a\u6216\u677f\u5757\u62d6\u7d2f\u3002') }
    "volume_drop" { return (U '\u4f4e\u5f00\u540e\u7ee7\u7eed\u653e\u91cf\u4e0b\u8dcc\uff0c\u8bf4\u660e\u5f00\u76d8\u629b\u538b\u8f83\u91cd\uff0c\u6ce8\u610f\u662f\u5426\u5b58\u5728\u5229\u7a7a\u6216\u677f\u5757\u8d70\u5f31\u3002') }
    "halted" { return (U '\u8be5\u80a1\u5f53\u524d\u7591\u4f3c\u505c\u724c\uff0c\u6682\u65e0\u6cd5\u8fdb\u884c\u5f00\u76d8\u627f\u63a5\u5224\u65ad\u3002') }
    "data_missing" { return (U '\u4e3b\u8981\u884c\u60c5\u6570\u636e\u7f3a\u5931\uff0c\u5efa\u8bae\u7a0d\u540e\u4eba\u5de5\u590d\u6838\u3002') }
    default { return (U '\u5f00\u76d8\u6ce2\u52a8\u6b63\u5e38\uff0c\u6682\u65f6\u65e0\u660e\u663e\u5f02\u5e38\u3002') }
  }
}

function ConvertTo-OpenStrengthAssessment {
  param(
    [Parameter(Mandatory = $true)]$Holding,
    [AllowNull()]$AuctionRow,
    [AllowNull()]$OpenRow,
    [AllowNull()]$SnapshotRow
  )

  $primaryTag = Get-OpenStrengthPrimaryTag -OpenRow $OpenRow -SnapshotRow $SnapshotRow
  $score = Get-OpenStrengthScore -OpenRow $OpenRow -SnapshotRow $SnapshotRow -PrimaryTag $primaryTag
  $openPrice = Get-SafeDoubleOrNull $OpenRow.open_price
  $prevClose = if ($null -ne (Get-SafeDoubleOrNull $OpenRow.prev_close)) { Get-SafeDoubleOrNull $OpenRow.prev_close } else { Get-SafeDoubleOrNull $AuctionRow.prev_close }
  $currentPrice = Get-SafeDoubleOrNull $SnapshotRow.current_price
  $changeVsOpen = if (($null -ne $currentPrice) -and ($null -ne $openPrice) -and ($openPrice -ne 0)) {
    (($currentPrice - $openPrice) / $openPrice) * 100
  } else {
    $null
  }
  $amplitudePct = if (($null -ne $SnapshotRow.high_0930_0940) -and ($null -ne $SnapshotRow.low_0930_0940) -and ($null -ne $prevClose) -and ($prevClose -ne 0)) {
    (($SnapshotRow.high_0930_0940 - $SnapshotRow.low_0930_0940) / $prevClose) * 100
  } else {
    $null
  }
  $aboveVwap = if (($null -ne $currentPrice) -and ($null -ne $SnapshotRow.vwap_0940)) {
    ($currentPrice -ge $SnapshotRow.vwap_0940)
  } else {
    $null
  }
  $priority = Get-OpenStrengthPriority -PrimaryTag $primaryTag
  $focusBoost = if ([string]$Holding.FocusLevel -eq "high") { 0.5 } else { 0 }

  [pscustomobject]@{
    code = [string]$Holding.Code
    name = [string]$Holding.Name
    focus_level = [string]$Holding.FocusLevel
    prev_close_mode = [string]$Holding.PrevCloseMode
    prev_close = $prevClose
    auction_price = Get-SafeDoubleOrNull $AuctionRow.auction_price
    open_price = $openPrice
    open_pct = Get-SafeDoubleOrNull $OpenRow.open_pct
    current_price = $currentPrice
    current_vs_open_pct = $changeVsOpen
    current_vs_prev_pct = Get-SafeDoubleOrNull $SnapshotRow.day_pct
    amplitude_pct = $amplitudePct
    amount_0930_0940 = Get-SafeDoubleOrNull $SnapshotRow.amount_0930_0940
    amount_ratio_pct = Get-SafeDoubleOrNull $SnapshotRow.reference_amount_ratio_pct
    amount_ratio_label = [string]$SnapshotRow.reference_amount_label
    high_0930_0940 = Get-SafeDoubleOrNull $SnapshotRow.high_0930_0940
    low_0930_0940 = Get-SafeDoubleOrNull $SnapshotRow.low_0930_0940
    vwap_0940 = Get-SafeDoubleOrNull $SnapshotRow.vwap_0940
    above_vwap = $aboveVwap
    buy1_price = Get-SafeDoubleOrNull $SnapshotRow.buy1_price
    buy1_volume = Get-SafeDoubleOrNull $SnapshotRow.buy1_volume
    sell1_price = Get-SafeDoubleOrNull $SnapshotRow.sell1_price
    sell1_volume = Get-SafeDoubleOrNull $SnapshotRow.sell1_volume
    primary_tag = $primaryTag
    primary_tag_text = Convert-OpenStrengthTagToText -Tag $primaryTag
    score = $score
    score_band = Get-OpenStrengthScoreBand -Score $score
    score_band_text = Convert-OpenStrengthBandToText -Band (Get-OpenStrengthScoreBand -Score $score)
    observation = Get-OpenStrengthObservation -PrimaryTag $primaryTag
    delayed = [bool]$SnapshotRow.delayed
    status = [string]$SnapshotRow.status
    priority_order = $priority
    reminder_priority = ($priority - $focusBoost)
  }
}

function Format-OpenStrengthScore {
  param([AllowNull()]$Score)

  if ($null -eq (Get-SafeDoubleOrNull $Score)) {
    return "**--**"
  }
  return (Format-AuctionScore -Score $Score)
}

function Format-OpenStrengthBool {
  param([AllowNull()]$Value)

  if ($null -eq $Value) { return (U '\u6570\u636e\u7f3a\u5931') }
  if ([bool]$Value) { return (U '\u662f') }
  return (U '\u5426')
}

function Get-OpenStrengthRatioLabelText {
  param([string]$Label)

  switch ($Label) {
    "avg5" { return (U '\u8fd15\u65e5\u5e73\u5747\u6210\u4ea4\u989d') }
    "yesterday" { return (U '\u6628\u65e5\u6210\u4ea4\u989d') }
    default { return (U '\u6628\u65e5\u6210\u4ea4\u989d') }
  }
}

function New-OpenStrengthReportJson {
  param(
    [Parameter(Mandatory = $true)][string]$TradeDate,
    [Parameter(Mandatory = $true)][object[]]$Assessments
  )

  [pscustomobject]@{
    trade_date = $TradeDate
    generated_at = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    summary = [pscustomobject]@{
      holdings_count = $Assessments.Count
      strong_count = @($Assessments | Where-Object { $_.score_band -eq "strong" }).Count
      support_count = @($Assessments | Where-Object { $_.score_band -eq "supportive" }).Count
      high_open_pullback_count = @($Assessments | Where-Object { $_.primary_tag -eq "gap_up_pullback" }).Count
      low_open_repair_count = @($Assessments | Where-Object { ($_.primary_tag -eq "low_open_repair") -or ($_.primary_tag -eq "low_open_strong_repair") }).Count
      volume_drop_count = @($Assessments | Where-Object { $_.primary_tag -eq "volume_drop" }).Count
      weak_count = @($Assessments | Where-Object { $_.score_band -eq "very_weak" }).Count
    }
    assessments = @($Assessments)
  }
}

function New-OpenStrengthReportContent {
  param(
    [Parameter(Mandatory = $true)][string]$TradeDate,
    [Parameter(Mandatory = $true)][object[]]$Assessments
  )

  $reportJson = New-OpenStrengthReportJson -TradeDate $TradeDate -Assessments $Assessments
  $summary = $reportJson.summary
  $priorityItems = @($Assessments | Sort-Object reminder_priority, { - (Get-SafeDouble $_.score) }, name | Where-Object {
    @("volume_gap_up_strong", "gap_up_hold", "low_open_strong_repair", "gap_up_clear_weakening", "volume_drop", "low_open_weaken") -contains [string]$_.primary_tag
  })

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add((U '# A\u80a1\u6301\u4ed39:40\u5f00\u76d8\u627f\u63a5\u5206\u6790') + "｜$TradeDate")
  $lines.Add("")
  $lines.Add((U '> \u5f53\u524d\u573a\u666f\uff1a**\u5f00\u76d8\u540e10\u5206\u949f\u627f\u63a5\u5206\u6790**'))
  $lines.Add("")
  if (@($Assessments | Where-Object { $_.delayed }).Count -gt 0) {
    $lines.Add((U '> \u8bf4\u660e\uff1a\u90e8\u5206\u5206\u65f6\u6570\u636e\u672a\u5b8c\u6574\u8fd4\u56de\uff0c\u4e2a\u522b\u80a1\u7968\u5df2\u6807\u8bb0\u4e3a\u201c\u6570\u636e\u53ef\u80fd\u5ef6\u8fdf\u201d\u3002'))
    $lines.Add("")
  }
  $lines.Add((U '## \u603b\u89c8'))
  $lines.Add((U '- \u6301\u4ed3\u80a1\u7968\u6570\u91cf\uff1a') + "**$($summary.holdings_count)**")
  $lines.Add((U '- \u5f00\u76d8\u5f3a\u52bf\u6570\u91cf\uff1a') + "**$($summary.strong_count)**")
  $lines.Add((U '- \u627f\u63a5\u8f83\u5f3a\u6570\u91cf\uff1a') + "**$($summary.support_count)**")
  $lines.Add((U '- \u9ad8\u5f00\u56de\u843d\u6570\u91cf\uff1a') + "**$($summary.high_open_pullback_count)**")
  $lines.Add((U '- \u4f4e\u5f00\u4fee\u590d\u6570\u91cf\uff1a') + "**$($summary.low_open_repair_count)**")
  $lines.Add((U '- \u653e\u91cf\u4e0b\u8dcc\u6570\u91cf\uff1a') + "**$($summary.volume_drop_count)**")
  $lines.Add((U '- \u660e\u663e\u5f31\u52bf\u6570\u91cf\uff1a') + "**$($summary.weak_count)**")
  $lines.Add("")
  $lines.Add((U '## \u91cd\u70b9\u63d0\u9192'))
  if ($priorityItems.Count -gt 0) {
    foreach ($item in $priorityItems) {
      $stockLabel = Format-AuctionStockLabel -Name $item.name -Code $item.code -PrevCloseMode $item.prev_close_mode
      $lines.Add("- $stockLabel" + (U '\uff1a') + "$($item.primary_tag_text)" + (U '\uff0c\u5f00\u76d8\u627f\u63a5\u8bc4\u5206 ') + (Format-OpenStrengthScore $item.score))
    }
  } else {
    $lines.Add((U '- \u6682\u65e0\u660e\u663e\u5f00\u76d8\u627f\u63a5\u5f02\u5e38\uff0c\u6574\u4f53\u4ee5\u6b63\u5e38\u6ce2\u52a8\u4e3a\u4e3b\u3002'))
  }
  $lines.Add("")
  $lines.Add((U '## \u5355\u80a1\u8be6\u60c5'))

  foreach ($item in ($Assessments | Sort-Object reminder_priority, { - (Get-SafeDouble $_.score) }, name)) {
    $stockLabel = Format-AuctionStockLabel -Name $item.name -Code $item.code -PrevCloseMode $item.prev_close_mode
    $ratioLabel = Get-OpenStrengthRatioLabelText -Label $item.amount_ratio_label
    $lines.Add("- $stockLabel")
    $lines.Add("  - " + (U '\u6628\u6536\u4ef7\uff1a') + "**$(if ($null -ne $item.prev_close) { '{0:N2}' -f $item.prev_close } else { '--' })**")
    $lines.Add("  - " + (U '\u5f00\u76d8\u4ef7\uff1a') + "**$(if ($null -ne $item.open_price) { '{0:N2}' -f $item.open_price } else { '--' })**")
    $lines.Add("  - " + (U '\u5f00\u76d8\u6da8\u8dcc\u5e45\uff1a') + "**$(Format-ColoredPct $item.open_pct)**")
    $lines.Add("  - " + (U '9:40\u4ef7\u683c\uff1a') + "**$(if ($null -ne $item.current_price) { '{0:N2}' -f $item.current_price } else { '--' })**")
    $lines.Add("  - " + (U '9:40\u76f8\u5bf9\u5f00\u76d8\u6da8\u8dcc\u5e45\uff1a') + "**$(Format-ColoredPct $item.current_vs_open_pct)**")
    $lines.Add("  - " + (U '9:40\u5f53\u65e5\u6da8\u8dcc\u5e45\uff1a') + "**$(Format-ColoredPct $item.current_vs_prev_pct)**")
    $lines.Add("  - " + (U '9:30\u20149:40\u6210\u4ea4\u989d\uff1a') + "**$(Format-CnyWan $item.amount_0930_0940)**")
    $lines.Add("  - " + (U '\u6210\u4ea4\u989d\u5360') + $ratioLabel + (U '\u6bd4\u4f8b\uff1a') + "**$(Format-Pct $item.amount_ratio_pct)**")
    $lines.Add("  - " + (U '9:30\u20149:40\u6700\u9ad8\u4ef7\uff1a') + "**$(if ($null -ne $item.high_0930_0940) { '{0:N2}' -f $item.high_0930_0940 } else { '--' })**")
    $lines.Add("  - " + (U '9:30\u20149:40\u6700\u4f4e\u4ef7\uff1a') + "**$(if ($null -ne $item.low_0930_0940) { '{0:N2}' -f $item.low_0930_0940 } else { '--' })**")
    $lines.Add("  - " + (U '\u662f\u5426\u9ad8\u4e8e\u5206\u65f6\u5747\u4ef7/VWAP\uff1a') + "**$(Format-OpenStrengthBool $item.above_vwap)**")
    if ($item.delayed) {
      $lines.Add("  - " + (U '\u6570\u636e\u72b6\u6001\uff1a**\u6570\u636e\u53ef\u80fd\u5ef6\u8fdf**'))
    }
    $lines.Add("  - " + (U '\u72b6\u6001\u6807\u7b7e\uff1a') + "**$($item.primary_tag_text)**")
    $lines.Add("  - " + (U '\u5f00\u76d8\u627f\u63a5\u8bc4\u5206\uff1a') + (Format-OpenStrengthScore $item.score))
    $lines.Add("  - " + (U '\u64cd\u4f5c\u63d0\u793a\uff1a') + $item.observation)
  }

  return ($lines -join "`n")
}
