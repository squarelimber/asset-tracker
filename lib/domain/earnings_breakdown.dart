import '../core/enums.dart';
import '../data/database.dart';
import 'daily_earnings.dart';
import 'holding_valuation.dart';
import 'product_monthly_earnings.dart';

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

class EarningsBreakdown {
  const EarningsBreakdown({
    required this.date,
    required this.rows,
    this.profit,
    this.baselineDate,
    this.verified = false,
  });
  final String date;
  final String? baselineDate;
  final double? profit;
  final List<HoldingDayEarning> rows;
  final bool verified;
  double get detailTotal => rows.fold(0.0, (sum, row) => sum + row.profit);
}

/// Explains exactly the snapshots used by the calendar, including gaps and
/// holdings that disappear. No price fetches or current-position fallbacks.
EarningsBreakdown earningsBreakdownOf(
  List<SnapshotRow> snapshots,
  String date,
) {
  final ordered =
      snapshots
          .where((s) => s.currency == 'CNY' && s.date.compareTo(date) <= 0)
          .toList()
        ..sort((a, b) => a.date.compareTo(b.date));
  if (ordered.isEmpty || ordered.last.date != date) {
    return EarningsBreakdown(date: date, rows: const []);
  }
  final current = ordered.last;
  final previous = ordered.length > 1 ? ordered[ordered.length - 2] : null;
  final expected = const DailyEarningsCalculator().compute(ordered).last.profit;
  final currentValues = snapshotHoldingValues(current);
  final previousValues = previous == null
      ? <DayHoldingValue>[]
      : snapshotHoldingValues(previous);
  if (currentValues == null || previousValues == null) {
    return EarningsBreakdown(
      date: date,
      baselineDate: previous?.date,
      profit: expected,
      rows: const [],
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
  final rows = <HoldingDayEarning>[];
  for (final id in {...before.keys, ...after.keys}) {
    final a = after[id];
    final b = before[id];
    final identity = a ?? b!;
    final profit = previous == null
        ? 0.0
        : ((a?.value ?? 0) - (a?.cost ?? 0)) -
              ((b?.value ?? 0) - (b?.cost ?? 0));
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
    verified: (total - expected).abs() < 0.000001,
  );
}

/// Monthly product views use the same recorded states, including a zero
/// value/cost after a position disappears. This preserves the sum identity.
List<ProductEarnings> productsFromSnapshots(List<SnapshotRow> snapshots) {
  final ordered = snapshots.where((s) => s.currency == 'CNY').toList()
    ..sort((a, b) => a.date.compareTo(b.date));
  final decoded = <String, List<DayHoldingValue>>{};
  final identities = <int, DayHoldingValue>{};
  for (final snapshot in ordered) {
    final values = snapshotHoldingValues(snapshot);
    if (values == null) throw StateError('历史快照尚无可核对的产品明细，请重建历史快照后重试');
    decoded[snapshot.date] = values;
    for (final value in values) {
      if (!value.liability) identities[value.holdingId] = value;
    }
  }
  return const ProductEarningsCalculator().compute([
    for (final entry in identities.entries)
      HoldingSeries(
        holdingId: entry.key,
        name: entry.value.name,
        type: entry.value.type,
        closed:
            ordered.isNotEmpty &&
            !(decoded[ordered.last.date] ?? []).any(
              (h) => h.holdingId == entry.key && h.value > 0,
            ),
        days: [
          for (final snapshot in ordered)
            _holdingDay(snapshot.date, entry.key, decoded[snapshot.date]!),
        ],
      ),
  ]);
}

HoldingDay _holdingDay(String date, int id, List<DayHoldingValue> values) {
  final value = values.where((v) => v.holdingId == id).firstOrNull;
  return HoldingDay(
    date: date,
    value: value?.value ?? 0,
    cost: value?.cost ?? 0,
  );
}
