import '../core/enums.dart';
import '../core/formats.dart';
import '../data/database.dart';

/// Generates CSV strings for holdings and transactions (Excel-friendly,
/// UTF-8 with BOM so Chinese opens correctly in Excel).
class CsvExport {
  const CsvExport();

  static String _esc(String v) {
    final s = v.replaceAll('"', '""');
    return '"$s"';
  }

  static String _num(double v) => v.toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '');

  /// Holdings CSV. [accountName] maps holding.accountId -> account name.
  /// Market value / cost / profit are converted to CNY via [cnyRates] (a
  /// missing rate falls back to the raw value), matching the in-app totals;
  /// the 币种 column keeps each holding's original currency and the per-unit
  /// figures (数量/单价/汇率) remain in that currency.
  String holdings(
    List<HoldingRow> holdings,
    Map<int, String> accountName, {
    Map<String, double> cnyRates = const {},
  }) {
    double rateOf(String currency) {
      final r = cnyRates[currency.toUpperCase()];
      return (r == null || r <= 0) ? 1 : r;
    }

    final buf = StringBuffer('\uFEFF');
    buf.writeln(
        '账户,名称,类型,代码,数量,成本单价,最新价,币种,买入日期,市值(CNY),成本(CNY),收益(CNY)');
    for (final h in holdings) {
      final type = AssetType.fromStorage(h.assetType);
      final rate = rateOf(h.currency);
      final marketValueCny = (type.isAmountBased
          ? h.quantity
          : h.quantity * h.latestPrice) * rate;
      final costCny = (type.isAmountBased
          ? (h.costPrice > 0 ? h.costPrice : h.quantity)
          : h.quantity * h.costPrice) * rate;
      buf.writeln([
        _esc(accountName[h.accountId] ?? ''),
        _esc(h.name),
        type.label,
        _esc(h.symbol ?? ''),
        _num(h.quantity),
        _num(h.costPrice),
        _num(h.latestPrice),
        h.currency,
        h.purchaseDate == null ? '' : Formats.date(h.purchaseDate!),
        _num(marketValueCny),
        _num(costCny),
        _num(marketValueCny - costCny),
      ].join(','));
    }
    return buf.toString();
  }

  /// Transactions CSV. [holdingName] maps holdingId -> holding name.
  String transactions(List<TransactionRow> txns, Map<int, String> holdingName) {
    final buf = StringBuffer('\uFEFF');
    buf.writeln('日期,类型,持仓,数量,单价,金额,币种,备注');
    for (final t in txns) {
      buf.writeln([
        Formats.date(t.occurredAt.toLocal()),
        TransactionType.fromStorage(t.type).label,
        _esc(t.holdingId == null ? '' : (holdingName[t.holdingId] ?? '')),
        t.quantity == null ? '' : _num(t.quantity!),
        t.price == null ? '' : _num(t.price!),
        _num(t.amount),
        t.currency,
        _esc(t.note ?? ''),
      ].join(','));
    }
    return buf.toString();
  }

  /// Detailed transactions CSV for the unified history page: adds account
  /// and counterparty (cash source / target / transfer partner) columns.
  String transactionsDetailed(
    List<TransactionRow> txns,
    Map<int, String> holdingName,
    Map<int, String> accountName,
  ) {
    final buf = StringBuffer('\uFEFF');
    buf.writeln('日期,类型,账户,持仓,数量,单价,金额,币种,对手方,备注');
    for (final t in txns) {
      final type = TransactionType.fromStorage(t.type);
      final counterparty = switch (type) {
        TransactionType.buy || TransactionType.expense =>
          t.cashSourceId == null ? '' : (holdingName[t.cashSourceId!] ?? ''),
        TransactionType.sell || TransactionType.dividend ||
        TransactionType.income =>
          t.cashTargetId == null ? '' : (holdingName[t.cashTargetId!] ?? ''),
        TransactionType.transferIn =>
          t.cashSourceId == null ? '' : (holdingName[t.cashSourceId!] ?? ''),
        TransactionType.transferOut =>
          t.cashTargetId == null ? '' : (holdingName[t.cashTargetId!] ?? ''),
        _ => '',
      };
      buf.writeln([
        Formats.date(t.occurredAt.toLocal()),
        type.label,
        _esc(accountName[t.accountId] ?? ''),
        _esc(t.holdingId == null ? '' : (holdingName[t.holdingId] ?? '')),
        t.quantity == null ? '' : _num(t.quantity!),
        t.price == null ? '' : _num(t.price!),
        _num(t.amount),
        t.currency,
        _esc(counterparty),
        _esc(t.note ?? ''),
      ].join(','));
    }
    return buf.toString();
  }
}
