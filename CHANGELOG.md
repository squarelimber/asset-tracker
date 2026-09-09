# Changelog

All notable changes to Asset Tracker. Entries are condensed from the commit history; dates follow the release tags.

## [0.9.1] - 2026-09-09

### Fixed

- 目标配比显示为天文数字: 目标占比在存储中是整百分数（40 表示 40%），但对比条组件按 0~1 比率格式化，导致显示成 4000%/3000% 等（且目标竖线被压到最右侧）。现在组装对比条目时统一换算为比率，目标显示为"40.0%"、偏差按百分点计算，附回归测试

## [0.9.0] - 2026-09-09

### Added

- 按大类聚合的资产配置视图: 资产配置卡片从细分的 11 种资产类型（现金/银行存款/活期理财/银行理财/股票/场内基金/场外基金/积存金/债券/加密货币/房产）聚合为 6 大类（股票/基金/黄金/债券/现金/其他）展示实际占比，一眼看清整体配置；点击大类可跳转持仓页并按大类筛选（如"基金"= 场内基金 + 场外基金）
- 新增"债券"资产类型: 录入国债/债基时可单独选择"债券"类型（手动净值，中等偏低风险），并归入债券大类
- 目标配置（计划配比）: 设置页可编辑各大类的目标占比（默认 股票40/基金30/黄金10/债券10/现金10），资产配置卡对比显示"实际 / 目标"与偏差百分点，超配/低配超过 ±5pp 时红/绿高亮提示，便于再平衡；目标存于本地设置，无需数据迁移

### Fixed

- 安卓右滑返回在部分页面直接退出应用: 交易流水/提醒/设置等 Shell 级页面通过 `go()` 切换无路由栈可弹，右滑返回被转发给系统导致退出。现在这些页面上的返回手势改为回到总览页，push 进入的页面（收益日历、账户详情）仍正常逐级返回
- 现金账户记收入/支出被强制要求选择关联账户: 收入/支出本无来源去向，却显示了"关联对方持仓"下拉框（默认选中第一只现金持仓且无法取消）。现在现金账户的收入/支出不再显示该选择，只填金额即可；仅转账类（转入/转出）保留来源/去向下拉

### Changed

- 资产趋势图手机端左移并增大显示区域: Y 轴标签留白从 48px 收窄到 40px、标签字号 10→9，绘图区整体左移 8px、加宽 8px

## [0.8.9] - 2026-09-08

### Fixed

- 金额型持仓（现金/银行存款/活期理财）的已落袋收益统计错误: 金额型持仓的成本价存的是累计投入总额而非单位成本，赎回流水按 (卖出价 − 成本价) × 数量 计算会得出天文数字级的虚假亏损（典型场景：用天天宝等活期产品出资买入基金后，已落袋收益变成数十亿的负数）。现在统计层对金额型持仓的已落袋收益按构造恒为 0 处理（赎回本金不产生盈亏），总览、统计、持仓明细与流水页的落袋数字一并修正
- 净现金流被内部划转虚增: "赎回转投其他持仓"（含新建持仓时的赎回出资）与转账等不经过现金账户的内部划转，此前被计入月度现金流、累计卖出与当日净额，虚增净现金流。现在净现金流只统计实际进出现金的流水（卖出回款入现金账户、现金账户出资买入、收入、支出、分红），统计页脚注同步说明口径

## [0.8.8] - 2026-09-08

### Added

- 用已持仓产品出资买入新产品: 记一笔买入时资金来源除现金账户外，可选择任一已持仓产品。系统在一次原子操作内完成"来源产品赎回 + 新产品买入"，生成同一时间戳的两条流水（赎回 + 买入）；金额型产品（如天天宝）按金额赎回，份额型产品（基金/股票等）按最新价折算份额（无最新价时回退成本价），余额/市值不足、币种不一致、来源与目标相同、负债产品均被拒绝。删除任一条流水时自动回滚对应腿（删赎回行恢复来源份额、删买入行恢复出资）
- 统一交易流水页: 全部交易类型（买入/卖出/收入/支出/分红/转入/转出）按日倒序分组的统一视图，支持类型 chip、账户、日期区间筛选与关键词搜索（持仓名/备注/账户名），顶部汇总净现金流与分类型统计，可导出 CSV（含对手方账户列）。入口：桌面左侧导航栏"流水"、手机顶栏图标，键盘快捷键 6

