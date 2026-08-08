# Asset Tracker

A local-first, multi-platform asset tracking app built with Flutter. Track your investments — stocks, ETFs, mutual funds, gold accumulation, bank wealth management products, and more — without manual daily bookkeeping.

[中文说明](#中文说明)

## Features

- **Multi-platform** — Android, iOS, Web, Windows desktop from a single codebase
- **Local-first & private** — all data stays on your device (SQLite). No account, no server, no cloud
- **Automatic market sync** — prices auto-update from free public sources:
  - A-share stocks & ETFs / LOFs (Sina Finance)
  - Mutual funds — intraday estimate + official NAV (Eastmoney)
  - Gold accumulation products (SGE Au99.99 spot price)
  - Foreign currency assets with auto FX rates
  - Bank wealth management products — manual NAV update with periodic reminders (no public API)
- **Transaction log** — buy / sell / dividend / transfer records as the basis for cost & return calculation
- **Portfolio dashboard** — net worth curve, asset allocation, returns breakdown
- **Rule engine alerts** — concentration risk, stock/bond ratio drift, daily drawdown warnings, cashflow reminders (loan/maturity/auto-invest dates)
- **Backup & restore** — export/import JSON or SQLite file to move data between devices

## Screenshots

*(coming soon)*

## Tech Stack

| Layer | Choice |
|-------|--------|
| Framework | Flutter 3.x (Dart) |
| State management | Riverpod |
| Database | Drift (SQLite) |
| Charts | fl_chart |
| Market data | Sina / Eastmoney / CoinGecko free endpoints |
| CI | GitHub Actions |

## Getting Started

### Prerequisites

- Flutter 3.29+ ([install guide](https://docs.flutter.dev/get-started/install))
- For Windows desktop: Visual Studio 2022 with "Desktop development with C++"

### Run

```bash
flutter pub get
flutter run -d windows   # or -d chrome / an Android device
```

### Build

```bash
flutter build windows
flutter build web
flutter build apk
```

## Project Structure

```
lib/
  app/          # entry, routing, theme
  core/         # constants, utils, responsive layout
  data/         # drift tables & DAOs
  domain/       # entities, repository interfaces, rule engine
  services/     # market data, notifications, backup
  features/     # accounts, holdings, portfolio, reports, alerts, settings
```

## Roadmap

- [x] Project scaffold
- [ ] Data layer (accounts, holdings, snapshots, alert rules)
- [ ] Market data engine (A-share → funds → gold/FX → manual NAV)
- [ ] Dashboard, net worth curve, reports
- [ ] Rule engine alerts + local notifications
- [ ] Backup/restore, CI, packaging

## Disclaimer

This app provides data aggregation and simple rule-based reminders for reference only. It does **not** constitute investment advice. All investment decisions are your own responsibility. Market data from third-party public endpoints may be delayed or inaccurate.

## License

MIT © 2026 [squarelimber](https://github.com/squarelimber)

---

## 中文说明

本地优先、多端复用的资产追踪 App。无需每日手动记账，行情自动联动。

- **多端支持**：Android / iOS / Web / Windows，一套代码
- **数据本地化**：数据仅存本机 SQLite，无需注册、无服务器、无云端
- **自动行情**：A股股票/场内基金（新浪）、场外基金（天天基金，盘中估值+官方净值）、积存金（上金所金价）、外币资产（自动汇率）；银行理财无公开接口，提供手动更新净值+定期提醒
- **交易流水**：买入/卖出/分红/转入转出，作为成本与收益计算基础
- **仪表盘**：净值曲线、资产配置、收益分析
- **规则提醒**：集中度风险、股债比例偏离、单日跌幅预警、还款/定投日提醒
- **备份恢复**：JSON/SQLite 导出导入，跨设备迁移

> 免责声明：本应用仅提供数据汇总与规则提醒，仅供参考，不构成投资建议。行情数据来自第三方免费接口，可能存在延迟或误差。
