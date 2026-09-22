# Changelog

All notable changes to Asset Tracker. Entries are condensed from the commit history; dates follow the release tags.

## [0.9.17] - 2026-09-22

### Fixed

- 份额型持仓历史改为按买卖流水重放份额，清仓/部分卖出产品不再按 0 市值构建历史

## [0.9.16] - 2026-09-21

### Added

- **资产走势图悬停/按压显示当日信息标签**: 鼠标移到（或手机上按住）曲线上任意日期，图表内直接显示「日期 + 数值 + 较前日」：净值模式显示净资产金额、收益率模式显示累计涨跌幅；「较前日」按资产口径（净资产+负债）计算，本金进出不影响当日盈亏；十字参考线保留。之前只能靠肉眼对照坐标轴估读
  - 隐私模式（小眼睛）打开时金额自动掩码，标签内不泄露具体数字
  - 桌面鼠标悬停与手机拖拽/点按两种交互都生效（悬停走 fl_chart 的 hover 事件、点按走既有 touch 事件，共用同一标签渲染）

### Notes

- 新增 `trendHoverLabelLines` 纯函数与 5 条单测（净值/收益率/掩码/首日/越界），标签文案口径与图表、收益日历一致

## [0.9.15] - 2026-09-21

### Added

- **记录流水可选「发生日期」，历史流水可改日期（补录历史操作的能力）**: 此前记一笔一律使用当前时间，补录「几天前实际发生、现在才记账」的操作只能记成今天——历史回放随即把该流水放在错误的日子：例如 9-02 买入月月鑫2 / 9-08 买入月月鑫（当天从天天宝出资赎回），今天才补录时两笔赎回被记成 9-21，而持仓按买入日 9-02/9-08 计入 → 9-02~9-20 期间同一笔钱在天天宝与月月鑫两边同时出现，净值被重复计算抬高（实测 250 万+ 的平台、9-02 无预兆 +27 万）。现在：
  - 「记一笔」对话框新增**发生日期**字段（默认今天，可回改到真实日期）；「用已持仓出资买入」的赎回+买入两条流水使用同一所选日期
  - 收选日期早于今天时自动打全量重建标记（light 回填窗口覆盖不到更早的日子）
  - 交易流水页**点击任意流水项**可「修改日期」，保存后自动全量重建历史净值

### Notes

- 已经因补录错位写坏的存量数据（如上述月月鑫场景）：用 0.9.15 把对应流水的日期改为真实发生日，或删除后按正确日期重录，再执行 设置 → 重建历史快照 一次即可修复，无需手动改数据库
- 修改/回填流水的日期会改写该日的历史本金与产品收益日历（金额型按流水重放），因此一律触发全量重建并需要联网
- 回归测试 3 条：`record(occurredAt:)` 落库、对话框日期字段透传与今天默认值、流水页「修改日期」入口；移除此功能后对话框用例立即失败（找不到「发生日期」）

## [0.9.14] - 2026-09-21

### Fixed

- **编辑持仓把资产类型从金额型（现金/银行存款/活期理财）切换到份额型（如 银行理财）时，收益瞬间变成巨额亏损、历史曲线被整体污染**: 两种口径在 `数量/成本/净值` 三列里存着不同含义——金额型 = 余额 / 累计投入 / 恒 1，份额型 = 份额 / 单位成本 / 净值。编辑弹窗此前只换类型标签、数字原样保留：朝朝宝（余额 5 万、累计投入 5 万）改成银行理财后，5 万被读成「份额」、5 万被读成「每份成本」，成本 = 5 万 × 5 万 = **25 亿**，收益瞬间 −25 亿；而银行理财的历史平滑插值又把「累计投入」当起始单价，之后每次全量重建历史都用这个错误单价把整段曲线写坏（实测：切换日附近快照被重算成 58,775，起点前的旧值却残留 → 曲线永久断层）。现在编辑弹窗在**跨金额性切换的瞬间**自动换算：余额→份额（净值 1 时同数）、累计投入÷份额→单位成本、份额×净值→余额、份额×单位成本→累计投入，并在弹窗内联展示换算结果与「请核对/请填真实净值」提示，收益在切换前后保持连续
- **从份额型改回金额型时「累计投入」会被悄悄丢成本金（=余额）**: 编辑弹窗的累计投入初始值此前按「打开弹窗时的类型」一次性判断，份额型打开时初始化为空，改回金额型后若不动该字段，保存就把成本写成余额。现在换算时同步填充，用户不改也正确
- **类型切换后普通回填不覆盖起点之前的旧口径快照**: 回填的 light 窗口只重算「上次运行日→今天」，切换日更早的快照会以旧口径永久残留（这就是改回现金后曲线依然错乱的原因）。现在跨金额性切换会写入全量重建标记（`history_full_rebuild`），下一次回填——无论自动还是手动「重建历史快照」——必定全量重算整个窗口，成功后清除标记；网络失败则保留标记下次重试

