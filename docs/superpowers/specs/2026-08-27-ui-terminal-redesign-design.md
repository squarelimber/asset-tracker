# UI 重设计：深色金融终端风（v0.7.0）

- 日期：2026-08-27
- 状态：已与用户逐节确认
- 范围：asset_tracker Flutter App UI 层全面重设计

## 1. 背景与目标

当前 App（v0.6.6+13）是 navy 主色的 M3 浅色主题，跟随系统明暗。问题：

- 各 feature 私有卡片/行组件重复（`_HoldingCard`/`_QuoteCard`/`_StatCard`/`_TransactionTile` ×2…），风格漂移
- 间距无 token，ad-hoc `SizedBox` 值散落各处
- 手机底部导航塞 7 项（M3 惯例 ≤5），窄屏拥挤
- 多处固定宽度金额列（110/90/130px），小屏有溢出风险
- 布局全部基于 `ListView`/`Column`/`Row`，无 sliver；产品收益日历靠 `IntrinsicHeight` + 双 ScrollController 同步 hack
- `holdings_page.dart` 1568 行、`portfolio_widgets.dart` 1056 行，文件过大

目标：一次性把 12 个页面重设计为**深色金融终端（Bloomberg 风）**，建立 token 体系与共享 sliver 组件库，发 0.7.0。

## 2. 已确认的决策

| 决策 | 选择 |
|---|---|
| 视觉方向 | B · 深色金融终端（Bloomberg 风） |
| 导航 | 5+2：主导航 5 项（总览/持仓/账户/行情/统计），提醒（铃铛）+ 设置（齿轮）移到顶栏 |
| 主题 | 只保留深色，删除浅色主题与跟随系统逻辑 |
| 范围 | 一次性全改：12 页 + 主题 + 共享组件，单版本 0.7.0 |
| 实现路径 | sliver 全面重写（含 token + 共享 sliver 组件库 + 目录重排） |
| 边界 | UI 为主；Riverpod providers 接口不变，耦合太深的允许顺手重构；data/services 层不动 |
| 数据配色约定 | 红涨绿跌（`up #F85149` / `down #3FB950`）保持不变 |

## 3. 设计 Token（`lib/app/theme.dart` 扩展）

### 3.1 色板（语义 token）

| Token | 值 | 用途 |
|---|---|---|
| `bg` | `#0A0C0F` | 页面底 |
| `surface` | `#12151A` | 卡片 |
| `surface2` | `#1A1F26` | 浮层/对话框/表头 |
| `border` | `#262B33` | 卡片边框/分隔线（弱分隔用 `#1C2128`） |
| `text1` | `#E6EDF3` | 主文本 |
| `text2` | `#8B949E` | 次要文本 |
| `text3` | `#545D68` | 弱文本/占位 |
| `up` | `#F85149` | 涨（红） |
| `down` | `#3FB950` | 跌（绿） |
| `accent` | `#58A6FF` | 选中/交互/聚焦 |
| `warning` | `#D29922` | 警告 |

涨跌色派生：热力格/高亮用 `up`/`down` 的 alpha 渐变（如 `#2A1215`/`#4A1E22` 深红底、`#101A14`/`#1C3327` 深绿底）。

### 3.2 字体

- **所有数字**：等宽（`ui-monospace`/Consolas 族）+ `tabularFigures`
- label：10–11px，大写，`letterSpacing .08–.1em`，`text2` 色
- KPI 大数字：28px（桌面）/ 24–26px（手机），700
- 行内数值：12–13px mono
- 正文：13px
- 行高紧凑（终端密度）

### 3.3 间距 / 圆角 / 密度

- 间距刻度：4 / 8 / 12 / 16 / 24（禁止其他值）
- 圆角：卡片 8px，pill 999，输入框 6px
- 卡片：`surface` 底 + 1px `border` + 无阴影（终端风不用 elevation）
- 行高：DataRow 行 34–38px（桌面）/ 40–44px（手机）

## 4. 导航壳（5+2）

- 路由不变：`/portfolio` `/holdings` `/accounts` `/accounts/:id` `/markets` `/stats` `/alerts` `/settings`；`/earnings-calendar`、`/product-earnings` 保留（入口移到总览页内）
- **手机（<720）**：`Scaffold` + 底部 `NavigationBar` 5 项（总览/持仓/账户/行情/统计）+ AppBar 右侧铃铛（→/alerts）、齿轮（→/settings）
- **桌面（≥1100）**：`NavigationRail` 5 项 + 顶栏同样两个图标
- 铃铛带未读提醒角标（有触发未读事件时）
- 平板（720–1100）：按手机布局（底部导航）

