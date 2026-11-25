import '../core/enums.dart';
import '../data/database.dart';
import 'daily_earnings.dart';
import 'earnings_breakdown.dart';
import 'holding_category.dart';
import 'product_monthly_earnings.dart';

class CategoryEarningsReport {
  const CategoryEarningsReport({
    required this.from,
    required this.to,
    required this.categories,
    required this.totalProfit,
    this.totalRate,
    required this.days,
    this.issues = const [],
  });

  final String from;
  final String to;
  final List<CategoryEarning> categories;
  final double totalProfit;
  final double? totalRate;
  final int days;
  final List<EarningsAttributionIssue> issues;

  bool get isEmpty => days == 0;
  bool get verified => issues.isEmpty;
}

class CategoryEarning {
  const CategoryEarning({
    required this.category,
    required this.profit,
    this.rate,
    required this.products,
  });

  final AssetCategory category;
  final double profit;
  final double? rate;
  final List<CategoryProductEarning> products;
}

class CategoryProductEarning {
  const CategoryProductEarning({
    required this.name,
    required this.holdingIds,
    required this.profit,
    this.rate,
    required this.closed,
  });

  final String name;
  final List<int> holdingIds;
  final double profit;
  final double? rate;
  final bool closed;
}

/// Earnings earned on [from] through [to], inclusive, in recorded CNY.
/// Holdings use their current effective allocation category; historical
/// holdings that no longer exist fall back to their recorded asset type.
/// Principal flows, realized gains and internal carried gains follow the
/// same attribution as the product earnings view.
CategoryEarningsReport categoryEarningsOf(
  List<SnapshotRow> snapshots, {
  required List<HoldingRow> holdings,
  List<TransactionRow> transactions = const [],
  required String from,
  required String to,
}) {
  if (snapshotCalendarDate(from) == null ||
      snapshotCalendarDate(to) == null ||
      from.compareTo(to) > 0) {
    throw ArgumentError('收益区间须为有效日期，且开始日期不能晚于结束日期。');
  }
  final ordered =
      snapshots
          .where(
            (s) => s.currency == 'CNY' && snapshotCalendarDate(s.date) != null,
          )
          .toList()
        ..sort((a, b) => a.date.compareTo(b.date));
  final selected = ordered
      .where((s) => s.date.compareTo(from) >= 0 && s.date.compareTo(to) <= 0)
      .toList();
  final issues = <EarningsAttributionIssue>[];
  void report(EarningsAttributionIssue issue) {
    if (!issues.any(
      (existing) =>
          existing.date == issue.date &&
          existing.transactionId == issue.transactionId &&
          existing.message == issue.message,
    )) {
      issues.add(issue);
    }
  }

  // A gap wholly inside the selected period still has an exact total.
  // A gap crossing either boundary cannot be assigned to this period.
  for (var i = 1; i < ordered.length; i++) {
    final intervalFrom = nextSnapshotDate(ordered[i - 1].date)!;
    final intervalTo = ordered[i].date;
    if (intervalTo.compareTo(from) < 0 || intervalFrom.compareTo(to) > 0) {
      continue;
    }
    if (intervalFrom.compareTo(from) < 0 || intervalTo.compareTo(to) > 0) {
      report(
        EarningsAttributionIssue(
          date: intervalTo,
          message:
              '${ordered[i - 1].date} 至 $intervalTo 的快照断档跨越所选区间边界，暂不能拆分区间收益。',
          canRebuild: true,
        ),
      );
    }
  }

  var totalProfit = 0.0;
  SnapshotRow? opening;
  for (var i = 0; i < ordered.length; i++) {
    final current = ordered[i];
    if (current.date.compareTo(from) < 0 || current.date.compareTo(to) > 0) {
      continue;
    }
    final previous = i == 0 ? null : ordered[i - 1];
    opening ??= previous ?? current;
    if (previous != null &&
        nextSnapshotDate(previous.date)!.compareTo(from) >= 0) {
      totalProfit +=
          snapshotAssetProfit(current) - snapshotAssetProfit(previous);
    }
  }

  CategoryEarningsReport result(List<CategoryEarning> categories) =>
      CategoryEarningsReport(
        from: from,
        to: to,
        categories: categories,
        totalProfit: totalProfit,
        totalRate:
            issues.isEmpty && opening != null && snapshotAssets(opening) > 0
            ? totalProfit / snapshotAssets(opening)
            : null,
        days: selected.length,
        issues: List.unmodifiable(issues),
      );
  if (selected.isEmpty) return result(const []);

  final baseline = ordered.where((s) => s.date.compareTo(from) < 0).lastOrNull;
  final series = holdingSeriesFromSnapshots(
    [?baseline, ...selected],
    transactions: transactions,
    attributionRequiredFrom: from,
    onIssue: report,
  );
  if (issues.isNotEmpty) return result(const []);

  final byId = {for (final h in holdings) h.id: h};
  final groups = <AssetCategory, List<HoldingSeries>>{};
  for (final holding in series) {
    final current = byId[holding.holdingId];
    final category = current == null
        ? holding.type.category
        : effectiveCategoryOf(current);
    (groups[category] ??= []).add(holding);
  }
  final categories = <CategoryEarning>[];
  const calculator = ProductEarningsCalculator();
  for (final group in groups.entries) {
    final products = <CategoryProductEarning>[];
    var categoryProfit = 0.0;
    var categoryOpening = 0.0;
    for (final product in calculator.compute(group.value)) {
      final first = product.daily.indexWhere(
        (day) => day.date.compareTo(from) >= 0,
      );
      if (first < 0) continue;
      final openingValue = first == 0
          ? product.daily[first].value
          : product.daily[first - 1].value;
      var profit = 0.0;
      var observed = false;
      for (var i = first; i < product.daily.length; i++) {
        final current = product.daily[i];
        final previous = i == 0 ? null : product.daily[i - 1];
        final adjustment = product.dailyProfitAdjustments[current.date] ?? 0;
        observed =
            observed ||
            current.value != 0 ||
            current.cost != 0 ||
            (previous?.value ?? 0) != 0 ||
            (previous?.cost ?? 0) != 0 ||
            adjustment != 0;
        if (previous != null) {
          profit +=
              (current.value - current.cost) -
              (previous.value - previous.cost) +
              adjustment;
        }
      }
      if (!observed) continue;
      categoryProfit += profit;
      categoryOpening += openingValue;
      products.add(
        CategoryProductEarning(
          name: product.name,
          holdingIds: product.holdingIds,
          profit: profit,
          rate: openingValue > 0 ? profit / openingValue : null,
          closed: product.closed,
        ),
      );
    }
    if (products.isEmpty) continue;
    products.sort((a, b) {
      final order = b.profit.compareTo(a.profit);
      return order == 0 ? a.name.compareTo(b.name) : order;
    });
    categories.add(
      CategoryEarning(
        category: group.key,
        profit: categoryProfit,
        rate: categoryOpening > 0 ? categoryProfit / categoryOpening : null,
        products: List.unmodifiable(products),
      ),
    );
  }
  final attributed = categories.fold(
    0.0,
    (sum, category) => sum + category.profit,
  );
  if ((attributed - totalProfit).abs() > 0.000001) {
    report(
      EarningsAttributionIssue(
        date: selected.last.date,
        message: '分类明细合计与同期总收益不一致，请重建历史快照后重试。',
        canRebuild: true,
      ),
    );
    return result(const []);
  }
  categories.sort((a, b) {
    final order = b.profit.compareTo(a.profit);
    return order == 0 ? a.category.index.compareTo(b.category.index) : order;
  });
  return result(List.unmodifiable(categories));
}
