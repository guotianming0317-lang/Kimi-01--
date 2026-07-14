param(
  [Parameter(Mandatory = $true, ParameterSetName = "Content")]
  [Parameter(Mandatory = $true, ParameterSetName = "ContentPath")]
  [string]$Title,

  [Parameter(Mandatory = $true, ParameterSetName = "Content")]
  [string]$Content,

  [Parameter(Mandatory = $true, ParameterSetName = "ContentPath")]
  [string]$ContentPath,

  [Parameter(ParameterSetName = "Content")]
  [Parameter(ParameterSetName = "ContentPath")]
  [ValidateSet("blue", "red", "orange", "green", "grey", "purple")]
  [string]$Template = "blue",

  [Parameter(ParameterSetName = "Content")]
  [Parameter(ParameterSetName = "ContentPath")]
  [string]$SettingsPath = "",

  [Parameter(ParameterSetName = "Content")]
  [Parameter(ParameterSetName = "ContentPath")]
  [ValidateRange(1, 10)]
  [int]$MaxAttempts = 3,

  [Parameter(ParameterSetName = "Content")]
  [Parameter(ParameterSetName = "ContentPath")]
  [ValidateRange(1, 30)]
  [int]$RetryDelaySeconds = 5,

  [Parameter(ParameterSetName = "Content")]
  [Parameter(ParameterSetName = "ContentPath")]
  [string]$QueueRoot = ""
)

$ErrorActionPreference = "Stop"
$stage = "initializing"
. (Join-Path $PSScriptRoot "FeishuCardShared.ps1")
trap {
  Write-Error ("Feishu sender failed while {0}: {1}" -f $stage, $_.Exception.Message)
  exit 1
}

function Find-SettingsPath {
  if ($SettingsPath) {
    return $SettingsPath
  }

  $documents = [Environment]::GetFolderPath("MyDocuments")
  $match = Get-ChildItem -LiteralPath $documents -Recurse -Filter "settings.yml" -ErrorAction SilentlyContinue |
    Where-Object {
      try {
        (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) -match "webhook_url:"
      } catch {
        $false
      }
    } |
    Select-Object -First 1

  if ($match) {
    return $match.FullName
  }

  return ""
}

function Get-FeishuCredential {
  if ($SettingsPath) {
    if (-not (Test-Path -LiteralPath $SettingsPath)) {
      throw "Feishu settings file not found: $SettingsPath"
    }

    $settings = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8
    $webhookMatch = [regex]::Match($settings, 'webhook_url:\s*"([^"]+)"')
    $secretMatch = [regex]::Match($settings, 'secret:\s*"([^"]+)"')

    if (-not $webhookMatch.Success) {
      throw "Feishu webhook is missing in settings."
    }

    return @{
      Webhook = $webhookMatch.Groups[1].Value.Trim()
      Secret = if ($secretMatch.Success) { $secretMatch.Groups[1].Value.Trim() } else { "" }
    }
  }

  $webhook = [Environment]::GetEnvironmentVariable("FEISHU_WEBHOOK_URL")
  $secret = [Environment]::GetEnvironmentVariable("FEISHU_SECRET")

  if ($webhook) {
    return @{
      Webhook = $webhook.Trim()
      Secret = if ($secret) { $secret.Trim() } else { "" }
    }
  }

  $path = Find-SettingsPath
  if (-not $path -or -not (Test-Path -LiteralPath $path)) {
    throw "Feishu settings file not found. Set FEISHU_WEBHOOK_URL or pass -SettingsPath."
  }

  $settings = Get-Content -LiteralPath $path -Raw -Encoding UTF8
  $webhookMatch = [regex]::Match($settings, 'webhook_url:\s*"([^"]+)"')
  $secretMatch = [regex]::Match($settings, 'secret:\s*"([^"]+)"')

  if (-not $webhookMatch.Success) {
    throw "Feishu webhook is missing in settings."
  }

  return @{
    Webhook = $webhookMatch.Groups[1].Value.Trim()
    Secret = if ($secretMatch.Success) { $secretMatch.Groups[1].Value.Trim() } else { "" }
  }
}

