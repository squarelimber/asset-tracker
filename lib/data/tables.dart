import 'package:drift/drift.dart';

/// An account groups multiple holdings, e.g. a brokerage account,
/// a bank card, or a dedicated fund account.
@DataClassName('AccountRow')
class Accounts extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 64)();
  TextColumn get type => text()();
  TextColumn get currency => text().withDefault(const Constant('CNY'))();
  TextColumn get note => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

/// A single holding position within an account.
@DataClassName('HoldingRow')
class Holdings extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get accountId => integer().references(Accounts, #id)();
  TextColumn get name => text().withLength(min: 1, max: 64)();
  TextColumn get assetType => text()();
  TextColumn get marketSource => text().withDefault(const Constant('manual'))();
  TextColumn get symbol => text().nullable()();
  RealColumn get quantity => real().withDefault(const Constant(0))();
  RealColumn get costPrice => real().withDefault(const Constant(0))();
  RealColumn get latestPrice => real().withDefault(const Constant(0))();
  TextColumn get currency => text().withDefault(const Constant('CNY'))();

  /// Foreign-currency -> CNY exchange rate recorded at purchase time, used
  /// for the cost-basis conversion. Null falls back to the current rate.
  RealColumn get costFxRate => real().nullable()();

  DateTimeColumn get purchaseDate => dateTime().nullable()();
  TextColumn get riskLevel => text().nullable()();

  /// Manual override of the holding's allocation category (an
  /// [AssetCategory.storageName]). Null = derive it from [assetType].
  ///
  /// The asset type says how a holding is recorded and priced; the category
  /// says where it counts in the allocation view, the 配置比例 alert and the
  /// category filter. An ETF carries the *product* type (场内基金 — Sina-
  /// priced, share-based) while its exposure may sit elsewhere: a 黄金ETF /
  /// 豆粕ETF is 黄金 / 商品 for allocation even though its product type is a
  /// fund. Mirrors the [riskLevel] manual override.
  TextColumn get categoryOverride => text().nullable()();
  TextColumn get note => text().nullable()();

  /// Archived holdings stay in the database (and in the earnings calendar)
  /// but are hidden from the default holdings views.
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

/// Buy / sell / dividend / transfer / income / expense records.
/// The basis for cost basis and return calculations.
@DataClassName('TransactionRow')
class Transactions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get accountId => integer().references(Accounts, #id)();
  IntColumn get holdingId => integer().nullable().references(Holdings, #id)();
  IntColumn get cashSourceId => integer().nullable().references(Holdings, #id)();
  IntColumn get cashTargetId => integer().nullable().references(Holdings, #id)();
  TextColumn get type => text()();
  RealColumn get quantity => real().nullable()();
  RealColumn get price => real().nullable()();
  RealColumn get amount => real()();
  TextColumn get currency => text().withDefault(const Constant('CNY'))();
  DateTimeColumn get occurredAt => dateTime()();
  TextColumn get note => text().nullable()();

  /// Whether the cash side of this transfer moved its invested amount
  /// (costPrice) together with the balance. Legacy transfers recorded
  /// before the fix have this false, so removal must not roll the cost back.
  BoolColumn get costMoved => boolean().withDefault(const Constant(true))();

  /// The invested amount this flow actually moved on the cash side,
  /// recorded at write time so the history replay can undo exactly that
  /// number instead of guessing.
  ///
  /// The write side moves a *proportional* share of the principal
  /// ([movedCostOf]): a transfer drains `costPrice x amount / balance`, not
  /// the raw amount, so the account keeps its gain rate. The replay used to
  /// subtract the raw amount, which only agrees when the principal equals
  /// the balance or the account is fully drained; otherwise the replayed
  /// pre-flow principal came out off by the account's unrealized gain and
  /// every day before the flow shifted with it.
  ///
  /// Null on rows written before this column existed (and on rows that
  /// never moved a cost); the replay then keeps the legacy behaviour.
  RealColumn get costMovedAmount => real().nullable()();

  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  List<Set<Column>> get uniqueKeys => [
        {accountId, holdingId, type, occurredAt, amount},
      ];
}

/// Latest market price cache written by the market data engine.
@DataClassName('PriceCacheRow')
class PriceCache extends Table {
  TextColumn get symbol => text()();
  TextColumn get source => text()();
  TextColumn get name => text().withDefault(const Constant(''))();
  RealColumn get price => real()();
  TextColumn get currency => text().withDefault(const Constant('CNY'))();
  RealColumn get prevClose => real().nullable()();
  RealColumn get change => real().nullable()();
  RealColumn get changePct => real().nullable()();
  DateTimeColumn get fetchedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {symbol};
}

/// Daily net worth snapshot, one row per day per currency.
@DataClassName('SnapshotRow')
class Snapshots extends Table {
  TextColumn get date => text()();
  TextColumn get currency => text().withDefault(const Constant('CNY'))();
  RealColumn get totalValue => real()();
  RealColumn get totalCost => real()();

  /// Outstanding liabilities on that day, so the earning view can exclude
  /// principal repayments/borrowing from the return (cash-flow, not gain).
  RealColumn get liabilities => real().withDefault(const Constant(0))();

  /// Last time this day's value was (re)derived.
  ///
  /// Doubles as the cross-device last-write-wins version for snapshots
  /// (`SyncFormatter.snapshotToRow` maps it to `updatedAt`), so it must be
  /// written explicitly on every recompute: a snapshot is derived data and
  /// is rewritten whenever the underlying prices or holdings change, and
  /// that correction has to be able to win the merge. Leaving the column
  /// default in place froze the version at the day's first write.
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {date, currency};
}

/// Rule engine alert rules.
@DataClassName('AlertRuleRow')
class AlertRules extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get type => text()();
  TextColumn get name => text()();
  TextColumn get params => text().withDefault(const Constant('{}'))();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

/// Deleted-row markers for multi-device sync (last-write-wins merge): a
/// tombstone wins over any live row with the same key, so deletions made
/// on one device never resurrect on another device.
@DataClassName('SyncTombstoneRow')
class SyncTombstones extends Table {
  /// Table name this tombstone belongs to (e.g. 'holdings').
  TextColumn get table => text()();

  /// Row key as a string: the integer row id for id-keyed tables, or the
  /// composite key (e.g. 'date|currency') for keyed tables.
  TextColumn get rowKey => text()();

  DateTimeColumn get deletedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {table, rowKey};
}

/// Fired alert events, used for dedup and history.
@DataClassName('AlertEventRow')
class AlertEvents extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get ruleId => integer().references(AlertRules, #id)();
  TextColumn get title => text()();
  TextColumn get message => text()();
  DateTimeColumn get triggeredAt => dateTime().withDefault(currentDateAndTime)();
}

/// Simple key-value store for app-level state (e.g. data migration markers).
@DataClassName('SettingRow')
class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {key};
}
