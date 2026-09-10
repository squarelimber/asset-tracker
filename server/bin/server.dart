import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/open.dart' show OperatingSystem, open;

import 'package:asset_sync_server/sync_store.dart';

/// AssetTracker sync server.
///
/// Protocol (single-user, last-write-wins, whole-snapshot exchange):
///   GET /api/sync        -> {rev, snapshot, tombstones}
///   PUT /api/sync        -> body {snapshot, tombstones, baseRev?};
///                           returns {rev}, or 409 {rev} when baseRev
///                           does not match the current revision.
///
/// Authentication: `Authorization: Bearer <token>` against the
/// ASSET_SYNC_TOKEN environment variable. The server binds to 127.0.0.1 by
/// default (override with HOST); binding to a non-loopback address without
/// a token is refused for direct runs (containers are exempt, where
/// 0.0.0.0 is the normal bind address).
Future<void> main(List<String> args) async {
  // Debian's libsqlite3-0 runtime package ships only the versioned
  // libsqlite3.so.0; the sqlite3 package's default 'libsqlite3.so' lookup
  // fails in a container, so load the versioned library explicitly.
  open.overrideFor(
    OperatingSystem.linux,
    () => DynamicLibrary.open('libsqlite3.so.0'),
  );

  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8787;
  final hostEnv = Platform.environment['HOST'] ?? '127.0.0.1';
  final dbPath =
      Platform.environment['SYNC_DB_PATH'] ?? 'sync_state.sqlite';
  final token = Platform.environment['ASSET_SYNC_TOKEN'];

  // 'localhost' is not a numeric address; InternetAddress would fail to
  // bind. Map it to the loopback literal (the bind host and the loopback
  // check below agree either way).
  final host = hostEnv == 'localhost' ? '127.0.0.1' : hostEnv;
  final loopback = host == '127.0.0.1' || host == '::1';
  // Binding to all interfaces is the normal mode inside a container (the
  // container boundary plus explicit port publishing is the security model),
  // so the token requirement only applies to direct runs on a host.
  final inContainer = File('/.dockerenv').existsSync();
  if (!loopback && (token == null || token.isEmpty) && !inContainer) {
    stderr.writeln(
      'refusing to bind $host without a token; '
      'set ASSET_SYNC_TOKEN or use HOST=127.0.0.1',
    );
    exit(1);
  }
  if (token == null || token.isEmpty) {
    stderr.writeln(
      'WARNING: running WITHOUT a bearer token — anyone who can reach '
      'http://$host:$port can read and overwrite the whole snapshot. '
      'Set ASSET_SYNC_TOKEN to enable authentication.',
    );
  }

  final store = SyncStore(dbPath);
  final router = Router()
    ..get('/api/sync', (Request req) => _handleGet(store, req))
    ..put('/api/sync', (Request req) => _handlePut(store, req))
    ..get('/health', (Request req) => Response.ok('ok'));

  final handler = const Pipeline()
      .addMiddleware(_rateLimit())
      .addMiddleware(_cors())
      .addMiddleware(_auth(token))
      .addHandler(router.call);

  await shelf_io.serve(handler, InternetAddress(host), port);
  stdout.writeln('asset-sync-server listening on http://$host:$port (db: $dbPath)');
  void shutdown() {
    store.close();
    exit(0);
  }
  // docker stop sends SIGTERM (SIGINT only fires on interactive Ctrl+C).
  ProcessSignal.sigint.watch().listen((_) => shutdown());
  ProcessSignal.sigterm.watch().listen((_) => shutdown());
}

Response _handleGet(SyncStore store, Request req) {
  final state = store.read();
  if (state == null) {
    return _json({'rev': 0, 'snapshot': <String, dynamic>{}, 'tombstones': []});
  }
  return _json({'rev': state.rev, 'snapshot': state.snapshot, 'tombstones': state.tombstones});
}

const _maxBodyBytes = 32 * 1024 * 1024;

/// Raised when the request body exceeds [_maxBodyBytes].
class _BodyTooLarge implements Exception {
  const _BodyTooLarge();
}

/// Raised when the body takes too long to arrive (slowloris).
class _SlowBody implements Exception {
  const _SlowBody();
}