## 5. 共享组件库（`lib/ui/components/`）

替换各页私有重复组件。组件清单：

| 组件 | 说明 |
|---|---|
| `TerminalCard` | 统一卡片壳：surface + 1px border + 8px 圆角 + 内边距 12 |
| `SectionHeader` | 大写 label + 可选右侧动作；表格场景做 `SliverPersistentHeader` 变体 |
| `KpiGrid` / `StatTile` | label + mono 数值 + delta；手机 2 列 / 桌面 4 列 |
| `DeltaText` | ▲/▼ + 百分比/金额，自动 `up`/`down` 着色 |
| `DataRow` | 紧凑行：左名称+副文本（ellipsis），右 mono 数值+delta；**金额列弹性宽度（Expanded + ellipsis），禁止固定宽** |
| `AllocationBars` | 见 5.1 |
| `HeatCell` | 日历热力格：红涨绿跌，饱和度按金额绝对值缩放；0/休市中性灰；内容降级梯度：完整金额 → 缩写（k/万）→ 纯色点 |
| `QuoteTable` | 分组报价表（代码/名称/最新/涨跌%，mono 右对齐） |
| `EmptyState` | 空状态（图标 + 提示 + 引导动作） |
| `TerminalFormFields` | 深色密集输入框：`surface2` 底 + 1px border，聚焦 accent 边框；金额字段 mono |
| `Sparkline` | 现有实现深色化 |
| `TerminalSheet` / `TerminalDialog` | 深色 sheet/对话框 chrome |

### 5.1 Allocation 响应式规则

- **手机/平板（<1100）**：条形列表——每类一根横向条，按金额降序，右侧 mono「金额 · 占比」；条高 5–6px
- **桌面（≥1100）**：堆叠条——最多 **Top 5 + 其他** 6 段（按金额取 Top 5，其余合并）；段高 22px，段间 2px 缝隙，顶部微高光渐变，≥10% 的段内嵌 mono 百分比；图例两列网格显示全部分类明细
- 每类固定颜色：沿用 `AssetType` 枚举颜色映射，深色下做亮度提升
- 点击行/段/图例行 → 下钻到该类持仓

### 5.2 净值趋势图（fl_chart 升级）

- 平滑曲线（Catmull-Rom 化折线）+ 渐变填充（线下方 accent 渐隐）+ 线条辉光（6px 低透明度叠层）
- 网格虚线 + 左侧 mono 轴标签（万为单位）+ 底部日期刻度（5 个）
- hover/触摸十字线 + 浮动 tooltip（日期、净值、环比涨跌红涨绿跌）
- 端点脉冲动画（AnimationController 驱动半径/透明度）
- 区间切换（1月/3月/6月/1年/全部）+ 统计行（区间收益/最大回撤/最新）

## 6. 逐页布局

### 6.1 总览（portfolio）

- **桌面**：顶部 4 KPI tile（总资产/总负债/净资产/今日盈亏）→ 左 2/3 净值趋势图 + 右 1/3 Allocation 堆叠条 → 底部两个日历入口 tile（收益日历/产品收益日历）
- **手机**：KPI 2×2 → 趋势图 → AllocationBars 条形列表 → 日历入口 2 tile，纯纵向堆叠

### 6.2 持仓（holdings）

- 工具栏：搜索框 + 资产/负债 SegmentedButton + 排序菜单
- **桌面**：高密度等宽表格，`SliverPersistentHeader` 固定表头（名称/代码/数量/成本/最新/盈亏·收益率），行点击 → 详情 sheet（交易流水），FAB 保留
- **手机**：表格退化为 DataRow 卡片列表
- 1568 行 `holdings_page.dart` 拆分：页面 + 表格/卡片 + 对话框 + 详情 sheet 分文件

### 6.3 账户（accounts）

- KPI 行（账户数/总余额）+ 账户 DataRow 列表（展开看账户内持仓 mini 行）；账户详情页：持仓 section + 交易流水 section（DataRow）

### 6.4 行情（markets）

- 横向卡片条 → **分组报价表**：5 个分组（A股/亚太/欧美/大宗商品/货币）各一张 `QuoteTable` 卡
- **桌面**：2 列网格；**手机**：分组紧凑行（名称+代码 / 最新+涨跌%）
- 刷新状态上顶栏（上次刷新时间 + 手动刷新按钮）；行点击 → 报价详情

### 6.5 统计（stats）

- KpiGrid（现有 7 个统计卡）+ 月度现金流柱状图（fl_chart 深色化）

