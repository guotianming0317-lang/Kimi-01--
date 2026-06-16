$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $PSScriptRoot "Run-FormalReplayPush.ps1"
if (-not (Test-Path -LiteralPath $runner)) {
  throw "Runner not found: $runner"
}

$taskPrefix = "AStockMainFundFeishuPush"
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$action = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$runner`""

$tasks = @(
  @{ Name = "$taskPrefix-Morning"; Start = "09:30"; Duration = "02:01" },
  @{ Name = "$taskPrefix-Afternoon"; Start = "13:00"; Duration = "02:01" }
)

foreach ($task in $tasks) {
  $taskName = "\$($task.Name)"
  schtasks.exe /Create /F `
    /TN $taskName `
    /SC WEEKLY `
    /D MON,TUE,WED,THU,FRI `
    /ST $task.Start `
    /RI 30 `
    /DU $task.Duration `
    /TR $action | Write-Output

  if ($LASTEXITCODE -ne 0) {
    throw "Failed to create scheduled task: $taskName"
  }

  schtasks.exe /Query /TN $taskName /FO LIST | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Scheduled task was not found after creation: $taskName"
  }
}

Write-Output "Installed Windows scheduled tasks for A-share main-fund Feishu push."
