# Asset Tracker

A local-first, multi-platform asset tracking app built with Flutter. Track your investments — stocks, ETFs, mutual funds, gold accumulation, bank wealth management products, credit cards, and more — without manual daily bookkeeping.

[中文说明](#中文说明)

## Features

- **Multi-platform** — Android, Web, Windows desktop from a single codebase
- **Local-first & private** — all data stays on your device (SQLite). No account, no server, no cloud
- **Automatic market sync** — prices auto-update from free public sources:
  - A-share stocks & ETFs / LOFs (Sina Finance on desktop, Tencent on the web; CORS-friendly)
  - Mutual funds — official NAV (Eastmoney API on desktop, push2 endpoint on the web)
  - Gold accumulation products (SGE Au99.99 spot price)
  - Foreign currency assets with auto FX rates
  - On desktop, each source falls back to its CORS-friendly web endpoint if the primary fails
  - Bank wealth management products — manual NAV updates with smooth daily accrual (no public API; history is interpolated between your updates, respecting income/expense flows)
- **Transaction log** — buy / sell / dividend / income / expense / transfer / credit-card spend (consume) / unit split, as the basis for cost & return calculation, with automatic rollback on delete
- **Liabilities** — credit cards and loans tracked separately from assets; repayments and borrowing via transfers
- **Portfolio dashboard** — net worth curve, asset allocation, returns breakdown, per-holding today's P&L
- **Earnings calendar** — monthly calendar of daily profits (cost-basis, immune to money flows); tap a day for per-holding day changes sorted by return
- **Privacy mode** — an eye toggle hides all monetary amounts behind a mask on the overview page
- **Corporate actions** — dividend cost-basis method (ex-dividend drops don't distort returns), unit split transactions, adjusted (qfq) price history so ex-rights days stay continuous
- **Multi-currency cost basis** — record the purchase-time exchange rate per holding so FX gains/losses are accounted for correctly
- **Rule engine alerts** — concentration risk, stock/bond ratio drift, daily drawdown warnings, cashflow reminders (loan/maturity/auto-invest dates); fired rules push local notifications (Android & Windows, once per rule per day)
- **Backup & restore** — JSON export/import (desktop/web download, system share sheet on mobile) preserving ids and transfer links

## Tech Stack

| Layer | Choice |
|-------|--------|
| Framework | Flutter 3.44+ (Dart) |
| State management | Riverpod |
| Database | Drift (SQLite; sqlite3.wasm on the web) |
| Charts | fl_chart |
| Market data | Sina / Tencent / Eastmoney / CoinGecko free endpoints |
| Sync | Optional self-hosted Dart (shelf) server, LWW + tombstones |
| CI | GitHub Actions (web deploy on Pages) |

## Try it online

Web version (auto-deployed from `main`): **https://squarelimber.github.io/asset-tracker/**

Built as WebAssembly with a WasmGC capability check — works on modern Chromium-based browsers, Firefox and Safari builds that support WasmGC. Data is stored locally in the browser (IndexedDB).

## Getting Started

### Prerequisites

- Flutter 3.44+ ([install guide](https://docs.flutter.dev/get-started/install))
- For Windows desktop: Visual Studio 2022 with "Desktop development with C++"

### Run

```bash
flutter pub get
flutter run -d windows   # or -d chrome / an Android device
```

### Build

```bash
flutter build windows
flutter build web --wasm --release --base-href=/asset-tracker/
flutter build apk
```

One-command full verification (analyze + tests + all-platform builds, ~1 min):

```powershell
.\tools\verify_all.ps1            # everything
.\tools\verify_all.ps1 -ChangedOnly   # only platforms whose files changed
```

## Project Structure

```
lib/
  app/          # entry, providers, routing, theme
  core/         # constants, symbols, formatting, responsive layout
  data/         # drift tables & DAOs
  domain/       # calculators (portfolio, rates, earnings, smooth history), rule engine
  services/     # market data, alerts, backup, snapshots, migrations, CSV export
  sync/         # multi-device sync (wire format, LWW merge, client)
  ui/           # design tokens, shell, shared components, pages
server/         # optional self-hosted sync server (Dart/shelf, Docker)
```

## Roadmap

- [x] Project scaffold
- [x] Data layer (accounts, holdings, snapshots, alert rules)
- [x] Market data engine (A-share → funds → gold/FX → manual NAV)
- [x] Dashboard, net worth curve, reports
- [x] Rule engine alerts (concentration / allocation / drawdown / cashflow)
- [x] Backup/restore (JSON), CI (analyze + test + web/windows builds)
- [x] Transaction log UI with automatic rollback
- [x] Android packaging (release APKs)
- [x] Web build (wasm) with WasmGC detection
- [x] Earnings calendar, privacy mode, dividend/split handling, smooth accrual for manual holdings, purchase-time FX rates
- [x] Local notifications (Android & Windows)

## Disclaimer

This app provides data aggregation and simple rule-based reminders for reference only. It does **not** constitute investment advice. All investment decisions are your own responsibility. Market data from third-party public endpoints may be delayed or inaccurate.

## License

MIT © 2026 [squarelimber](https://github.com/squarelimber)

---

## 中文说明

本地优先、多端复用的资产追踪 App。无需每日手动记账，行情自动联动。

- **多端支持**：Android / Web / Windows，一套代码
- **数据本地化**：数据仅存本机 SQLite，无需注册、无服务器、无云端
- **自动行情**：A股股票/场内基金（桌面新浪、网页腾讯，均支持 CORS）、场外基金（天天基金官方净值）、积存金（上金所金价）、外币资产（自动汇率）；银行理财无公开接口，提供手动更新净值 + 每日平滑计提（按收入/支出流水分段插值，两端始终真实）
- **交易流水**：买入/卖出/分红/收入/支出/转入转出/信用卡消费/份额折算，删除自动回滚，作为成本与收益计算基础
- **负债管理**：信用卡/贷款与资产分开统计，转账还款/借款一键记录
- **仪表盘**：净值曲线、资产配置、收益分析、每个持仓的今日收益
- **收益日历**：每日收益月历（成本法口径，资金进出免疫），点选日期查看按当日涨跌排序的持仓明细
- **隐私保护**：总览页小眼睛开关，金额默认掩码显示
- **除权除息**：分红成本法（除息不虚降）、份额折算流水、前复权历史（折算/除权日无跳变）
- **多币种成本**：每个持仓记录买入时汇率，汇兑损益正确计入
- **规则提醒**：集中度风险、股债比例偏离、单日跌幅预警、还款/定投日提醒，触发时推送本地通知（Android / Windows，同一规则每天最多一次）
- **备份恢复**：JSON 导出导入（桌面/网页下载、移动端系统分享），保留原始 ID 与转账关联

> 免责声明：本应用仅提供数据汇总与规则提醒，仅供参考，不构成投资建议。行情数据来自第三方免费接口，可能存在延迟或误差。
