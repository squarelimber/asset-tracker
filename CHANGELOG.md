# Changelog

All notable changes to Asset Tracker. Entries are condensed from the commit history; dates follow the release tags.

## [Unreleased]

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
