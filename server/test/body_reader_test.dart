import 'dart:async';
import 'dart:convert';

import 'package:asset_sync_server/body_reader.dart';
import 'package:test/test.dart';

void main() {
  test('stalled request times out and cancels its subscription', () async {
    var cancelled = false;
    final controller = StreamController<List<int>>(
      onCancel: () {
        cancelled = true;
      },
    );
    controller.add(utf8.encode('{'));
    await expectLater(
      readLimitedBody(controller.stream, 100,
          timeout: const Duration(milliseconds: 50)),
      throwsA(isA<SlowBody>()),
    );
    expect(cancelled, isTrue);
    await controller.close();
  });

  test('reads UTF-8 body and enforces byte limit', () async {
    expect(
        await readLimitedBody(Stream.value(utf8.encode('hello')), 5), 'hello');
    await expectLater(
      readLimitedBody(Stream.value(utf8.encode('hello')), 4),
      throwsA(isA<BodyTooLarge>()),
    );
  });
}
