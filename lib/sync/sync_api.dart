import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Server response of GET /api/sync.
class RemoteState {
  const RemoteState({required this.rev, required this.snapshot, required this.tombstones});

  final int rev;
  final Map<String, dynamic> snapshot;
  final List<dynamic> tombstones;
}

/// Thin HTTP client for the asset-sync-server protocol.
class SyncApi {
  SyncApi(this._baseUrl, {String? token, http.Client? client})
      // ignore: prefer_initializing_formals
      : _token = token,
        _client = client ?? http.Client();

  final String _baseUrl;
  final String? _token;
  final http.Client _client;

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = _baseUrl.endsWith('/') ? _baseUrl.substring(0, _baseUrl.length - 1) : _baseUrl;
    return Uri.parse('$base$path').replace(queryParameters: query);
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_token?.isNotEmpty == true) 'Authorization': 'Bearer $_token',
      };

  /// Fetches the latest state. Returns null when the server has no data yet.
  Future<RemoteState> fetch() async {
    final res = await _client.get(_uri('/api/sync'), headers: _headers);
    if (res.statusCode != 200) {
      throw SyncException('获取失败 (HTTP ${res.statusCode})');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return RemoteState(
      rev: (body['rev'] as num?)?.toInt() ?? 0,
      snapshot: (body['snapshot'] as Map<String, dynamic>?) ?? const {},
      tombstones: (body['tombstones'] as List?) ?? const [],
    );
  }

  /// Pushes the full snapshot, returning the new revision.
  Future<int> push(Map<String, dynamic> snapshot, List<dynamic> tombstones) async {
    final res = await _client.put(
      _uri('/api/sync'),
      headers: _headers,
      body: jsonEncode({'snapshot': snapshot, 'tombstones': tombstones}),
    );
    if (res.statusCode != 200) {
      throw SyncException('上传失败 (HTTP ${res.statusCode})');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return (body['rev'] as num?)?.toInt() ?? 0;
  }

  void close() => _client.close();
}

class SyncException implements Exception {
  SyncException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Validates and normalizes a server URL entered by the user.
String? validateServerUrl(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
    return '地址需以 http:// 或 https:// 开头';
  }
  if (uri.host.isEmpty) return '地址缺少主机名';
  return null;
}

/// True when [error] is a network-level failure (server unreachable),
/// which the UI may present differently from an HTTP error.
bool isNetworkError(Object error) =>
    error is SocketException || error is http.ClientException;