function New-FeishuSignature {
  param(
    [string]$Timestamp,
    [string]$Secret
  )

  $stringToSign = "$Timestamp`n$Secret"
  $hmac = [System.Security.Cryptography.HMACSHA256]::new()
  $hmac.Key = [System.Text.Encoding]::UTF8.GetBytes($stringToSign)
  return [Convert]::ToBase64String($hmac.ComputeHash([byte[]]@()))
}

function Save-QueuedPush {
  param(
    [string]$QueueDirectory,

    [Parameter(Mandatory = $true)]
    [string]$Reason
  )

  if (-not $QueueDirectory) {
    return
  }

  New-Item -ItemType Directory -Force -Path $QueueDirectory | Out-Null
  $queueFile = Join-Path $QueueDirectory ("queued_push_{0}.json" -f (Get-Date -Format "yyyyMMdd_HHmmss_fff"))
  $queueItem = [pscustomobject]@{
    queued_at = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    title = $Title
    template = $Template
    content = $Content
    content_path = $ContentPath
    settings_path = $SettingsPath
    reason = $Reason
  }
  $queueItem | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $queueFile -Encoding UTF8
}

if ($ContentPath) {
  if (-not (Test-Path -LiteralPath $ContentPath)) {
    throw "Content file not found: $ContentPath"
  }
  $Content = Get-Content -LiteralPath $ContentPath -Raw -Encoding UTF8
}

if (-not $Content) {
  throw "Content or ContentPath is required."
}

$stage = "loading Feishu credentials"
$credentials = Get-FeishuCredential

$stage = "building Feishu card"
$messageSpecs = @(New-FeishuMessageSpecs -Title $Title -Content $Content)
if (-not $messageSpecs) {
  throw "No Feishu message content generated."
}

$stage = "signing Feishu request"
foreach ($messageSpec in $messageSpecs) {
  $payload = @{
    msg_type = "interactive"
    card = @{
      config = @{ wide_screen_mode = $true }
      header = @{
        template = $Template
        title = @{
          tag = "plain_text"
          content = [string]$messageSpec.Title
        }
      }
      elements = @($messageSpec.Elements)
    }
  }

  if ($credentials.Secret) {
    $timestamp = [string][int][double]::Parse((Get-Date -UFormat %s))
    $payload.timestamp = $timestamp
    $payload.sign = New-FeishuSignature -Timestamp $timestamp -Secret $credentials.Secret
  }

  $stage = "sending Feishu request"
  $json = $payload | ConvertTo-Json -Depth 12
  $response = $null
  $lastError = $null
  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    try {
      $response = Invoke-RestMethod `
        -Method Post `
        -Uri $credentials.Webhook `
        -ContentType "application/json; charset=utf-8" `
        -Body $json `
        -TimeoutSec 20
      $lastError = $null
      break
    } catch {
      $lastError = $_.Exception.Message
      if ($attempt -ge $MaxAttempts) {
        if ($QueueRoot) {
          Save-QueuedPush -QueueDirectory $QueueRoot -Reason $lastError
        }
        throw "attempt $attempt/$MaxAttempts failed: $lastError"
      }
      Start-Sleep -Seconds $RetryDelaySeconds
    }
  }

  $code = 0
  if ($null -ne $response.code) {
    $code = [int]$response.code
  } elseif ($null -ne $response.StatusCode) {
    $code = [int]$response.StatusCode
  }

  if ($code -ne 0) {
    if ($QueueRoot) {
      Save-QueuedPush -QueueDirectory $QueueRoot -Reason ("Feishu push failed: {0}" -f ($response | ConvertTo-Json -Compress -Depth 5))
    }
    throw "Feishu push failed: $($response | ConvertTo-Json -Compress -Depth 5)"
  }
}

Write-Output "Feishu push succeeded."
