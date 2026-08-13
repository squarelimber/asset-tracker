import 'dart:math';

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

  /// Privacy mask for hidden monetary amounts.
  static String masked() => '¥•••••';

  /// Signed amount with explicit +/-, e.g. "+1,234.50".
  static String signedAmount(double v) => v >= 0 ? '+${_amount.format(v)}' : _amount.format(v);

  static String date(DateTime d) => _date.format(d);
  static String dateTime(DateTime d) => _dateTime.format(d);

  /// Format a numeric value to at most 4 decimals.
  static String smartNum(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return _num.format(v);
  }

  /// Currency symbol for common ISO codes, null when unknown.
  static String? _currencySymbol(String code) => switch (code.toUpperCase()) {
        'CNY' || 'RMB' => '¥',
        'USD' => '\$',
        'EUR' => '€',
        'HKD' => 'HK\$',
        'GBP' => '£',
        'JPY' => 'JP¥',
        'AUD' => 'A\$',
        'CAD' => 'C\$',
        'CHF' => 'CHF ',
        'SGD' => 'S\$',
        _ => null,
      };

  /// Money value with the right currency symbol:
  /// e.g. money(1234.5, 'USD') -> "$1,234.50"; unknown codes -> "XXX 1,234.50".
  static String money(double v, [String currency = 'CNY']) {
    final symbol = _currencySymbol(currency);
    return symbol == null ? '${currency.toUpperCase()} ${_amount.format(v)}' : '$symbol${_amount.format(v)}';
  }

  /// Holding duration in a human-friendly form, e.g. "2年3个月",
  /// "8个月", "15天". [from] must not be after [to].
  static String holdingDuration(DateTime from, [DateTime? to]) {
    final end = to ?? DateTime.now();
    var months = (end.year - from.year) * 12 + (end.month - from.month);
    var days = end.day - from.day;
    if (days < 0) {
      months -= 1;
      days += DateTime(end.year, end.month, 0).day;
    }
    if (months < 0) return '刚刚买入';
    final years = months ~/ 12;
    final restMonths = months % 12;
    if (years > 0) {
      return restMonths > 0 ? '$years年$restMonths个月' : '$years年';
    }
    if (restMonths > 0) return '$restMonths个月';
    if (days > 0) return '$days天';
    return '1天以内';
  }

  /// Annualized return from total return and holding period in days.
  /// Returns null when the period is unknown/zero or the input is invalid.
  static double? annualizedReturn(double totalReturnPct, int days) {
    if (days <= 0) return null;
    final years = days / 365.0;
    if (totalReturnPct <= -1) return null; // total loss has no annualized value
    return pow(1 + totalReturnPct, 1 / years) - 1;
  }
}

/// Cached today's date string (yyyy-MM-dd) for snapshot keys.
String todayKey([DateTime? now]) => Formats.date(now ?? DateTime.now());
