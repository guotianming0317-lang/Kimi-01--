param(
  [Parameter(Mandatory = $true)]
  [string]$SourcePath,

  [string]$TargetPath = ""
)

$ErrorActionPreference = "Stop"

if (-not $TargetPath) {
  $TargetPath = Join-Path (Split-Path -Parent $PSScriptRoot) "data\after_hours_external.latest.json"
}

if (-not (Test-Path -LiteralPath $SourcePath)) {
  throw "External after-hours data file not found: $SourcePath"
}

$sourceFullPath = [System.IO.Path]::GetFullPath($SourcePath)
$targetFullPath = [System.IO.Path]::GetFullPath($TargetPath)
$targetDir = Split-Path -Parent $targetFullPath
if (-not (Test-Path -LiteralPath $targetDir)) {
  New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
}

$raw = Get-Content -LiteralPath $sourceFullPath -Raw -Encoding UTF8 | ConvertFrom-Json
$items = @()
foreach ($item in @($raw)) {
  $code = ([string]$item.code).Trim()
  if (-not ($code -match '^\d{6}$')) {
    throw "Invalid stock code in external after-hours data: $code"
  }

  $items += [pscustomobject]@{
    code = $code
    source = if ($item.PSObject.Properties.Name -contains "source" -and $item.source) { [string]$item.source } else { "external_import" }
    supported = if ($item.PSObject.Properties.Name -contains "supported") { [bool]$item.supported } else { $true }
    volume = $item.volume
    amount = $item.amount
  }
}

$encoding = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($targetFullPath, ($items | ConvertTo-Json -Depth 6), $encoding)

Write-Output ("Imported after-hours external data: {0}" -f $targetFullPath)
