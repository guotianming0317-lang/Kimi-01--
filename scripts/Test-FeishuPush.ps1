$ErrorActionPreference = "Stop"

$sender = Join-Path $PSScriptRoot "Send-FeishuCard.ps1"
$message = @"
**自检时间：** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
**自动化：** A股半导体与主力资金监控
**状态：** 正在验证飞书 webhook、签名和卡片推送链路。

这是一条测试消息，不代表市场监控报告。
"@

& $sender `
  -Title "A股半导体与主力资金监控｜测试推送" `
  -Template "blue" `
  -Content $message