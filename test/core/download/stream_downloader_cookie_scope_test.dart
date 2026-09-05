import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/stream_downloader.dart';
import 'package:mida/core/extractors/media_models.dart';

/// Minimal local server that just records the `cookie` header it saw on
/// its single request, so `StreamDownloader.download`'s per-request cookie
/// scoping (docs/plan-phase5-coverage.md Item D) can be verified without
/// touching the real network.
class _CookieRecordingServer {
  final HttpServer server;
  String? lastCookieHeader;

  _CookieRecordingServer(this.server);

  static Future<_CookieRecordingServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _CookieRecordingServer(server);
    server.listen((request) async {
      instance.lastCookieHeader = request.headers.value('cookie');
      request.response.headers.contentLength = 5;
      request.response.add('hello'.codeUnits);
      await request.response.close();
    });
    return instance;
  }

  String get url => 'http://127.0.0.1:${server.port}/file.bin';
}

void main() {
  group('StreamDownloader cookie domain scoping', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mida_stream_cookie_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('a cookie scoped to the request host is sent', () async {
      final server = await _CookieRecordingServer.start();
      addTearDown(() => server.server.close(force: true));

      final downloader = StreamDownloader(allowPrivateHosts: true);
      addTearDown(downloader.close);

      await downloader.download(
        url: server.url,
        outputPath: '${tempDir.path}/out.bin',
        cookiesByDomain: const {
          '127.0.0.1': [CookieEntry(domain: '127.0.0.1', path: '/', secure: false, name: 'sid', value: 'abc123')],
        },
      );

      expect(server.lastCookieHeader, 'sid=abc123');
    });

    test('guard can fail: a cookie scoped to an unrelated domain is never sent', () async {
      // Proves the per-request scoping, not "any cookiesByDomain present",
      // gates what is sent - the exact bug class this feature exists to
      // fix (a different format's/host's cookie leaking onto this
      // request).
      final server = await _CookieRecordingServer.start();
      addTearDown(() => server.server.close(force: true));

      final downloader = StreamDownloader(allowPrivateHosts: true);
      addTearDown(downloader.close);

      await downloader.download(
        url: server.url,
        outputPath: '${tempDir.path}/out.bin',
        cookiesByDomain: const {
          'unrelated-host.example.com': [
            CookieEntry(domain: 'unrelated-host.example.com', path: '/', secure: false, name: 'sid', value: 'abc123'),
          ],
        },
      );

      expect(server.lastCookieHeader, isNull);
    });

    test('an explicit Cookie header in `headers` is still honored when cookiesByDomain has no match (fallback)', () async {
      final server = await _CookieRecordingServer.start();
      addTearDown(() => server.server.close(force: true));

      final downloader = StreamDownloader(allowPrivateHosts: true);
      addTearDown(downloader.close);

      await downloader.download(
        url: server.url,
        outputPath: '${tempDir.path}/out.bin',
        headers: const {'Cookie': 'legacy=1'},
        cookiesByDomain: const {},
      );

      expect(server.lastCookieHeader, 'legacy=1');
    });
  });
}
