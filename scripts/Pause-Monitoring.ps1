$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$dataRoot = Join-Path $root "data"
$pauseFlag = Join-Path $dataRoot "monitoring_paused.flag"

New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null
"Paused on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') by user request." |
  Set-Content -LiteralPath $pauseFlag -Encoding UTF8

Write-Output "Monitoring paused: $pauseFlag"
