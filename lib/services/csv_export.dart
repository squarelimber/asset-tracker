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
  String holdings(List<HoldingRow> holdings, Map<int, String> accountName) {
    final buf = StringBuffer('\uFEFF');
    buf.writeln(
        '账户,名称,类型,代码,数量,成本单价,最新价,币种,买入日期,市值,成本,收益');
    for (final h in holdings) {
      final type = AssetType.fromStorage(h.assetType);
      final marketValue = type.isAmountBased
          ? h.quantity
          : h.quantity * h.latestPrice;
      final cost = type.isAmountBased
          ? (h.costPrice > 0 ? h.costPrice : h.quantity)
          : h.quantity * h.costPrice;
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
        _num(marketValue),
        _num(cost),
        _num(marketValue - cost),
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
}
