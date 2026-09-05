import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/stream_downloader.dart';

/// A minimal server that always redirects to [target].
Future<HttpServer> _startRedirectServer(String target) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.statusCode = 302;
    request.response.headers.set('location', target);
    await request.response.close();
  });
  return server;
}

void main() {
  group('StreamDownloader redirect-hop host policy (guard: allowPrivateHosts only exempts hop 0)', () {
    test('a redirect from an exempted hop 0 to a private/loopback host is still refused', () async {
      final loopSelf = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      loopSelf.listen((request) async {
        request.response.statusCode = 200;
        request.response.add([1, 2, 3]);
        await request.response.close();
      });
      // Hop 0 (the entry URL) is loopback and exempted by allowPrivateHosts,
      // but it redirects right back to another loopback URL - that hop is
      // NOT hop 0, so it must still be rejected even though the whole chain
      // never leaves 127.0.0.1.
      final redirectServer = await _startRedirectServer('http://127.0.0.1:${loopSelf.port}/final');
      final tempDir = await Directory.systemTemp.createTemp('mida_stream_dl_redirect_');
      final outputPath = '${tempDir.path}/out.bin';

      try {
        final downloader = StreamDownloader(allowPrivateHosts: true, maxRetries: 1);
        await expectLater(
          downloader.download(
            url: 'http://127.0.0.1:${redirectServer.port}/start',
            outputPath: outputPath,
            contentLength: null,
          ),
          throwsA(isA<StreamDownloadException>()),
        );
      } finally {
        await redirectServer.close(force: true);
        await loopSelf.close(force: true);
        await tempDir.delete(recursive: true);
      }
    });
  });
}
