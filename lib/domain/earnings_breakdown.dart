import '../core/enums.dart';
import '../core/formats.dart';
import '../data/database.dart';
import 'daily_earnings.dart';
import 'holding_valuation.dart';
import 'product_monthly_earnings.dart';
import 'transaction_identity.dart';

class HoldingDayEarning {
  const HoldingDayEarning({
    required this.holdingId,
    required this.name,
    required this.type,
    required this.value,
    required this.profit,
  });
  final int holdingId;
  final String name;
  final AssetType type;
  final double value;
  final double profit;
}

class EarningsAttributionIssue {
  const EarningsAttributionIssue({
    required this.date,
    required this.message,
    this.canRebuild = false,
    this.transactionId,
  });

  final String date;
  final String message;
  final bool canRebuild;
  final int? transactionId;
}

class ProductEarningsReport {
  const ProductEarningsReport(this.products, {this.issues = const []});

  final List<ProductEarnings> products;
  final List<EarningsAttributionIssue> issues;
}

class EarningsBreakdown {
  const EarningsBreakdown({
    required this.date,
    required this.rows,
    this.profit,
    this.baselineDate,
    this.verified = false,
    this.issue,
    this.attributionIssue,
  });
  final String date;
  final String? baselineDate;
  final double? profit;
  final List<HoldingDayEarning> rows;
  final bool verified;
  final String? issue;
  final EarningsAttributionIssue? attributionIssue;
  bool get spansMultipleDays =>
      baselineDate != null && nextSnapshotDate(baselineDate!) != date;

  double get detailTotal => rows.fold(0.0, (sum, row) => sum + row.profit);
}

/// Explains exactly the snapshots used by the calendar, including gaps and
/// holdings that disappear. No price fetches or current-position fallbacks.
EarningsBreakdown earningsBreakdownOf(
  List<SnapshotRow> snapshots,
  String date, {
  List<TransactionRow> transactions = const [],
}) {
  final ordered =
      snapshots
          .where(
            (s) =>
                s.currency == 'CNY' &&
                s.date.compareTo(date) <= 0 &&
                snapshotCalendarDate(s.date) != null,
          )
          .toList()
        ..sort((a, b) => a.date.compareTo(b.date));
  if (ordered.isEmpty || ordered.last.date != date) {
    return EarningsBreakdown(date: date, rows: const []);
  }
  final current = ordered.last;
  final previous = ordered.length > 1 ? ordered[ordered.length - 2] : null;
  final expected = previous == null
      ? 0.0
      : snapshotAssetProfit(current) - snapshotAssetProfit(previous);
  final currentValues = snapshotHoldingValues(current);
  final previousValues = previous == null
      ? <DayHoldingValue>[]
      : snapshotHoldingValues(previous);
  if (currentValues == null || previousValues == null) {
    final missing = _snapshotIssue(
      date, currentValues == null ? current.date : previous!.date,
    );
    return EarningsBreakdown(
      date: date,
      baselineDate: previous?.date,
      profit: expected,
      rows: const [],
      issue: missing.message,
      attributionIssue: missing,
    );
  }
  final before = {
    for (final h in previousValues)
      if (!h.liability) h.holdingId: h,
  };
  final after = {
    for (final h in currentValues)
      if (!h.liability) h.holdingId: h,
  };
  final ids = _observedHoldings(before, after);
  final adjustments = previous == null
      ? const <int, double>{}
      : internalTransferProfitAdjustments(
          transactions,
          previous.date,
          current.date,
          ids,
          snapshotCreatedAt: current.createdAt,
        );
  final issue = previous == null
      ? null
      : _incompleteAttribution(
          transactions,
          previous.date,
          current.date,
          current.createdAt,
          ids,
          _knownLiabilities(previousValues, currentValues),
        );
  final rows = <HoldingDayEarning>[];
  for (final id in {...before.keys, ...after.keys}) {
    final a = after[id];
    final b = before[id];
    // Cached snapshots can keep a closed holding with zero value and cost.
    // Keep the closing day's change, then stop listing the empty position.
    if ((a?.value ?? 0) == 0 &&
        (a?.cost ?? 0) == 0 &&
        (b?.value ?? 0) == 0 &&
        (b?.cost ?? 0) == 0 &&
        (a?.realizedProfit ?? 0) == (b?.realizedProfit ?? 0)) {
      continue;
    }
    final identity = a ?? b!;
    final profit = previous == null
        ? 0.0
        : ((a?.value ?? 0) - (a?.cost ?? 0)) -
              ((b?.value ?? 0) - (b?.cost ?? 0)) +
              (a?.realizedProfit ?? 0) - (b?.realizedProfit ?? 0) +
              (adjustments[id] ?? 0);
    rows.add(
      HoldingDayEarning(
        holdingId: id,
        name: identity.name,
        type: identity.type,
        value: a?.value ?? 0,
        profit: profit,
      ),
    );
  }
  rows.sort((a, b) => b.profit.compareTo(a.profit));
  final total = rows.fold(0.0, (sum, row) => sum + row.profit);
  return EarningsBreakdown(
    date: date,
    baselineDate: previous?.date,
    profit: expected,
    rows: rows,
    verified: issue == null && (total - expected).abs() < 0.000001,
    issue: issue?.message,
    attributionIssue: issue,
  );
}

