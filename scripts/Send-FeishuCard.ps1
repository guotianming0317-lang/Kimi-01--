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
  [ValidateSet("blue", "red", "orange", "green", "grey")]
  [string]$Template = "blue",

  [Parameter(ParameterSetName = "Content")]
  [Parameter(ParameterSetName = "ContentPath")]
  [string]$SettingsPath = ""
)

$ErrorActionPreference = "Stop"
$stage = "initializing"
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
$elements = @()
$chunk = ""
foreach ($line in ($Content -split "`r?`n")) {
  $candidate = if ($chunk) { "$chunk`n$line" } else { $line }
  if ($candidate.Length -gt 3000 -and $chunk) {
    $elements += @{
      tag = "div"
      text = @{
        tag = "lark_md"
        content = $chunk
      }
    }
    $elements += @{ tag = "hr" }
    $chunk = $line
  } else {
    $chunk = $candidate
  }
}

if ($chunk) {
  $elements += @{
    tag = "div"
    text = @{
      tag = "lark_md"
      content = $chunk
    }
  }
}

$payload = @{
  msg_type = "interactive"
  card = @{
    config = @{ wide_screen_mode = $true }
    header = @{
      template = $Template
      title = @{
        tag = "plain_text"
        content = $Title
      }
    }
    elements = @($elements)
  }
}

$stage = "signing Feishu request"
if ($credentials.Secret) {
  $timestamp = [string][int][double]::Parse((Get-Date -UFormat %s))
  $payload.timestamp = $timestamp
  $payload.sign = New-FeishuSignature -Timestamp $timestamp -Secret $credentials.Secret
}

$stage = "sending Feishu request"
$json = $payload | ConvertTo-Json -Depth 12
$response = Invoke-RestMethod `
  -Method Post `
  -Uri $credentials.Webhook `
  -ContentType "application/json; charset=utf-8" `
  -Body $json `
  -TimeoutSec 20

$code = 0
if ($null -ne $response.code) {
  $code = [int]$response.code
} elseif ($null -ne $response.StatusCode) {
  $code = [int]$response.StatusCode
}

if ($code -ne 0) {
  throw "Feishu push failed: $($response | ConvertTo-Json -Compress -Depth 5)"
}

Write-Output "Feishu push succeeded."