### Notes

- 本次修复只保证**之后**的切换正确；**已经写坏的持仓行**（如朝朝宝当前的 数量 5 万 / 成本单价 5 万 / 净值 1）需要先手动把「成本单价」改成真实单位成本（= 累计投入 ÷ 份额，通常为 1），保存后再执行一次 设置 → 重建历史快照
- 历史全量重算需要联网（拉取行情历史）；离线时标记会保留到下次网络正常自动重试
- 新增回归用例 12 条：语义换算 7（含 0 余额 / 缺净值 / 同侧切换边界）、收益连续 2（切换后组合收益保持、平滑历史从单位成本起插值）、全量重建 1、编辑弹窗端到端 2（银行存款→银行理财、银行理财→现金，断言换算后字段与重建标记落库）。均做反向验证——撤掉换算逻辑时弹窗用例立即失败（成本单价显示 50000 而非 1）

## [0.9.13] - 2026-09-20

### Fixed

- **外币持仓在汇率拿不到时被按 1:1 折算，净资产与「今日收益」出现大额偏差，并被同步到其它设备**: 折算函数对取不到的货币会静默回落成 1，算出来的数字看着仍然合理；而快照写完即落库、跨设备按最后一次写入生效，所以错的那个会扩散出去。现在缺汇率就不写这一天，宁可留空等下次刷新补上；历史回填与产品收益页同样拒绝使用不完整的汇率表
- **现金账户记收入或支出后，收益凭空变动**: 收支与买卖路径仍读原始的「累计投入」列并截断到 0，而 0 在这套成本口径里同时表示「从未记录过本金」——记一笔收入会把本金写成那笔收入本身；支出超过已记录本金则被截断为 0，随后又被当成余额。现在与转账走同一套规则：按有效本金、按比例移动
- **执行「重建历史快照」后，转账日之前的历史本金被算错**: 重放按整笔金额反推，而写入时是按比例移动本金，两者只在余额等于本金、或账户被全额取出时才一致。现在每笔流水实际移动的本金随记录一并保存，重放直接读取

### Notes

- **数据库 schema 9 → 10**：新增可空列 `transactions.cost_moved_amount`。老库升级后既有流水该列为空，重放对它们沿用旧行为，**升级不会改变任何已有数字**
- 备份与多设备同步已带上该字段，旧备份（无此字段）可正常导入
- 缺汇率时当天不写快照（日历会空一格），下次刷新拿到真实汇率后自动补上
- 「重建历史快照」在**盘中**执行仍会把今天定格在盘中价，这是该操作本身的性质，建议收盘后执行
- 新增现金收支成本口径、汇率守卫与 `migration_v10` 共 12 条回归用例，均做过反向验证（撤掉修复后对应用例立即失败）

## [0.9.12] - 2026-09-18

### Fixed

