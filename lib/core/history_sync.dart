/// Settings keys for history-sync coordination.
///
/// When holdings change (add/edit/delete, transactions, account removal),
/// callers set `historySyncDirty = '1'` instead of rebuilding immediately.
/// The portfolio page performs the actual (slow) rebuild on open and clears
/// the flag when done — so a partial/failed rebuild is retried next time.
library;

const String historySyncDirtyKey = 'history_sync_dirty';

const String historyDirtySet = '1';
const String historyDirtyClear = '0';

/// Set when an edit crosses the amount-based boundary (a type switch that
/// changes the *semantics* of quantity/costPrice/latestPrice). The next
/// backfill must rebuild the whole window from the earliest purchase date —
/// a light run (since the last run) would leave days written under the old
/// semantics in place and the net-worth curve shows a permanent step where
/// the type changed. Read and cleared by the backfill service.
const String historyFullRebuildKey = 'history_full_rebuild';