/// Moves accumulated P/L along with internal funding, while attributing it
/// to the product where it arose rather than the destination of the money.
/// Each complete adjustment is zero-sum and refers to the interval between
/// two actual snapshots, which may span multiple calendar days.
///
/// Historical moved cost is essential; do not estimate missing values or
/// convert foreign-currency transactions without a historical exchange rate.
Map<int, double> internalTransferProfitAdjustments(
  List<TransactionRow> transactions,
  String previousDate,
  String currentDate,
  Set<int> availableHoldingIds, {
  DateTime? snapshotCreatedAt,
}) {
  final result = <int, double>{};
  void move(int? from, int? to, double? amount, double? movedCost) {
    if (from == null ||
        to == null ||
        from == to ||
        !availableHoldingIds.contains(from) ||
        !availableHoldingIds.contains(to) ||
        amount == null ||
        !amount.isFinite ||
        movedCost == null ||
        !movedCost.isFinite) {
      return;
    }
    final adjustment = amount - movedCost;
    result[from] = (result[from] ?? 0) + adjustment;
    result[to] = (result[to] ?? 0) - adjustment;
  }

  final internalBuys = <TransactionRow>[];
  final internalSells = <TransactionRow>[];
  for (final t in transactions) {
    final day = todayKey(t.occurredAt.toLocal());
    if (day.compareTo(previousDate) <= 0 ||
        day.compareTo(currentDate) > 0 ||
        t.currency.toUpperCase() != 'CNY' ||
        (snapshotCreatedAt != null && t.historyUpdatedAt.isAfter(snapshotCreatedAt))) {
      continue;
    }
    final type = TransactionType.fromStorage(t.type);
    switch (type) {
      case TransactionType.buy:
        if (t.cashSourceId != null) {
          move(t.cashSourceId, t.holdingId, t.amount, t.costMovedAmount);
        } else if (t.internalMove) {
          internalBuys.add(t);
        }
      case TransactionType.sell:
        if (t.cashTargetId != null) {
          move(t.holdingId, t.cashTargetId, t.amount, t.costMovedAmount);
        } else if (t.internalMove) {
          internalSells.add(t);
        }
      case TransactionType.transferIn || TransactionType.transferOut:
        move(t.cashSourceId, t.cashTargetId, t.amount, t.costMovedAmount);
      default:
        break;
    }
  }

  // Redemption-funded purchases have two rows rather than cross-references.
  // Pair only unambiguous records with the same timestamp, amount and moved
  // cost; guessing among duplicate legacy rows could attribute gains wrongly.
  bool matches(TransactionRow buy, TransactionRow sell) =>
      buy.costMovedAmount != null &&
      buy.costMovedAmount == sell.costMovedAmount &&
      hasSameRedemption(buy, sell);

  for (final buy in internalBuys) {
    final matchingSells = internalSells.where((sell) => matches(buy, sell));
    if (matchingSells.length != 1) continue;
    final sell = matchingSells.single;
    if (internalBuys.where((candidate) => matches(candidate, sell)).length !=
        1) {
      continue;
    }
    move(sell.holdingId, buy.holdingId, buy.amount, buy.costMovedAmount);
  }
  return result;
}

Set<int> _observedHoldings(
  Map<int, DayHoldingValue> before,
  Map<int, DayHoldingValue> after,
) => {
  for (final id in {...before.keys, ...after.keys})
    if ((before[id]?.value ?? 0) != 0 ||
        (before[id]?.cost ?? 0) != 0 ||
        (after[id]?.value ?? 0) != 0 ||
        (after[id]?.cost ?? 0) != 0)
      id,
};

Set<int> _knownLiabilities(
  List<DayHoldingValue> before,
  List<DayHoldingValue> after,
) {
  final liabilities = <int>{};
  final assets = <int>{};
  for (final valuation in [...before, ...after]) {
    (valuation.liability ? liabilities : assets).add(valuation.holdingId);
  }
  return liabilities.difference(assets);
}