- **转账（账户间划转）后收益出现一笔大额假亏损，过一会儿自动刷新、或手动点刷新才恢复正常**: 转账写成本时按「原累计投入 ± 整笔金额」计算并把下限截到 0，转出金额超过已记录的累计投入时成本被截成 0；而「成本为 0」又被当成「从未记录过成本」，退回拿余额当成本——被转出账户原本的未实现收益就这样被当成了新增成本。现在划转的成本严格守恒：随钱走的本金按「有效本金 × 划出金额 / 余额」按比例同移，划出方与划入方施加同一个数
- **冷启动显示错误的「今日收益」，点右上角刷新一下才对**: 历史回填按流水反推历史本金时，会把「本金恒定」的时间区段按顺序写入、由后一段覆盖前一段的边界日，而本金为 0 的区段被整段丢弃——账户被全额转出（余额与累计投入都归零）后，转账当天留下了转账前的本金，市值侧却已归零，于是当天凭空多出一整笔转账的亏损。现在零本金区段同样保留，清零账户当天不会再留下转账前的本金

### Notes

- 以上两处只影响**之后**的写入与回填，**不会自动修正已经写坏的历史数据**：若曾在清空某个账户（如余额宝全额转出）前后记过转账，请核对被转入账户的「累计投入」是否需要按源账户的实际本金手工修正，并在**收盘后**执行一次 设置 → 重建历史快照
- 新增「转账成本守恒」6 条与历史重放的单元 / 端到端回归用例，均做了反向验证（撤掉修复后立即失败）

## [0.9.11] - 2026-09-17

### Fixed

- **美元持仓的「成本(CNY)」没有按汇率折算，收益被算成了正数**: 导出 CSV 时「兴业银行 汇利日盈6号A」一行显示 市值 98,210.59 / 成本 14,375.55 / 收益 +83,835.04——成本其实是没换算的美元原值（13,083.68 × 1.0987 = 14,375.55），而市值已按 6.7121 折算过，两列口径相撞。真实成本应为 99,910.07（按买入时记录的 6.95）、收益 **−1,699.48**（产品净值 +1.78%，汇率 −3.42%）。同一个问题还让该持仓在「总览净资产」里只被算成 14,631.87，**少计约 8.36 万**
  - 根因：银行理财只要填了代码就会被标成 `marketSource=forex`，而汇率折算函数对 `forex` 一律返回系数 1——本意是给「代码即货币（如 USD）、单价即汇率」的汇率联动产品，但 `Y05A9W10006A` 是**产品代码不是货币**，被误判后连买入时记录的 `costFxRate` 也被忽略
  - 现在只有「来源为 forex **且** 代码确实是货币代码（USD/EUR/HKD…）」才算汇率联动，产品代码按外币正常折算；汇率代码清单由行情源与折算规则共用一份，两者不可能再各说各话
  - CSV 导出的市值列此前用的是裸汇率、成本列用的是折算函数，两套口径并存，现已统一；收益日历里点开的日明细、持仓页的两处合计同步修正
- **商品类 ETF / 黄金 ETF 无法记录正确的产品类型与标的归类**: 这类持仓的**产品类型**是场内基金（份额制、按 6 位代码走实时行情），**标的归类**却是商品或黄金。此前归类只由资产类型机械推导，于是只有三条烂路：选「商品」品类时候选类型是加密货币/期货，后者的**产品代码框直接置灰**（提示「手动净值资产无需代码」），代码根本录不进去；选「黄金」品类只有「积存金」，代码框虽开着，保存时行情源被写死成上金所积存金，填 `518880` 只会一直报「不支持的代码」；老实选「场内基金」则被算进**权益**，资产配置视图、配置比例告警、持仓页品类筛选全部失真

### Added

