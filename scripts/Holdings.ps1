$ErrorActionPreference = "Stop"

function Import-HeldStocks {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    throw "持仓清单不存在：$Path"
  }

  $rows = @(Import-Csv -LiteralPath $Path -Encoding UTF8)
  if (-not $rows) {
    throw "持仓清单为空：$Path"
  }

  $seen = @{}
  $items = @()
  foreach ($row in $rows) {
    $code = ([string]$row.Code).Trim()
    $name = ([string]$row.Name).Trim()
    $focusLevel = Resolve-FocusLevel -Value $row.FocusLevel
    $prevCloseMode = Resolve-PrevCloseMode -Value $row.PrevCloseMode

    if (-not ($code -match "^\d{6}$")) {
      throw "持仓清单存在无效股票代码：$code"
    }
    if (-not $name) {
      throw "持仓清单中 $code 缺少股票名称"
    }
    if ($seen.ContainsKey($code)) {
      continue
    }

    $seen[$code] = $true
    $items += [pscustomobject]@{
      Code = $code
      Name = $name
      FocusLevel = $focusLevel
      PrevCloseMode = $prevCloseMode
      SecId = "$(Get-QuoteMarketPrefix $code).$code"
      ThsMarket = Get-ThsMarketCode $code
    }
  }

  return @($items)
}

function Resolve-FocusLevel {
  param(
    [AllowNull()]
    [object]$Value
  )

  $text = ([string]$Value).Trim().ToLowerInvariant()
  switch ($text) {
    "high" { return "high" }
    "重点" { return "high" }
    "high_priority" { return "high" }
    "normal" { return "normal" }
    "普通" { return "normal" }
    default {
      if ($text) {
        return "normal"
      }
      return "normal"
    }
  }
}

function Resolve-PrevCloseMode {
  param(
    [AllowNull()]
    [object]$Value
  )

  $text = ([string]$Value).Trim().ToLowerInvariant()
  switch ($text) {
    "qfq" { return "qfq" }
    "forward" { return "qfq" }
    "forward_adjusted" { return "qfq" }
    "前复权" { return "qfq" }
    default { return "raw" }
  }
}

function Get-QuoteMarketPrefix {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Code
  )

  if ($Code -match "^[56]") {
    return "1"
  }
  return "0"
}

function Get-ThsMarketCode {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Code
  )

  if ($Code.StartsWith("6")) {
    return "USHA"
  }
  if ($Code.StartsWith("9")) {
    return "USTM"
  }
  return "USZA"
}
