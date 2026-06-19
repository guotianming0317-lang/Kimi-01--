$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Holdings.ps1")

function Enable-PreferredTls {
  try {
    $current = [Net.ServicePointManager]::SecurityProtocol
    $tls12 = [Net.SecurityProtocolType]::Tls12
    if (($current -band $tls12) -ne $tls12) {
      [Net.ServicePointManager]::SecurityProtocol = ($current -bor $tls12)
    }
  } catch {
    # Ignore when the host runtime does not expose these knobs.
  }
}

function Invoke-EastmoneyJson {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Uri,

    [hashtable]$Headers = @{"User-Agent"="Mozilla/5.0";"Referer"="https://quote.eastmoney.com/"},

    [ValidateRange(1, 10)]
    [int]$MaxAttempts = 3,

    [ValidateRange(1, 30)]
    [int]$RetryDelaySeconds = 3
  )

  $lastError = $null
  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    try {
      Enable-PreferredTls
      return Invoke-RestMethod -Uri $Uri -Headers $Headers -TimeoutSec 20
    } catch {
      $irmError = $_.Exception.Message
      try {
        $curlArgs = @("-sS", "--connect-timeout", "20")
        foreach ($key in $Headers.Keys) {
          $curlArgs += @("-H", ("{0}: {1}" -f $key, $Headers[$key]))
        }
        $curlArgs += $Uri
        $curlText = & curl.exe @curlArgs
        if ($LASTEXITCODE -eq 0 -and $curlText) {
          return ($curlText | ConvertFrom-Json)
        }
        $lastError = if ($curlText) { $curlText } else { "curl exit code $LASTEXITCODE" }
      } catch {
        $lastError = "$irmError; curl fallback: $($_.Exception.Message)"
      }
      if ($attempt -ge $MaxAttempts) {
        throw "Eastmoney request failed after $attempt attempts: $lastError"
      }
      Start-Sleep -Seconds $RetryDelaySeconds
    }
  }
}

function New-MonitorContext {
  param(
    [Parameter(Mandatory = $true)]
    [string]$DataRoot,

    [string]$LogName = "fund_push.log"
  )

  $outbox = Join-Path $DataRoot "outbox"
  $snapshotRoot = Join-Path $DataRoot "snapshots"
  $logDir = Join-Path $DataRoot "logs"
  $pendingPushRoot = Join-Path $DataRoot "pending_pushes"
  $pauseFlag = Join-Path $DataRoot "monitoring_paused.flag"

  New-Item -ItemType Directory -Force -Path $outbox | Out-Null
  New-Item -ItemType Directory -Force -Path $snapshotRoot | Out-Null
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
  New-Item -ItemType Directory -Force -Path $pendingPushRoot | Out-Null

  [pscustomobject]@{
    DataRoot = $DataRoot
    Outbox = $outbox
    SnapshotRoot = $snapshotRoot
    PendingPushRoot = $pendingPushRoot
    LogFile = (Join-Path $logDir $LogName)
    PauseFlag = $pauseFlag
  }
}

function Write-MonitorLog {
  param(
    [Parameter(Mandatory = $true)]
    [string]$LogFile,

    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
}

function Test-MonitorPaused {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PauseFlag
  )

  Test-Path -LiteralPath $PauseFlag
}

function Get-HeldQuoteRows {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Holdings,

    [string]$QuoteDataPath = ""
  )

  $fields = "f12,f14,f2,f3,f4,f5,f6,f62,f184,f66,f69,f72,f75,f78,f81,f84,f87,f124"
  if ($QuoteDataPath) {
    if (-not (Test-Path -LiteralPath $QuoteDataPath)) {
      throw "行情数据文件不存在：$QuoteDataPath"
    }
    $data = Get-Content -LiteralPath $QuoteDataPath -Raw -Encoding UTF8 | ConvertFrom-Json
  } else {
    $secids = ($Holdings.SecId) -join ","
    $url = "https://push2.eastmoney.com/api/qt/ulist.np/get?fltt=2&invt=2&fields=$fields&secids=$secids"
    $data = Invoke-EastmoneyJson -Uri $url
  }

  $rows = @($data.data.diff)
  if (-not $rows) {
    throw "行情接口未返回有效数据。"
  }

  $heldCodes = @($Holdings | Select-Object -ExpandProperty Code)
  $valid = @($rows | Where-Object { $_.f12 -and $_.f14 -and ($heldCodes -contains ([string]$_.f12)) })
  if (-not $valid) {
    throw "行情数据中没有匹配到持仓股票。"
  }

  if (-not $QuoteDataPath) {
    try {
      $detailMap = Get-HeldQuoteDetailMap -Holdings $Holdings
      Merge-HeldQuoteDetailFields -Rows $valid -DetailMap $detailMap
    } catch {
      # Detail flow fields are optional for report enrichment.
    }
  }

  return $valid
}