EarningsAttributionIssue _snapshotIssue(String affected, String missing) =>
    EarningsAttributionIssue(
      date: affected,
      message: '$missing 的快照缺少可核对的产品明细。请重建历史快照后重试。',
      canRebuild: true,
    );

EarningsAttributionIssue? _incompleteAttribution(
  List<TransactionRow> transactions,
  String previousDate,
  String currentDate,
  DateTime snapshotCreatedAt,
  Set<int> ids,
  Set<int> liabilities,
) {
  final interval = transactions.where((t) {
    final day = todayKey(t.occurredAt.toLocal());
    return day.compareTo(previousDate) > 0 && day.compareTo(currentDate) <= 0;
  }).toList();

  for (final t in interval) {
    EarningsAttributionIssue issue(String reason, {bool canRebuild = false}) =>
        EarningsAttributionIssue(
          date: currentDate,
          message: '${todayKey(t.occurredAt.toLocal())} 的${TransactionType.fromStorage(t.type).label}流水$reason',
          transactionId: t.id,
          canRebuild: canRebuild,
        );
    final type = TransactionType.fromStorage(t.type);
    final isBuy = type == TransactionType.buy;
    final isSell = type == TransactionType.sell;
    final isTransfer =
        type == TransactionType.transferIn ||
        type == TransactionType.transferOut;
    final pairedLeg =
        t.internalMove &&
        ((isBuy && t.cashSourceId == null) ||
            (isSell && t.cashTargetId == null));
    final direct =
        (isBuy && t.cashSourceId != null) ||
        (isSell && t.cashTargetId != null) ||
        isTransfer;
    if (!pairedLeg && !direct) continue;
    if (!ids.contains(t.holdingId) &&
        !ids.contains(t.cashSourceId) &&
        !ids.contains(t.cashTargetId)) {
      continue;
    }
    if (t.historyUpdatedAt.isAfter(snapshotCreatedAt)) {
      return issue('晚于收益快照更新，请重建历史快照。', canRebuild: true);
    }
    // Debt is not a product in the asset-side return. A known cash/debt
    // transfer has no second product that should receive an adjustment.
    if (isTransfer &&
        ((ids.contains(t.cashSourceId) &&
                liabilities.contains(t.cashTargetId)) ||
            (liabilities.contains(t.cashSourceId) &&
                ids.contains(t.cashTargetId)))) {
      continue;
    }
    // With precisely equal amount and recorded transferred principal there
    // is no carried gain to reattribute, even across currencies or when the
    // counterpart is unavailable. A later changed transaction still makes
    // the snapshot stale and must be checked above.
    if (t.amount.isFinite &&
        t.costMovedAmount != null &&
        t.costMovedAmount!.isFinite &&
        t.amount == t.costMovedAmount) {
      continue;
    }
    if (!t.amount.isFinite ||
        t.costMovedAmount == null ||
        !t.costMovedAmount!.isFinite) {
      return issue('缺少有效的转移本金，重建快照无法补齐原流水字段。');
    }
    if (t.currency.toUpperCase() != 'CNY') {
      return issue('缺少 ${t.currency.toUpperCase()} 的历史折算汇率，无法拆分产品收益。');
    }

    if (pairedLeg) {
      final opposite = interval
          .where(
            (other) =>
                other.internalMove &&
                (isBuy
                    ? other.type == 'sell' && other.cashTargetId == null
                    : other.type == 'buy' && other.cashSourceId == null) &&
                hasSameRedemption(t, other),
          )
          .toList();
      if (opposite.length != 1) return issue('无法唯一匹配对应的赎回或买入记录。');
      if (opposite.single.historyUpdatedAt.isAfter(snapshotCreatedAt)) {
        return issue('的配对记录晚于收益快照更新，请重建历史快照。', canRebuild: true);
      }
      if (!ids.contains(t.holdingId) ||
          !ids.contains(opposite.single.holdingId) ||
          t.holdingId == opposite.single.holdingId) {
        return issue('的买入或赎回产品缺少可核对的持仓快照。');
      }
      final sameSide = interval.where(
        (other) =>
            other.internalMove &&
            other.type == t.type &&
            (isBuy ? other.cashSourceId == null : other.cashTargetId == null) &&
            hasSameRedemption(other, opposite.single),
      );
      if (sameSide.length != 1) return issue('无法唯一匹配对应的赎回或买入记录。');
    } else {
      final from = isBuy
          ? t.cashSourceId
          : isSell
          ? t.holdingId
          : t.cashSourceId;
      final to = isBuy
          ? t.holdingId
          : isSell
          ? t.cashTargetId
          : t.cashTargetId;
      if (from == null ||
          to == null ||
          from == to ||
          !ids.contains(from) ||
          !ids.contains(to)) {
        return issue('缺少可核对的资金来源、去向或对应持仓快照。');
      }
    }
  }
  return null;
}

