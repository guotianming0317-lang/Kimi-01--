# A股已持股份主力资金流动报告 - 项目上下文

## 1. 项目目标

本项目用于监控“已持有的 A 股股票”资金动向，并通过飞书推送：

- 固定频率报告
- 主力资金瞬时大额异常预警
- 手动补跑/补发消息

当前口径已经从“半导体观察池”切换为“仅监控持仓股票”。

## 2. 当前主线功能

### 2.1 固定报告

- 监控范围：`data/holdings.csv`
- 报告脚本：`scripts/Run-FormalReplayPush.ps1`
- 默认口径：
  - 完整持有列表
  - 按主力净额从流入到流出排序
  - 展示主力净额、涨跌幅、特大单、大单、中小单
  - 展示主力总流入 / 主力总流出

### 2.2 异常预警

- 监控脚本：`scripts/Run-AnomalyMonitor.ps1`
- 用途：检测主力资金瞬时大额流动
- 推送方式：独立飞书消息

### 2.3 补发 / 重放

- 飞书补发队列：`data/pending_pushes/`
- 重放脚本：`scripts/Replay-PendingFeishuPushes.ps1`
- 15:00 收盘模拟补发脚本：
  - `scripts/Send-SimulatedClosePush.ps1`

### 2.4 详情数据导出

- 导出脚本：`scripts/Export-HeldDetailData.ps1`
- 作用：单独抓取持仓股票的东财详情字段，供手动补发使用

## 3. 关键数据文件

### 3.1 持仓清单

- 文件：`data/holdings.csv`
- 当前维护方式：手动维护
- 后续增减持仓时，优先修改此文件

### 3.2 运行产物

以下内容视为运行产物，不作为主线代码的一部分：

- `data/outbox/`
- `data/logs/`
- `data/snapshots/`
- `data/pending_pushes/`
- `data/detail_cache/`
- `data/field_probe/`
- `data/preview/`
- 自检、推送测试、异常测试目录

这些目录已经通过 `.gitignore` 处理，默认不进 Git。

## 4. Git 工作流约定

### 4.1 主线

- GitHub 仓库：
  - `https://github.com/guotianming0317-lang/Kimi-01--.git`
- 主线分支：
  - `main`

### 4.2 后续开发方式

新功能不要直接在 `main` 上开发。

建议流程：

1. 从 `main` 创建新分支
2. 在分支上开发、测试
3. 验证通过后再合并回 `main`

建议分支名格式：

- `codex/功能名`
- `codex/fix-问题名`

## 5. 关键脚本索引

- 持仓加载：
  - `scripts/Holdings.ps1`
- 公共监控逻辑：
  - `scripts/HeldStockMonitorShared.ps1`
- 飞书卡片拆分与组装：
  - `scripts/FeishuCardShared.ps1`
- 飞书发送：
  - `scripts/Send-FeishuCard.ps1`
- 固定报告：
  - `scripts/Run-FormalReplayPush.ps1`
- 异常预警：
  - `scripts/Run-AnomalyMonitor.ps1`
- 暂停监控：
  - `scripts/Pause-Monitoring.ps1`
- 恢复监控：
  - `scripts/Resume-Monitoring.ps1`
- 定时任务安装：
  - `scripts/Install-WindowsFundPushTasks.ps1`
- 模拟收盘补发：
  - `scripts/Send-SimulatedClosePush.ps1`
- 导出东财详情：
  - `scripts/Export-HeldDetailData.ps1`

## 6. 已知限制

### 6.1 东财接口不稳定

东财接口偶尔会出现：

- `基础连接已经关闭: 连接被意外关闭`
- `无法连接到远程服务器`

项目已加入：

- 重试
- curl 兜底
- 快照降级

但接口波动仍然可能导致实时详情缺失。

### 6.2 飞书 / GitHub 可能受网络环境影响

本项目多次出现以下情况：

- 浏览器可访问网络
- PowerShell / curl 的 443 请求失败

这类问题通常与本机网络出口、VPN、杀毒/代理、命令行 HTTPS 链路有关，而不是脚本本身。

### 6.3 个别股票详情字段可能缺失

例如曾出现：

- `三只松鼠（300783）` 的详情字段 `f139` 为 `"-"`

在这种情况下，脚本应显示 `--`，而不是伪造总流入 / 总流出。

## 7. 下次接手时建议先看

如果重新进入本项目，建议优先查看：

1. `PROJECT_CONTEXT.md`
2. `WORKLOG.md`
3. `data/holdings.csv`
4. `scripts/HeldStockMonitorShared.ps1`
5. 最近一次需要处理的问题相关脚本
