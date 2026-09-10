# asset_tracker v0.9.3 全量 Bug 审查报告

> **状态（2026-09-11）**：本报告的全部 finding 已随 **v0.9.4（快修包）+ v0.9.5（剩余全量）** 修复完毕。
> v0.9.4 修：H1/H2/H3/H6/H8/C1/M13/M22/M23(提示版)/L8/L10/L15/L16 + 对话框关闭崩溃。
> v0.9.5 修：C2、H4、H5、H7、H9、H10、M1/M2/M3/M4/M5/M6/M7/M9/M10/M11/M12/M14-M22、L1-L7/L9/L12-L18 中未含于 v0.9.4 的全部项。
> 两个已知的固有残留（非本次引入）：① v1 极老备份"持仓无 id + 交易有 holdingId"的错链风险由备份文件本身决定，导入无法凭空恢复映射；② market-linked 持仓抓取失败时日明细回退当前价（回填侧有失败即中止保护）。

> 审查日期：2026-09-11 · 基线 commit `523a2b8`（v0.9.3+29）
> 方式：`flutter analyze lib test`（0 issues，exit 0）+ 全量 `flutter test`（356 通过 6 skip）+ `dart analyze`/`dart test`（server 干净，5/5）
> 深度审查：3 路并行对抗审查（v0.9.3 diff、核心计算/域逻辑、同步链路与服务器）+ 人工交叉验证，关键 finding 均经代码复读确认。
> 结论标注：🔴 C=数据损坏/静默丢失 · 🟠 H=功能错误 · 🟡 M=边缘场景/口径 · ⚪ L=建议 · ✅=已修复

---

## 二、已修复：银行理财币种改 USD 保存后仍是 CNY（用户报告）✅

**根因（两个子问题叠加）**
1. `holding_dialogs.dart` 编辑保存路径：手动净值的银行理财被**无条件**翻成 `forex` 源（添加流程与编辑流程另一分支都判了"有行情代码才联动"，仅此一处漏判）→ `autoCny=true` → 币种保存时强制改回 CNY。
2. forex 联动持仓的币种字段可编辑、保存静默改回、无提示。

**修复**（commit 待提交）
- 编辑保存：`bankWealth → forex` 仅当行情代码非空时生效（与添加流程 `bankWealth when hasSymbol => 'forex'` 对齐）→ 手动净值理财的币种可改。
- 添加/编辑对话框：汇率联动持仓币种字段**禁用 + 说明**（"清空行情代码可解锁"），随类型/代码输入实时联动。
- 新增回归测试 `test/edit_holding_currency_test.dart`：手动理财改 USD 能存、联动理财锁 CNY。
- 验证：analyze 0 issues；全量 `flutter test` **356 通过（6 skip）**。

**遗留（需拍板）**：M26——编辑时换币种只改标签，数量/成本/净值不换算（见 M 级）。

---

## 三、C 级（数据损坏 / 静默丢失）

### C1 备份导入不清同步墓碑 →「删除 → 恢复备份 → 同步」恢复的数据被静默吞掉
- **位置**：`lib/services/backup_service.dart:74-84`（importJson 事务只清 accounts/holdings/transactions/snapshots/alertRules 五表）；`lib/data/asset_dao.dart:427` 的 `deleteAllTombstones` 存在但导入未调用。
- **触发**：设备 A 删除持仓（本地+服务器写入墓碑）→ 导入含该持仓的备份（备份行 updatedAt 必然早于墓碑）→ 下次同步 merge 时墓碑胜 → 恢复的行被删并推送，无任何报错。
- **修复**：导入清库事务内追加 `deleteAllTombstones()`（恢复的数据代表新意志）；或把导入行 updatedAt 提升为导入时刻。

