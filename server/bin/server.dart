import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/open.dart' show OperatingSystem, open;

import 'package:asset_sync_server/sync_store.dart';

/// AssetTracker sync server.
///
/// Protocol (single-user, last-write-wins, whole-snapshot exchange):
///   GET /api/sync        -> {rev, snapshot, tombstones}
///   PUT /api/sync        -> body {snapshot, tombstones}; returns {rev}
///
/// Authentication: `Authorization: Bearer <token>` against the
/// ASSET_SYNC_TOKEN environment variable. When the variable is not set,
/// authentication is skipped (personal deployments on a trusted LAN).
Future<void> main(List<String> args) async {
  // Debian's libsqlite3-0 runtime package ships only the versioned
  // libsqlite3.so.0; the sqlite3 package's default 'libsqlite3.so' lookup
  // fails in a container, so load the versioned library explicitly.
  open.overrideFor(
    OperatingSystem.linux,
    () => DynamicLibrary.open('libsqlite3.so.0'),
  );

  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8787;
  final dbPath =
      Platform.environment['SYNC_DB_PATH'] ?? 'sync_state.sqlite';
  final token = Platform.environment['ASSET_SYNC_TOKEN'];

  final store = SyncStore(dbPath);
  final router = Router()
    ..get('/api/sync', (Request req) => _handleGet(store, req))
    ..put('/api/sync', (Request req) => _handlePut(store, req))
    ..get('/health', (Request req) => Response.ok('ok'));

  final handler = const Pipeline()
      .addMiddleware(_cors())
      .addMiddleware(_auth(token))
      .addHandler(router.call);

  await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
  stdout.writeln('asset-sync-server listening on http://0.0.0.0:$port (db: $dbPath)');
  ProcessSignal.sigint.watch().listen((_) {
    store.close();
    exit(0);
  });
}

Response _handleGet(SyncStore store, Request req) {
  final state = store.read();
  if (state == null) {
    return _json({'rev': 0, 'snapshot': <String, dynamic>{}, 'tombstones': []});
  }
  return _json({'rev': state.rev, 'snapshot': state.snapshot, 'tombstones': state.tombstones});
}

Future<Response> _handlePut(SyncStore store, Request req) async {
  final body = jsonDecode(await req.readAsString());
  if (body is! Map<String, dynamic>) {
    return Response.badRequest(body: 'expected JSON object');
  }
  final snapshot = body['snapshot'];
  final tombstones = body['tombstones'] ?? const [];
  if (snapshot is! Map<String, dynamic> || tombstones is! List) {
    return Response.badRequest(body: 'snapshot must be an object, tombstones a list');
  }
  final result = store.write(snapshot, tombstones);
  return _json({'rev': result.rev});
}

Middleware _auth(String? token) {
  if (token == null || token.isEmpty) return (inner) => inner;
  return (inner) {
    return (Request req) {
      final auth = req.headers['authorization'];
      final expected = 'Bearer $token';
      if (auth == null || auth != expected) {
        return Response.unauthorized('unauthorized');
      }
      return inner(req);
    };
  };
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