/// Monthly product views use the same recorded states, including a zero
/// value/cost after a position disappears. This preserves the sum identity.
List<ProductEarnings> productsFromSnapshots(
  List<SnapshotRow> snapshots, {
  List<TransactionRow> transactions = const [],
  String? attributionRequiredFrom,
  void Function(EarningsAttributionIssue)? onIssue,
}) {
  final ordered = snapshots.where((s) => s.currency == 'CNY').toList()
    ..sort((a, b) => a.date.compareTo(b.date));
  final decoded = <String, List<DayHoldingValue>>{};
  final identities = <int, DayHoldingValue>{};
  bool inWindow(String day) =>
      attributionRequiredFrom == null || day.compareTo(attributionRequiredFrom) >= 0;
  void report(EarningsAttributionIssue issue) {
    if (onIssue == null) throw StateError(issue.message);
    if (inWindow(issue.date)) onIssue(issue);
  }
  for (final snapshot in ordered) {
    final values = snapshotHoldingValues(snapshot);
    if (values == null) {
      report(_snapshotIssue(snapshot.date, snapshot.date));
      continue;
    }
    decoded[snapshot.date] = values;
    for (final value in values) {
      if (!value.liability) identities[value.holdingId] = value;
    }
  }
  final adjustmentsByDate = <String, Map<int, double>>{};
  for (var i = 1; i < ordered.length; i++) {
    final previous = ordered[i - 1];
    final current = ordered[i];
    final previousValues = decoded[previous.date];
    final currentValues = decoded[current.date];
    if (currentValues == null) continue;
    if (previousValues == null) {
      report(_snapshotIssue(current.date, previous.date));
      continue;
    }
    final before = {
      for (final h in previousValues)
        if (!h.liability) h.holdingId: h,
    };
    final after = {
      for (final h in currentValues)
        if (!h.liability) h.holdingId: h,
    };
    final ids = _observedHoldings(before, after);
    final issue = _incompleteAttribution(
      transactions,
      previous.date,
      current.date,
      current.createdAt,
      ids,
      _knownLiabilities(previousValues, currentValues),
    );
    if (issue != null) {
      if (inWindow(current.date)) report(issue);
      continue;
    }
    adjustmentsByDate[current.date] = internalTransferProfitAdjustments(
      transactions,
      previous.date,
      current.date,
      ids,
      snapshotCreatedAt: current.createdAt,
    );
  }
  // A realized gain is cumulative in a snapshot. Add only its interval
  // change while keeping the visible product value and cost unchanged.
  final realizedByHolding = <int, double>{};
  for (final entry in decoded.entries) {
    final adjustments = adjustmentsByDate.putIfAbsent(entry.key, () => {});
    final current = {
      for (final value in entry.value)
        if (!value.liability) value.holdingId: value.realizedProfit,
    };
    if (entry.key != decoded.keys.first) {
      for (final id in {...realizedByHolding.keys, ...current.keys}) {
        final delta = (current[id] ?? 0) - (realizedByHolding[id] ?? 0);
        if (delta != 0) adjustments.update(id, (value) => value + delta, ifAbsent: () => delta);
      }
    }
    realizedByHolding
      ..clear()
      ..addAll(current);
  }
  final latestValues = ordered.isEmpty ? null : decoded[ordered.last.date];
  return const ProductEarningsCalculator().compute([
    for (final entry in identities.entries)
      HoldingSeries(
        holdingId: entry.key,
        name: entry.value.name,
        type: entry.value.type,
        closed:
            latestValues != null &&
            !latestValues.any(
              (h) =>
                  !h.liability &&
                  h.holdingId == entry.key &&
                  (h.value != 0 || h.cost != 0),
            ),
        days: [
          for (final snapshot in decoded.entries)
            _holdingDay(
              snapshot.key,
              entry.key,
              snapshot.value,
              adjustmentsByDate[snapshot.key]?[entry.key] ?? 0,
            ),
        ],
      ),
  ]);
}

HoldingDay _holdingDay(
  String date,
  int id,
  List<DayHoldingValue> values,
  double adjustment,
) {
  final value = values
      .where((v) => v.holdingId == id && !v.liability)
      .firstOrNull;
  return HoldingDay(
    date: date,
    value: value?.value ?? 0,
    cost: value?.cost ?? 0,
    profitAdjustment: adjustment,
  );
}
