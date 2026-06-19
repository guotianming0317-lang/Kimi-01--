param(
  [Parameter(Mandatory = $true)]
  [string]$WatchFile,

  [string]$HoldingsPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "data\holdings.csv"),

  [string]$BlockName = "HELD_POSITIONS"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Holdings.ps1")

if (-not (Test-Path -LiteralPath $WatchFile)) {
  throw "Watchlist file not found: $WatchFile"
}

$holdings = @(Import-HeldStocks -Path $HoldingsPath)
$backup = "$WatchFile.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
Copy-Item -LiteralPath $WatchFile -Destination $backup -Force

$content = Get-Content -LiteralPath $WatchFile -Raw -Encoding UTF8
$xml = New-Object System.Xml.XmlDocument
$xml.PreserveWhitespace = $true
$xml.LoadXml($content)

$root = $xml.DocumentElement
foreach ($block in @($root.SelectNodes("Block"))) {
  if ($block.GetAttribute("name") -eq $BlockName) {
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

$maxId += 1
$block = $xml.CreateElement("Block")
$block.SetAttribute("name", $BlockName)
$block.SetAttribute("id", [string]$maxId)
$block.SetAttribute("IsLock", "false")
$block.SetAttribute("IsNameChanged", "false")
$block.SetAttribute("IsSecuritiesChanged", "true")

foreach ($stock in ($holdings | Sort-Object Code -Unique)) {
  $security = $xml.CreateElement("security")
  $security.SetAttribute("market", $stock.ThsMarket)
  $security.SetAttribute("code", $stock.Code)
  [void]$block.AppendChild($security)
}
[void]$root.AppendChild($block)

$sortList = @()
$currentSort = $root.GetAttribute("sort_list")
if ($currentSort) {
  $sortList += $currentSort.Split(",") | Where-Object { $_ }
}
$sortList += "{0:X}" -f $maxId
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

Write-Output "Updated held-stock watchlist block: $BlockName"
Write-Output "Backup: $backup"
Write-Output "Held stocks: $($holdings.Count)"