- 添加/编辑持仓新增**「配置归类」**（新增/编辑弹窗里镜像已有的「风险等级」覆盖）：默认「自动（按资产类型）」，可指定为 债券/权益/黄金/商品/现金/房产/银行理财。归类与产品类型从此互不干扰——豆粕ETF 记成「场内基金 + 归类商品」，黄金ETF 记成「场内基金 + 归类黄金」，代码、份额与实时行情照常工作
- 添加弹窗的品类选择现在就是「配置归类」，并给 债券 / 黄金 / 商品 三个品类的候选类型补上**「基金」**——基金本就是这些标的的通用载体（债基、商品基金、黄金ETF）。选择跨品类时弹窗会明确提示「归类为 X，产品类型为 Y」
- 行情代码输入框放开为「只要不是金额型资产、负债即可填写」（与编辑弹窗原有规则一致），期货、债券也能记录代码

### Notes

- **数据库 schema 8 → 9**：新增可空列 `holdings.category_override`。老库升级后全部既有持仓该字段为空，即继续沿用「按资产类型归类」这一原行为，**升级不会改变任何已有数字**；只有在弹窗里明确指定过归类时才落库（且与类型自然归类相同时不写，避免把归类钉死）
- 数据备份与多设备同步均已带上该字段：旧备份（无此字段）可正常导入，导入后等价于「未覆盖」
- 回归测试新增 `test/holding_category_test.dart` 12 条与 `test/migration_v9_test.dart` 3 条，其中包含一条**端到端弹窗用例**：在「商品」品类下选「基金」、填 `159985`，存出来必须是 `etf` + `sz159985` + 新浪行情 + 商品归类。两条关键路径都做了反向验证——撤掉归类覆盖逻辑时 6 条立即失败（含弹窗用例 `Expected commodity / Actual equity`），撤掉「商品」下的「基金」候选时端到端用例立即失败，证明这些测试是真防线而不是摆设

## [0.9.10] - 2026-09-16

### Fixed

- **点「重建历史快照」后应用陷入无限刷新循环（0.9.9 引入的回归）**: 回填每次运行都会把「上次运行日」写入设置表，而 drift 在设置表**任何一行**被写入时都会重新发射正在被监视的那一行；`historySyncProvider` 恰好一边监视「历史待重算」标志、一边调用回填，于是它自己触发自己——提示条不停弹出「已回填 1 天历史净值」，收益日历反复重载，且每一轮都会重新联网抓取全部持仓的历史行情。现在被监视的设置流会丢弃重复值（`watchSetting` 的 `distinct()`），回填也只在锚点日确实变化时才写入
- 该循环不会损坏数据（每轮写入的值都相同），但会持续消耗流量与电量，遇到时请先强制停止应用

### Notes

- 回归测试新增 `test/settings_watch_test.dart`，锁定这条契约：写入其它设置项不得触发发射、重写相同值不得触发发射、自身值变化仍须发射、监视标志的 provider 写别的设置不得重跑自己。移除 `distinct()` 后其中 3 条立即失败（provider 循环用例实测 `Expected: <40> Actual: <80>`），即直接把该自激复现出来，因此这些测试是真实防线

## [0.9.9] - 2026-09-16

### Fixed

- **总览与收益日历的"今日收益"被严重低估（实测少算约 4,800 元）**: 当日收益取"今天快照 − 昨天快照"，而快照可能写在**盘中**——昨天的基准一旦定格在高位就再也不会被修正。2026-09-15 恰好高开低走（半导体 0.968→0.964、标普500 2.659→2.640、红利 3.387→3.382），13:45 那次刷新写下的快照把 9-16 的收益压低了约 2,070 元；再叠加场外基金净值天然滞后一天（9-15 的净值跌幅被记进 9-16，约 2,170 元），当日收益显示 +104.30，而实际约 +4,900
- 历史回填改为重算「自上次运行以来的每一天」: 此前只重算今天，昨天（以及任何被实时价定格的日子）永远不会被修正，其偏差会持续污染次日收益。现在按 `[上次运行日, 今天]` 重建，App 长时间未打开形成的任意长度空档也能一次修好，而锚点之前（可能是用户手动改过）的日子不受影响
- 升级后首次启动的回填窗口向后取固定 7 天，而不是退化成「只重算今天」: 取 7 天覆盖"周末 + 假期"这一最长常规空档，使升级设备在第一次启动时就自动修好窗口内被定格的日子，不必等用户手动重建
- 回填完成后不再无条件用实时行情重写当天快照: 该调用不刷新行情、用的是缓存价，违反 `SnapshotService` 关于「`force` 只能在报价确认新鲜时传入」的约定，会用未经验证的数值覆盖与历史序列本已一致的当天数据。现在仅在回填确实没有写今天时才兜底，其余情形交给行情页那条带刷新闸门的写入
- 告警事件的写入时间改为**所评估的时间点**（此前用列默认值，即真实时钟）: 注入时间运行时（测试、历史回放）两者不一致，事件会落在自己的去重窗口之外，导致同一条规则在已触发过的重复日再次触发

