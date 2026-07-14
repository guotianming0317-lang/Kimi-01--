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

function Invoke-JsonHttpFallback {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Uri,

    [hashtable]$Headers = @{},

    [int]$TimeoutSec = 20
  )

  $handler = New-Object System.Net.Http.HttpClientHandler
  $client = New-Object System.Net.Http.HttpClient($handler)
  try {
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    foreach ($key in $Headers.Keys) {
      [void]$client.DefaultRequestHeaders.TryAddWithoutValidation([string]$key, [string]$Headers[$key])
    }

    $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
    $response.EnsureSuccessStatusCode() | Out-Null
    $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if (-not $content) {
      throw "empty response content"
    }
    return ($content | ConvertFrom-Json)
  } finally {
    $client.Dispose()
    $handler.Dispose()
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
        return Invoke-JsonHttpFallback -Uri $Uri -Headers $Headers -TimeoutSec 20
      } catch {
        $lastError = "$irmError; http fallback: $($_.Exception.Message)"
      }
      if ($attempt -ge $MaxAttempts) {
        throw "Eastmoney request failed after $attempt attempts: $lastError"
      }
      Start-Sleep -Seconds $RetryDelaySeconds
    }
  }
}

function Invoke-HiddenConsoleCommand {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [string[]]$Arguments = @()
  )

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $escapedArgs = @($Arguments | ForEach-Object {
    $value = [string]$_
    if ($value -match '[\s"]') {
      '"' + ($value -replace '"', '\"') + '"'
    } else {
      $value
    }
  })
  $psi.Arguments = ($escapedArgs -join ' ')

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $psi
  [void]$process.Start()
  $stdout = $process.StandardOutput.ReadToEnd()
  $stderr = $process.StandardError.ReadToEnd()
  $process.WaitForExit()

  [pscustomobject]@{
    ExitCode = $process.ExitCode
    StdOut = $stdout
    StdErr = $stderr
  }
}

function ConvertTo-PowershellArgumentList {
  param(
    [hashtable]$Parameters = @{}
  )

  $args = New-Object System.Collections.Generic.List[string]
  foreach ($entry in @($Parameters.GetEnumerator() | Sort-Object Name)) {
    $name = [string]$entry.Key
    $value = $entry.Value
    if ($value -is [System.Management.Automation.SwitchParameter]) {
      if ([bool]$value.IsPresent) {
        $args.Add("-$name")
      }
      continue
    }
    if ($value -is [bool]) {
      if ([bool]$value) {
        $args.Add("-$name")
      }
      continue
    }
    if ($null -eq $value) {
      continue
    }
    $args.Add("-$name")
    $args.Add([string]$value)
  }
  return @($args)
}

