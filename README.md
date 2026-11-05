# Asset Tracker

A local-first asset tracker that keeps every position — stocks, funds, gold, deposits, bank wealth products, crypto, property, liabilities — accurate without daily manual bookkeeping. Prices update themselves; your data never leaves your device unless you want it to.

**Live web version:** https://squarelimber.github.io/asset-tracker/

<p align="center">
  <img src="docs/screenshots/dashboard.png" alt="Dashboard" width="800">
</p>

## Why

Most portfolio apps force a choice: a cloud service that wants your financial data, or a spreadsheet you update by hand. Asset Tracker takes a third path — a real database on your own device, live market prices from free public endpoints, and an optional sync server **you** host. There is no account, no telemetry, and no third party in the loop.

## Features

### Tracking

- **13 asset types** — cash, bank deposits, demand & fixed wealth products, bank wealth management (银行理财), stocks, on- & off-exchange funds, gold accumulation, bonds, crypto, futures, property, and liabilities (credit cards & loans)
- **Transaction log as the source of truth** — buy / sell / dividend / income / expense / transfer / card spend / unit split; deleting an entry rolls the holding back automatically
- **Amount-based and share-based holdings** — a deposit account and a stock position are modelled the way they actually behave, with cost basis conserved across transfers and redemptions
- **Liabilities tracked separately** — repayments and borrowing are plain transfers; debt never pollutes asset totals or allocation ratios
- **Manual category override** — a gold ETF is a fund by product but gold by exposure; file it where it belongs and every allocation view follows

### Market data

- **Automatic quotes from free public sources** — A-shares & exchange funds (Sina / Tencent), fund NAVs (Eastmoney), gold (SGE spot), FX rates, crypto (CoinGecko)
- **Web endpoints as fallback** — on desktop, each source falls back to its CORS-friendly web twin if the primary fails
- **Sanity guard** — a quote that jumps implausibly against the last known price is rejected instead of written (a mis-mapped ticker cannot fabricate a 99% loss)
- **Bank wealth products without an API** — update the NAV manually; daily accrual is interpolated between your updates along the actual income/expense flows, so both ends are always real
- **Corporate actions** — dividend cost-basis method (ex-dividend drops don't distort returns), unit splits, forward-adjusted price history

### Analysis

- **Dashboard** — net-worth curve, allocation, per-type and per-category breakdowns, per-holding today's P&L
- **Earnings calendar** — daily profit by month on a cost basis (immune to money moving between accounts); tap a day for the per-holding detail
- **Multi-currency cost basis** — record the purchase-time FX rate per holding; currency gains and FX gains are accounted separately
- **CSV export** — holdings, transactions, snapshots

### Peace of mind

- **Local-first & private** — SQLite on device (IndexedDB on web). No account, no cloud, no analytics
- **Optional self-hosted sync** — a small Dart server you run yourself (Docker included); opaque last-write-wins merge with tombstones, your data never touches anyone else's machine
- **Rule-engine alerts** — concentration risk, allocation drift, daily drawdown, cashflow reminders (loan / maturity / auto-invest dates); fired rules push local notifications, once per rule per day
- **Privacy mode** — one toggle masks every amount on the overview
- **Backup & restore** — JSON export/import preserving ids and transfer links

## Tech Stack

| Layer | Choice |
|-------|--------|
| Framework | Flutter (Dart) |
| State | Riverpod |
| Database | Drift (SQLite; sqlite3.wasm on web) |
| Charts | fl_chart |
| Market data | Sina / Tencent / Eastmoney / SGE / CoinGecko free endpoints |
| Sync | Optional self-hosted Dart (shelf) server, LWW + tombstones |
| CI | GitHub Actions (analyze → test → web / Windows / Android builds, Pages deploy) |

## Getting Started

### Run from source

```bash
flutter pub get
flutter run -d windows   # or -d chrome / an Android device
```

Windows desktop builds need Visual Studio 2022 with "Desktop development with C++".

### Build

```bash
flutter build windows
flutter build web --wasm --release --base-href=/asset-tracker/
flutter build apk
```

One-command full verification (analyze + tests + all-platform builds):

```powershell
.\tools\verify_all.ps1              # everything
.\tools\verify_all.ps1 -ChangedOnly # only platforms whose files changed
```

## Project Structure

```
lib/
  app/          # entry, providers, routing, theme
  core/         # constants, symbols, formatting, responsive layout
  data/         # drift tables & DAOs
  domain/       # calculators (portfolio, cost basis, earnings, smooth history), rule engine
  services/     # market data, alerts, backup, snapshots, migrations, CSV export
  sync/         # multi-device sync (wire format, LWW merge, client)
  ui/           # design tokens, shell, shared components, pages
server/         # optional self-hosted sync server (Dart/shelf, Docker)
```

## Releases

Latest: **v0.11.0** — see [CHANGELOG.md](CHANGELOG.md) for per-version notes. Releases ship Android APKs, Windows zip and the web build via GitHub Actions.

## Disclaimer

This app provides data aggregation and simple rule-based reminders for reference only. It is **not** investment advice. Market data comes from third-party public endpoints and may be delayed or inaccurate. Investment decisions are your own responsibility.

## License

MIT © 2026 [squarelimber](https://github.com/squarelimber)
