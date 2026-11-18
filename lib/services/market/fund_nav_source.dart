import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/enums.dart';
import '../../core/formats.dart';
import 'history_source.dart';
import 'market_data_source.dart';

/// Fund-only NAV history from Eastmoney's mobile API, which also serves web.
class FundNavSource extends HistoryDataSource {
  FundNavSource(this._client) : super(MarketSource.eastmoney);

  final http.Client _client;

  /// Charts request at most one year. One page covers all daily observations
  /// within that window, including products publishing on non-trading days.
  @override
  Future<DailyPriceHistory> fetch(
    String symbol,
    DateTime from,
    DateTime to,
  ) async {
    final uri =
        Uri.https('fundmobapi.eastmoney.com', '/FundMNewApi/FundMNHisNetList', {
          'FCODE': symbol,
          'pageIndex': '1',
          'pageSize': '500',
          'deviceid': 'Wap',
          'plat': 'Wap',
          'product': 'EFund',
          'version': '2.0.0',
        });
    final response = await _client.get(uri).timeout(marketHttpTimeout);
    if (response.statusCode != 200) throw StateError('净值接口不可用');
    final json = jsonDecode(utf8.decode(response.bodyBytes));
    if (json is! Map || json['ErrCode'] != 0) throw StateError('净值加载失败');
    final rows = json['Datas'];
    if (rows is! List) return {};
    final start = todayKey(from);
    final end = todayKey(to);
    final result = <String, double>{};
    for (final row in rows.whereType<Map>()) {
      final date = row['FSRQ'];
      final parsed = date is String ? DateTime.tryParse(date) : null;
      final price = double.tryParse(row['DWJZ']?.toString() ?? '');
      if (date is String &&
          parsed != null &&
          todayKey(parsed) == date &&
          date.compareTo(start) >= 0 &&
          date.compareTo(end) <= 0 &&
          price != null &&
          price.isFinite &&
          price > 0) {
        result[date] = price;
      }
    }
    return result;
  }
}
