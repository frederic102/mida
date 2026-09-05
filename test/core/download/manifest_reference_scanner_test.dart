import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/manifest_reference_scanner.dart';
import 'package:mida/core/extractors/media_models.dart';

/// Covers `ManifestReferenceScanner`'s own size-cap-while-reading behavior
/// - split out of `hls_ffmpeg_downloader_manifest_security_test.dart`
/// (which covers what the scanner is used *for*, not its own internals) to
/// keep both files under this project's 400-line cap.
void main() {
  group('ManifestReferenceScanner.scanAndCheck: maxBytes is enforced while reading', () {
    late HttpServer server;

    tearDown(() async {
      await server.close(force: true);
    });

    // NOT a guard-can-fail test on its own: a bounded (self-terminating)
    // over-cap response gets rejected whether the cap is checked
    // incrementally inside the read loop or once after a full `.join()`
    // (both eventually see the same total and throw the same way) - this
    // only proves the *outcome* (over-size is refused). See the report for
    // why a real-time proof of the "checked while reading, not after"
    // distinction specifically (an unbounded response that a `.join()`-based
    // implementation would never finish reading at all) was attempted and
    // dropped: reverting to `.join()` against a genuinely never-ending
    // response made this suite hang for minutes instead of failing fast,
    // which is itself evidence of the difference but not a test that can
    // ship in a hermetic suite with a sane timeout.
    test('a manifest response larger than maxBytes is rejected with PARSE_ERROR, not read to completion '
        'and accepted', () async {
      final chunk = List<int>.filled(64 * 1024, 0x41); // 'A' * 64KB
      const chunkCount = 90; // 90 * 64KB ~= 5.6MB, over the 5MB cap
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        for (var i = 0; i < chunkCount; i++) {
          request.response.add(chunk);
        }
        await request.response.close();
      });

      final scanner = ManifestReferenceScanner();
      await expectLater(
        scanner.scanAndCheck(Uri.parse('http://127.0.0.1:${server.port}/master.m3u8'), const {},
            allowPrivateHosts: true),
        throwsA(isA<MediaExtractionException>()
            .having((e) => e.status, 'status', 'PARSE_ERROR')
            .having((e) => e.reason, 'reason', contains('while being read'))),
      );
    });

    test('a manifest body under maxBytes is read normally', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        request.response.write('#EXTM3U\n#EXTINF:10,\nhttps://cdn.example.invalid/segment.ts\n');
        await request.response.close();
      });

      final scanner = ManifestReferenceScanner();
      final leaves = await scanner.scanAndCheck(
        Uri.parse('http://127.0.0.1:${server.port}/master.m3u8'),
        const {},
        allowPrivateHosts: true,
        resolveHost: (host) async => [InternetAddress('93.184.216.34')],
      );
      expect(leaves, [Uri.parse('https://cdn.example.invalid/segment.ts')]);
    });
  });

  group('ManifestReferenceScanner.scanAndCheck: leaf DNS-answer (rebinding) check', () {
    late HttpServer server;

    tearDown(() async {
      await server.close(force: true);
    });

    test('guard can fail: a segment host that is syntactically public but resolves to 10.0.0.1 is rejected',
        () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        request.response.write('#EXTM3U\n#EXTINF:10,\nhttps://looks-public.example.test/segment.ts\n');
        await request.response.close();
      });

      var lookupCalls = 0;
      final scanner = ManifestReferenceScanner();
      await expectLater(
        scanner.scanAndCheck(
          Uri.parse('http://127.0.0.1:${server.port}/master.m3u8'),
          const {},
          allowPrivateHosts: true,
          resolveHost: (host) async {
            lookupCalls++;
            return [InternetAddress('10.0.0.1')];
          },
        ),
        throwsA(isA<MediaExtractionException>()
            .having((e) => e.status, 'status', 'UNSUPPORTED_URL')
            .having((e) => e.reason, 'reason', contains('10.0.0.1'))),
      );
      expect(lookupCalls, 1);
      // Guard can fail (see report): dropping the
      // `HostPolicy.assertResolvesToPublicHost` call from the leaf loop
      // (leaving only the syntactic `assertAllowedHost`) made this test
      // fail - `scanAndCheck` returned normally instead of throwing, and
      // `lookupCalls` stayed 0.
    });

    test('duplicate segment hosts are resolved only once', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        request.response.write(
          '#EXTM3U\n#EXTINF:10,\nhttps://cdn.example.invalid/seg1.ts\n#EXTINF:10,\nhttps://cdn.example.invalid/seg2.ts\n',
        );
        await request.response.close();
      });

      var lookupCalls = 0;
      final scanner = ManifestReferenceScanner();
      await scanner.scanAndCheck(
        Uri.parse('http://127.0.0.1:${server.port}/master.m3u8'),
        const {},
        allowPrivateHosts: true,
        resolveHost: (host) async {
          lookupCalls++;
          return [InternetAddress('93.184.216.34')];
        },
      );
      expect(lookupCalls, 1);
    });
  });
}
