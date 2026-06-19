param(
  [string]$Code = "002594",
  [string]$Name = "BYD",
  [string]$DataRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) "data"),
  [int]$MaxField = 260
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Holdings.ps1")

function Invoke-EastmoneyProbeJson {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Uri,

    [hashtable]$Headers,

    [ValidateRange(1, 10)]
    [int]$MaxAttempts = 3,

    [ValidateRange(1, 30)]
    [int]$RetryDelaySeconds = 3
  )

  $lastError = $null
  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    try {
      return Invoke-RestMethod -Uri $Uri -Headers $Headers -TimeoutSec 20
    } catch {
      $lastError = $_.Exception.Message
      if ($attempt -ge $MaxAttempts) {
        throw "Probe request failed after $attempt attempts: $lastError"
      }
      Start-Sleep -Seconds $RetryDelaySeconds
    }
  }
}

if (-not ($Code -match "^\d{6}$")) {
  throw "Stock code must be 6 digits: $Code"
}

$marketPrefix = Get-QuoteMarketPrefix -Code $Code
$secId = "$marketPrefix.$Code"
$probeDir = Join-Path $DataRoot "field_probe"
New-Item -ItemType Directory -Force -Path $probeDir | Out-Null

function New-FieldBatch {
  param(
    [int]$Start,
    [int]$End
  )

  $fields = New-Object System.Collections.Generic.List[string]
  for ($i = $Start; $i -le $End; $i++) {
    $fields.Add("f$i")
  }
  return ($fields -join ",")
}

$headers = @{
  "User-Agent" = "Mozilla/5.0"
  "Referer" = "https://quote.eastmoney.com/"
}

$allProps = [ordered]@{}
for ($start = 1; $start -le $MaxField; $start += 40) {
  $end = [Math]::Min($start + 39, $MaxField)
  $fields = New-FieldBatch -Start $start -End $end
  $query = "fltt=2&invt=2&fields=$fields&secid=$secId"
  $uri = "https://push2.eastmoney.com/api/qt/stock/get?$query"
  $response = Invoke-EastmoneyProbeJson -Uri $uri -Headers $headers
  foreach ($prop in $response.data.PSObject.Properties) {
    $allProps[$prop.Name] = $prop.Value
  }
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$jsonPath = Join-Path $probeDir ("eastmoney_fields_{0}_{1}.json" -f $Code, $timestamp)
$txtPath = Join-Path $probeDir ("eastmoney_fields_{0}_{1}.txt" -f $Code, $timestamp)

[pscustomobject]@{
  code = $Code
  name = $Name
  secid = $secId
  captured_at = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  fields = $allProps
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("code=$Code")
$lines.Add("name=$Name")
$lines.Add("secid=$secId")
$lines.Add("captured_at=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$lines.Add("")
foreach ($entry in $allProps.GetEnumerator() | Sort-Object Name) {
  if ($null -eq $entry.Value) { continue }
  $text = [string]$entry.Value
  if ($text.Trim() -eq "") { continue }
  $lines.Add(("{0}={1}" -f $entry.Key, $entry.Value))
}
$lines | Set-Content -LiteralPath $txtPath -Encoding UTF8

Write-Output "Field probe saved:"
Write-Output $jsonPath
Write-Output $txtPath
