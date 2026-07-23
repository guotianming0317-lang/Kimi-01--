$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Holdings.ps1")

function ConvertTo-TushareTsCode {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Code
  )

  if (-not ($Code -match '^\d{6}$')) {
    throw "Invalid stock code for Tushare conversion: $Code"
  }

  if ($Code.StartsWith("6")) {
    return "$Code.SH"
  }
  return "$Code.SZ"
}

function ConvertTo-TushareTradeDate {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Value
  )

  $text = ([string]$Value).Trim()
  if ($text -match '^\d{8}$') {
    return $text
  }

  try {
    return (Get-Date $text -Format "yyyyMMdd")
  } catch {
    throw "Invalid Tushare trade date: $Value"
  }
}

function Read-SimpleEnvFile {
  param(
    [string]$Path = ""
  )

  $map = @{}
  if ((-not $Path) -or (-not (Test-Path -LiteralPath $Path))) {
    return $map
  }

  foreach ($line in @(Get-Content -LiteralPath $Path -Encoding UTF8)) {
    $text = ([string]$line).Trim()
    if ((-not $text) -or $text.StartsWith("#")) {
      continue
    }

    $pair = $text -split "=", 2
    if ($pair.Count -lt 2) {
      continue
    }

    $key = ([string]$pair[0]).Trim()
    $value = ([string]$pair[1]).Trim()
    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
      $value = $value.Substring(1, $value.Length - 2)
    }
    if ($key) {
      $map[$key] = $value
    }
  }

  return $map
}

function Read-SimpleConfigJson {
  param(
    [string]$Path = ""
  )

  $map = @{}
  if ((-not $Path) -or (-not (Test-Path -LiteralPath $Path))) {
    return $map
  }

  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($property in $raw.PSObject.Properties) {
    $map[$property.Name] = $property.Value
  }
  return $map
}

function ConvertTo-ConfigBool {
  param(
    [AllowNull()]
    [object]$Value,

    [bool]$Default = $false
  )

  if ($null -eq $Value) {
    return $Default
  }

  $text = ([string]$Value).Trim().ToLowerInvariant()
  switch ($text) {
    "1" { return $true }
    "true" { return $true }
    "yes" { return $true }
    "on" { return $true }
    "0" { return $false }
    "false" { return $false }
    "no" { return $false }
    "off" { return $false }
    default { return $Default }
  }
}

function Get-TushareConfig {
  param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$EnvPath = "",
    [string]$ConfigPath = ""
  )

  if (-not $EnvPath) {
    $EnvPath = Join-Path $ProjectRoot ".env"
  }
  if (-not $ConfigPath) {
    $ConfigPath = Join-Path $ProjectRoot "config.json"
  }

  $jsonConfig = Read-SimpleConfigJson -Path $ConfigPath
  $envFileConfig = Read-SimpleEnvFile -Path $EnvPath

  $token = [Environment]::GetEnvironmentVariable("TUSHARE_TOKEN")
  if (-not $token -and $envFileConfig.ContainsKey("TUSHARE_TOKEN")) {
    $token = [string]$envFileConfig["TUSHARE_TOKEN"]
  }
  if (-not $token -and $jsonConfig.ContainsKey("TUSHARE_TOKEN")) {
    $token = [string]$jsonConfig["TUSHARE_TOKEN"]
  }

  $enabledRaw = [Environment]::GetEnvironmentVariable("TUSHARE_ENABLED")
  if (-not $enabledRaw -and $envFileConfig.ContainsKey("TUSHARE_ENABLED")) {
    $enabledRaw = $envFileConfig["TUSHARE_ENABLED"]
  }
  if (($null -eq $enabledRaw -or [string]$enabledRaw -eq "") -and $jsonConfig.ContainsKey("TUSHARE_ENABLED")) {
    $enabledRaw = $jsonConfig["TUSHARE_ENABLED"]
  }

  $tradeDateRaw = [Environment]::GetEnvironmentVariable("TUSHARE_TRADE_DATE")
  if (-not $tradeDateRaw -and $envFileConfig.ContainsKey("TUSHARE_TRADE_DATE")) {
    $tradeDateRaw = [string]$envFileConfig["TUSHARE_TRADE_DATE"]
  }
  if (-not $tradeDateRaw -and $jsonConfig.ContainsKey("TUSHARE_TRADE_DATE")) {
    $tradeDateRaw = [string]$jsonConfig["TUSHARE_TRADE_DATE"]
  }

  [pscustomobject]@{
    token = $token
    enabled = ConvertTo-ConfigBool -Value $enabledRaw -Default $false
    trade_date = if ($tradeDateRaw) { ConvertTo-TushareTradeDate -Value $tradeDateRaw } else { $null }
    env_path = $EnvPath
    config_path = $ConfigPath
  }
}

function Get-TushareFieldValue {
  param(
    [hashtable]$FieldMap = @{},
    [string[]]$Aliases = @()
  )

  foreach ($alias in $Aliases) {
    if ($FieldMap.ContainsKey($alias)) {
      return $FieldMap[$alias]
    }
  }
  return $null
}

