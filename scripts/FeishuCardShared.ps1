$ErrorActionPreference = "Stop"

function Split-FeishuContentChunks {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Content,

    [ValidateRange(200, 3000)]
    [int]$MaxChunkLength = 3000
  )

  $chunks = New-Object System.Collections.Generic.List[string]
  $chunk = ""
  foreach ($line in ($Content -split "`r?`n")) {
    $candidate = if ($chunk) { "$chunk`n$line" } else { $line }
    if ($candidate.Length -gt $MaxChunkLength -and $chunk) {
      $chunks.Add($chunk)
      $chunk = $line
    } else {
      $chunk = $candidate
    }
  }

  if ($chunk) {
    $chunks.Add($chunk)
  }

  return @($chunks)
}

function New-FeishuMessageSpecs {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Title,

    [Parameter(Mandatory = $true)]
    [string]$Content,

    [ValidateRange(1, 10)]
    [int]$MaxChunksPerMessage = 2
  )

  $chunks = @(Split-FeishuContentChunks -Content $Content)
  if (-not $chunks) {
    return @()
  }

  $specs = @()
  $partCount = [Math]::Ceiling($chunks.Count / [double]$MaxChunksPerMessage)

  for ($partIndex = 0; $partIndex -lt $partCount; $partIndex++) {
    $startIndex = $partIndex * $MaxChunksPerMessage
    $endIndex = [Math]::Min($startIndex + $MaxChunksPerMessage - 1, $chunks.Count - 1)
    $groupChunks = @($chunks[$startIndex..$endIndex])

    $partTitle = if ($partCount -gt 1) {
      "{0} ({1}/{2})" -f $Title, ($partIndex + 1), $partCount
    } else {
      $Title
    }

    $elements = @()
    for ($j = 0; $j -lt $groupChunks.Count; $j++) {
      $elements += @{
        tag = "div"
        text = @{
          tag = "lark_md"
          content = [string]$groupChunks[$j]
        }
      }

      if ($j -lt ($groupChunks.Count - 1)) {
        $elements += @{ tag = "hr" }
      }
    }

    $specs += [pscustomobject]@{
      Title = $partTitle
      Elements = @($elements)
    }
  }

  return @($specs)
}
