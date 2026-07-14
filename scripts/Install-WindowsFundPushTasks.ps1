$ErrorActionPreference = "Stop"

$reportRunner = Join-Path $PSScriptRoot "Run-FormalReplayPush.ps1"
$anomalyRunner = Join-Path $PSScriptRoot "Run-AnomalyMonitor.ps1"
$replayRunner = Join-Path $PSScriptRoot "Replay-PendingFeishuPushes.ps1"
$auctionRunner = Join-Path $PSScriptRoot "Run-AuctionMonitor.ps1"
$auctionCatchUpRunner = Join-Path $PSScriptRoot "Run-AuctionCatchUp.ps1"
$afterHoursRunner = Join-Path $PSScriptRoot "Run-AfterHoursFixedPriceReport.ps1"
$openStrengthCaptureRunner = Join-Path $PSScriptRoot "Run-OpenStrengthCapture.ps1"
$openStrengthReportRunner = Join-Path $PSScriptRoot "Run-OpenStrengthReport.ps1"
$hiddenLauncher = Join-Path $PSScriptRoot "LaunchHiddenPowerShell.vbs"
foreach ($runner in @($reportRunner, $anomalyRunner, $replayRunner, $auctionRunner, $auctionCatchUpRunner, $afterHoursRunner, $openStrengthCaptureRunner, $openStrengthReportRunner, $hiddenLauncher)) {
  if (-not (Test-Path -LiteralPath $runner)) {
    throw "Runner not found: $runner"
  }
}

$wscript = Join-Path $env:SystemRoot "System32\wscript.exe"
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
    [string]$Interval = "",
    [string]$Duration = ""
  )

  $escapedCommand = ConvertTo-XmlText $Command
  $escapedArguments = ConvertTo-XmlText $Arguments
  $escapedAuthor = ConvertTo-XmlText $Author
  $escapedDescription = ConvertTo-XmlText $Description

  $repetitionBlock = ""
  if ($Interval -and $Duration) {
    $repetitionBlock = @"
      <Repetition>
        <Interval>$Interval</Interval>
        <Duration>$Duration</Duration>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
"@
  }

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
$repetitionBlock
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
  },
  @{
    Name = "AStockAuctionOpen-0915"
    StartBoundary = "2026-01-01T09:15:00"
    Runner = $auctionRunner
    Arguments = "-Session open -Checkpoint 0915"
    Description = "Held A-share opening auction snapshot at 09:15"
  },
  @{
    Name = "AStockAuctionOpen-0920"
    StartBoundary = "2026-01-01T09:20:00"
    Runner = $auctionRunner
    Arguments = "-Session open -Checkpoint 0920"
    Description = "Held A-share opening auction snapshot at 09:20"
  },
  @{
    Name = "AStockAuctionOpen-0923"
    StartBoundary = "2026-01-01T09:23:00"
    Runner = $auctionRunner
    Arguments = "-Session open -Checkpoint 0923"
    Description = "Held A-share opening auction snapshot at 09:23"
  },
  @{
    Name = "AStockAuctionOpen-092430"
    StartBoundary = "2026-01-01T09:24:30"
    Runner = $auctionRunner
    Arguments = "-Session open -Checkpoint 092430"
    Description = "Held A-share opening auction snapshot at 09:24:30"
  },
  @{
    Name = "AStockAuctionOpen-0925"
    StartBoundary = "2026-01-01T09:25:00"
    Runner = $auctionRunner
    Arguments = "-Session open -Checkpoint 0925"
    Description = "Held A-share opening auction snapshot at 09:25"
  },
  @{
    Name = "AStockAuctionOpen-0926"
    StartBoundary = "2026-01-01T09:26:00"
    Runner = $auctionRunner
    Arguments = "-Session open -Checkpoint 0926"
    Description = "Held A-share opening auction final report at 09:26"
  },
  @{
    Name = "AStockAuctionClose-1457"
    StartBoundary = "2026-01-01T14:57:00"
    Runner = $auctionRunner
    Arguments = "-Session close -Checkpoint 1457"
    Description = "Held A-share closing auction snapshot at 14:57"
  },
  @{
    Name = "AStockAuctionClose-1459"
    StartBoundary = "2026-01-01T14:59:00"
    Runner = $auctionRunner
    Arguments = "-Session close -Checkpoint 1459"
    Description = "Held A-share closing auction snapshot at 14:59"
  },
  @{
    Name = "AStockAuctionClose-1500"
    StartBoundary = "2026-01-01T15:00:00"
    Runner = $auctionRunner
    Arguments = "-Session close -Checkpoint 1500"
    Description = "Held A-share closing auction capture at 15:00 with final push at 15:01"
  },
  @{
    Name = "AStockAuctionCatchUp-Open"
    StartBoundary = "2026-01-01T09:15:00"
    Runner = $auctionCatchUpRunner
    Arguments = "-Session open"
    Description = "Held A-share opening auction catch-up every 1 minute during auction window"
    Interval = "PT1M"
    Duration = "PT21M"
  },
  @{
    Name = "AStockAuctionCatchUp-Close"
    StartBoundary = "2026-01-01T14:57:00"
    Runner = $auctionCatchUpRunner
    Arguments = "-Session close"
    Description = "Held A-share closing auction catch-up every 1 minute during closing auction window"
    Interval = "PT1M"
    Duration = "PT5M"
  },
  @{
    Name = "AStockOpenStrength-0925"
    StartBoundary = "2026-01-01T09:25:00"
    Runner = $openStrengthCaptureRunner
    Arguments = "-Checkpoint 0925"
    Description = "Held A-share 09:25 auction snapshot for 09:40 opening strength analysis"
  },
  @{
    Name = "AStockOpenStrength-0930"
    StartBoundary = "2026-01-01T09:30:00"
    Runner = $openStrengthCaptureRunner
    Arguments = "-Checkpoint 0930"
    Description = "Held A-share 09:30 open snapshot for 09:40 opening strength analysis"
  },
  @{
    Name = "AStockOpenStrength-0940"
    StartBoundary = "2026-01-01T09:40:00"
    Runner = $openStrengthCaptureRunner
    Arguments = "-Checkpoint 0940"
    Description = "Held A-share 09:40 live snapshot for opening strength analysis"
  },
  @{
    Name = "AStockOpenStrength-0941"
    StartBoundary = "2026-01-01T09:41:00"
    Runner = $openStrengthReportRunner
    Description = "Held A-share 09:40 opening strength report at 09:41"
  },
  @{
    Name = "AStockAfterHoursFixed-1531"
    StartBoundary = "2026-01-01T15:31:00"
    Runner = $afterHoursRunner
    Description = "Held A-share after-hours fixed-price trading report at 15:31"
  }
)

foreach ($task in $tasks) {
  $runnerArguments = if ($task.ContainsKey("Arguments")) { [string]$task.Arguments } else { "" }
  $arguments = if ($runnerArguments) {
    "`"$hiddenLauncher`" `"$($task.Runner)`" `"$runnerArguments`""
  } else {
    "`"$hiddenLauncher`" `"$($task.Runner)`""
  }
  $xml = New-TaskXml `
    -StartBoundary $task.StartBoundary `
    -Command $wscript `
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
Write-Output "Installed opening auction checkpoints at 09:15/09:20/09:23/09:24:30/09:25/09:26 and closing auction checkpoints at 14:57/14:59/15:00."
Write-Output "Installed auction catch-up tasks every 1 minute during 09:15-09:26 and 14:57-15:00."
Write-Output "Installed 09:25/09:30/09:40 capture tasks, 09:41 opening-strength report task, and 15:31 after-hours fixed-price report task."