Future<Response> _handlePut(SyncStore store, Request req) async {
  final String raw;
  try {
    raw = await _readLimited(req, _maxBodyBytes);
  } on _BodyTooLarge {
    return Response(413, body: 'request body too large');
  } on FormatException {
    return Response.badRequest(body: 'body is not valid UTF-8');
  }
  final Object? body;
  try {
    body = jsonDecode(raw);
  } on FormatException {
    return Response.badRequest(body: 'body is not valid JSON');
  }
  if (body is! Map<String, dynamic>) {
    return Response.badRequest(body: 'expected JSON object');
  }
  final snapshot = body['snapshot'];
  final tombstones = body['tombstones'] ?? const [];
  if (snapshot is! Map<String, dynamic> || tombstones is! List) {
    return Response.badRequest(body: 'snapshot must be an object, tombstones a list');
  }
  if (body['baseRev'] != null && body['baseRev'] is! num) {
    return Response.badRequest(body: 'baseRev must be a number');
  }
  final baseRev = (body['baseRev'] as num?)?.toInt();
  final result = store.write(snapshot, tombstones, baseRev: baseRev);
  if (result.conflict) {
    return Response(
      409,
      body: jsonEncode({'rev': result.rev}),
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
  }
  return _json({'rev': result.rev});
}

/// Reads the request body, throwing [_BodyTooLarge] once [maxBytes] is
/// exceeded and [_SlowBody] when the body takes longer than a minute to
/// arrive, so clients cannot fill the disk or hold a connection open.
Future<String> _readLimited(Request req, int maxBytes) async {
  var size = 0;
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  final buffer = BytesBuilder(copy: false);
  await for (final chunk in req.read()) {
    if (DateTime.now().isAfter(deadline)) {
      throw const _SlowBody();
    }
    size += chunk.length;
    if (size > maxBytes) throw const _BodyTooLarge();
    buffer.add(chunk);
  }
  return utf8.decode(buffer.takeBytes());
}

/// Naive sliding-window rate limit (single-user personal server).
///
/// shelf's [Request] does not expose the peer address, so the client is
/// identified by the first `X-Forwarded-For` hop when present and otherwise
/// by a single global bucket (fine for one user, and still caps a runaway
/// client or a misbehaving proxy).
Middleware _rateLimit({
  int limit = 300,
  Duration window = const Duration(minutes: 1),
}) {
  final hits = <String, List<int>>{};
  var lastSweepMs = DateTime.now().millisecondsSinceEpoch;
  return (inner) {
    return (Request req) {
      final forwarded = req.headers['x-forwarded-for'];
      final key =
          (forwarded != null && forwarded.isNotEmpty)
              ? forwarded.split(',').first.trim()
              : 'global';
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      // Periodic sweep: remove keys whose window emptied out, so rotating
      // or spoofed X-Forwarded-For values cannot grow the map unboundedly.
      if (nowMs - lastSweepMs > window.inMilliseconds) {
        lastSweepMs = nowMs;
        hits.removeWhere((_, times) {
          times.removeWhere((t) => nowMs - t > window.inMilliseconds);
          return times.isEmpty;
        });
      }
      final times = hits.putIfAbsent(key, () => <int>[])
        ..removeWhere((t) => nowMs - t > window.inMilliseconds);
      if (times.length >= limit) {
        return Response(429, body: 'too many requests');
      }
      times.add(nowMs);
      return inner(req);
    };
  };
}

Middleware _auth(String? token) {
  if (token == null || token.isEmpty) return (inner) => inner;
  final expected = 'Bearer $token';
  return (inner) {
    return (Request req) {
      final auth = req.headers['authorization'];
      if (auth == null ||
          auth.length != expected.length ||
          !_constantTimeEquals(auth, expected)) {
        return Response.unauthorized('unauthorized');
      }
      return inner(req);
    };
  };
}

/// Byte-wise comparison without short-circuiting on the first difference,
/// so the token cannot be probed byte by byte through response timing.
bool _constantTimeEquals(String a, String b) {
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

Middleware _cors() {
  return (inner) {
    return (Request req) async {
      if (req.method == 'OPTIONS') {
        return Response.ok('', headers: _corsHeaders);
      }
      final response = await inner(req);
      return response.change(headers: _corsHeaders);
    };
  };
}

const _corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, PUT, OPTIONS',
  'Access-Control-Allow-Headers': 'Authorization, Content-Type',
};

Response _json(Object body) => Response.ok(
      jsonEncode(body),
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
