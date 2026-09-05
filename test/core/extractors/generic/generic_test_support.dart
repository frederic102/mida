import 'dart:io';

/// A tiny fake page server: every path serves a canned response so tests
/// don't depend on the real network. Mirrors the pattern already used by
/// `test/core/download/*_test.dart` (local HttpServer, no mocking lib).
/// Shared between `generic_extractor_test.dart` and
/// `generic_extractor_drm_ssrf_test.dart` (DRY: both need the same
/// single-response fake server).
class FakePageServer {
  final HttpServer server;
  String path = '/';
  int statusCode = 200;
  String contentType = 'text/html; charset=utf-8';
  String body = '<html><body>empty</body></html>';

  FakePageServer._(this.server);

  static Future<FakePageServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakePageServer._(server);
    server.listen((request) async {
      request.response.statusCode = fake.statusCode;
      request.response.headers.set('Content-Type', fake.contentType);
      request.response.write(fake.body);
      await request.response.close();
    });
    return fake;
  }

  Uri urlFor(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  Future<void> close() => server.close(force: true);
}
