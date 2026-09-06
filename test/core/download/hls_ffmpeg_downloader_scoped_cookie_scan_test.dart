import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/hls_ffmpeg_downloader.dart';
import 'package:mida/core/extractors/media_models.dart';

/// Independent pre-review item 4 (phase 6): `downloadVerified` used to run
/// its manifest-safety scan (`_assertManifestSafe`) against the raw,
/// unscoped `headers` only - never the domain-scoped cookie ffmpeg itself
/// would go on to send via `_withScopedCookie`. An authenticated manifest
/// therefore got scanned without the cookie it actually needs, 403'd, and
/// the scanner (seeing a non-manifest error-page body) found no leaf
/// references to check at all - silently "passing" a scan that never
/// looked at anything real, even though the *download* right after it
/// (which did carry the cookie) would go on to actually reach whatever the
/// manifest really referenced.
Future<List<InternetAddress>> _fakePublicResolver(String host) async => [InternetAddress('127.0.0.1')];

void main() {
  test('guard-can-fail: the manifest scan uses the same scoped cookie ffmpeg itself sends, so an authenticated '
      'manifest is actually scanned (not skipped as an unreadable 403 error page)', () async {
    late Directory tempDir;
    tempDir = await Directory.systemTemp.createTemp('mida_hls_scoped_cookie_scan_');
    addTearDown(() => tempDir.delete(recursive: true));

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final cookie = request.headers.value('cookie');
      if (cookie != 'session=ok') {
        request.response.statusCode = 403;
        request.response.write('Forbidden');
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
      // A media playlist (no #EXT-X-STREAM-INF): this plain line is a
      // segment - a leaf, always host-checked, never fetched by the
      // scanner itself.
      request.response.write('#EXTM3U\n#EXTINF:10,\nhttp://127.0.0.1:1/segment.ts\n');
      await request.response.close();
    });

    final downloader = HlsFfmpegDownloader(
      allowPrivateHosts: true,
      resolveHost: _fakePublicResolver,
      ffmpegPathResolver: () async => 'irrelevant.exe',
    );

    await expectLater(
      downloader.downloadVerified(
        url: 'http://127.0.0.1:${server.port}/media.m3u8',
        outputPath: '${tempDir.path}/out.mp4',
        cookiesByDomain: const {
          '127.0.0.1': [CookieEntry(domain: '127.0.0.1', path: '/', secure: false, name: 'session', value: 'ok')],
        },
      ),
      throwsA(isA<MediaExtractionException>().having((e) => e.reason, 'reason', contains('segment/key/map'))),
    );
    // Guard can fail (see report): before this fix, `_assertManifestSafe`
    // was called with the raw, unscoped `headers` map - which never
    // carries `cookiesByDomain`'s cookie - so this fixture would 403, the
    // scanner would see a body with no manifest shape at all (no leaf
    // references), and `downloadVerified` would proceed straight past the
    // scan (never reaching, let alone rejecting, the loopback segment
    // reference this test asserts on) into `run` - which fails for the
    // unrelated reason of `irrelevant.exe` not being real ffmpeg instead
    // of the expected `MediaExtractionException`.
  });
}