### 6.6 提醒（alerts）

- 事件 DataRow 列表（最近触发）+ 规则行（名称 + Switch + 删除）；FAB 添加规则

### 6.7 设置（settings）+ 同步设置

- `TerminalCard` 分组表单：备份导出/导入、CSV 导出、数据同步入口、关于；深色 `TerminalFormFields`；平台分支（share sheet vs 文件保存）保留

### 6.8 收益日历（earnings calendar）

- 月视图：`HeatCell` 7 列网格（日号 + 当日盈亏），顶部月名 + 本月合计；点日期 → `DayDetailSheet`（深色化）
- 年视图：12 个月 tile（月名 + 合计 + 迷你条）
- 月/年 SegmentedButton 保留

### 6.9 产品收益日历（product earnings calendar）

- 年视图矩阵：`CustomScrollView` + `SliverPersistentHeader`（月份头固定）+ 产品列固定（横向滚动时不动），**替代 `IntrinsicHeight` + 双 ScrollController 同步 hack**
- 月视图：产品列表 + `Sparkline`（深色化）保留
- **矩阵响应式规则**：

| 断点 | 月份列 | 产品列宽 | 单元格 |
|---|---|---|---|
| 桌面 ≥1100 | 12 个月，列宽=(内容宽−150)/12，最小 52px，不够横向滚动 | 150px | 缩写金额（+1.2k） |
| 平板 720–1100 | 12 个月放不下自动退 6 月窗口 | 120px | 缩写金额 |
| 手机 <720 | 6 个月窗口（左右翻页，保留现有 toggle 交互） | 92px | 缩写金额；<360px 退化为纯色点 |

## 7. 目录结构

```
lib/
  app/            app.dart, router.dart, theme.dart（扩展为 token 体系）
  ui/
    shell/        shell_page.dart（5+2 导航）
    components/   共享组件库（第 5 节清单）
    pages/        portfolio/ holdings/ accounts/ markets/ stats/
                  alerts/ settings/ calendar/（12 页，私有 widget 随页走）
  features/       各域 providers（接口不变，耦合太深顺手改）
  core/           formats, enums, symbols, responsive（保留）
  data/ services/ drift、同步、行情（不动）
```

原则：`features` = 逻辑，`ui` = 表现；页面只消费 providers，不碰 data/services。

## 8. 测试策略

- 现有 256 个测试保持全绿（providers 接口不变）
- 新增共享组件测试：TerminalCard / DataRow / AllocationBars（响应式切换、Top5+其他合并）/ HeatCell（降级梯度）
- 新增**溢出回归测试**：12 页用种子数据在 360×640（最小手机）与 1280×800（桌面）各 pump 一次，断言无 RenderFlex overflow（现状完全缺失）
- 更新引用旧 widget 的测试：`add_holding_flow_test`、`invested_profit_field_test`、`invested_profit_edit_test`
- `product_earnings_calendar_test` 重写：断言新 sliver 矩阵月份头滚动时固定
- CI 不变：`flutter analyze`（**必须看退出码**，info 级也判失败）+ `flutter test`

## 9. 迁移计划（12 个 commit，每个 commit 后 analyze + test 必须绿）

1. Token + 深色主题（删浅色）+ 5+2 导航壳
2. 共享组件库
3. 总览页（含净值趋势图升级）
4. 持仓页（拆分 + 表格化）
5. 账户 + 账户详情
6. 行情页
7. 统计页
8. 提醒页
9. 设置 + 同步设置
10. 收益日历
11. 产品收益日历（sliver 矩阵）
12. 清理旧私有组件 + 版本 0.7.0+14 → 按 AGENTS.md 发版流程（tag v0.7.0、4 资产、latest tag 同步）

## 10. 风险

| 风险 | 缓解 |
|---|---|
| fl_chart 深色 + 自定义 touch 十字线 | commit 3 内先做 spike 验证，不行则自绘 CustomPainter（现有 `_TrendChart` 已有自绘基础） |
| sliver 矩阵固定列 + 固定头 | commit 11 单独做，先写表头固定测试再实现 |
| 旧 widget 测试连锁更新 | 每页迁移 commit 内同步更新该页相关测试 |
| 1568 行 holdings 拆分 | 拆分行为不变，先拆后改样式 |

## 11. 明确不做（YAGNI）

- 不动 data/services 层（drift、同步、行情源）
- 不做主题切换 UI（只保留深色）
- 不做 iOS 平台
- 不引入新 UI 框架/状态管理
- 不做 golden 测试（溢出回归测试已覆盖布局风险）