### Fixed

- 持仓页手机端搜索框被挤出屏幕: 工具栏栏目过多（流水/提醒/设置/搜索/筛选/排序/刷新 共 7 个），窄屏上搜索框被挤压。现在手机/平板端搜索框移到工具栏正下方（固定于列表上方，全宽），筛选/排序同步移入列表区作为"资产|负债"切换下方的一行两个下拉框；桌面端布局不变

## [0.8.7] - 2026-09-07

### Fixed

- 手机端资产总览卡片 2×2 布局: 行切分三元条件写反（`i + columns < cells.length`），导致手机上第一行渲染 4 个格子、第二行重复渲染后两个格子。现在手机稳定 2×2、桌面 1×4，布局测试改为断言行内标签与格子数
- 持仓页搜索不匹配资产类型: 从资产配置卡片点击某类（如"场外基金"）跳转到持仓页时，搜索词是类型标签，但过滤只匹配名称/代码导致结果为空。现在同时匹配资产类型标签与存储名（如"场外基金"/`mutual_fund`），搜索框提示更新为"搜索名称/代码/类型"

### Changed

- 资产走势卡片排版: 手机端图表高度 330→190px，绘图区从近正方形（232×302）变为约 1.4:1 横长方形，整卡高度缩短约 30%；"指数对比"从标题行移入区间 chip 行（手机/桌面一致），标题行在窄屏上不再折行

## [0.8.6] - 2026-09-07

### Fixed

- 天天宝本金 income 被误算为收益: `smooth_history` 新增 `today` 参数，回填时跳过当日本金入账，避免把本金当作收益计入净值曲线
- 手机端资产总览卡片布局: 改用直接宽度判断（< 1100px → 2×2，≥ 1100px → 4 列），修复部分机型上四卡片挤成一行的问题

### CI

- Release workflow 改为幂等: 若 release 已存在则更新 notes 并 `--clobber` 重传资产，不再因重复创建而失败

## [0.8.5] - 2026-09-06

### Fixed

- 历史净值回填在网络异常时会用"当前价"回填整段历史、把走势/收益率算错的问题: 之前某个行情源拉取失败会被静默吞掉，随后逐日计算时该持仓所有历史日期都回退用最新价填充，污染整条净值曲线（2026-09-04 网络差时即发生，导致 2020-08 至 2026-09 的快照整体偏差）。现在任一行情源拉取失败会让本次回填**整体中止、不写任何快照**（提示检查网络后重试），绝不用错价覆盖正确历史；刚建仓无历史的正常空序列不受影响

## [0.8.4] - 2026-09-06

### Fixed

- 资产走势某天掉到 0 的问题: 持仓表为空的设备（如刚安装、首次同步前）启动时会写入一条全 0 快照，再经同步的 last-write-wins 策略覆盖掉其他设备上的正常数据。现在持仓为空时跳过快照写入，并补了回归测试

## [0.8.3] - 2026-09-06

### Changed

- 总览: 总资产/总负债/净资产/今日盈亏 merged into one 资产总览 card (4 columns on desktop, 2×2 on phone)
- 资产走势 chart enlarged (phone 280→330px, desktop 240→280px); Y-axis labels right-aligned flush with the plot edge so the first data point starts right at the axis
- 资产走势 toolbar: title shares one row with the 收益率/净值 toggle + 指数对比 chip (right-aligned); range presets get their own dedicated row (single horizontally scrollable line on phone, no wrapping pile-up)

## [0.8.2] - 2026-09-06

### Added

