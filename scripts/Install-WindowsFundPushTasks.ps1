$ErrorActionPreference = "Stop"

$reportRunner = Join-Path $PSScriptRoot "Run-FormalReplayPush.ps1"
$anomalyRunner = Join-Path $PSScriptRoot "Run-AnomalyMonitor.ps1"
$replayRunner = Join-Path $PSScriptRoot "Replay-PendingFeishuPushes.ps1"
foreach ($runner in @($reportRunner, $anomalyRunner, $replayRunner)) {
  if (-not (Test-Path -LiteralPath $runner)) {
    throw "Runner not found: $runner"
  }
}

$ps = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$author = "$env:USERDOMAIN\$env:USERNAME"

function ConvertTo-XmlText {
  param([string]$Value)
  [System.Security.SecurityElement]::Escape($Value)
}

function New-TaskXml {
  param(
    [string]$StartBoundary,
    [string]$Command,
    [string]$Arguments,
    [string]$Author,
    [string]$Description,
    [string]$Interval,
    [string]$Duration
  )

  $escapedCommand = ConvertTo-XmlText $Command
  $escapedArguments = ConvertTo-XmlText $Arguments
  $escapedAuthor = ConvertTo-XmlText $Author
  $escapedDescription = ConvertTo-XmlText $Description

  @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>$escapedAuthor</Author>
    <Description>$escapedDescription</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>$StartBoundary</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByWeek>
        <DaysOfWeek>
          <Monday />
          <Tuesday />
          <Wednesday />
          <Thursday />
          <Friday />
        </DaysOfWeek>
        <WeeksInterval>1</WeeksInterval>
      </ScheduleByWeek>
      <Repetition>
        <Interval>$Interval</Interval>
        <Duration>$Duration</Duration>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>true</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <DisallowStartOnRemoteAppSession>false</DisallowStartOnRemoteAppSession>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT20M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$escapedCommand</Command>
      <Arguments>$escapedArguments</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}

$tasks = @(
  @{
    Name = "AStockMainFundFeishuPush-Morning"
    StartBoundary = "2026-01-01T09:30:00"
    Runner = $reportRunner
    Description = "Held A-share main-fund report to Feishu every 30 minutes during trading sessions"
    Interval = "PT30M"
    Duration = "PT2H1M"
  },
  @{
    Name = "AStockMainFundFeishuPush-Afternoon"
    StartBoundary = "2026-01-01T13:00:00"
    Runner = $reportRunner
    Description = "Held A-share main-fund report to Feishu every 30 minutes during trading sessions"
    Interval = "PT30M"
    Duration = "PT2H1M"
  },
  @{
    Name = "AStockMainFundAnomalyPush-Morning"
    StartBoundary = "2026-01-01T09:30:00"
    Runner = $anomalyRunner
    Description = "Held A-share anomaly push to Feishu every 1 minute during trading sessions"
    Interval = "PT1M"
    Duration = "PT2H1M"
  },
  @{
    Name = "AStockMainFundAnomalyPush-Afternoon"
    StartBoundary = "2026-01-01T13:00:00"
    Runner = $anomalyRunner
    Description = "Held A-share anomaly push to Feishu every 1 minute during trading sessions"
    Interval = "PT1M"
    Duration = "PT2H1M"
  },
  @{
    Name = "AStockMainFundReplayPush-Morning"
    StartBoundary = "2026-01-01T09:35:00"
    Runner = $replayRunner
    Arguments = "-QueueRoot `"$((Join-Path (Split-Path -Parent $PSScriptRoot) 'data\pending_pushes'))`""
    Description = "Replay pending Feishu pushes every 5 minutes during morning trading session"
    Interval = "PT5M"
    Duration = "PT1H56M"
  },
  @{
    Name = "AStockMainFundReplayPush-Afternoon"
    StartBoundary = "2026-01-01T13:05:00"
    Runner = $replayRunner
    Arguments = "-QueueRoot `"$((Join-Path (Split-Path -Parent $PSScriptRoot) 'data\pending_pushes'))`""
    Description = "Replay pending Feishu pushes every 5 minutes during afternoon trading session"
    Interval = "PT5M"
    Duration = "PT1H56M"
  }
)

foreach ($task in $tasks) {
  $runnerArguments = if ($task.ContainsKey("Arguments")) { " $($task.Arguments)" } else { "" }
  $arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($task.Runner)`"$runnerArguments"
  $xml = New-TaskXml `
    -StartBoundary $task.StartBoundary `
    -Command $ps `
    -Arguments $arguments `
    -Author $author `
    -Description $task.Description `
    -Interval $task.Interval `
    -Duration $task.Duration

  Register-ScheduledTask `
    -TaskName $task.Name `
    -Xml $xml `
    -Force | Out-Null

  $taskInfo = Get-ScheduledTaskInfo -TaskName $task.Name
  Write-Output "Installed scheduled task: $($task.Name)"
  Write-Output "Next run: $($taskInfo.NextRunTime)"
}

Write-Output "Installed fixed report tasks at 30-minute intervals, anomaly tasks at 1-minute intervals, and replay tasks at 5-minute intervals."
