$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$pauseFlag = Join-Path $root "data\monitoring_paused.flag"

if (Test-Path -LiteralPath $pauseFlag) {
  Remove-Item -LiteralPath $pauseFlag -Force
  Write-Output "Monitoring resumed."
} else {
  Write-Output "Monitoring was not paused."
}
