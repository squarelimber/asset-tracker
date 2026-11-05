import 'package:asset_sync_server/rate_limit.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  test('ignores spoofed forwarded addresses by default', () async {
    final handler = rateLimit(limit: 1)((_) => Response.ok('ok'));
    expect(
        (await handler(Request('GET', Uri.http('localhost', '/'),
                headers: {'x-forwarded-for': '1.1.1.1'})))
            .statusCode,
        200);
    expect(
        (await handler(Request('GET', Uri.http('localhost', '/'),
                headers: {'x-forwarded-for': '2.2.2.2'})))
            .statusCode,
        429);
  });
  test('uses forwarded addresses only with an explicitly trusted proxy',
      () async {
    final handler =
        rateLimit(limit: 1, trustProxy: true)((_) => Response.ok('ok'));
    expect(
        (await handler(Request('GET', Uri.http('localhost', '/'),
                headers: {'x-forwarded-for': '1.1.1.1'})))
            .statusCode,
        200);
    expect(
        (await handler(Request('GET', Uri.http('localhost', '/'),
                headers: {'x-forwarded-for': '2.2.2.2'})))
            .statusCode,
        200);
    expect(
        (await handler(Request('GET', Uri.http('localhost', '/'),
                headers: {'x-forwarded-for': '1.1.1.1'})))
            .statusCode,
        429);
  });
}
