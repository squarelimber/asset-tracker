import 'dart:convert';

import 'package:cross_file/cross_file.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reproduces the cross_file Android bytes-path bug:
/// XFile.readAsString() maps UTF-8 bytes 1:1 (Latin-1) when the file was
/// constructed from data, garbling Chinese. Reading bytes + utf8.decode
/// is the safe cross-platform approach.
void main() {
  test('readAsString on data-backed XFile garbles Chinese (bug repro)', () async {
    final payload = '{"name":"支付宝","holdings":[{"name":"红利ETF"}]}';
    final file = XFile.fromData(utf8.encode(payload));

    final garbled = await file.readAsString();
    // The bytes are mapped 1:1 so the decoded string differs from the input.
    expect(garbled, isNot(equals(payload)));

    // Safe path: raw bytes + explicit UTF-8 decode.
    final bytes = await file.readAsBytes();
    expect(utf8.decode(bytes), payload);
  });

  test('utf8 decode of bytes keeps Chinese intact', () async {
    const chinese = '招商银行 · 朝朝宝 · 易方达消费行业';
    final bytes = utf8.encode(chinese);
    expect(utf8.decode(bytes), chinese);
  });
}
