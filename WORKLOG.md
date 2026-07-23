# A股已持股份主力资金流动报告 - 维护记录

## 最近一次主线整理

- 已将项目主线保存到 GitHub
- 远端仓库：
  - `https://github.com/guotianming0317-lang/Kimi-01--.git`
- 当前主线分支：
  - `main`

## 重点修复记录

### 1. 监控范围从旧半导体池切换为“仅持仓”

#### 问题

项目最初基于旧的半导体观察池逻辑，不符合“只看已持仓股票”的需求。

#### 处理

- 新增持仓清单读取逻辑：
  - `scripts/Holdings.ps1`
- 持仓来源改为：
  - `data/holdings.csv`
- 固定报告、异常预警均切换到持仓口径

#### 结果

后续所有报告默认基于持仓清单，不再依赖旧的半导体股票池。

---

### 2. 飞书推送标色缺失

#### 问题

早期推送中，涨跌幅、流入/流出颜色未正确显示，阅读困难。

#### 处理

- 在公共格式化逻辑中统一处理：
  - 正值红色
  - 负值绿色
- 核心函数位于：
  - `scripts/HeldStockMonitorShared.ps1`

#### 结果

当前主力净额、涨跌幅、特大单/大单/中小单、主力总流入/总流出已支持颜色标记。

---

### 3. PowerShell 弹窗与后台运行

#### 问题

定时执行时 PowerShell 窗口频繁弹出，影响使用。

#### 处理

- 定时任务安装脚本改为使用隐藏窗口参数
- 相关脚本：
  - `scripts/Install-WindowsFundPushTasks.ps1`

#### 结果

自动任务以更后台的方式运行，减少前台弹窗。

---

### 4. 中文路径 / PowerShell `-File` 路径问题

#### 问题

在项目位于中文目录时，多次出现：

- `-File 形式参数的参数 scripts\xxx.ps1 不存在`

本质上是：

- 终端当前目录不对
- 或使用相对路径时路径解析失败

#### 处理经验

优先使用以下两种方式之一：

1. 先 `cd` 到项目目录，再运行相对路径
2. 直接使用脚本绝对路径

#### 建议

今后给用户的命令，尽量优先提供完整路径版本，减少中文路径带来的歧义。

---

### 5. 计划任务重复间隔与异常预警拆分

#### 需求变化

- 固定报告频率改为 15 分钟，后又改回 30 分钟
- 异常预警改为独立运行，而不是绑定固定报告

#### 处理

- 固定报告：
  - 30 分钟
- 异常预警：
  - 1 分钟
- 待补发重放：
  - 5 分钟

统一由以下脚本维护：

- `scripts/Install-WindowsFundPushTasks.ps1`

#### 结果

监控拆成三类任务：

- 固定报告
- 异常预警
- 待补发重放

---

### 6. “主力总流入 / 主力总流出” 数据错误

#### 问题

早期版本把批量行情接口中的某组字段误当成真实总流入/总流出，导致：

- 总流入和总流出相同
- 数值明显不合理
- 旧快照被污染

#### 核心定位过程

通过字段探测脚本比对东财接口字段：

- `scripts/Probe-EastmoneyFlowFields.ps1`

确认：

- 批量接口 `ulist.np/get` 中那组字段不能直接信任
- 单股详情接口 `qt/stock/get` 才能提供可信的原始明细

#### 修复方式

在 `scripts/HeldStockMonitorShared.ps1` 中：

1. 批量接口不再作为总流入/总流出的可信来源
2. 真实总流入/总流出改为依赖单股详情接口补充
3. 如果原始字段缺失或不满足基本合理性，则显示 `--`

#### 结果

现在“主力总流入 / 主力总流出”只有在详情字段可信时才展示，不再展示伪数据。

---

### 7. 旧快照补发时总流入 / 总流出丢失

#### 问题

15:00 的旧快照是在修复前生成的，因此补发时虽然主力净额等数据存在，但总流入 / 总流出缺失。

#### 处理

新增两条脚本链路：

1. 导出持仓详情：
   - `scripts/Export-HeldDetailData.ps1`
2. 模拟收盘补发：
   - `scripts/Send-SimulatedClosePush.ps1`

处理流程：

1. 先导出东财详情字段到本地 JSON
2. 再让模拟补发脚本吃这份 JSON
3. 用这份详情补齐旧快照中缺失的总流入 / 总流出

#### 结果

15:00 收盘补发消息已可以基于本地详情文件补齐真实总流入 / 总流出。

---

### 8. 模拟补发脚本中文编码问题

#### 问题

直接在 PowerShell 脚本源码中写中文时，当前环境多次出现编码损坏，表现为：

- 脚本解析报错
- 中文文本变成乱码

#### 处理

最终采用“源码 ASCII，运行时转中文”的做法：

- `scripts/Send-SimulatedClosePush.ps1`

通过统一函数在运行时把 Unicode 转成中文，避免脚本文件本身被编码链路破坏。

#### 结果

补发脚本现在既能稳定执行，又能输出中文标题和中文正文。

---

### 9. 飞书网络问题 / GitHub 网络问题

#### 现象

曾多次出现：

- 飞书 webhook 无法连接
- GitHub push 失败
- PowerShell / curl 443 不通
- 浏览器可上网，但命令行 HTTPS 不通

#### 实际结论

