# Asset Tracker

A local-first asset tracker that keeps every position — stocks, funds, gold, deposits, bank wealth products, crypto, property, liabilities — accurate without daily manual bookkeeping. Prices update themselves; your data never leaves your device unless you want it to.

**Live web version:** https://squarelimber.github.io/asset-tracker/

## Why

Most portfolio apps force a choice: a cloud service that wants your financial data, or a spreadsheet you update by hand. Asset Tracker takes a third path — a real database on your own device, live market prices from free public endpoints, and an optional sync server **you** host. There is no account, no telemetry, and no third party in the loop.

## Features

### Tracking

- **13 asset types** — cash, bank deposits, demand & fixed wealth products, bank wealth management (银行理财), stocks, on- & off-exchange funds, gold accumulation, bonds, crypto, futures, property, and liabilities (credit cards & loans)
- **Transaction history and corrections** — log buys, sells, dividends, income, expenses, transfers, card spending, and unit splits. View execution details and preview changes to trade amounts, quantities, or prices and their effect on linked holdings. Closed positions can reconcile a transposed sale quantity and price against the complete recorded share ledger. Date edits check historical balances before saving.
- **Amount-based and share-based holdings** — a deposit account and a stock position are modelled the way they actually behave, with cost basis conserved across transfers and redemptions
- **Liabilities tracked separately** — repayments and borrowing are plain transfers; debt never pollutes asset totals or allocation ratios
- **Manual category override** — a gold ETF is a fund by product but gold by exposure; file it where it belongs and every allocation view follows

### Market data

- **Automatic quotes from free public sources** — A-shares & exchange funds (Sina / Tencent), fund NAVs (Eastmoney), gold (SGE spot), FX rates, crypto (CoinGecko)
- **Web endpoints as fallback** — on desktop, each source falls back to its CORS-friendly web twin if the primary fails
- **Sanity guard** — a quote that jumps implausibly against the last known price is rejected instead of written (a mis-mapped ticker cannot fabricate a 99% loss)
- **Manual NAV for bank wealth products** — record or backfill dated NAV observations. Historical valuations use the observed NAV on each recorded date and interpolate between observations.
- **Corporate actions** — dividend cost-basis method (ex-dividend drops don't distort returns), unit splits, forward-adjusted price history

### Analysis

- **Dashboard** — historical portfolio trends, estimated intraday portfolio P&L for covered holdings, per-holding daily P&L, and allocation by type and category
- **Earnings calendars** — review daily portfolio profit or monthly profit by product. Daily details show each holding's contribution, including realized gains on sales whose proceeds leave the tracked portfolio.
- **Category earnings** — compare profit and return by allocation category for this month, this year, or a custom period; expand a category to inspect its products, including closed positions.
- **Risk statistics** — estimated Sharpe ratio and annualized volatility from consecutive usable daily snapshots, with an adjustable risk-free rate
- **Multi-currency cost basis** — record the purchase-time FX rate per holding; currency gains and FX gains are accounted separately
- **CSV export** — holdings, transactions, snapshots

### Peace of mind

- **Local-first & private** — SQLite on device (IndexedDB on web). No account, no cloud, no analytics
- **Optional self-hosted sync** — run your own Dart sync server (Docker included). Clients reconcile independently recorded trades against a common opening balance and report conflicts they cannot resolve safely.
- **Rule-engine alerts** — concentration risk, allocation drift, daily drawdown, cashflow reminders (loan / maturity / auto-invest dates); fired rules push local notifications, once per rule per day
- **Privacy mode** — one toggle masks every amount on the overview
- **Backup & restore** — JSON export/import preserves record IDs, transfer links, archived holdings, and the transaction timestamps used to validate historical snapshots

## Tech Stack

| Layer | Choice |
|-------|--------|
| Framework | Flutter (Dart) |
| State | Riverpod |
| Database | Drift (SQLite; sqlite3.wasm on web) |
| Charts | fl_chart |
| Market data | Sina / Tencent / Eastmoney / SGE / CoinGecko free endpoints |
| Sync | Optional self-hosted Dart (shelf) server with ledger reconciliation |
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
  sync/         # multi-device sync, wire format, and merge client
  ui/           # design tokens, shell, shared components, pages
server/         # optional self-hosted sync server (Dart/shelf, Docker)
```

## Releases

- Download Android APKs and the Windows x64 ZIP. [Latest GitHub Release](https://github.com/squarelimber/asset-tracker/releases/latest)
- Open the web build deployed by GitHub Actions. [Web app](https://squarelimber.github.io/asset-tracker/)
- Read the changes in each release. [Changelog](CHANGELOG.md)

## Disclaimer

This app provides data aggregation and simple rule-based reminders for reference only. It is **not** investment advice. Market data comes from third-party public endpoints and may be delayed or inaccurate. Investment decisions are your own responsibility.

## License

MIT © 2026 [squarelimber](https://github.com/squarelimber)