### C2 备份导入 id 模型与 AUTOINCREMENT 脱节 → v1 备份导入错链/误拒
- **位置**：`backup_service.dart:243-254`（_effectiveIds）、:211-238（校验）、:86-159（插入）。
- **根因**：① 模型假设"空库自增从 max(1, maxExplicit+1) 起"，但表是 `PRIMARY KEY AUTOINCREMENT`，DELETE 不重置 sqlite_sequence 高水位 → 在用过的设备上导入缺省 id 行时实际分配 id ≠ 校验模型，引用错链且无外键兜底；② v1 备份 holdings 无 id、transactions 带 holdingId → 持仓重编 1..m 后交易引用错位（m 小则误拒、m 大则静默挂错持仓）。
- **现有测试为何没发现**：legacy 用例恰好用全新内存库 + 交易无 holdingId，两个盲区都绕开。
- **修复**：导入时按 _effectiveIds 显式写 id 并重映射缺省 id 行的引用；或导入前重置 sqlite_sequence。

---

## 四、H 级（功能错误）

### H1 债券/期货持仓完全无法记交易
- **位置**：`transaction_dialogs.dart:24` `isShare = isMarketLinked || bankWealth`（v0.7.0 引入，bond v0.9.0 / futures v0.9.3 未更新）。
- **后果**：记一笔只有收入/支出/转账四项，服务层全部抛错回滚（无脏数据，但一笔都记不了）；买入/卖出/分红/折算入口不存在，补仓/平仓只能绕道编辑对话框改数量（不走流水、不进统计）。
- **修复**：`isShare` 改为 `!type.isAmountBased && type != AssetType.liability`（或 `AssetType` 加 `isShareLike` getter 统一口径）。

### H2 持仓入口「支出」永远失败
- **位置**：`transaction_dialogs.dart:347-362`（expense 把 holding.id 传进 `cashSourceId`）× `transaction_service.dart:91-92`（expense 只读 `cashTargetId`）。
- **后果**：`_applyCashMove(null)` 抛"需要指定现金持仓"→ 整体回滚。自 2026-08-09（2525075）起如此；账户页入口走 cashTargetId 正常，持仓入口全坏。次生：`transactions_page._counterpartyText(:94-95)`、`CsvExport.transactionsDetailed(:93-94)` 对 expense 读 cashSourceId，与 record 约定相反 → 支出行对手方恒空。
- **修复**：对话框 expense 改传 `cashTargetId`（与 income 对称）；同步修两处消费方。

### H3 外币持仓的买/卖/分红流水一律以 CNY 落库
- **位置**：`transaction_dialogs.dart:330-364`（`record()` 未传 `currency:`，service 默认 'CNY'；`recordBuyFundedByHolding:327` 传了）；账户页对话框 `:582-592` 同病。
- **后果**：USD 股票卖出的已落袋收益 = `(price−unitCost)×qty×rateOf('CNY')=1` → USD 数字直接当 CNY（差汇率倍数）；月度现金流/累计买卖同理。测试 `portfolio_calculator_test 'realized profit of foreign sells'` 假设的 currency=USD 流水 UI 根本产生不出来。
- **修复**：两处 `record()` 传 `currency: holding.currency`。

### H4 产品收益日历翻看往年出现幻影盈亏
- **位置**：`lib/domain/product_monthly_earnings.dart:271-289`（HoldingReplay）。
- **根因**：正向循环只写 `toDay-1`；随后 `while (i < events.length)` 把**所有剩余事件（含 toDay 之后的）**全部 apply 再写 `result[toDay]` → 窗口最后一天 = 今天实际持仓 → 切到过去年份时该年 12 月 profit 出现大额假 Δ，跨年基线也错。
- **修复**：最后一段只消费日期 ≤ toDay 的事件。