这类问题多数不是代码错误，而是本机网络出口、VPN、代理、命令行 HTTPS 链路不稳定。

#### 当前缓解措施

飞书发送已增加：

- 重试
- 消息分段
- 待补发队列
- 重放脚本

东财请求已增加：

- 重试
- TLS 处理
- curl 兜底

#### 处理经验

如果再次出现网络问题，优先检查：

1. `Test-NetConnection open.feishu.cn -Port 443`
2. `Test-NetConnection github.com -Port 443`
3. VPN / 杀毒 / 代理 / 网络出口

---

## 当前重要事实

- 主线已推送到 GitHub `main`
- 后续功能开发应切新分支
- `data/holdings.csv` 是当前持仓单一事实来源
- “主力总流入 / 总流出” 以东财详情字段为准
- 个别源头缺值股票允许显示 `--`

## 下次优先回顾

如果后续继续改这个项目，优先回顾：

1. `PROJECT_CONTEXT.md`
2. `WORKLOG.md`
3. `scripts/HeldStockMonitorShared.ps1`
4. `scripts/Send-SimulatedClosePush.ps1`
5. `scripts/Install-WindowsFundPushTasks.ps1`

---

### 10. 2026-06-24 上午固定报告未自动送达

#### 现象

用户反馈 2026-06-24 早盘“今天也没主动发推送”。

排查后确认：

- Windows 计划任务并没有停，上午固定报告任务仍处于 `Enabled / Ready`
- `AStockMainFundFeishuPush-Morning` 实际运行时间为 `2026/6/24 10:00:01`
- 下一次运行时间正常显示为 `2026/6/24 10:30:00`

说明问题不在“任务没有安装 / 没有触发”，而在“任务触发后的执行链路”。

#### 当天实际链路结果

1. `09:30`
   - 日志出现：
     - `quote failed without snapshot fallback :: 输入对象“-”不是数字。`
   - 结论：
     - 东财返回的某个字段仍然是 `"-"`
     - 当前脚本某处仍存在把该字段直接强制转数字的路径
     - 因为当天 `09:30` 没有可用快照回退，所以第一条报告直接失败

2. `10:00`
   - 已成功生成报告文件：
     - `data/outbox/formal_replay_20260624_100007.md`
   - 但日志出现：
     - `push failed ... :: Feishu sender exited with code 1`
   - 结论：
     - 数据抓取与报告生成链路是通的
     - 故障点落在飞书发送阶段，而不是定时任务或正文生成阶段

3. 手动补发
   - 使用 `scripts/Send-FeishuCard.ps1` 对 `formal_replay_20260624_100007.md` 手动补发
   - 返回：
     - `Feishu push succeeded.`
   - 同时 `data/pending_pushes/` 为空
   - 结论：
     - 当时更像一次瞬时发送异常
     - 不是 webhook 永久失效，也不是正文内容本身无法发送

#### 经验总结

以后如果再次出现“今天没有自动推送”，不要先假设任务坏了，应按下面顺序排查：

1. 查 `data/logs/fund_push.log`
2. 查 `data/outbox/` 是否已经生成对应时段的 `.md`
3. 查 `data/pending_pushes/` 是否有待补发队列
4. 查计划任务：
   - `AStockMainFundFeishuPush-Morning`
   - `AStockMainFundFeishuPush-Afternoon`
5. 根据结果区分是：
   - 没取到数据
   - 生成了报告但飞书发送失败
   - 任务根本没触发

#### 后续待修重点

- 继续清理 `"-"` 被当成数字解析的问题，尤其是 `09:30` 首条报告场景
- 飞书发送失败虽然可手动补发成功，但仍需继续观察是否存在偶发网络或 webhook 瞬时异常

#### 后续修复结果（同日补充）

本轮没有只做“补发”，而是补了长久方案：

1. 上午漏掉的三份固定报告已手动补发成功：
   - `10:30`
   - `11:00`
   - `11:30`

2. 在 `scripts/HeldStockMonitorShared.ps1` 中新增统一安全数值解析：
   - `Get-SafeDoubleOrNull`
   - `Get-SafeDouble`
   - `Get-SafeSum`

3. 固定报告 / 异常监控 / 模拟补发脚本改为统一使用安全数值解析：
   - `scripts/Run-FormalReplayPush.ps1`
   - `scripts/Run-AnomalyMonitor.ps1`
   - `scripts/Send-SimulatedClosePush.ps1`

4. 修复目标：
   - 任何字段出现 `"-"` 时，不再把整份报告打崩
   - 排序、求和、涨跌方向判断、中小单合并、日内变化计算都统一走安全解析

5. 飞书发送链路补齐一处闭环：
   - `scripts/Send-FeishuCard.ps1`
   - 现在即使飞书返回业务失败响应，也会写入 `data/pending_pushes/`
   - 不再只对“网络重试耗尽”这一类失败入队

6. 测试结果：
   - `scripts/Tests/Holdings.Tests.ps1`
   - 已补充 `"-"` 缺失值场景覆盖
   - 全部测试通过

7. 现场自检结果：
   - 使用实时数据执行 `Run-FormalReplayPush.ps1 -NoPush`
   - 成功生成：
     - `data/outbox/formal_replay_20260624_122247.md`

结论：

