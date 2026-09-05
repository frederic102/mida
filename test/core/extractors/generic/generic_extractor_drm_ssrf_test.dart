import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/generic_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';

import 'generic_test_support.dart';

/// Split out of `generic_extractor_test.dart` (which was at the 400-line
/// cap) to stay under it. Covers two live-probe regressions plus the
/// SSRF guard: (1) Vimeo's DRM-wrapped `/playlist/drm/cbcs,...` master
/// was picked as a format and fed to ffmpeg, which failed with "Invalid
/// data found when processing input"; (2) an unreachable/garbage HLS
/// master used to still contribute a broken placeholder format instead of
/// being skipped; (3) every network call must refuse loopback/private/
/// link-local hosts, including redirect targets.
void main() {
  group('GenericExtractor: DRM filtering, format ordering, and skip-on-fail', () {
    late FakePageServer server;

    setUp(() async {
      server = await FakePageServer.start();
    });

    tearDown(() async {
      await server.close();
    });

    test('a page whose only candidates are DRM-marked URLs raises DRM_PROTECTED, not NO_MEDIA_FOUND', () async {
      server.body = '''
        <html><body>
          <script>
            var sources = {
              "a": "https://cdn.example.com/playlist/drm/cbcs.mpd",
              "b": "https://cdn.example.com/playlist/widevine.m3u8"
            };
          </script>
        </body></html>
      ''';
      final extractor = GenericExtractor(allowPrivateHosts: true);

      await expectLater(
        extractor.extract(server.urlFor('/drm-only')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'DRM_PROTECTED')),
      );
    });

    test('formats are ordered: expanded HLS variants (with height) first, then mpd, then everything else',
        () async {
      const playlist = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=640x360
seg.m3u8
''';
      final playlistServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => playlistServer.close(force: true));
      playlistServer.listen((request) async {
        request.response.headers.set('Content-Type', 'application/vnd.apple.mpegurl');
        request.response.write(playlist);
        await request.response.close();
      });

      // A local server (not a `cdn.example.com` placeholder that a live
      // reachability probe or the new DRM-scanning mpd fetch would
      // actually have to resolve over the real network): serves a clean,
      // non-DRM manifest body so the `application/dash+xml` Content-Type
      // both passes the reachability probe (manifest exemption) and lets
      // `FormatExpander`'s own DRM-scan fetch complete instantly.
      final mpdServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => mpdServer.close(force: true));
      mpdServer.listen((request) async {
        request.response.headers.set('Content-Type', 'application/dash+xml');
        request.response.write('<MPD><Period><AdaptationSet></AdaptationSet></Period></MPD>');
        await request.response.close();
      });

      server.body = '''
        <html><body>
          <video src="/plain.mp4"></video>
          <script>
            var sources = {
              "dash": "http:\\/\\/127.0.0.1:${mpdServer.port}\\/manifest.mpd",
              "hls": "http:\\/\\/127.0.0.1:${playlistServer.port}\\/master.m3u8"
            };
          </script>
        </body></html>
      ''';

      final extractor = GenericExtractor(allowPrivateHosts: true);
      final info = await extractor.extract(server.urlFor('/mixed'));

      expect(info.formats, hasLength(3));
      expect(info.formats[0].container, 'm3u8');
      expect(info.formats[0].height, 360);
      expect(info.formats[1].container, 'mpd');
      expect(info.formats[2].container, 'mp4');
    });

    test('an HLS master URL that 404s contributes no format, instead of a broken placeholder', () async {
      final brokenPlaylistServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => brokenPlaylistServer.close(force: true));
      brokenPlaylistServer.listen((request) async {
        request.response.statusCode = 404;
        request.response.write('<html><body>not found</body></html>');
        await request.response.close();
      });

      server.body = '''
        <html><body>
          <video src="/plain.mp4"></video>
          <script>
            var src = "http:\\/\\/127.0.0.1:${brokenPlaylistServer.port}\\/gone.m3u8";
          </script>
        </body></html>
      ''';

      final extractor = GenericExtractor(allowPrivateHosts: true);
      final info = await extractor.extract(server.urlFor('/one-broken-one-fine'));

      expect(info.formats, hasLength(1));
      expect(info.formats.single.container, 'mp4');
    });

    // Guard-can-fail evidence for both ordering and skip-on-fail (see
    // report): temporarily changing `_expandFormats`'s failure branch
    // from `return const [];` to the old
    // `return [_formatFor(id: url, url: url, container: container)];`
    // made the 404 test above fail (2 formats instead of 1, the second
    // pointing at the URL that 404s). The DRM-only test has its own
    // separate guard-can-fail note in `html_media_sniffer_test.dart`
    // (disabling `HtmlMediaSniffer._looksLikeDrmUrl` turns it red there).
    //
    // Manifest-body DRM detection (SAMPLE-AES/PlayReady/ContentProtection/
    // every-variant-checked/8-fetch-cap) has its own dedicated file:
    // `generic_extractor_drm_manifest_test.dart`.
  });

  group('GenericExtractor: SSRF guard (host_policy.dart)', () {
    late FakePageServer server;

    setUp(() async {
      server = await FakePageServer.start();
    });

    tearDown(() async {
      await server.close();
    });

    test('extract() rejects a loopback URL by default (allowPrivateHosts: false)', () async {
      final extractor = GenericExtractor();
      await expectLater(
        extractor.extract(server.urlFor('/anything')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL')),
      );
    });

    test('extract() rejects an IPv4-mapped IPv6 loopback target (::ffff:127.0.0.1) (F2)', () async {
      final extractor = GenericExtractor();
      await expectLater(
        extractor.extract(Uri.parse('http://[::ffff:127.0.0.1]:${server.server.port}/anything')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL')),
      );
    });

    test('a page that redirects to a private target never reaches it, and the extract() call rejects', () async {
      var privateTargetHits = 0;
      final privateTargetServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => privateTargetServer.close(force: true));
      privateTargetServer.listen((request) async {
        privateTargetHits++;
        request.response.write('should never be reached');
        await request.response.close();
      });

      // A dedicated server that immediately 302s to the private target,
      // standing in for "an allowed public page whose response happens
      // to redirect somewhere it should not".
      final redirectingServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => redirectingServer.close(force: true));
      redirectingServer.listen((request) async {
        request.response.statusCode = 302;
        request.response.headers.set('Location', 'http://127.0.0.1:${privateTargetServer.port}/reached');
        await request.response.close();
      });

      final extractor = GenericExtractor(allowPrivateHosts: true); // exempts hop 0 (the entry URL) only
      await expectLater(
        extractor.extract(Uri.parse('http://127.0.0.1:${redirectingServer.port}/start')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL')),
      );
      expect(privateTargetHits, 0, reason: 'the redirect target must never be contacted');
    });

    // Guard-can-fail evidence for the redirect test (see report and
    // `host_policy_test.dart`, which has the same evidence at the
    // `HostPolicy.guardedRequest` unit level): temporarily exempting
    // every hop (not just hop 0) from the host check when
    // `allowPrivateHosts` is true made this test fail, with
    // `privateTargetHits` becoming 1 and no exception thrown.
  });
}
