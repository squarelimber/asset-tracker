import 'dart:convert';

import 'formats.dart';

/// Dated unit prices explicitly recorded for a holding.
Map<String, double> decodeNavHistory(String? raw) {
  if (raw == null) return {};
  try {
    final map = jsonDecode(raw);
    if (map is! Map<String, dynamic>) return {};
    return {
      for (final entry in map.entries)
        if (_validDate(entry.key) &&
            entry.value is num &&
            (entry.value as num).isFinite &&
            (entry.value as num) > 0)
          entry.key: (entry.value as num).toDouble(),
    };
  } on FormatException {
    return {};
  }
}

bool _validDate(String key) {
  final date = DateTime.tryParse(key);
  return date != null && todayKey(date) == key;
}

String encodeNavHistory(Map<String, double> values) {
  final dates = values.keys.toList()..sort();
  return jsonEncode({for (final date in dates) date: values[date]});
}
