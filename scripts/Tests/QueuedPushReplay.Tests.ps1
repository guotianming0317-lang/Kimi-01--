$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptsRoot = Join-Path $repoRoot "scripts"

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Message
  )

  if (-not $Condition) {
    throw $Message
  }
}

function New-TestDir {
  $path = Join-Path ([System.IO.Path]::GetTempPath()) ("queued-replay-tests_{0}" -f ([guid]::NewGuid().ToString("N")))
  New-Item -ItemType Directory -Force -Path $path | Out-Null
  return $path
}

$testDir = New-TestDir
try {
  $staleQueueRoot = Join-Path $testDir "stale_queue"
  New-Item -ItemType Directory -Force -Path $staleQueueRoot | Out-Null

  [pscustomobject]@{
    title = "stale close message"
    template = "orange"
    content = "stale payload"
    queued_at = "2026-07-14T15:32:00+08:00"
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $staleQueueRoot "queued_push_stale.json") -Encoding UTF8

  $staleOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "Replay-PendingFeishuPushes.ps1") `
    -QueueRoot $staleQueueRoot `
    -CurrentTime ([datetime]"2026-07-15 09:26:00") 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Replay script should keep running when stale items are dropped."
  }

  $staleText = $staleOutput -join "`n"
  Assert-True ($staleText -match "Dropped stale queued push from previous day") "Replay should drop previous-day queued pushes."
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $staleQueueRoot "queued_push_stale.json"))) "Dropped stale queue item should not remain for later replay."

  $freshQueueRoot = Join-Path $testDir "fresh_queue"
  New-Item -ItemType Directory -Force -Path $freshQueueRoot | Out-Null

  [pscustomobject]@{
    title = "fresh opening auction"
    template = "purple"
    content = "fresh payload"
    queued_at = "2026-07-15T09:20:00+08:00"
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $freshQueueRoot "queued_push_fresh.json") -Encoding UTF8

  $freshOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "Replay-PendingFeishuPushes.ps1") `
    -QueueRoot $freshQueueRoot `
    -CurrentTime ([datetime]"2026-07-15 09:26:00") 2>&1

  $freshText = $freshOutput -join "`n"
  Assert-True (-not ($freshText -match "Dropped stale queued push from previous day")) "Same-day queued pushes should not be mistaken for stale items."
  Assert-True ((Test-Path -LiteralPath (Join-Path $freshQueueRoot "queued_push_fresh.json"))) "Fresh queue item should remain when send fails in test environment."

  Write-Output "All queued replay tests passed."
} finally {
  if (Test-Path -LiteralPath $testDir) {
    Remove-Item -LiteralPath $testDir -Recurse -Force
  }
}