function Invoke-HiddenPowershellScript {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptPath,

    [hashtable]$Parameters = @{}
  )

  if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "PowerShell script not found: $ScriptPath"
  }

  $powershell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
  $arguments = New-Object System.Collections.Generic.List[string]
  $arguments.Add("-NoProfile")
  $arguments.Add("-ExecutionPolicy")
  $arguments.Add("Bypass")
  $arguments.Add("-File")
  $arguments.Add($ScriptPath)
  foreach ($item in @(ConvertTo-PowershellArgumentList -Parameters $Parameters)) {
    $arguments.Add([string]$item)
  }

  $result = Invoke-HiddenConsoleCommand -FilePath $powershell -Arguments @($arguments)
  if ($result.ExitCode -ne 0) {
    $detail = if ($result.StdErr) { $result.StdErr.Trim() } elseif ($result.StdOut) { $result.StdOut.Trim() } else { "exit code $($result.ExitCode)" }
    throw "Hidden PowerShell script failed: $detail"
  }
  return $result
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
      $detailMap = @{}
      try {
        $detailMap = Get-HeldQuoteDetailMap -Holdings $Holdings
        if ($detailMap.Count -gt 0) {
          Save-HeldQuoteDetailCache -DetailMap $detailMap | Out-Null
        }
      } catch {
        # Detail flow fields are optional for report enrichment.
      }

      $cachedDetailMap = Get-LatestHeldQuoteDetailCacheMap -Codes @($Holdings | ForEach-Object { [string]$_.Code })
      foreach ($code in $cachedDetailMap.Keys) {
        if ((-not $detailMap.ContainsKey($code)) -or (-not (Test-HasResolvedMainFlowDetail -Detail $detailMap[$code]))) {
          $detailMap[$code] = $cachedDetailMap[$code]
        }
      }

      if ($detailMap.Count -gt 0) {
        Merge-HeldQuoteDetailFields -Rows $valid -DetailMap $detailMap
      }
    } catch {
      # Never let optional detail enrichment block the base quote snapshot.
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

function Get-DetailCacheRoot {
  $projectRoot = Split-Path -Parent $PSScriptRoot
  Join-Path $projectRoot "data\detail_cache"
}

function Save-HeldQuoteDetailCache {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$DetailMap
  )

  if ($DetailMap.Count -eq 0) {
    return $null
  }

  $detailDir = Get-DetailCacheRoot
  New-Item -ItemType Directory -Force -Path $detailDir | Out-Null
  $detailFile = Join-Path $detailDir ("held_detail_runtime_{0}.json" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
  $items = foreach ($code in ($DetailMap.Keys | Sort-Object)) {
    $detail = $DetailMap[$code]
    [pscustomobject]@{
      code = [string]$code
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
  $items | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $detailFile -Encoding UTF8
  return $detailFile
}

function Get-LatestHeldQuoteDetailCacheMap {
  param(
    [string[]]$Codes = @()
  )

  $detailDir = Get-DetailCacheRoot
  if (-not (Test-Path -LiteralPath $detailDir)) {
    return @{}
  }

  $latestFile = Get-ChildItem -LiteralPath $detailDir -Filter "held_detail*.json" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if ($null -eq $latestFile) {
    return @{}
  }

  try {
    $raw = Get-Content -LiteralPath $latestFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $map = @{}
    foreach ($item in @($raw)) {
      $code = [string]$item.code
      if ($Codes.Count -gt 0 -and $Codes -notcontains $code) {
        continue
      }
      $map[$code] = $item
    }
    return $map
  } catch {
    return @{}
  }
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
  $needsRetry = New-Object System.Collections.Generic.List[object]

  foreach ($holding in $Holdings) {
    $uri = "https://push2.eastmoney.com/api/qt/stock/get?fltt=2&invt=2&fields=$detailFields&secid=$($holding.SecId)"
    try {
      $response = Invoke-EastmoneyJson -Uri $uri -Headers $headers
      if ($response.data) {
        $map[[string]$holding.Code] = $response.data
        if (-not (Test-HasResolvedMainFlowDetail -Detail $response.data)) {
          $needsRetry.Add($holding)
        }
      } else {
        $errors.Add("$($holding.Code): empty detail payload")
      }
    } catch {
      $errors.Add("$($holding.Code): $($_.Exception.Message)")
    }
  }

  if ($needsRetry.Count -gt 0) {
    Start-Sleep -Seconds 1
    foreach ($holding in $needsRetry) {
      $uri = "https://push2.eastmoney.com/api/qt/stock/get?fltt=2&invt=2&fields=$detailFields&secid=$($holding.SecId)"
      try {
        $retryResponse = Invoke-EastmoneyJson -Uri $uri -Headers $headers
        if ($retryResponse.data -and (Test-HasResolvedMainFlowDetail -Detail $retryResponse.data)) {
          $map[[string]$holding.Code] = $retryResponse.data
        }
      } catch {
        # Keep the first-pass payload; the caller can still render partial data.
      }
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

  if (-not (Test-Path -LiteralPath $SnapshotRoot)) {
    return $null
  }

  $tradeDate = (Get-Date).ToString("yyyyMMdd")
  $snapshotDir = Join-Path $SnapshotRoot $tradeDate
  if (Test-Path -LiteralPath $snapshotDir) {
    $sameDaySnapshot = Get-ChildItem -LiteralPath $snapshotDir -Filter "snapshot_*.json" -ErrorAction SilentlyContinue |
      Sort-Object Name |
      Select-Object -Last 1
    if ($null -ne $sameDaySnapshot) {
      return $sameDaySnapshot
    }
  }

  Get-ChildItem -LiteralPath $SnapshotRoot -Directory -ErrorAction SilentlyContinue |
    ForEach-Object {
      Get-ChildItem -LiteralPath $_.FullName -Filter "snapshot_*.json" -ErrorAction SilentlyContinue
    } |
    Sort-Object LastWriteTime, FullName |
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

function Get-SafeDoubleOrNull {
  param($Value)

  if (Test-MissingValue $Value) {
    return $null
  }

  if ($Value -is [double] -or $Value -is [float] -or $Value -is [decimal] -or $Value -is [int] -or $Value -is [long]) {
    return [double]$Value
  }

  $text = [string]$Value
  $styles = [Globalization.NumberStyles]::Float -bor [Globalization.NumberStyles]::AllowThousands
  $parsed = 0.0
  if ([double]::TryParse($text, $styles, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
    return $parsed
  }
  if ([double]::TryParse($text, $styles, [Globalization.CultureInfo]::CurrentCulture, [ref]$parsed)) {
    return $parsed
  }

  return $null
}

function Get-SafeDouble {
  param(
    $Value,
    [double]$Default = 0
  )

  $parsed = Get-SafeDoubleOrNull $Value
  if ($null -eq $parsed) {
    return $Default
  }
  return [double]$parsed
}

function Get-SafeSum {
  param(
    [object[]]$Items,

    [Parameter(Mandatory = $true)]
    [string]$PropertyName
  )

  $sum = 0.0
  if ($null -eq $Items) {
    return $sum
  }
  foreach ($item in $Items) {
    $sum += Get-SafeDouble (Select-Object -InputObject $item -ExpandProperty $PropertyName -ErrorAction SilentlyContinue)
  }
  return $sum
}

function Get-UserFriendlyReportError {
  param(
    [string]$Message
  )

  if ([string]::IsNullOrWhiteSpace($Message)) {
    return "未知原因"
  }

  $clean = $Message.Trim()
  $jsonStart = $clean.IndexOf('{"')
  if ($jsonStart -lt 0) {
    $jsonStart = $clean.IndexOf('{')
  }
  if ($jsonStart -gt 0) {
    $clean = $clean.Substring(0, $jsonStart).TrimEnd()
  }

  if ($clean -match "Eastmoney request failed after \d+ attempts:\s*(.+)$") {
    $clean = $Matches[1].Trim()
  }

  $clean = $clean -replace "\s*;\s*curl fallback:\s*", "；curl 兜底失败："
  $clean = $clean -replace "基础连接已经关闭: 连接被意外关闭。", "连接被远端中断。"
  $clean = $clean -replace "无法连接到远程服务器", "无法连接到远程服务器。"
  $clean = $clean -replace '传入的对象无效，应为“:”或“}”。\s*(\(\d+\):)?', "返回内容解析失败。"
  $clean = $clean -replace "\s+", " "
  $clean = $clean.Trim(" ", ";", "；")

  if ([string]::IsNullOrWhiteSpace($clean)) {
    return "接口返回异常"
  }

  return $clean
}

function Format-CnyWan($value) {
  $parsed = Get-SafeDoubleOrNull $value
  if ($null -eq $parsed) { return "--" }
  $num = [double]$parsed
  if ([Math]::Abs($num) -ge 100000000) { return ("{0:N2}亿元" -f ($num / 100000000)) }
  return ("{0:N2}万元" -f ($num / 10000))
}

function Format-Pct($value) {
  $parsed = Get-SafeDoubleOrNull $value
  if ($null -eq $parsed) { return "--" }
  return ("{0:N2}%" -f ([double]$parsed))
}

function Format-ColoredPct($value) {
  $parsed = Get-SafeDoubleOrNull $value
  if ($null -eq $parsed) { return "--" }
  $num = [double]$parsed
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
  $parsed = Get-SafeDoubleOrNull $value
  if ($null -eq $parsed) { return "--" }
  $num = [double]$parsed
  $prefix = if ($num -gt 0) { "+" } else { "" }
  if ([Math]::Abs($num) -ge 100000000) { return ("{0}{1:N2}亿元" -f $prefix, ($num / 100000000)) }
  return ("{0}{1:N2}万元" -f $prefix, ($num / 10000))
}

function Format-ColoredSignedCny($value) {
  $parsed = Get-SafeDoubleOrNull $value
  if ($null -eq $parsed) { return "--" }
  $num = [double]$parsed
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
  $parsed = Get-SafeDoubleOrNull $value
  if ($null -eq $parsed) { return "--" }
  $num = [Math]::Abs([double]$parsed)
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
  $num = Get-SafeDouble $delta
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

  $midSmallFlow = (Get-SafeDouble $MediumFlow) + (Get-SafeDouble $SmallFlow)
  $midSmallRatio = (Get-SafeDouble $MediumRatio) + (Get-SafeDouble $SmallRatio)
  Format-OrderFlowSegment -Label "中小单" -Flow $midSmallFlow -Ratio $midSmallRatio
}

function Resolve-OrderInOut {
  param(
    $Flow,
    $In,
    $Out
  )

  $flowValue = Get-SafeDoubleOrNull $Flow
  $inValue = Get-SafeDoubleOrNull $In
  $outValue = Get-SafeDoubleOrNull $Out

  if (($null -ne $inValue) -and ($null -ne $outValue)) {
    return [pscustomobject]@{
      IsResolved = $true
      In = [double]$inValue
      Out = [double]$outValue
    }
  }

  if ($null -eq $flowValue) {
    return [pscustomobject]@{
      IsResolved = $false
      In = $null
      Out = $null
    }
  }

  if (($null -eq $inValue) -and ($null -ne $outValue)) {
    $inValue = $flowValue + $outValue
  } elseif (($null -ne $inValue) -and ($null -eq $outValue)) {
    $outValue = $inValue - $flowValue
  } elseif (($null -eq $inValue) -and ($null -eq $outValue) -and ([Math]::Abs($flowValue) -lt 0.0001)) {
    $inValue = 0.0
    $outValue = 0.0
  }

  if (($null -eq $inValue) -or ($null -eq $outValue) -or ($inValue -lt 0) -or ($outValue -lt 0)) {
    return [pscustomobject]@{
      IsResolved = $false
      In = $null
      Out = $null
    }
  }

  [pscustomobject]@{
    IsResolved = $true
    In = [double]$inValue
    Out = [double]$outValue
  }
}

function Get-MainFlowSummary {
  param(
    $MainFlow,
    $SuperFlow,
    $SuperIn,
    $SuperOut,
    $LargeFlow,
    $LargeIn,
    $LargeOut
  )

  $superResolved = Resolve-OrderInOut -Flow $SuperFlow -In $SuperIn -Out $SuperOut
  $largeResolved = Resolve-OrderInOut -Flow $LargeFlow -In $LargeIn -Out $LargeOut

  if ((-not $superResolved.IsResolved) -or (-not $largeResolved.IsResolved)) {
    return "主力总流入：**--** ｜ 主力总流出：**--**"
  }

  $inflow = [double]$superResolved.In + [double]$largeResolved.In
  $outflow = [double]$superResolved.Out + [double]$largeResolved.Out
  $mainParsed = Get-SafeDoubleOrNull $MainFlow
  $net = if ($null -eq $mainParsed) { $null } else { [Math]::Abs([double]$mainParsed) }

  if (($inflow -lt 0) -or ($outflow -lt 0)) {
    return "主力总流入：**--** ｜ 主力总流出：**--**"
  }

  if (($null -ne $net) -and (($inflow + $outflow) -lt $net)) {
    return "主力总流入：**--** ｜ 主力总流出：**--**"
  }

  "主力总流入：**$(Format-ColoredAbsoluteCny -Value $inflow -Color "red")** ｜ 主力总流出：**$(Format-ColoredAbsoluteCny -Value $outflow -Color "green")**"
}

function Test-HasResolvedMainFlowDetail {
  param(
    $Detail
  )

  if ($null -eq $Detail) {
    return $false
  }

  $superResolved = Resolve-OrderInOut -Flow $Detail.f137 -In $Detail.f138 -Out $Detail.f139
  $largeResolved = Resolve-OrderInOut -Flow $Detail.f140 -In $Detail.f141 -Out $Detail.f142

  return ($superResolved.IsResolved -and $largeResolved.IsResolved)
}
