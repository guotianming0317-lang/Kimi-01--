param(
  [Parameter(Mandatory = $true)]
  [string]$WatchFile,

  [string]$HoldingsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "data\holdings.csv"),

  [string]$BlockName = "HELD_POSITIONS"
)

$ErrorActionPreference = "Stop"
$replacement = Join-Path $PSScriptRoot "Update-HeldStockWatchlist.ps1"

Write-Warning "Update-SemiconductorWatchlist.ps1 已兼容转向：现在同步的是已持仓股票，不再维护半导体产业链池。"
& $replacement -WatchFile $WatchFile -HoldingsPath $HoldingsPath -BlockName $BlockName
