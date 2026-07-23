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

## 8. 最新补充风险（2026-06-24）

- 2026-06-24 上午固定报告任务并未停摆，`09:30` 与 `10:00` 的 Windows 计划任务都实际触发了。
- `09:30` 失败原因仍是东财返回个别字段为 `"-"` 时，被脚本当作数字解析，日志关键词：
  - `quote failed without snapshot fallback :: 输入对象“-”不是数字。`
- `10:00` 已成功生成报告文件 `formal_replay_20260624_100007.md`，但飞书自动发送失败，日志关键词：
  - `push failed ... :: Feishu sender exited with code 1`
- 随后手动补发同一份报告成功，说明当时故障更像“瞬时发送链路异常”，而不是任务未运行或报告未生成。
- 后续如果再出现“今天没主动发推送”，优先排查顺序应是：
  1. 查看 `data/logs/fund_push.log`
  2. 查看 `data/outbox/` 是否已经生成对应时段报告
  3. 查看 `data/pending_pushes/` 是否有积压
  4. 查询两个固定报告计划任务的 `Last Run Time / Last Result / Next Run Time`
## 9. 2026-07-01 鍒嗘敮琛ュ厖锛氶泦鍚堢珵浠风洃鎺у紑鍙戜腑

### 9.1 褰撳墠鍒嗘敮

- 褰撳墠涓嶅湪 `main`
- 鍔熻兘鍒嗘敮锛?`codex/auction-monitoring`
- 鐢ㄩ€斾笓鐢細鎼缓鈥淎鑲￠泦鍚堢珵浠锋寔浠撶洃鎺р€濇柊鍔熻兘

### 9.2 鏂板姛鑳借寖鍥?

鏂板涓ゅ绔炰环鐩戞帶鍦烘櫙锛?

1. 寮€鐩樼珵浠风洃鎺?
   - 鏃堕棿鐐癸細`09:15`銆?`09:20`銆?`09:23`銆?`09:24:30`銆?`09:25`銆?`09:26`
   - 鏈€缁堟帹閫佺偣锛?`09:26`

2. 灏剧洏绔炰环鐩戞帶
   - 鏃堕棿鐐癸細`14:57`銆?`14:59`銆?`15:00`
   - 鏈€缁堟帹閫佺偣锛?`15:00`

3. 琛ュ緱鏈哄埗
   - 鍦ㄧ珵浠风獥鍙ｆ湡鍐呭鍔犲垎閽熺骇 catch-up
   - 鐢ㄤ簬鐢佃剳杈冩櫄鍚姩鎴栫綉缁滄仮澶嶅悗锛岃ˉ鎶撶珵浠峰揩鐓?

### 9.3 鏂板 / 鍏抽敭鑴氭湰

- `scripts/AuctionMonitorShared.ps1`
  - 绔炰环琛屾儏杞崲銆佸垽鏂爣绛俱€佽瘎鍒嗐€佹帹鏂囩敓鎴?
- `scripts/Run-AuctionMonitor.ps1`
  - 鍗曟绔炰环閲囨牱涓庢渶缁堟姤鍛婄敓鎴?
- `scripts/Run-AuctionCatchUp.ps1`
  - 绔炰环鏃剁獥鍐呯殑鍒嗛挓绾цˉ鎶?
- `scripts/Tests/AuctionMonitor.Tests.ps1`
  - 绔炰环鍒嗙被銆佽瘎鍒嗐€佹枃妗堢敓鎴愮瓑娴嬭瘯

### 9.4 鎸佷粨琛ㄦ柊澧炵害瀹?

- `data/holdings.csv` 鏂板 `PrevCloseMode`
- 鐢ㄤ簬鎸夎偂绁ㄩ厤缃?鏄惁浣跨敤鍓嶅鏉冨彛寰勭殑鏄ユ敹浠?
- 鐩墠宸茬煡绾﹀畾锛?
  - `002594,姣斾簹杩?qfq`
- 濡傚悗缁繕鏈夊叾浠栬偂绁ㄩ渶瑕佸墠澶嶆潈锛屽彲鐩存帴鍦?CSV 涓户缁～鍐?

### 9.5 椋炰功绔炰环鎺ㄩ€侀鏍艰鍒?

