param(
  [Parameter(Mandatory = $true)]
  [string]$WatchFile
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $WatchFile)) {
  throw "Watchlist file not found: $WatchFile"
}

$backup = "$WatchFile.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
Copy-Item -LiteralPath $WatchFile -Destination $backup -Force

$groups = [ordered]@{
  SEMI_OPTICAL_COMM = @(
    "300308", "300502", "300394", "002281", "603083", "688498", "300570",
    "000988", "601138"
  )
  SEMI_MATERIALS = @(
    "300346", "688126", "688549", "688019", "688146", "300655", "603078",
    "300666", "600183", "002436", "002916", "688519"
  )
  SEMI_EQUIPMENT = @(
    "002371", "688012", "688082", "688072", "688120", "688037", "688409"
  )
  SEMI_TEST = @(
    "688200", "300604", "300567"
  )
  SEMI_PACKAGING = @(
    "600584", "002156", "002185", "688362", "603005", "688216"
  )
  SEMI_DESIGN_EDA_IP = @(
    "603160", "603501", "688380", "688521", "688206", "301269"
  )
  SEMI_FOUNDRY_POWER = @(
    "688981", "688347", "688469", "688234", "688126"
  )
}

function Get-MarketCode {
  param([string]$Code)

  if ($Code.StartsWith("6")) {
    return "USHA"
  }
  if ($Code.StartsWith("9")) {
    return "USTM"
  }
  return "USZA"
}

$content = Get-Content -LiteralPath $WatchFile -Raw -Encoding UTF8
$xml = New-Object System.Xml.XmlDocument
$xml.PreserveWhitespace = $true
$xml.LoadXml($content)

$root = $xml.DocumentElement
$existingNames = @($groups.Keys)
foreach ($block in @($root.SelectNodes("Block"))) {
  if ($existingNames -contains $block.GetAttribute("name")) {
    [void]$root.RemoveChild($block)
  }
}

$maxId = 0
foreach ($block in @($root.SelectNodes("Block"))) {
  $id = 0
  if ([int]::TryParse($block.GetAttribute("id"), [ref]$id) -and $id -gt $maxId) {
    $maxId = $id
  }
}

$newIds = @()
foreach ($entry in $groups.GetEnumerator()) {
  $maxId += 1
  $newIds += $maxId

  $block = $xml.CreateElement("Block")
  $block.SetAttribute("name", $entry.Key)
  $block.SetAttribute("id", [string]$maxId)
  $block.SetAttribute("IsLock", "false")
  $block.SetAttribute("IsNameChanged", "false")
  $block.SetAttribute("IsSecuritiesChanged", "true")

  foreach ($code in ($entry.Value | Sort-Object -Unique)) {
    $security = $xml.CreateElement("security")
    $security.SetAttribute("market", (Get-MarketCode $code))
    $security.SetAttribute("code", $code)
    [void]$block.AppendChild($security)
  }

  [void]$root.AppendChild($block)
}

$sortList = @()
$currentSort = $root.GetAttribute("sort_list")
if ($currentSort) {
  $sortList += $currentSort.Split(",") | Where-Object { $_ }
}
$sortList += $newIds | ForEach-Object { "{0:X}" -f $_ }
$root.SetAttribute("sort_list", (($sortList | Select-Object -Unique) -join ",") + ",")

$settings = New-Object System.Xml.XmlWriterSettings
$settings.Encoding = New-Object System.Text.UTF8Encoding($true)
$settings.Indent = $true
$settings.OmitXmlDeclaration = $true

$writer = [System.Xml.XmlWriter]::Create($WatchFile, $settings)
try {
  $xml.Save($writer)
} finally {
  $writer.Close()
}

$allCodes = @($xml.hevo.Block.security | Where-Object code | Select-Object -ExpandProperty code | Sort-Object -Unique)
Write-Output "Updated semiconductor watchlist groups."
Write-Output "Backup: $backup"
Write-Output "Unique monitored stocks: $($allCodes.Count)"