### H5 平滑回放漏掉 buy/sell 对现金类持仓的本金联动 → 历史净资产虚高/悬崖
- **位置**：`lib/domain/smooth_history.dart:192-211`（_flowDelta 对 `buy||sell||dividend||consume||split` 一律返回 0）。
- **根因**：v0.8.8 起这些腿真实存在：① `recordBuyFundedByHolding` 赎回腿 = holdingId 为**现金持仓自身**的 sell 行；② 普通买入联动腿 `cashSourceId=现金`；③ 卖出回款腿 `cashTargetId=现金`。全被忽略 → startCost 可被 clamp 0，赎回日之后到昨天的回填快照仍是赎回前余额，今天才被拉回 → 净资产趋势"今天才掉的悬崖"；日明细/产品收益同源错。`smooth_history_test` 只测了 income/transfer。
- **修复**：`_flowDelta` 补三条腿：金额型自身 sell → −amount；`buy && cashSourceId==h.id` → −amount；`sell && cashTargetId==h.id` → +amount（dividend 保持 0 正确）。修后 `forceRebuild` 重算即可修复历史，无需数据迁移。

### H6 CoinGecko 日涨跌幅显示 ×100
- **位置**：`lib/services/market/coingecko_source.dart:44-61`。
- **根因**：`cny_24h_change` 是百分数（1.23=1.23%），直接存进 `changePct`；其他源均存小数（sina=(p−prev)/prev、tencent=/100、eastmoney 基金=/10000）；且它自己算 `prevClose` 又按百分数 `price/(1+changePct/100)` —— 自相矛盾。消费端 Formats.pct 按小数 ×100 → BTC +1.23% 显示 **+123.5%**。
- **修复**：`changePct: changePct / 100`。

### H7 深市场内基金（159/16/18 开头）从「基金」入口必落场外类型
- **位置**：`holding_dialogs.dart:424-436`（只认 `startsWith('sh')`）× `:47-48`（权益下拉只有 stock+mutualFund，etf 已合并移除）。
- **后果**：159915/161725 等 → mutual_fund+eastmoney（日更 NAV），盘中涨跌不可见；输入 `sz159915` 则 eastmoney 直接失败。App 自己的 stock hint 还在举 159915 的例子。
- **修复**：沪深场内前缀精确判定（sz: 159/16/18 → etf）或恢复显式"场内/场外"子选项。

### H8 519xxx 场外基金被误判为沪市 ETF → 自动净值永久失败
- **位置**：`lib/core/symbols.dart:13-20`（一切 5 开头 6 位码归 sh）× `holding_dialogs.dart:428-436`。
- **后果**：519688 等 → etf+sina → sina 无此码 → 永远"无行情"，每次刷新 failed++；旧版显式选"场外"则正常（v0.9.3 回归）。沪市场内基金实占 500-518。
- **修复**：5 开头但非 519 段才归 sh（或显式子选项）。

### H9 混合版本同步：旧客户端把 futures/bond 永久降级为 cash
- **位置**：`lib/core/enums.dart:69-74`（fromStorage orElse→cash）× `holding_dialogs.dart:883-906`（编辑保存写回回落后的类型）。
- **后果**：v0.9.2 旧设备拉到 futures/bond 持仓显示为"现金"（金额语义全错），用户任何一次编辑即写回 `cash/manual` 且 updatedAt 变新 → LWW 同步传播，新类型数据被永久改写；旧备份导入同样静默降级显示。
- **修复**：fromStorage 对未知 storageName 不静默回落（返回 null 或保守手动净值类型），UI 标注"未知类型"并禁止写回 assetType。

### H10 服务器默认部署路径无鉴权（部署默认值问题）
- **位置**：`server/bin/server.dart:41-52`（容器豁免 token）× `Dockerfile:17`（HOST=0.0.0.0）× `docker-compose.yml`（默认空 token + `8787:8787` 全接口）× CORS `*`。
- **后果**：照 README/compose 部署 → 局域网（或转发后的公网）任何人可 GET 全量财务快照、PUT 覆盖整库。
- **修复**：compose 默认强制非空 token（`${ASSET_SYNC_TOKEN:?}`）；启动日志无 token 时大字提示；CORS 收紧或移除。

---

## 五、M 级（边缘场景 / 口径 / 部署）