- 绔炰环鎺ㄩ€侀〉绛炬敼涓?`purple`
- 鏍囬鍓嶄娇鐢ㄧ传鑹插渾鐐瑰浘鏍囷紝鐢ㄤ簬涓庡叾浠栫洃鎺х被鍨嬪尯鍒?
- 鏍囬鏄庣‘鍖哄垎锛?
  - `A股集合竞价持仓监控`
  - 寮€鐩樻垨灏剧洏鍦烘櫙浼氬湪姝ｆ枃涓槑纭爣娉?

### 9.6 姝ｆ枃鏍峰紡瑙勫垯

- 闄や簿纭棩鏈熴€佹椂闂村锛屽敖閲忓皢鏁板瓧浣跨敤绮椾綋
- 鈥滃己搴﹁瘎鍒嗏€濋鑹插尯闂达細
  - `80-100` 绾㈣壊
  - `50-79` 姗欒壊
  - `0-49` 缁胯壊
- 涓偂鍚嶇О鍜屼唬鐮佷娇鐢ㄧ传鑹?+ 鍔犵矖
- `〔鍓嶅鏉僝` 浣跨敤钃濊壊

### 9.7 褰撳墠鐘舵€?

- 浠婂ぉ宸茬敤鍋囨暟鎹仛杩囨ā鎷熸帹閫侀瑙?
- 椋炰功绱壊椤剁鏍峰紡宸查獙璇佹甯?
- 涓偂绱壊鍔犵矖銆?`〔鍓嶅鏉僝` 钃濊壊鏄剧ず宸查獙璇佹甯?
- 鏄庡ぉ杩橀渶鍋氱殑鏄?鐢ㄧ湡瀹炵珵浠锋暟鎹湪浜ゆ槗鏃ュ仛涓€娆″畬鏁撮獙璇?

### 9.8 鏈€閲嶈鐨勫綋鍓嶇害瀹?

鍦ㄦ槑澶╃湡瀹炵珵浠锋暟鎹獙璇侀€氳繃涔嬪墠锛?

- **涓嶈鍚堝苟鍥?`main`**
- 鎵€鏈夊悗缁井璋冧粛缁х画鍦?`codex/auction-monitoring` 涓婂畬鎴?
## 10. 2026-07-02 10:30 涓诲姏鎬绘祦鍏? / 鎬绘祦鍑虹己澶辫ˉ鍏呯粡楠?

### 10.1 褰撴棩鐜拌薄

- `2026-07-02 10:30` 鍥哄畾鐩戞帶鎺ㄩ€佷腑锛?
  - `涓法鑺?U锛?88549锛?
  - `娌～浜т笟锛?88126锛?
- 鈥滀富鍔涘€绘祦鍏? / 鎬绘祦鍑衡€濅负 `--`
- 浣嗗叾浠栬鎯呮暟鎹甯?

### 10.2 瑕佺偣鍒ゆ柇

- 杩欎笉鏄姤鍛婃帓鐗堟紡鍐?
- 涔熶笉鏄寔浠撴紡鎺?
- 鏍规湰鍘熷洜鏄?`10:30` 褰撴涓滆储璇︽儏鎺ュ彛瀵硅繖涓や釜鏍囪繑鍥炵殑鎬绘祦鍏? / 鎬绘祦鍑哄瓧娈典负绌?

### 10.3 鍚庣画澶勭悊绛栫暐