- `"-"` 数值解析这类老问题，已经从“单点补丁”升级为“统一安全数值层”
- 后续如果再因 `"-"` 打崩上午首条报告，应优先检查是否还有遗漏脚本未接入 `Get-SafeDouble*` 体系

---

### 11. 2026-06-29 13:01 报告中个股“主力总流入/总流出”缺失

#### 现象

`formal_replay_20260629_130008.md` 中：

- `三只松鼠（300783）`
- `上海九百（600838）`

两只股票的“主力总流入 / 主力总流出”都显示为 `--`。

#### 原因定位

不是飞书渲染问题，也不是报告正文遗漏，而是东财详情字段本身不完整：

- `600838`
  - `f138 = "-"`
  - `f139 = 1033045`
  - `f141 = 3588341`
  - `f142 = 4419310`
- `300783`
  - `f138 = "-"`
  - `f139 = "-"`
  - `f141 = 13883780`
  - `f142 = 11892343`

原来的 `Get-MainFlowSummary` 逻辑要求四个基础字段都完整，只要其中任意一个为 `"-"`，整行就直接显示 `--`。

#### 修复思路

已改为“能根据净额反推就反推”：

- 新增 `Resolve-OrderInOut`
- 在 `Get-MainFlowSummary` 中引入：
  - `SuperFlow`
  - `LargeFlow`

推导规则：

1. 如果 `In/Out` 都有，直接使用
2. 如果只缺一侧，使用 `净额 = 流入 - 流出` 反推
3. 如果双侧都缺，但净额为 `0`，则按 `0 / 0` 处理
4. 只有完全无法可靠推导时，才继续显示 `--`

#### 本次补发结果

已生成修正补发版：

- `data/outbox/formal_replay_20260629_130008_corrected.md`

并已成功推送到飞书，标题为：

- `A股已持股份资金动向监控｜资金报告（13:01 修正补发）`

本次补齐后的值为：

- `三只松鼠（300783）`
  - 主力总流入：`1,388.38万元`
  - 主力总流出：`1,189.23万元`
- `上海九百（600838）`
  - 主力总流入：`358.83万元`
  - 主力总流出：`545.24万元`

---

### 12. 2026-06-30 调整异常预警灵敏度

#### 调整内容

将 `scripts/Run-AnomalyMonitor.ps1` 的默认异常阈值从：

- `50000000`（5000 万元）

调整为：

- `30000000`（3000 万元）

#### 调整原因

原阈值偏保守，更适合只盯特别剧烈的瞬时资金波动；  
本次调整为 3000 万后，可以更早捕捉中等强度的大额异动，同时仍保留一定的降噪能力。

#### 影响

- 后续默认异常预警会更敏感
- Windows 计划任务不需要重装，脚本默认值修改后会直接生效

#### 自检结果

为避免影响正式监控，本次使用单独目录进行了模拟异常自检：

- 自检目录：
  - `data/anomaly_monitor_selfcheck/`
- 自检脚本：
  - `scripts/Run-AnomalyMonitor.ps1`
- 自检方式：
  - 保持正式默认阈值为 `30000000`
  - 仅在自检运行时临时传入超低阈值，强制生成一条异常预警
  - 不发送飞书，只验证生成链路

自检结果：

- 已成功生成模拟异常文件：
  - `data/anomaly_monitor_selfcheck/outbox/anomaly_alert_20260630_120801.md`
- 说明以下链路均正常：
  - 分钟级任务逻辑
  - 快照读取与对比
  - 异常正文生成
  - 资金动向分项展示
  - 主力总流入 / 主力总流出展示

补充说明：

- 模拟文件中出现 `+0.00万元` 一类内容，是因为自检时人为把阈值压到极低，只为强制触发
- 这不代表正式监控会按 0 元级别报警
- 正式监控当前仍按 `3000 万元` 阈值运行

---

### 13. 2026-06-30 固定报告静默失败补救

#### 触发背景

`2026-06-30 09:30` 与 `10:00` 两次固定报告任务都实际触发，但东财接口短时中断：

- `curl: (56) Failure when receiving data from the peer`

同时当天当时还没有成功快照，因此旧逻辑会出现：

- 没有实时行情
- 没有快照可回退
- 最终只写日志，不主动推送

也就是“静默失败”。

#### 修复内容

在 `scripts/Run-FormalReplayPush.ps1` 中补齐第三条路径：

1. 有实时数据：正常发报告
2. 无实时数据但有快照：发降级报告
3. 无实时数据且无快照：自动发一条“接口异常说明”

实现效果：

- 不再因为接口临时中断而完全静默
- 用户至少会收到一条说明，知道是接口异常，不是任务停摆
- 该说明消息标题会使用：
  - `A股已持股份资金动向监控｜接口异常说明`

#### 细节修正

同时修复了一处展示问题：

- 在“完全没有有效行情且无快照”的场景下
- 持仓范围合计主力净额不再显示伪造的 `0.00万元`
- 改为明确显示 `--`

#### 测试覆盖

`scripts/Tests/Holdings.Tests.ps1` 已新增验证：

- 主行情失败且无快照时，脚本仍能生成说明文件
- 文件中应出现：
  - `【异常】本次未获取到有效行情，且没有可用快照回退`
- 此时合计主力净额应显示：
  - `--`
---

### 14. 2026-07-01 codex/auction-monitoring 鍒嗘敮寮€鍙戣褰?

