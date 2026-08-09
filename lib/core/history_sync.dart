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