**交易与资金**
- **M1** 转账/还款无余额校验：源余额可扣成负数（`_applyTransfer/_applyBalanceMove` 无 balance 检查，对话框也不校验）；且源=目标时两次 `_applyBalanceMove` 之间 cost 被 clamp 0 → 金额大于成本时成本永久漂移（如 500→600）。
- **M2** 跨币种资金联动：金额型来源跳过币种校验（`transaction_dialogs.dart:119` 提前放行）；`_applyCashMove/_applyTransfer` 无币种断言；USD↔CNY 转账两边各动同一数字 → 净资产凭空缩水 (fx−1)×金额；下拉不筛币种。
- **M3** 删除 split 流水无"更晚流水"守卫（`transaction_service.dart:507-508`，buy 有 `:526` 检查）→ 删非最新 split 会按比例缩放其后所有交易的数量/成本，静默损坏单持仓（borderline C，可手工修复）。
- **M4** 交易唯一键 `{accountId,holdingId,type,occurredAt,amount}`（`tables.dart:69-72`）：同秒同金额第二笔必败（生硬 UNIQUE 文案）；同步路径撞键 → 整轮同步失败且 3 轮重试同败（`sync_service.dart:248` 普通 INSERT）。

**计算/统计口径**
- **M5** 月/年收益率分母用净资产 `days.first.totalValue`（`daily_earnings.dart:135/163`），分子已是资产口径 → 有负债时收益率被放大。
- **M6** 规则引擎/AlertService 计算不带 cnyRates（`rule_engine.dart:79/119`、`alert_service.dart:30-36`）→ 外币持仓集中度/权益占比与 CNY 混算；`_equityTypes` 与 `AssetCategory.equity` 重复定义易漂移。
- **M7** price_cache 两套口径：summaryProvider/alert_service 用原始 `h.symbol` 查缓存，缓存键已归一化；**编辑对话框保存不归一化 symbol**（`holding_dialogs.dart:849`）→ 裸 6 位代码后"今日盈亏%"分母缺失（行卡片走 `cacheSymbolFor` 正常）。
- **M8** 历史日明细无行情时回退"今天的净值"（`holding_details.dart:197-204`；_sources 无 forex 适配）→ forex 银行理财所有历史日显示当前价（backfill 侧有失败即中止保护，明细没有）。
- **M9** bond/futures/property 不进产品收益日历（`product_earnings_service.dart:86-87` adapter==null → continue）→ 新类型无产品收益数据。
- **M10** 目标配比未知键静默归入"债券"（`enums.dart:135` orElse bond × `target_allocation.dart:58-67`），与"unknown categories are ignored"文档矛盾；legacy 只含 other 的计划迁出后 targetPct 全 0。
- **M11** 目标滑块 `divisions:20` 步长=cap/20 可产生小数（如 27.5/52.5），保存 `roundToDouble` 逐项进位可存出合计 101% → 保存被"≤100%"拒绝形成自造死锁（`alerts_page.dart:443` × `target_allocation.dart:80`）；旧版（≤0.9.2）可存 >100 计划，迁移后滑块位置 clamp 但 % 文本显原值、cap=0 行不可拖；% 文本未随 cap 钳制。

**CSV / 导出**
- **M12** CSV 持仓"成本(CNY)"用当前汇率忽略 `costFxRate`（`csv_export.dart:41-43` vs `symbols.dart:47-52`），成本/收益列与 App 内口径不一致，doc 却声称 "matching the in-app totals"。
- **M13** 设置页导出用 `ref.read(cnyRatesProvider).value ?? {}`（`settings_page.dart:211-214`）→ provider 未就绪时外币全部按 ×1 写入 "(CNY)" 列（USD 差 ~7 倍），应改 `await ...future`。
- **M14** 未知币种静默 1:1：FX 源仅 8 币种（gold_fx_source/tencent），对话框允许任意 ISO 码 → SGD 等各处 `?? 1` 当 CNY（`symbols.dart:39-52` 等）。