function ConvertFrom-TushareDailyResponse {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Response,

    [Parameter(Mandatory = $true)]
    [object[]]$Holdings,

    [Parameter(Mandatory = $true)]
    [string]$TradeDate,

    [datetimeoffset]$SourceTime = ([datetimeoffset]::Now)
  )

  $targetDate = ConvertTo-TushareTradeDate -Value $TradeDate
  $sourceText = $SourceTime.ToString("yyyy-MM-ddTHH:mm:sszzz")
  $holdingMap = @{}
  foreach ($holding in $Holdings) {
    $holdingMap[[string]$holding.Code] = $holding
  }

  $responseFields = @($Response.data.fields)
  $responseItems = @($Response.data.items)
  $rowsByCode = @{}

  foreach ($row in $responseItems) {
    $fieldMap = @{}
    for ($index = 0; $index -lt $responseFields.Count; $index++) {
      $fieldMap[[string]$responseFields[$index]] = if ($index -lt $row.Count) { $row[$index] } else { $null }
    }

    $tsCode = [string](Get-TushareFieldValue -FieldMap $fieldMap -Aliases @("ts_code", "code"))
    if (-not $tsCode) {
      continue
    }
    $baseCode = ($tsCode -split "\.")[0]
    if ($holdingMap.ContainsKey($baseCode)) {
      $rowsByCode[$baseCode] = $fieldMap
    }
  }

  $volumeAliases = @(
    "ah_vol",
    "after_hours_volume",
    "after_volume",
    "after_vol",
    "post_volume",
    "post_vol",
    "after_trade_volume",
    "after_trade_vol"
  )
  $amountAliases = @(
    "ah_amount",
    "after_hours_amount",
    "after_amount",
    "post_amount",
    "after_trade_amount"
  )

  $items = @()
  foreach ($holding in $Holdings) {
    $code = [string]$holding.Code
    $name = [string]$holding.Name
    $market = if ($code.StartsWith("6")) { "SH" } else { "SZ" }
    $fieldMap = if ($rowsByCode.ContainsKey($code)) { $rowsByCode[$code] } else { @{} }
    $closeValue = Get-TushareFieldValue -FieldMap $fieldMap -Aliases @("close")
    $volumeValue = Get-TushareFieldValue -FieldMap $fieldMap -Aliases $volumeAliases
    $amountValue = Get-TushareFieldValue -FieldMap $fieldMap -Aliases $amountAliases
    $rowTradeDate = [string](Get-TushareFieldValue -FieldMap $fieldMap -Aliases @("trade_date"))

    $hasAfterHoursFields = $false
    foreach ($alias in @($volumeAliases + $amountAliases)) {
      if ($fieldMap.ContainsKey($alias)) {
        $hasAfterHoursFields = $true
        break
      }
    }

    $status = "missing_after_hours_fields"
    $afterVolume = $null
    $afterAmount = $null

    if ($hasAfterHoursFields) {
      $afterVolume = if ($null -ne $volumeValue -and [string]$volumeValue -ne "") { [double]$volumeValue } else { $null }
      # Tushare Pro daily after-hours amount is returned in thousands of CNY.
      $afterAmount = if ($null -ne $amountValue -and [string]$amountValue -ne "") { [double]$amountValue * 1000.0 } else { $null }

      if (($null -eq $afterVolume) -or ($null -eq $afterAmount)) {
        $status = "missing_after_hours_fields"
      } elseif (($afterVolume -le 0) -and ($afterAmount -le 0)) {
        $status = "no_after_hours_trade"
      } else {
        $status = "ok"
      }
    }

    if ($status -eq "missing_after_hours_fields") {
      $afterVolume = 0
      $afterAmount = 0
    }

    $closeNumber = if ($null -ne $closeValue -and [string]$closeValue -ne "") { [double]$closeValue } else { $null }
    $items += [pscustomobject]@{
      code = $code
      name = $name
      market = $market
      trade_date = if ($rowTradeDate) { $rowTradeDate } else { $targetDate }
      close = $closeNumber
      after_hours_volume = [double]$afterVolume
      after_hours_amount = [double]$afterAmount
      source = "tushare"
      source_time = $sourceText
      data_status = $status
    }
  }

  return @($items)
}

function Save-TushareAfterHoursExternalData {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Items,

    [Parameter(Mandatory = $true)]
    [string]$TargetPath
  )

  $targetFullPath = [System.IO.Path]::GetFullPath($TargetPath)
  $targetDir = Split-Path -Parent $targetFullPath
  if (-not (Test-Path -LiteralPath $targetDir)) {
    New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
  }

  $encoding = New-Object System.Text.UTF8Encoding($true)
  [System.IO.File]::WriteAllText($targetFullPath, ($Items | ConvertTo-Json -Depth 8), $encoding)
  return $targetFullPath
}

function Invoke-TushareDailyRequest {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Token,

    [Parameter(Mandatory = $true)]
    [string]$TradeDate
  )

  $body = @{
    api_name = "daily"
    token = $Token
    params = @{
      trade_date = (ConvertTo-TushareTradeDate -Value $TradeDate)
    }
    fields = "ts_code,trade_date,close,ah_vol,ah_amount"
  } | ConvertTo-Json -Depth 6

  Invoke-RestMethod -Method Post -Uri "https://api.tushare.pro" -ContentType "application/json" -Body $body -TimeoutSec 40
}