### Added

- 设置页「数据备份」卡片新增**「重建历史快照」**: 联网重抓历史收盘价与基金净值，重算全部历史快照。这是修正**已经落库**的盘中偏差快照的唯一手段（此前没有任何入口，只能靠"编辑一次持仓"间接触发）。执行时先刷新行情、仅在全部成功后才重写当天，避免用未验证的缓存价覆盖正确数值
- 设置页「关于」区显示当前安装版本（形如 `0.9.9+35`），便于反馈问题时核对
- 新增依赖 `package_info_plus`，用于读取应用包信息
- 回归测试：回填在「次日」「长空档」两种情形下自动修复被定格的日期、锚点之前的日子不受影响，以及无锚点时回溯固定一周的边界行为（窗口内修复 / 边界日属窗口内 / 窗口外不动）

### Notes

- 详细排查过程、逐日线/净值对账与收盘后验证见 `docs/bug-report-today-earning-2026-09-16.md`

## [0.9.8] - 2026-09-15

### Security

- **Android 发布签名密钥轮换（免卸载）**: 旧 keystore 与其口令此前被提交进这个公开仓库，现已视为泄露。新密钥为 RSA-4096，发布包改为**带签名谱系（proof-of-rotation）**的双签名——v1/v2 块仍由旧密钥签（Android 7.0–8.1 的签名校验不变，照常覆盖升级），v3/v3.1 块由新密钥签并携带"新密钥继承自旧密钥"的谱系证明，因此 **Android 9+ 直接认可新身份，无需卸载重装**。已在装有旧签名的设备上实测覆盖安装成功
- 签名材料改为只从 CI secrets 注入（旧 keystore、新密钥、口令、谱系共 6 项），仓库与提交历史中不再存在任何密钥文件
- 新增 `tools/check_apk_rotation.py`: 发布构建在上传前校验每个 APK 是否带谱系，缺失即构建失败，避免悄悄发出未正确签名的包

### Notes

- 泄露的密钥文件已从**全部历史提交与 tag** 中移除，历史 sha 因此被重写（所有 tag 已重新指向内容相同的新提交）；旧密钥仍保留在 CI secret 中，仅用于继续为旧设备提供 v2 签名
- 从任意旧版本**直接覆盖安装即可**，无需卸载

## [0.9.7] - 2026-09-14

### Fixed