**同步 / 服务器**
- **M15** 同步应用期窄窗口 TOCTOU：merge 基于导出快照、`_upsertLocalRow` 无条件覆盖、`_replaceTombstones` 全清重建 → 同步进行中的本地删除/编辑可能被旧数据回滚（`sync_service.dart:83-98/146-158/308-312`；autoSync 启动即跑，与"打开就操作"重叠）。
- **M16** autoSync 成功后 `history_sync_dirty` 无人消费 → 本会话派生快照陈旧（`main.dart:71-79`、`sync_service.dart:122-124`、仅手动同步 invalidate historySyncProvider）→ 合并进来的还款/交易漏进日收益直到重启。
- **M17** X-Forwarded-For 完全可伪造：绕过限流 / 伪造受害者 IP 反向锁死合法客户端 / hits map 无界增长；`_readLimited` 无总超时（slowloris）（`server.dart:131-153`）。
- **M18** token 比较非常量时间（`server.dart:158-166`）。
- **M19** server `_handlePut` 错误码：畸形 JSON/坏 baseRev → 500；非法 UTF-8 → 误报 413（`server.dart:88-122`）。
- **M20** 快照（snapshots）删除从不写墓碑 → 多设备下 `deleteSnapshotsBefore` 的修剪每次同步被服务器旧行复活（`asset_dao.dart:296-298`；merge 对 remote-only 行一律回填）。

**UI / 文案**
- **M21** 统计页"月度收益"柱状图 X 轴标签错位（`stats_page.dart:206-218`：`(value*n).round()-1` 假设 value∈[0,1]，fl_chart BarChart bottom titles 按轴坐标 0..n−1 采样 → 标签挤在最左、首柱与最后一月无标签）。
- **M22** 收益日历脚注与实现相反（`earnings_calendar_page.dart:189` 写"负债变化计入当日盈亏"，实现恰是 v0.9.2 修复后的排除口径）。
- **M23** 编辑持仓换币种时数量/成本/净值不换算、无警告（`holding_dialogs.dart:840-907`）——USD 股票改 CNY 后市值缩为 1/7。**需要拍板**：按汇率换算金额类字段，或换币种时弹确认 + 提示重填。
- **M24** 转账/还款同源目标无校验（并入 M1）；手动净值份额型（bond/futures）历史快照全程按当前净值回填（`history_backfill_service.dart:244`，文档化取舍，与 bankWealth 平滑插值口径不一致，列此备查）。

---

## 六、L 级（建议项）

| # | 问题 | 位置 |
|---|---|---|
| L1 | 墓碑只增不减（客户端 sync_tombstones 与服务器列表均无 GC） | `sync_service.dart:308-312` |
| L2 | `_same` 用 jsonEncode 全文比较，键序/数字形态敏感 → 潜在永久假冲突 | `sync_merge.dart:276-282` |
| L3 | push 409 分支对代 理 HTML 响应 jsonDecode 抛异常，误入通用失败而非冲突重试 | `sync_api.dart:84-87` |
| L4 | token 明文存 settings 表；validateServerUrl 允许 http 明文传 token | `sync_settings_page.dart:84` |
| L5 | tombstone 项无最小形状校验，畸形项可致删除失效复活 | `sync_service.dart:315-316` |
| L6 | DataMigrationService 多条 customStatement 不在事务内；`_migrateEtfSplit512480` 用户专属补丁对所有安装全局运行 | `data_migration_service.dart:89-136` |
| L7 | 备份不含 settings 表（目标配比不随备份迁移）；导入不清理 alertEvents（悬空 ruleId 参与去重） | `backup_service.dart` |
| L8 | 交易流水页 `isToday = day == DateTime.now()` 恒 false（含时间分量）→"· 今天"角标永不显示 | `transactions_page.dart:425` |
| L9 | `TradeStats.count` 死代码且公式错（fold 恒 0），无调用方 | `trade_stats.dart:37` |
| L10 | `sellProfitText` 硬编码 "¥"，外币持仓落袋预览符号错误 | `transaction_dialogs.dart:398` |
| L11 | `AssetType.fromStorage` orElse→cash（H9 同源，显示层也会把未知类型当现金） | `enums.dart:69-74` |
| L12 | 目标合计保存校验 `total > 100` 浮点和可因 100.0000001 被拒（建议 >100.0001） | `alerts_page.dart:388-394` |
| L13 | 桌面端配置条"其他"切片点击 → 持仓页查询匹配不到任何类别 → 空列表 | `allocation_bars.dart:41-50` |
| L14 | CSV 公式注入：_esc 只处理引号，=/+/-/@ 开头单元格可被 Excel 执行 | `csv_export.dart:10-13` |
| L15 | futures 添加对话框代码字段被禁用却显示"如 螺纹钢2405"hint | `holding_dialogs.dart:248-261` |
| L16 | `target_allocation.dart:15` 注释仍指向已迁走的 settings page | `target_allocation.dart:15` |
| L17 | server 仅处理 SIGINT，docker stop 的 SIGTERM 未监听 | `server.dart:68-71` |
| L18 | `HOST=localhost` 通过回环检查但 `InternetAddress('localhost')` bind 失败崩溃 | `server.dart:41/66` |
| L19 | todayEarningOf 把 snapshots.last 当"今天"，今天快照未生成的竞态下显示昨天收益 | `daily_earnings.dart:78-89` |
| L20 | drift "multiple databases" 警告：仅 widget 测试环境噪音，非产品问题 | `test/`（备查） |