#### 鍒嗘敮淇℃伅

- 褰撳墠鍔熻兘鍒嗘敮锛?`codex/auction-monitoring`
- 鏈℃槸鍦?`main` 涔嬪鐙珛鎼缓鐨勬柊鍔熻兘鍒嗘敮
- 鐩墠杩樹笉鍚堝苟鍥?`main`
- 鍘熷洜锛氶渶绛夊埌鏄庡ぉ浜ゆ槗鏃ョ敤鐪熷疄绔炰环鏁版嵁楠岃瘉閫氳繃鍚庡啀鍚堝苟

#### 浠婂ぉ瀹屾垚鐨勬牳蹇冨姛鑳?

1. 鏂板 A鑲￠泦鍚堢珵浠锋寔浠撶洃鎺ч摼璺?
   - 寮€鐩樼珵浠风洃鎺х偣锛?`09:15`銆?`09:20`銆?`09:23`銆?`09:24:30`銆?`09:25`銆?`09:26`
   - 灏剧洏绔炰环鐩戞帶鐐癸細`14:57`銆?`14:59`銆?`15:00`
   - `09:26` 杈撳嚭寮€鐩樻渶缁堟姤鍛?
   - `15:00` 杈撳嚭灏剧洏鏈€缁堟姤鍛?

2. 鏂板绔炰环琛ュ緱鏈哄埗
   - 鏂拌剼鏈細`scripts/Run-AuctionCatchUp.ps1`
   - 鐢ㄤ簬鍦ㄧ珵浠风獥鍙ｆ湡鍐呮寜鍒嗛挓琛ュ彇蹇収
   - 鐢ㄤ簬闃叉鐢佃剳鎴栫綉缁滅◢鏅氬氨缁悗锛屽畬鍏ㄩ敊杩囨煇涓珵浠风偣

3. 鏂板绔炰环鍏辩敤閫昏緫涓庢祴璇?
   - 鏂拌剼鏈細`scripts/AuctionMonitorShared.ps1`
   - 鏂拌剼鏈細`scripts/Run-AuctionMonitor.ps1`
   - 鏂版祴璇曪細`scripts/Tests/AuctionMonitor.Tests.ps1`

4. 椋炰功鎺ㄩ€侀鏍艰皟鏁?
   - 集合竞价推送改为绱壊椤跺簳锛岀敤浜庝笌鈥滃浐瀹氱洃鎺р€濆拰鈥滅灛鏃跺ぇ棰濆紓甯糕€濆仛鍖哄垎
   - 鏍囬鍓嶆坊鍔犵传鑹插渾鐐瑰浘鏍?
   - 涓轰簡閬垮厤 PowerShell 5.1 涔辩爜锛屽浘鏍囨敼涓鸿繍琛屾椂鐢?`[char]::ConvertFromUtf32(0x1F7E3)` 鍔ㄦ€佺敓鎴?

