import 'package:intl/intl.dart';

/// Number / currency formatting helpers.
class Formats {
  Formats._();

  static final NumberFormat _amount = NumberFormat('#,##0.00');
  static final NumberFormat _amountCompact = NumberFormat.compactCurrency(
    symbol: '',
    decimalDigits: 1,
    locale: 'zh_CN',
  );
  static final NumberFormat _pct = NumberFormat('0.00%');
  static final NumberFormat _pct1 = NumberFormat('0.0%');
  static final NumberFormat _num = NumberFormat('#,##0.####');
  static final DateFormat _date = DateFormat('yyyy-MM-dd');
  static final DateFormat _dateTime = DateFormat('MM-dd HH:mm');

  static String amount(double v) => _amount.format(v);

  /// e.g. 1.2万 for large values on the dashboard.
  static String amountCompact(double v) => _amountCompact.format(v);

  static String pct(double v) => _pct.format(v);
  static String pct1(double v) => _pct1.format(v);

  static String num(double v) => _num.format(v);

  /// Signed amount with explicit +/-, e.g. "+1,234.50".
  static String signedAmount(double v) => v >= 0 ? '+${_amount.format(v)}' : _amount.format(v);

  static String date(DateTime d) => _date.format(d);
  static String dateTime(DateTime d) => _dateTime.format(d);

  /// Format a numeric value to at most 4 decimals.
  static String smartNum(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return _num.format(v);
  }
}

/// Cached today's date string (yyyy-MM-dd) for snapshot keys.
String todayKey([DateTime? now]) => Formats.date(now ?? DateTime.now());