- Pull-to-refresh on every data page: 总览 / 持仓 / 账户（含明细）/ 行情 / 统计 / 提醒 / 两个日历页 / 明细 sheet
- Unified `ErrorState` component (icon + friendly message + retry) replacing ad-hoc error text across all pages
- Markets page: 60s TTL quote cache; manual refresh keeps stale data while refetching, with snackbar feedback and an "更新于" timestamp
- `SessionChip`: A-share trading session pill in 总览/行情 headers (交易中 / 午休 / 未开盘 / 已收盘 / 休市, local time; no holiday calendar)
- Desktop rail: 提醒 / 设置 actions pinned to the bottom of the navigation rail
- Desktop keyboard shortcuts: 1-5 switch main pages, r refresh, / focus search (suppressed while editing)
- Holdings table: click column headers to sort (pair toggle); row context menu (right-click on desktop, long-press on phone) with 记一笔交易 / 更新价格 / 编辑 / 归档 / 删除 (confirm dialog)
- Mobile: swipe a holdings row left to archive; long-press for the full menu
- Stats page: 最佳/最差月份 (monthly cash flow) and 盈利月份占比
- Overflow regression smoke tests: all 10 pages at 360×640 and 1280×800 with a fully seeded in-memory database

### Changed

- Dialogs and bottom sheets use terminal-styled chrome (surface2 background, border, unified radius)
- Tappable phone rows get ≥44px touch targets
- text3 raised to #768390 (5.0:1 contrast on bg, WCAG AA for normal text)
- Desktop content max width 1280 → 1440
- Web: dark background + theme-color meta to prevent white flash before the WASM bundle loads
- KPI tile values wrap to 2 lines with ellipsis instead of overflowing

## [0.8.1] - 2026-09-04

### Added

- Sold-out (fully redeemed / fully sold) positions are first-class citizens:
  - Lifecycle filter on the holdings page: 全部 / 仅当前持仓 / 仅已清仓 / 已归档; default view keeps active positions on top, exited ones sink to the bottom (most recently touched first)
  - Status badges on list rows and the detail sheet: 清仓 (share-based), 已结清 (amount-based), 已还清 (liabilities), 已归档
  - Detail sheet for exited share-based positions shows realized P&L (Σ (sell price − unit cost) × quantity, with return % against invested capital) and the last-sell date; holding duration ends at the last sell
  - Exited amount-based positions show 已结清 with zero residual cost instead of a misleading live quote
  - Archive / restore from the detail sheet menu: archived positions stay in the database and the earnings calendar but are hidden from the default views (reachable via the 已归档 filter)
  - Desktop holdings table shows realized P&L for exited positions instead of stale quotes
- Deleting a holding that has transaction history now warns that its earnings-calendar history will be permanently removed and suggests archiving instead

### Changed

- Market refresh skips fully exited positions (no live position to price)
- Schema v8: `holdings.archived` column (defaults to false), migrated in place

## [0.8.0] - 2026-09-04

### Added

- Local notifications for alert rules (Android & Windows): fired rules push a system notification at startup and after each market refresh, deduped to once per rule per day; toggle in Settings → 提醒通知. Web build intentionally unaffected (no service-worker replacement, no permission prompt)
- Cross-source fallback on desktop: Sina → Tencent, Eastmoney API → push2, Sina gold/FX → Tencent adapter, so a single endpoint outage degrades to the secondary source instead of stale cached prices
- `TerminalFab` shared component (floating quick-action button), wired into accounts / alerts / holdings pages

### Fixed

- Mono font fallback chain for cross-platform numeric rendering

## [0.7.0] - 2026-08-28

### Changed

- Full dark "financial terminal" UI redesign (Bloomberg style, red-up / green-down):
  - Design tokens (`lib/ui/tokens.dart`) and dark-only theme
  - 5+2 navigation shell; shared component library in `lib/ui/components/`
  - All 12 pages rewritten; pages moved from `lib/features/` to `lib/ui/pages/`
- Overflow regression tests for the redesigned pages

### Fixed

- Calendar pages are pushed so the back button works
- NavigationRail selected / unselected colors
- Allocation colors and M3 outline border contrast
- Dark window title bar and dark snackbar

## [0.6.6] - 2026-08-25

### Added

- Earnings calendar year view: pinned product column and month header

### Fixed

- Profit math: unrealized = assets − cost; total = unrealized + realized; realized gains CNY-converted; unit cost kept on full sell-out

## [0.6.5] - 2026-08-24

### Fixed