---

## 七、已验证无问题的方面

- **收益口径**：资产口径 `(totalValue+liabilities)−totalCost` 在 _assetProfit/todayEarningOf/rate_series/range_stats/较前日 全链一致，3 个防回归测试在位；快照 totalValue 存 netWorth 一致。
- **金额型已落袋恒 0**：TradeStats/realizedProfitByHolding/PortfolioCalculator/_TransactionTile 全部传 amountBased 集合，v0.8.9 回归测试覆盖。
- **净现金流口径**：TradeStats 与 `_dayNet` 一致（buy 仅 cashSourceId、sell 仅 cashTargetId、transfer/consume/split 排除）。
- **除零/空值守卫**：全项目无裸除零（profitPct、HeatCell.heat、NiceAxis、ratio、dayChangePct 均有守卫）。
- **日期/时区**：月聚合、周一起始日历、`DateTime(y,m−1,d)` 跨月、RangeOption 均正确。
- **同步核心**：baseRev 乐观锁读写区间无 await（单 isolate 原子）、409 三轮重试 re-merge、`_same` 忽略 latestPrice 且仅价格更新不 bump updatedAt、删除-重建同 id 墓碑语义、级联墓碑一致。
- **服务器**：哑存储不解析枚举（futures/bond 透传无碍）、auth 在 body 读取前、限流→auth 顺序正确、SyncApi finally close、30s 超时用 Future.timeout（规避 package:http 无 per-request timeout 的已知坑）。
- **v0.9.3 兼容面**：无 schema 变更（schemaVersion=8）；target_allocation legacy 键迁移语义正确且幂等（6 测试用例）；AssetCategory 重构无残留引用（全项目 grep）；rule_engine 用独立类型集合不受大类重构影响；负债不进配置卡（calculator `continue`）。
- **autoCny 新规则**：不持久化、既有 CNY 持仓编辑无漂移、判定顺序正确、USD 折算链路（valueRateOf/costRateOf/cnyRatesProvider）自洽；sync/backup 无枚举白名单，futures/新币种可正常同步备份。

---

## 八、修复路线建议

1. **v0.9.4 快修包**（几行级改动为主）：H1、H2、H3、H6、H8、C1、M13、M22、M23(提示版)、L8、L10、L15、L16
2. **中等改动**：C2（备份 id 重映射）、H4（回放窗口）、H5（_flowDelta 补腿）、H7/H8（基金代码判定重做）、H9（未知类型不回落）、M3（split 守卫）、M11（滑块归一化）、M15/M16/M19/M20（服务器与同步健壮性）
3. **需用户拍板的口径/UX**：M23（换币种是否自动换算数值）、M5（月收益率分母）、M2（跨币种联动的产品语义）、H10（部署默认值）
