import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

class BodyTooLarge implements Exception {
  const BodyTooLarge();
}

class SlowBody implements Exception {
  const SlowBody();
}

/// Reads UTF-8 data with a size limit and a deadline for the whole stream.
Future<String> readLimitedBody(Stream<List<int>> stream, int maxBytes,
    {Duration timeout = const Duration(seconds: 60)}) async {
  var size = 0;
  final stopwatch = Stopwatch()..start();
  final buffer = BytesBuilder(copy: false);
  final chunks = StreamIterator<List<int>>(stream);
  try {
    while (true) {
      final remaining = timeout - stopwatch.elapsed;
      if (remaining <= Duration.zero) throw const SlowBody();
      final bool hasNext;
      try {
        hasNext = await chunks.moveNext().timeout(remaining);
      } on TimeoutException {
        throw const SlowBody();
      }
      if (!hasNext) break;
      final chunk = chunks.current;
      size += chunk.length;
      if (size > maxBytes) throw const BodyTooLarge();
      buffer.add(chunk);
    }
  } finally {
    await chunks.cancel();
  }
  return utf8.decode(buffer.takeBytes());
}