function Get-HeldQuoteDetailMap {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Holdings
  )

  (Get-HeldQuoteDetailFetchResult -Holdings $Holdings).Map
}

function Get-HeldQuoteDetailFetchResult {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Holdings
  )

  $headers = @{
    "User-Agent" = "Mozilla/5.0"
    "Referer" = "https://quote.eastmoney.com/"
  }
  $detailFields = "f137,f138,f139,f140,f141,f142,f143,f144,f145,f146,f147,f148,f149"
  $map = @{}
  $errors = New-Object System.Collections.Generic.List[string]

  foreach ($holding in $Holdings) {
    $uri = "https://push2.eastmoney.com/api/qt/stock/get?fltt=2&invt=2&fields=$detailFields&secid=$($holding.SecId)"
    try {
      $response = Invoke-EastmoneyJson -Uri $uri -Headers $headers
      if ($response.data) {
        $map[[string]$holding.Code] = $response.data
      } else {
        $errors.Add("$($holding.Code): empty detail payload")
      }
    } catch {
      $errors.Add("$($holding.Code): $($_.Exception.Message)")
    }
  }

  [pscustomobject]@{
    Map = $map
    Errors = @($errors)
  }
}

function Merge-HeldQuoteDetailFields {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Rows,

    [Parameter(Mandatory = $true)]
    [hashtable]$DetailMap
  )

  foreach ($row in $Rows) {
    $code = [string]$row.f12
    if (-not $DetailMap.ContainsKey($code)) { continue }
    $detail = $DetailMap[$code]
    foreach ($fieldName in @("f137", "f138", "f139", "f140", "f141", "f142", "f143", "f144", "f145", "f146", "f147", "f148", "f149")) {
      if ($detail.PSObject.Properties.Name -contains $fieldName) {
        $row | Add-Member -NotePropertyName $fieldName -NotePropertyValue $detail.$fieldName -Force
      }
    }
  }
}

function New-SnapshotRows {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Rows
  )

  @($Rows | ForEach-Object {
    [pscustomobject]@{
      code = [string]$_.f12
      name = [string]$_.f14
      price = $_.f2
      pct = $_.f3
      main_flow = $_.f62
      main_ratio = $_.f184
      super_flow = $_.f66
      super_in = if ($_.PSObject.Properties.Name -contains "f138") { $_.f138 } else { $null }
      super_out = if ($_.PSObject.Properties.Name -contains "f139") { $_.f139 } else { $null }
      super_ratio = $_.f69
      large_flow = $_.f72
      large_in = if ($_.PSObject.Properties.Name -contains "f141") { $_.f141 } else { $null }
      large_out = if ($_.PSObject.Properties.Name -contains "f142") { $_.f142 } else { $null }
      large_ratio = $_.f75
      medium_flow = $_.f78
      medium_ratio = $_.f81
      small_flow = $_.f84
      small_ratio = $_.f87
    }
  })
}

function Save-MonitorSnapshot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SnapshotRoot,

    [Parameter(Mandatory = $true)]
    [int]$TotalCount,

    [Parameter(Mandatory = $true)]
    [object[]]$SnapshotRows
  )

  $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $now = Get-Date
  $tradeDate = $now.ToString("yyyyMMdd")
  $snapshotDir = Join-Path $SnapshotRoot $tradeDate
  New-Item -ItemType Directory -Force -Path $snapshotDir | Out-Null

  $snapshot = [pscustomobject]@{
    time = $time
    trade_date = $tradeDate
    total_count = $TotalCount
    valid_count = $SnapshotRows.Count
    total_main_flow = (($SnapshotRows | Measure-Object -Property main_flow -Sum).Sum)
    rows = $SnapshotRows
  }

  $snapshotFile = Join-Path $snapshotDir ("snapshot_{0}.json" -f $now.ToString("HHmmss"))
  $snapshot | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $snapshotFile -Encoding UTF8

  [pscustomobject]@{
    Snapshot = $snapshot
    SnapshotFile = $snapshotFile
    SnapshotDir = $snapshotDir
  }
}

function Get-LatestSnapshotFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SnapshotRoot
  )

  $tradeDate = (Get-Date).ToString("yyyyMMdd")
  $snapshotDir = Join-Path $SnapshotRoot $tradeDate
  if (-not (Test-Path -LiteralPath $snapshotDir)) {
    return $null
  }

  Get-ChildItem -LiteralPath $snapshotDir -Filter "snapshot_*.json" -ErrorAction SilentlyContinue |
    Sort-Object Name |
    Select-Object -Last 1
}