5. 鎶ュ憡姝ｆ枃鏍峰紡鍗囩骇
   - 涓偂鈥滃悕绉?+浠ｇ爜鈥濇敼涓虹传鑹诧紝骞跺姞绮?
   - `[鍓嶅鏉僝 鏍囪瘑鏀逛负钃濊壊
   - 鈥滃己搴﹁瘎鍒嗏€濇寜鍒嗘暟鍖洪棿鏄剧ず棰滆壊锛?
     - `80-100` 绾㈣壊
     - `50-79` 姗欒壊
     - `0-49` 缁胯壊
   - 鏂囨湰涓槑纭爣娉ㄢ€滃紑鐩樼珵浠风洃鎺р€濇垨鈥滃熬鐩樼珵浠风洃鎺р€?

6. 绔炰环鈥滃墠澶嶆潈鈥濋€昏緫
   - `data/holdings.csv` 鏂板 `PrevCloseMode`
   - `002594 姣斾簹杩?` 宸茶涓?`qfq`
   - `scripts/Holdings.ps1` 澧炲姞 `PrevCloseMode` 褰掍竴鍖栧鐞?
   - `scripts/AuctionMonitorShared.ps1` 鍦?`qfq` 妯″紡涓嬩紭鍏堜娇鐢ㄥ墠澶嶆潈鏄ユ敹锛岄伩鍏嶆定璺屽箙璁＄畻澶辩湡
   - 鎶ュ憡涓湪瀵瑰簲涓偂鍚嶇О鍚庢樉绀?`〔鍓嶅鏉僝`

#### 浠婂ぉ宸查獙璇佺殑缁撴灉

- 鐩稿叧 Pester 娴嬭瘯宸查€氳繃
- 绱壊鏍囬鏍峰紡宸叉垚鍔熸帹閫佸埌椋炰功
- 涓偂鈥滃悕绉?+浠ｇ爜鈥濈传鑹插姞绮楁樉绀哄凡鍦ㄩ涔︿腑楠岃瘉姝ｅ父
- `[鍓嶅鏉僝` 钃濊壊鏍囪宸查獙璇佹甯?
- 鐩稿叧鏁板瓧绮椾綋鏄剧ず宸查獙璇佹甯?

#### 浠婂ぉ灏氭湭瀹屾垚鐨勬渶鍚庝竴姝?

- 鏄庡ぉ浜ゆ槗鏃ラ渶鐢ㄧ湡瀹炵珵浠锋暟鎹仛涓€杞畬鏁撮獙璇?
- 楂樹紭鍏堢骇楠岃瘉鐐癸細
  - `09:15-09:26` 寮€鐩樼珵浠峰悇鏃堕棿鐐瑰揩鐓ф槸鍚﹀彲姝ｅ父钀藉湴
  - `14:57-15:00` 灏剧洏绔炰环鏄惁鍙甯稿嚭鎶?
  - `姣斾簹杩?002594` 鍓嶅鏉冩定璺屽箙鏄惁璁＄畻姝ｅ父
  - `重点提醒` 鎺掑簭鏄惁绗﹀悎鐪嬩附涔犳儻
  - `操作提示` 鏂囨鏄惁杩樺彲缁х画寰皟

#### 缁撹

浠婂ぉ鐨勫垎鏀紑鍙戝凡瀹屾垚涓昏鎼缓銆佹枃妗堝垏鎹€佹牱寮忚皟鏁淬€佸墠澶嶆潈鏀寔鍜屾祴璇曢獙璇併€?
鐩墠鐘舵€侊細**鍙敤浜庢槑澶╁疄鐩樻暟鎹洖楠岋紝浣嗘殏涓嶅悎骞跺洖 `main`**銆?
---

### 15. 2026-07-02 10:30 鍥哄畾鐩戞帶涓や粙涓偂鈥滀富鍔涘€绘祦鍏? / 鎬绘祦鍑衡€濆瓧娈电己澶辨帓鏌?

#### 闂鐜拌薄

- 鐢ㄦ埛鍙嶉 `2026-07-02 10:30` 鍥哄畾鐩戞帶鎺ㄩ€佷腑锛?
  - `涓法鑺?U锛?88549锛?
  - `娌～浜т笟锛?88126锛?
- 杩欎袱鍙偂绁ㄧ殑鈥滀富鍔涘€绘祦鍏? / 涓诲姏鎬绘祦鍑衡€濇樉绀轰负 `--`
- 浣嗗叾浠栬鎯呭瓧娈碉紙涓诲姏鍑€棰濄€佹定璺屽箙銆佺壒澶у崟 / 澶у崟 / 涓皬鍗曪級鍧囨甯稿睍绀?

#### 鑷缁撴灉

- `10:30` 鍘熸姤鍛婃枃浠讹細
  - `data/outbox/formal_replay_20260702_103026.md`
- 蹇収鏂囦欢锛?
  - `data/snapshots/20260702/snapshot_103026.json`
- 鏌ョ湅蹇収鍙‘璁わ細
  - `688549` 鍜?`688126` 鍦?`10:30` 鏃剁殑 `super_in / super_out / large_in / large_out` 鍧囦负 `null`
  - 鍥犳鎶ュ憡涓樉绀?`--` 鏄鍚堝綋鏃舵暟鎹姸鎬佺殑锛屼笉鏄姤鍛婄粍瑁呮紡鍐?

#### 鏍规湰鍘熷洜

- 褰撴涓婚鎯呮帴鍙ｅ凡杩斿洖杩欎袱鍙偂绁ㄧ殑涓诲姏鍑€棰濈瓑鍩虹鏁版嵁
- 浣嗙敤浜庤ˉ鍏呪€滀富鍔涘€绘祦鍏? / 鎬绘祦鍑衡€濈殑涓滆储璇︽儏鎺ュ彛鍦ㄥ綋鏃跺杩欎袱鍙偂绁ㄨ繑鍥炰簡绌哄€?
- 鍥犳鏈闂灞炰簬锛?
  - **璇︽儏琛ュ叏閾捐矾褰撴鎶栧姩**
  - 涓嶆槸鎸佷粨婕忕洃鎺?
  - 涓嶆槸绉戝垱鏉胯偂绁ㄦ案涔呬笉鏀寔

#### 鐜板満楠岃瘉

- 鍚庣画鍗曠嫭瀵?`688126` 鍜?`688549` 鎵ц涓滆储瀛楁鎺㈡祴锛岃幏寰楀埌鍙敤鐨勭湡瀹炶鎯呭瓧娈?
- 鍙‘璁よ繖涓や釜鏍囩殑骞朵笉鏄棤娉曡幏鍙?鈥滀富鍔涘€绘祦鍏? / 鎬绘祦鍑衡€?
- 璇存槑鏄?`10:30` 褰撴杩斿洖绌哄€硷紝鑰屼笉鏄案涔呮€х己瀛?

#### 宸插畬鎴愪慨澶?

- 淇敼鑴氭湰锛?
  - `scripts/HeldStockMonitorShared.ps1`
- 鏂板閫昏緫锛?
  - 濡傛灉鏌愬彧鑲＄エ绗竴娆℃姄鍙栧埌鐨勮鎯呮槸绌哄€兼垨涓嶆弧瓒虫€绘祦鍏? / 鎬绘祦鍑烘帹瀵兼潯浠?
  - 鍒欒嚜鍔ㄥ璇ヨ偂绁ㄥ啀琛ヤ竴娆¤鎯呮姄鍙?
- 鐩爣锛?
  - 闄嶄綆鈥滈儴鍒嗚偂绁ㄨ鎯呮湁锛屼絾鎬绘祦鍏? / 鎬绘祦鍑虹己澶扁€濈殑姒傜巼

#### 娴嬭瘯缁撴灉

- 娴嬭瘯鑴氭湰锛?
  - `scripts/Tests/Holdings.Tests.ps1`
- 鏂板楠岃瘉锛?
  - 瀹屾暣璇︽儏搴斿垽瀹氫负鍙敤
  - 绌鸿鎯呭簲鍒ゅ畾涓洪渶瑕侀噸璇?
- 杩愯缁撴灉锛?
  - `All holdings tests passed.`

#### 琛ュ彂鎯呭喌

- 鏈鏈敤 `10:43+` 鐨勫疄鏃舵暟鍊煎幓鍐掑厖 `10:30` 鍘嗗彶鏁板€?
- 鍘熷洜锛氳繖鏍蜂細鎶婅ˉ鍙戞枃妗堝彉鎴愨€滃綋鍓嶅€肩偣鈥濊€屼笉鏄€?10:30 鍘熷鍙ｅ緞鈥?
- 鍥犳鏀逛负鍙戦€佷竴鏉♀€滅己澶卞瓧娈垫疆鍏呰鏄庘€濓細
  - `data/outbox/formal_replay_20260702_103026_supplement.md`
- 璇ユ潯琛ュ厖璇存槑宸叉垚鍔熷彂閫佸埌椋炰功
- 鏂囦腑鏄庣‘璇存槑锛?
  - `10:30` 褰撴缂哄け鍘熷洜
  - 脚本已修复为自动二次补抓
  - 当前实时回读值仅用于确认链路恢复锛屼笉绛夊悓浜?`10:30` 鍘嗗彶鍊?
---

### 16. 2026-07-02 集合竞价推送分流到新飞书群

#### 变更背景

- 用户反馈当前消息过于密集
- 决定将“集合竞价”相关推送单独发到新建飞书群
- 原固定监控与异常预警仍保留在原群，不做迁移

#### 新 webhook

- 集合竞价专用 webhook：已配置在本机设置文件/环境变量中，日志不保存真实地址。

#### 本次调整内容

1. 新增本地配置文件
   - `data/auction_feishu.settings.yml`
   - 仅供集合竞价链路读取

2. 调整发送优先级
   - 文件：`scripts/Send-FeishuCard.ps1`
   - 修正为：如果显式传入 `-SettingsPath`
   - 则优先使用该设置文件中的 webhook / secret
   - 不再被环境变量中的默认飞书配置覆盖

3. 调整集合竞价发送链路
   - 文件：
     - `scripts/Run-AuctionMonitor.ps1`
     - `scripts/Run-AuctionCatchUp.ps1`
   - 逻辑：
     - 若存在 `data/auction_feishu.settings.yml`
     - 则集合竞价推送与补跑推送都使用该配置文件
     - 否则回退到原默认发送方式

4. 集合竞价上下文补充
   - 文件：`scripts/AuctionMonitorShared.ps1`
   - 新增集合竞价专用设置文件路径注入

#### 验证结果

- `scripts/Tests/AuctionMonitor.Tests.ps1`
  - 运行结果：`All auction monitor tests passed.`
- 已人工发送一条“集合竞价分流测试”到新群
- 用户确认：**已收到**

#### 当前分流规则

- 集合竞价相关推送：
  - 发往新群
- 固定监控 / 异常预警：
  - 继续发往原群

#### 备注

- `data/auction_feishu.settings.yml` 位于 `data/` 目录下
- 该目录已在 `.gitignore` 范围内
- 因此属于本地运行配置，不会混入主线版本库
## 2026-07-03 集合竞价漏发排查与修复

### 现象

- 用户今天只收到一条“分流测试”消息，没有收到真实的集合竞价数据推送。
- 该“分流测试”消息不是今日实时推送，而是前一日为了验证新群分流所做的人为测试。

### 排查结论

- `data/auction_open/logs/auction_open.log` 显示：
  - `2026-07-03 09:15` 成功保存了 `snapshot_open_0915.json`
  - `09:20 / 09:23 / 09:24:30 / 09:25 / 09:26` 都有 `start open checkpoint=...`
  - 但这些检查点后面没有继续出现 `snapshot saved` / `pushed`
- 说明不是定时任务没触发，而是脚本在运行过程中中断。

### 根因

- 集合竞价脚本在每个检查点都会调用 `push2his.eastmoney.com`
- 该接口用于拉取：
  - 昨收参考值
  - 昨日成交额
  - 近 5 日平均成交额
  - 前复权股票参考收盘价
- 今天复跑 `Run-AuctionMonitor.ps1` 的 `0920` / `0926` 检查点时，稳定复现：
  - `Eastmoney request failed after 3 attempts`
  - `Failed to connect to push2his.eastmoney.com port 443`
- 因旧逻辑会直接抛错退出，所以 `09:20` 之后真实推送链路中断。

### 修复策略

1. 为集合竞价增加“当日参考数据缓存”
   - 路径：`auction_open/cache/daily_metrics_YYYYMMDD.json`
   - `auction_close` 同样适用

2. 将参考数据获取改为“缓存优先兜底”
   - 若本地缓存已完整覆盖持仓股票，则后续检查点直接使用缓存
   - 若实时拉取成功，则更新缓存
   - 若实时拉取失败，则优先回退到缓存
   - 若缓存也不存在，则允许部分字段为空，但不再因为该接口失败导致整段报告中断

3. 为前复权股票增加容错
   - 有缓存时继续使用缓存中的 `prev_close`
   - 无缓存时允许为空，但不阻断整份集合竞价报告

4. 优化超时行为
   - 当历史参考接口第一次失败后，不再对后续所有股票逐只重复慢重试
   - 避免把 `09:20-09:26` 的定时监控窗口整体拖死

### 代码改动

- `scripts/AuctionMonitorShared.ps1`
  - 新增：
    - `DailyMetricsCachePath`
    - `ConvertTo-AuctionMetricMap`
    - `Read-AuctionDailyMetricsCache`
    - `Save-AuctionDailyMetricsCache`
  - `Get-AuctionDailyMetricsMap`
    - 支持缓存读取
    - 支持接口失败回退缓存
    - 接口失败后停止逐股重复慢重试
  - `Get-AuctionQuoteRows`
    - 新增 `-CachePath`

- `scripts/Run-AuctionMonitor.ps1`
  - 调用集合竞价抓取时传入 `DailyMetricsCachePath`

- `scripts/Run-AuctionCatchUp.ps1`
  - 补跑链路同样使用缓存兜底

- `scripts/Tests/AuctionMonitor.Tests.ps1`
  - 新增断网/缓存兜底场景测试
  - 覆盖前复权股票在参考接口失败时的回退行为

### 验证结果

- `scripts/Tests/AuctionMonitor.Tests.ps1`
  - 通过：`All auction monitor tests passed.`

- `scripts/Tests/OpenStrengthMonitor.Tests.ps1`
  - 通过：`All open strength monitor tests passed.`

### 备注

- 在当前 Codex 受限运行环境中，`push2.eastmoney.com` 也可能被网络层拦截，因此这里无法直接代替用户本机完成真实补发验证。
- 但“集合竞价因 `push2his` 断连而整段退出”的老问题已经完成结构性修复。

---

## 2026-07-06 新规适配记录

### 目标

适配 2026-07-06 起实施的 A 股收盘新规：

- 保留 `14:57—15:00` 收盘集合竞价监控
- 新增 `15:05—15:30` 盘后固定价格交易监控
- 防止把盘后固定价格交易误判成收盘集合竞价
- 修正主板 `ST / *ST` 涨跌停计算口径为 `10%`

### 本次实际改动

- `scripts/AuctionMonitorShared.ps1`
  - 新增 `after_hours` 会话支持
  - 新增收盘集合竞价与盘后固定价格交易的独立报告结构
  - 新增 `regular_session_amount / closing_auction_amount / after_hours_amount / total_day_amount`
  - 收盘标题统一为：`A股持仓收盘集合竞价监控`
  - “补跑说明”改为只在手动预览中显示

- `scripts/Run-AuctionMonitor.ps1`
  - 收盘集合竞价仍由 `15:00` 采集完成
  - 正式推送延后到 `15:01`

- `scripts/Run-AfterHoursFixedPriceReport.ps1`
  - 新增 `15:31` 盘后固定价格交易报告执行入口

- `scripts/Run-AuctionCatchUp.ps1`
  - 继续兼容尾盘补跑链路

- `scripts/Install-WindowsFundPushTasks.ps1`
  - 重新安装并加入 `AStockAfterHoursFixed-1531`

### 验证结果

- `scripts/Tests/AuctionMonitor.Tests.ps1`
  - 通过：`All auction monitor tests passed.`

- `scripts/Tests/OpenStrengthMonitor.Tests.ps1`
  - 通过：`All open strength monitor tests passed.`

- 计划任务重装成功：
  - `AStockAuctionClose-1457`
  - `AStockAuctionClose-1459`
  - `AStockAuctionClose-1500`
  - `AStockAfterHoursFixed-1531`

### 当天观察结果

- `15:31` 盘后固定价格交易报告链路可以成功生成
- 但 2026-07-06 当天数据源未返回 `15:05—15:30` 明细
- 因此盘后报告按预期显示：`数据源暂不支持盘后固定价格交易数据`

### 后续待观察

下一交易日重点确认：

1. `15:01` 收盘集合竞价是否按新版口径自动发送
2. `15:31` 盘后固定价格交易是否自动发送
3. 数据源是否开始返回真实的 `15:05—15:30` 盘后成交数据
## 2026-07-07 diagnosis and repair

### Symptoms

- `2026-07-07` open-auction push at `09:26` did not complete.
- `9:40` open-strength report showed many `--` fields even though later local snapshots contained values.
- fixed funds report sometimes lost `主力总流入 / 主力总流出`.
- anomaly chain showed a visible error during the trading session.

### Root causes

1. Eastmoney quote requests failed repeatedly during the opening-auction window with `curl: (56) Failure when receiving data from the peer`, so the old `auction_open` path never reached a usable `09:26` report.
2. `open_strength` had refreshed capture data, but an earlier report had already been generated from stale snapshot files; the report and snapshots were out of sync.
3. fixed funds reporting was too sensitive to optional detail enrichment. If Eastmoney detail fields or local detail-cache merge had an issue, the whole quote path could lose its snapshot opportunity. Also, some stocks truly return `"-"` for in/out detail legs, so those totals cannot be fabricated safely.
4. anomaly monitoring itself stayed alive; the visible failure was a transient Feishu send error, not a broken anomaly detector.

### Repairs applied

- `scripts/OpenStrengthMonitorShared.ps1`
  - added stronger fallbacks for `open_price` and `current_price` using trend bars
  - report generation now works correctly when fed refreshed `0930` and `0940` snapshots
- `scripts/Run-OpenStrengthCapture.ps1`
  - now reuses `data/auction_open/cache/daily_metrics_YYYYMMDD.json`
- `scripts/Run-FormalReplayPush.ps1`
  - `-NoPush` now skips pending-message replay, so dry-run checks stay side-effect free
- `scripts/HeldStockMonitorShared.ps1`
  - detail enrichment now has an outer safety wrapper and can no longer block the base quote snapshot path
  - runtime detail cache continues to be used as a best-effort fallback for `主力总流入 / 主力总流出`

### Verification

- regenerated `9:40` report after refreshed captures and confirmed the missing `prev_close`, `open_price`, `current_price`, and amount-ratio fields were restored
- `OpenStrengthMonitor.Tests.ps1` passed
- `AuctionMonitor.Tests.ps1` passed
- `Holdings.Tests.ps1` passed
- live anomaly dry-run completed with `未触发异常预警`

### Remaining reality

- if Eastmoney detail fields for a stock still return literal `"-"` on both in/out legs, the report should keep `--` for totals
- the opening-auction fix is code-complete, but the real proof will be the next live `09:26` trading-session run
---

## 2026-07-17 Cross-Day Replay Incident

- Symptom:
  - Around 13:00 on 2026-07-17, Feishu received two copies of the previous trading day's closing auction monitor message.
- Root cause:
  - The 2026-07-16 close-auction push failed at 15:01 because of Feishu frequency limiting and was queued into `data/pending_pushes/`.
  - Morning replay deferral correctly prevented the old message from appearing during the opening-session reports.
  - In the afternoon, both `Run-FormalReplayPush.ps1` and `Run-AnomalyMonitor.ps1` invoked `Replay-PendingFeishuPushes.ps1`.
  - The replay queue previously had no file-level lock, so two scheduled tasks could read and resend the same queued item at nearly the same time.
- Evidence:
  - `data/auction_close/logs/auction_close.log` shows `2026-07-16 15:01:05 error close checkpoint=1500 ... frequency limited`
  - `scripts/Run-FormalReplayPush.ps1` and `scripts/Run-AnomalyMonitor.ps1` both replay pending pushes before their own reporting logic.
- Fix:
  - Added queue-file claiming in `scripts/Replay-PendingFeishuPushes.ps1`
  - Replay now renames `queued_push_*.json` to `*.processing.json` before sending
  - Only the process that successfully renames the file can send it
  - If replay is deferred or send fails, the file is restored back to `.json`
- Result:
  - Cross-day queued pushes will not be duplicated by concurrent scheduled tasks
  - Any queued push whose queue date is earlier than the current local date is dropped immediately
  - No pending message may cross a calendar day, even if the original failure was caused by rate limiting
- Validation:
  - `scripts/Tests/QueuedPushReplay.Tests.ps1`
  - `scripts/Tests/AuctionMonitor.Tests.ps1`

## 2026-07-23 Cross-Day Replay Policy Hardening

- Replaced the old morning-deferral behavior in `scripts/Replay-PendingFeishuPushes.ps1` with an unconditional stale-date check.
- A queued item from any previous calendar date is deleted when discovered and is never sent.
- Verified with a simulated 2026-07-23 replay run against the stale 2026-07-21 auction-close queue item; it was dropped and `Replayed pending pushes: 0` was returned.
- This prevents delayed fixed reports, auction reports, anomaly reports, and other queued Feishu messages from appearing on a later trading day.

---

## 2026-07-17 Tushare After-Hours Amount Unit Fix

- Symptom:
  - The after-hours fixed-price report showed unrealistically small after-hours traded amounts, for example BYD displayed `0.47万元`.
- Root cause:
  - Tushare Pro after-hours volume is expressed in lots (`手`)
  - Tushare Pro after-hours amount is expressed in thousand CNY (`千元`)
  - The project previously treated `after_hours_amount` as CNY, so the displayed amount was 1000x too small.
- Evidence:
  - BYD sample row:
    - close = `90.18`
    - after_hours_volume = `517`
    - after_hours_amount = `4662.306`
  - Cross-check:
    - `90.18 × 517 × 100 = 4,662,306 CNY`
    - `4662.306 × 1000 = 4,662,306 CNY`
  - This proves the imported Tushare amount must be multiplied by `1000`.
- Fix:
  - `scripts/TushareAfterHoursShared.ps1`
    - convert `after_hours_amount` from thousand CNY into CNY at import time
  - `scripts/AuctionMonitorShared.ps1`
    - annotate after-hours volume as `手`
  - `data/after_hours_external.latest.json`
    - corrected the locally cached historical Tushare sample values to CNY
- Result:
  - BYD after-hours line now renders as:
    - `15:05—15:30盘后成交量：517 手`
    - `15:05—15:30盘后成交额：466.23万元`
- Validation:
  - `scripts/Tests/TushareAfterHours.Tests.ps1`
  - `scripts/Tests/AuctionMonitor.Tests.ps1`
  - `scripts/Tests/OpenStrengthMonitor.Tests.ps1`
