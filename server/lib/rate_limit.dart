import 'package:shelf/shelf.dart';

/// Limit requests globally unless a trusted reverse proxy is explicitly configured.
/// The proxy must remove client-supplied X-Forwarded-For headers.
Middleware rateLimit({
  int limit = 300,
  Duration window = const Duration(minutes: 1),
  bool trustProxy = false,
}) {
  final hits = <String, List<int>>{};
  var lastSweepMs = DateTime.now().millisecondsSinceEpoch;
  return (inner) => (Request req) {
        final forwarded = trustProxy ? req.headers['x-forwarded-for'] : null;
        final key = forwarded != null && forwarded.isNotEmpty
            ? forwarded.split(',').first.trim()
            : 'global';
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (nowMs - lastSweepMs > window.inMilliseconds) {
          lastSweepMs = nowMs;
          hits.removeWhere((_, times) {
            times.removeWhere((t) => nowMs - t > window.inMilliseconds);
            return times.isEmpty;
          });
        }
        final times = hits.putIfAbsent(key, () => <int>[])
          ..removeWhere((t) => nowMs - t > window.inMilliseconds);
        if (times.length >= limit)
          return Response(429, body: 'too many requests');
        times.add(nowMs);
        return inner(req);
      };
}