- **非交易日"当日盈亏"出现数百元假涨跌，过一会儿又自己恢复**: 黄金持仓的实时价与历史价取自**两个不同品种**——实时走"伦敦现货金 × 美元汇率 ÷ 31.1034768"，历史回填走"上金所黄金期货 AU0"，两者基差约 1%。而"今天"此前不在回填窗口内、由实时路径单独写入，于是这段基差全部落在当天这一条快照上（先写今天、几十秒后全量重建历史，重建又不覆盖今天）——表现为周末/非交易日突然多出几百元，等下一次重建按收盘序列重算该日又"恢复正常"。现在两条路径统一由**伦敦现货金**经同一换算函数折算为元/克（`core/gold.dart` 单一定义，实时与历史共用），口径差在结构上不可能再出现；升级后首次回填自动全量重算一次
- **历史回填窗口纳入"今天"**: 同一套逐日估值逻辑现在也产出今天这条快照，实时路径与历史路径不再在唯一一天上分叉（此前 `while (day.isBefore(today))` 把今天永久排除在重建之外）
- 行情刷新失败仍强制重写当天快照: 刷新有失败项时不再用缓存中的旧价覆盖当天数值（断网冷启动即可复现），避免把已经正确的当天数据改坏
- 快照重写不更新同步版本: `createdAt` 是对外同步的最后写入时间，但此前依赖数据库默认值、重写时不回写，导致修正后的数值在多设备合并时永远赢不过旧的错误值（现显式写入，附回归测试）
- 持仓列表/详情的"今日盈亏"在休市与开盘前把上一交易日的涨跌算成今天的: 行情源的涨跌幅字段描述的是"最近一个已结束的交易时段"，周末/开盘前它仍指向上一时段。现按行情源区分（A 股/场外基金/黄金/汇率按交易时段判定，加密货币 7×24 不受影响，附回归测试）
- 总览卡片"今日盈亏"可能显示的不是今天: 当天快照尚未写入时会拿最近两条历史快照相减，把更早某天的涨跌标成"今天"。现在要求最后一条快照就是今天，否则回落到与同卡片"总资产"同一时点的实时数值

### Added

- 口径一致性回归测试（`test/gold_consistency_test.dart`）：同一 symbol、同一天，断言实时金价与历史金价逐分一致；另附联网校验用例（`--dart-define=LIVE=true`），实测两条路径相对误差 < 0.5%，可挡住"同一持仓用两个品种报价"这一整类问题

### Notes

- 详细排查过程见 `docs/bug-report-weekend-earnings-2026-09-14.md`

## [0.9.6] - 2026-09-11

### Changed

- 汇率联动银行理财的币种改为自由标记: v0.9.4 曾把这类持仓的币种字段锁定为 CNY（用户反馈"无法更改"）。实际上汇率联动持仓的单价本身就是汇率（市值 = 数量 × 汇率，折算已内含在单价中），币种只是个标签——现在始终可编辑、保存不再强制 CNY，"USD 美元理财 + 实时汇率折算"两个诉求可同时满足；切换币种只是改标记，数量/成本/单价无需重填。存量 CNY 持仓的数值行为完全不变（附回归测试与防双倍折算单测）
- 汇率联动持仓切换币种时不再弹出"数值不会自动换算"提示（对该类持仓不适用）

## [0.9.5] - 2026-09-11

### Fixed