- **涓嶈** 鐢ㄥ悗闈?10:40+` 鐨勫疄鏃舵暟鍊煎幓浼鎴?`10:30` 鍘嗗彶鍊?
- 濡傞渶琛ュ彂锛屼紭鍏堝彂鈥滆ˉ鍏呰鏄庘€濊€屼笉鏄慨鏀瑰師鍘嗗彶鍙ｅ緞
- 鏂囨涓鏄庣‘鍖哄垎锛?
  - 鍘嗗彶蹇収鍊?
  - 褰撳墠瀹炴椂鍥炶鍊?

### 10.4 宸茬粡钀藉湴鐨勪慨澶?

- 鏂囦欢锛?
  - `scripts/HeldStockMonitorShared.ps1`
- 宸叉柊澧為€昏緫锛?
  - 濡傛灉绗竴娆¤鎯呮姄鍙栧埌鐨勬暟鎹笉瓒充互瑙ｆ瀽鈥滀富鍔涘€绘祦鍏? / 鎬绘祦鍑衡€?
  - 瀵硅鑲＄エ鑷姩杩涜绗簩娆¤ˉ鎶?

### 10.5 娴嬭瘯涓庨獙璇?

- `scripts/Tests/Holdings.Tests.ps1` 宸叉柊澧炵浉搴旀柇瑷€
- 鏈€鏂拌繍琛岀粨鏋滐細
  - `All holdings tests passed.`

### 10.6 鍚庨潰鍐嶇鍒扮被浼奸棶棰樼殑澶勭悊椤哄簭

1. 鍏堢湅褰撴椂鎶ュ憡鏂囦欢
2. 鍐嶇湅瀵瑰簲蹇収鏂囦欢涓?`super_in / super_out / large_in / large_out` 鏄惁涓虹┖
3. 濡傛灉蹇収灏卞凡涓虹┖锛屽垯瀹氫綅涓衡€滃綋鏃惰鎯呮簮绌哄€尖€?
4. 浼樺厛鍙戣ˉ鍏呰鏄庯紝涓嶇洿鎺ョ敤鍚庣画瀹炴椂鍊煎洖濉巻鍙叉姤鍛?
## 11. 2026-07-02 集合竞价飞书分流配置

### 11.1 目标

- 将“集合竞价”相关推送单独发送到新飞书群
- 保持“固定监控 / 异常预警”继续发送到原飞书群

### 11.2 当前实现方式

- 新增本地配置文件：
  - `data/auction_feishu.settings.yml`
- 集合竞价脚本：
  - `scripts/Run-AuctionMonitor.ps1`
  - `scripts/Run-AuctionCatchUp.ps1`
- 若检测到该配置文件存在，则显式传入：
  - `-SettingsPath data/auction_feishu.settings.yml`

### 11.3 重要实现细节

- `scripts/Send-FeishuCard.ps1` 已调整优先级：
  - **显式传入的 `SettingsPath` 优先于环境变量**
- 这样可以确保：
  - 集合竞价走新群
  - 其他链路仍走原默认飞书配置

### 11.4 验证状态

- 已发送“集合竞价分流测试”到新群
- 用户已确认收到

### 11.5 后续使用约定

- 后续如需更换集合竞价群，只改：
  - `data/auction_feishu.settings.yml`
- 不需要动：
  - 固定监控脚本
  - 异常预警脚本
  - 默认飞书环境变量
## 2026-07-03 集合竞价漏发问题

### 结论

- 2026-07-03 用户未收到真实集合竞价推送，不是因为飞书分流错误，也不是因为定时任务没有触发。
- 实际原因是：集合竞价脚本在 `09:20` 之后拉取 Eastmoney 历史参考数据时，`push2his.eastmoney.com` 连接失败，旧逻辑直接中断。

### 证据

- `data/auction_open/logs/auction_open.log`
  - `09:15` 有成功保存快照
  - `09:20 / 09:23 / 09:24:30 / 09:25 / 09:26` 仅记录 `start open checkpoint=...`
  - 后续没有 `snapshot saved` / `pushed`

### 已完成修复

- 为集合竞价链路增加“当日参考数据缓存”
- 后续检查点优先使用缓存，不再每次重新依赖 `push2his`
- 若历史参考接口失败：
  - 优先回退缓存
  - 无缓存时允许部分字段为空
  - 不再让整份集合竞价报告直接报废
- 对前复权股票增加 `prev_close` 缓存兜底
- 历史接口首次失败后，不再对所有股票逐只重复慢重试

### 影响范围

- 影响脚本：
  - `scripts/AuctionMonitorShared.ps1`
  - `scripts/Run-AuctionMonitor.ps1`
  - `scripts/Run-AuctionCatchUp.ps1`
- 已补充测试：
  - `scripts/Tests/AuctionMonitor.Tests.ps1`

### 当前状态

- 集合竞价链路已完成结构性修复
- 仍需在用户本机真实交易日环境下继续观察 `09:15 -> 09:26` 自动推送表现

## 12. 2026-07-06 A股收盘新规适配

### 12.1 本次目标

根据 2026-07-06 起生效的 A 股收盘相关新规，在现有尾盘监控基础上完成：

- 保留 `14:57—15:00` 收盘集合竞价监控
- 新增 `15:05—15:30` 盘后固定价格交易监控
- 严格区分收盘集合竞价与盘后固定价格交易
- 修正主板 `ST / *ST` 涨跌幅限制为 `10%`

### 12.2 当前尾盘会话划分

- `close`
  - 标题：`A股持仓收盘集合竞价监控`
  - 采集点：`14:57`、`14:59`、`15:00`
  - 正式推送时间：`15:01`

- `after_hours`
  - 标题：`A股持仓盘后固定价格交易监控`
  - 分析时段：`15:05—15:30`
  - 正式推送时间：`15:31`

### 12.3 新增口径

尾盘相关金额口径已拆分为：

- `regular_session_amount`
- `closing_auction_amount`
- `after_hours_amount`
- `total_day_amount`

后续不能再把 `15:05—15:30` 的成交误算进 `14:57—15:00`。

### 12.4 关键脚本

- `scripts/AuctionMonitorShared.ps1`
- `scripts/Run-AuctionMonitor.ps1`
- `scripts/Run-AuctionCatchUp.ps1`
- `scripts/Run-AfterHoursFixedPriceReport.ps1`
- `scripts/Install-WindowsFundPushTasks.ps1`

### 12.5 当前已知状态

- 收盘集合竞价新版报告结构已完成
- 标题已统一为：`A股持仓收盘集合竞价监控`
- “补跑说明”只允许出现在手动预览，不进入正式自动推送
- `15:31` 盘后固定价格交易报告链路已可正常生成
- 2026-07-06 当天数据源未返回 `15:05—15:30` 明细时，报告按设计显示：
  - `数据源暂不支持盘后固定价格交易数据`

### 12.6 验证结果

- `scripts/Tests/AuctionMonitor.Tests.ps1`：通过
- `scripts/Tests/OpenStrengthMonitor.Tests.ps1`：通过
- 计划任务已重装成功，含：
  - `AStockAuctionClose-1457`
  - `AStockAuctionClose-1459`
  - `AStockAuctionClose-1500`
  - `AStockAfterHoursFixed-1531`

### 12.7 后续观察重点

下一交易日优先观察：

1. `15:01` 是否按新版规则发送收盘集合竞价报告
2. `15:31` 是否发送盘后固定价格交易报告
## 11. 2026-07-07 quick diagnosis notes

- `auction_open` on `2026-07-07` did not complete its `09:26` open-auction push because Eastmoney quote requests repeatedly failed with `curl: (56) Failure when receiving data from the peer` from `09:20` onward.
- `open_strength` had a split-brain issue: refreshed `open_0930.json` and `snapshot_0940.json` contained valid data, but an earlier report file had been generated before those refreshed snapshots were written. Regenerating the report after refreshed captures restored the missing fields.
- `Run-OpenStrengthCapture.ps1` now reuses `data/auction_open/cache/daily_metrics_YYYYMMDD.json`, so `prev_close`, open price fallback, current price fallback, and amount-ratio fields are more robust when live quote payloads are partial.
- Fixed report dry-run behavior: `Run-FormalReplayPush.ps1 -NoPush` now skips pending Feishu replay, making self-checks safe.
- `Get-HeldQuoteRows` now treats detail enrichment as optional end-to-end. Even if Eastmoney detail fields or local detail-cache merge fail, base quotes should still continue and snapshots can still be written.
- `主力总流入 / 主力总流出` still depends on Eastmoney detail fields. If the source returns literal `"-"` for both in/out legs on a stock, the report intentionally keeps `--` instead of fabricating totals.
- `anomaly_monitor` was healthy on 2026-07-07 overall; the visible error was a transient Feishu send failure at `10:05`, not a broken anomaly detection chain.
## 2026-07-17 Replay Constraint

- Cross-day pending Feishu messages must be protected against concurrent replay.
- The project now relies on queue-file claiming inside `scripts/Replay-PendingFeishuPushes.ps1`:
  - `queued_push_*.json` is renamed to `*.processing.json` before send
  - only the task that claims the file may process it
  - failed or deferred replay restores the file back to `.json`
- This protection is required because both:
  - `scripts/Run-FormalReplayPush.ps1`
  - `scripts/Run-AnomalyMonitor.ps1`
  replay pending pushes when they start.
- Previous-day queued messages are now stale immediately and must be dropped on replay; they must never be deferred into a later session or sent across trading dates.

## 2026-07-17 After-Hours Unit Constraint

- For Tushare Pro after-hours data:
  - `after_hours_volume` is in `手`
  - `after_hours_amount` is in `千元`
- The project standard output unit is:
  - volume displayed as `手`
  - amount stored and formatted as `元`
- Therefore `scripts/TushareAfterHoursShared.ps1` must multiply imported Tushare `after_hours_amount` by `1000` before downstream reporting.
- If a future refactor touches after-hours import or report formatting, preserve this conversion rule or the report will understate after-hours traded amount by 1000x.