function Convert-SnapshotRowsToQuoteRows {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$SnapshotRows
  )

  @($SnapshotRows | ForEach-Object {
    [pscustomobject]@{
      f12 = [string]$_.code
      f14 = [string]$_.name
      f2 = $_.price
      f3 = $_.pct
      f62 = $_.main_flow
      f184 = $_.main_ratio
      f66 = $_.super_flow
      f138 = $_.super_in
      f139 = $_.super_out
      f69 = $_.super_ratio
      f72 = $_.large_flow
      f141 = $_.large_in
      f142 = $_.large_out
      f75 = $_.large_ratio
      f78 = $_.medium_flow
      f81 = $_.medium_ratio
      f84 = $_.small_flow
      f87 = $_.small_ratio
    }
  })
}

function Test-MissingValue($value) {
  if ($null -eq $value) { return $true }
  if ($value -is [string] -and ($value -eq "-" -or $value.Trim() -eq "")) { return $true }
  return $false
}

function Format-CnyWan($value) {
  if (Test-MissingValue $value) { return "--" }
  $num = [double]$value
  if ([Math]::Abs($num) -ge 100000000) { return ("{0:N2}亿元" -f ($num / 100000000)) }
  return ("{0:N2}万元" -f ($num / 10000))
}

function Format-Pct($value) {
  if (Test-MissingValue $value) { return "--" }
  return ("{0:N2}%" -f ([double]$value))
}

function Format-ColoredPct($value) {
  if (Test-MissingValue $value) { return "--" }
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

function Format-SignedCny($value) {
  if (Test-MissingValue $value) { return "--" }
  $num = [double]$value
  $prefix = if ($num -gt 0) { "+" } else { "" }
  if ([Math]::Abs($num) -ge 100000000) { return ("{0}{1:N2}亿元" -f $prefix, ($num / 100000000)) }
  return ("{0}{1:N2}万元" -f $prefix, ($num / 10000))
}

function Format-ColoredSignedCny($value) {
  if (Test-MissingValue $value) { return "--" }
  $num = [double]$value
  $text = Format-SignedCny $value
  if ($num -gt 0) {
    return "<font color=`"red`">$text</font>"
  }
  if ($num -lt 0) {
    return "<font color=`"green`">$text</font>"
  }
  return "<font color=`"grey`">$text</font>"
}

function Format-AbsoluteCny($value) {
  if (Test-MissingValue $value) { return "--" }
  $num = [Math]::Abs([double]$value)
  if ($num -ge 100000000) { return ("{0:N2}亿元" -f ($num / 100000000)) }
  return ("{0:N2}万元" -f ($num / 10000))
}

function Format-ColoredAbsoluteCny {
  param(
    $Value,

    [Parameter(Mandatory = $true)]
    [ValidateSet("red", "green", "grey")]
    [string]$Color
  )

  if (Test-MissingValue $Value) { return "--" }
  $text = Format-AbsoluteCny $Value
  return "<font color=`"$Color`">$text</font>"
}

function Format-DeltaText($delta) {
  $num = [double]$delta
  if ([Math]::Abs($num) -lt 1000000) { return "基本持平" }
  if ($num -gt 0) { return "改善 $(Format-SignedCny $num)" }
  return "恶化 $(Format-SignedCny $num)"
}

function Format-OrderFlowSegment {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Label,

    $Flow,

    $Ratio
  )

  "$Label **$(Format-ColoredSignedCny $Flow) / $(Format-Pct $Ratio)**"
}

function Format-MidSmallFlowSegment {
  param(
    $MediumFlow,
    $MediumRatio,
    $SmallFlow,
    $SmallRatio
  )

  $midSmallFlow = [double]$MediumFlow + [double]$SmallFlow
  $midSmallRatio = [double]$MediumRatio + [double]$SmallRatio
  Format-OrderFlowSegment -Label "中小单" -Flow $midSmallFlow -Ratio $midSmallRatio
}

function Get-MainFlowSummary {
  param(
    $MainFlow,
    $SuperIn,
    $SuperOut,
    $LargeIn,
    $LargeOut
  )

  if ((Test-MissingValue $SuperIn) -or (Test-MissingValue $SuperOut) -or (Test-MissingValue $LargeIn) -or (Test-MissingValue $LargeOut)) {
    return "主力总流入：**--** ｜ 主力总流出：**--**"
  }

  $inflow = [double]$SuperIn + [double]$LargeIn
  $outflow = [double]$SuperOut + [double]$LargeOut
  $net = if (Test-MissingValue $MainFlow) { $null } else { [Math]::Abs([double]$MainFlow) }

  if (($inflow -lt 0) -or ($outflow -lt 0)) {
    return "主力总流入：**--** ｜ 主力总流出：**--**"
  }

  if (($null -ne $net) -and (($inflow + $outflow) -lt $net)) {
    return "主力总流入：**--** ｜ 主力总流出：**--**"
  }

  "主力总流入：**$(Format-ColoredAbsoluteCny -Value $inflow -Color "red")** ｜ 主力总流出：**$(Format-ColoredAbsoluteCny -Value $outflow -Color "green")**"
}