- 净资产历史"悬崖"修复: 平滑回放此前忽略 buy/sell 对现金类持仓的本金联动腿（出资买入的赎回腿、买入扣款腿、卖出回款腿），"天天宝出资买基金"后历史余额/投入一直停在赎回前水平，直到今天才被拉回。现在三条腿全部回放，历史净资产与投入逐日正确（可在历史回填中重算，无需迁移）
- 产品收益日历翻看往年出现幻影盈亏: 回放把窗口之后发生的交易也应用到窗口最后一天，往年的最后一天被算成"今天的实际持仓"。现在只消费窗口内的事件（附回归测试）
- 删除非最新"份额折算"流水会静默缩放其后所有交易的数量/成本: 现在与买入回滚一样，要求先删除更晚的流水（附回归测试）
- 转账/还款无余额校验（源余额可扣成负数），且源=目标同一持仓时成本被永久漂移: 现在拒绝同一持仓互转并校验余额；转账/买入扣款/卖出入账/分红增加币种一致性校验，跨币种不再平移同一数字（附回归测试）
- 备份导入会把交易挂到错误的持仓上（曾在使用过的设备上）: 导入现在显式写入校验模型计算的 id，校验与实际写入完全一致；备份新增携带目标配比计划，导入清理历史告警事件
- 同步健壮性: 同步进行中的本地编辑/删除不再被旧合并数据回滚（应用阶段守卫）；快照删除写入墓碑（跨设备修剪不再被服务器复活）；同秒同金额流水唯一键冲突不再导致整轮同步失败（本地记录路径给出友好提示）；同步墓碑 180 天自动清理；同步比较改为逐字段（键序/数字形态变化不再制造永久假冲突）；409 冲突解析容忍代理错误页；墓碑项增加表名白名单校验
- 启动自动同步合并数据后，当日收益/快照立即重建（原需重启 App）
- 月/年收益率分母改为资产口径（原用净资产，有负债时收益率被放大）
- 提醒规则计算接入汇率折算（外币持仓的集中度/权益占比与 CNY 总资产同口径）；"权益类"判定改为与资产配置大类单源
- 总览"今日盈亏"与提醒的价格缓存统一按归一化行情代码查询，编辑对话框保存的裸代码也会归一化
- 债券/期货/房产/汇率联动银行理财的历史净值改为平滑插值（原全程按当前价回填，历史收益虚增），并纳入产品收益日历；升级后首次历史回填自动全量重算一次
- 深市场内基金代码（159/16/18 开头）从统一"基金"入口正确落为场内基金（此前永远被判为场外，盘中行情不可见）
- 旧版保存过合计超过 100% 的目标配比导致的"编辑死锁"修复: 编辑器装载时自动归一化；保存统一写入一位小数，不再能存出 101%
- 统计页"月度收益"柱状图 X 轴标签错位修复（原来全部挤在第一根柱内）
- 数据迁移重建表改为原子事务（中途失败不再留下打不开的数据库）；移除 512480 拆分的全局补丁（曾影响其他设备的小仓位）
- 同步服务器: docker compose 默认强制设置 ASSET_SYNC_TOKEN（原先默认空=完全无鉴权）；无 token 启动时打大字警告；token 比较改为恒定时间；请求体超限/超时/畸形 JSON 返回正确的 HTTP 状态码；限流表定期清理；响应 docker stop 的 SIGTERM；HOST=localhost 正确绑定
- 目标配比未知键按文档忽略（不再静默计入"债券"）；不支持币种（如 SGD）在对话框提示将按 1:1 折算；桌面资产配置的"其他"切片不再伪装可点击；导出 CSV 防公式注入；流水对手方/成本列口径修正

## [0.9.4] - 2026-09-11

### Fixed

- 银行理财币种编辑被静默改回人民币: 手动净值银行理财在每次编辑时被误判为汇率联动并强制 CNY，币种改 USD 保存后不生效。现在手动净值类型可正常修改币种; 外汇联动（填写行情代码）的银行理财币种字段锁定并显示原因，不再静默改写（附回归测试）
- 债券/期货持仓无法记交易: 「记一笔」只显示收入/支出/转账且保存全部失败，买入/卖出入口缺失。现在与股票/基金一致提供买入/卖出/分红/份额折算（房产持仓同样恢复可用）
- 持仓入口「支出」永远失败报"需要指定现金持仓": 联动字段传反导致扣款从未生效（流水页/CSV 的支出对手方列也一直为空）。现在与「收入」对称，真正扣减现金余额
- 外币持仓的买入/卖出/分红流水一律按 CNY 入账: USD 持仓的已落袋收益/现金流统计差一个汇率倍数。现在按持仓币种记录流水
- 加密货币日涨跌幅显示 ×100（+1.23% 显示成 +123.5%）: CoinGecko 源的百分比口径与其它行情源统一
- 519xxx 场外基金代码被误判为场内基金导致自动净值永远失败: 现在正确保持场外类型（沪市场内基金代码段为 500-518）
- 备份导入后「删除 → 恢复备份 → 同步」会把恢复的数据静默吞掉: 导入时清除本地同步墓碑并将恢复数据的时间戳提升为导入时刻，恢复数据优先于删除记录
- 冷启动直接导出持仓 CSV 时，外币市值/成本列静默按 1:1 写入 CNY 列: 导出前等待汇率就绪
- 「记一笔」「记流水」对话框关闭时偶发控制器已释放崩溃（关闭动画期间释放控制器）
- 流水页「· 今天」角标永不显示（日期比较含时间分量）; 收益日历脚注与实际口径相反（负债变动其实不计入盈亏）; 卖出落袋预览外币符号错误; 期货添加页显示误导性代码示例
- 编辑持仓切换币种时提示: 数量/成本单价/最新净值不会自动换算，请按新币种确认填写