- Sync: tombstone-union merge and `baseRev` conflict retry
- Backup v2 format validation
- Market data request timeouts
- Sync server hardening (container binds 0.0.0.0; CI lint fix)

## [0.6.4] - 2026-08-20

### Added

- Per-product monthly earnings calendar with flow replay for sold-out holdings

### Changed

- Trend chart downsampling with nice axis ticks; removed market history trend

## [0.6.2] - 2026-08-19

### Fixed

- Net-worth chart toolbar readable on phones

## [0.6.1] - 2026-08-18

### Fixed

- Sync: rebuild derived snapshots after sync; earnings filtered to CNY

### Changed

- Stop tracking `server/sync_state.sqlite`

## [0.6.0] - 2026-08-18

### Added

- Multi-device sync via self-hosted Dart (shelf) server: LWW + tombstones, Docker image, container smoke test in CI

### Fixed

- v6 → v7 migration crashed real databases (app would not start)
- Settings page scrolls when content exceeds the window height
- CI: scoped `flutter analyze` to app code; added server analyze / test job

## [0.5.0] - 2026-08-18

### Fixed

- Earnings: replay historical cost alongside value so transfers never leak into returns
- Earnings: exclude liability changes (repayments / borrowing); added yearly calendar view
- Today's earning uses the snapshot view, matching the calendar
- Portfolio and calendar share one history sync pipeline
- Day detail aligned with snapshot numbers; smooth accrual shown for cash holdings

## [0.4.0] - 2026-08-13

### Added

- Earnings calendar (monthly grid of daily profits)
- Smooth accrual history for manual holdings (bank wealth + cash), flow-aware
- Cost-basis FX rate per holding
- Amount privacy toggle (eye icon) and dividend cost-basis method

### Fixed

- Backup import preserves original ids and transfer links
- 512480 ETF 1:2 split data migration + qfq-adjusted backfill + split transaction type
- `verify_all.ps1`: single `pub get`, parallel platform builds

## [0.3.1] - 2026-08-12

### Added

- Credit-card consume transaction type; liability-friendly forms
- Holdings split into asset / liability sections; liabilities excluded from asset totals

### Fixed

- Transfer removal rolls back correctly (direction + legacy cost marker)
- Repayments no longer distort return rates; transfers visible in holding details
- Export via share sheet on Android / iOS

## [0.3.0] - 2026-08-11

### Added

- Per-holding today's profit on cards and detail sheet
- Web: CORS-friendly Tencent / Eastmoney push2 endpoints; WasmGC detection with a clear browser-upgrade message

### Fixed

- True cumulative return rate for the asset trend (benchmarks stay normalized to 0% at range start)
- Backup import as raw bytes with explicit UTF-8 decode (Android garbling)
- CI: deploy web only on web-affecting changes; pinned Flutter 3.44.9; gradle build caching

## [0.2.0] - 2026-08-09

### Added

- Multi-currency conversion, realized / unrealized profit, stats page, CSV export
- Global markets page (indices, commodities, FX) with trend charts
- Return-rate view with benchmark comparison (CSI300 / SSE / SZSE50 / ChiNext)
- Unified holding transaction entry (buy / sell / transfer / repay / income / expense), schema v4
- Alipay-style trend module with range selector and touch tooltip
- Amount-based assets (cash / deposit / liquid wealth) with direct amount entry, schema v3
- Purchase date with holding duration and annualized return, schema v2
- Allocation card with type / risk dimensions; risk level field, schema v6

### Fixed

- FX conversion applied consistently across account totals, stats and snapshots
- Reliable history sync via dirty marker + portfolio-driven rebuild
- Atomic snapshot rebuild; forward-fill prices on non-trading days
- Range profit measured as profit change, immune to new investments
- Rebuilt holdings table to drop the legacy `UNIQUE(symbol)` constraint

## [0.1.0] - 2026-08-08

### Added

- Initial release: accounts / holdings CRUD, market data engine (Sina / Eastmoney / gold / FX)
- Portfolio dashboard with allocation and net worth chart
- Rule engine alerts (concentration / ratio / drawdown / cashflow)
- Backup / restore (JSON), settings page, GitHub Actions CI
- Web (wasm) + Android + Windows builds; GitHub Pages deployment