## [0.9.3] - 2026-09-09

### Added

- 资产配置大类重构: 由"股票/基金/黄金/债券/现金/其他"改为 债券/权益/黄金/商品/现金/房产/银行理财 七大类（股票+场内基金+场外基金→权益、加密货币→商品、房产与银行理财单独成类、"其他"下线）；已保存的目标配置自动迁移（股票+基金→权益、加密→商品、旧"其他"丢弃）
- 新增"期货"资产类型: 归入商品大类，高风险、手动净值，行情代码提示"如 螺纹钢2405"
- 添加持仓二级选择: 先选大类（债券/权益/黄金/商品/现金/房产/银行理财/负债），再选该大类下的具体类型；场内基金与场外基金合并为单个"基金"选项，按代码自动识别（沪市 5/6 开头→场内基金，其余→场外基金，不填代码默认场外），类型列表不再平铺 10 余项

### Changed

- 目标配置（计划配比）从设置页移到提醒页，与"配置比例偏离"提醒规则相邻，配置与偏离提醒同处一地
- 目标配置合计不超过 100%: 每类滑块上限 = 剩余可分配额度（物理上无法拖超），底部实时显示"合计/剩余"，保存前再次校验
- 币种字段对所有资产类型可编辑: 此前股票/基金/黄金/加密等市场联动类型被强制人民币，美元持仓无法按 USD 记录；现在仅外汇联动的银行理财锁人民币，其余类型可按需设置币种
- 导出持仓 CSV 的市值/成本/收益按汇率折算为人民币（列名标注 CNY），币种列保留原币种，数量/单价仍为原币单位，与 App 内显示口径一致

### Fixed

- 美元持仓被当作人民币统计: 市场联动类型币种曾被强制 CNY 且编辑时币种字段隐藏，美元持仓无法修正。现在编辑对话框币种字段始终可见、可自由修改

## [0.9.2] - 2026-09-09

### Fixed

- 目标配比显示为天文数字: 目标占比在存储中是整百分数（40 表示 40%），但对比条组件按 0~1 比率格式化，导致显示成 4000%/3000% 等（且目标竖线被压到最右侧）。现在组装对比条目时统一换算为比率，目标显示为"40.0%"、偏差按百分点计算，附回归测试
- 信用卡消费被统计成亏损: 收益统计原按"净资产（总资产−负债）− 成本"计算，先记一笔信用卡消费（负债增加）时净资产被拉低，当天收益直接变负。现在统一按资产口径（净资产+负债）− 成本计算：消费/借款/还款只改变负债线、不再计入盈亏，本金转入转出同样不计入；影响今日收益、收益日历、统计页月度收益、趋势图收益率与区间统计及"较前日"提示，历史数据重算即正确，无需迁移
- 总览页右滑返回无法退出应用: 返回拦截把根页面也包含在内，导致在总览页右滑返回无法退出 App。现在仅在无栈可退的 Shell 二级页面拦截并回到总览；总览页右滑正常退出，账户详情等压栈页面正常逐级返回（附模拟系统返回的回归测试）
- 统计页最佳/最差月份与盈利月份占比改用收益口径: 原基于月度净现金流（现金流为正 ≠ 盈利，大额赎回本金回流会虚高"盈利月份"）。现基于每日净值快照的月度投资收益（剔除转入转出本金与负债变动影响），月度图表同步改为"月度收益"

### Changed

- 资产走势图 Y 轴左侧留白按标签实际宽度动态贴合: 手机端不再固定 40px，标签多宽留多宽（下限 22px），绘图区进一步左移、显示区域更大，桌面端不变

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
