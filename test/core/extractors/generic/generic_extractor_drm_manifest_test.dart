import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/generic_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';

import 'generic_test_support.dart';

/// Manifest-body DRM detection (security follow-up), split out of
/// `generic_extractor_drm_ssrf_test.dart` to stay under the 400-line cap:
/// the existing DRM check in `HtmlMediaSniffer` only looks at the
/// candidate URL's own text, so a clean-looking `.m3u8`/`.mpd` URL whose
/// actual manifest body carries real DRM key material (FairPlay, Widevine,
/// PlayReady) used to sail straight through as a normal format. Round 2
/// follow-up: the original fix only checked an HLS master's *first*
/// emitted variant; this file also covers every variant being checked
/// (capped, budget-respecting).
void main() {
  group('GenericExtractor: manifest-body DRM detection', () {
    late FakePageServer server;

    setUp(() async {
      server = await FakePageServer.start();
    });

    tearDown(() async {
      await server.close();
    });

    test(
      'an HLS master whose URL looks clean but whose body carries #EXT-X-KEY METHOD=SAMPLE-AES raises '
      'DRM_PROTECTED (not silently exposed as a downloadable format) - the sniffer\'s own URL-substring '
      'DRM check cannot see this at all',
      () async {
        final drmPlaylistServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => drmPlaylistServer.close(force: true));
        drmPlaylistServer.listen((request) async {
          request.response.headers.set('Content-Type', 'application/vnd.apple.mpegurl');
          request.response.write(
            '#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,KEYFORMAT="com.apple.streamingkeydelivery"\n'
            '#EXTINF:6.0,\nseg0.ts\n#EXT-X-ENDLIST\n',
          );
          await request.response.close();
        });

        server.body = '''
          <html><body>
            <video src="http:\\/\\/127.0.0.1:${drmPlaylistServer.port}\\/master.m3u8"></video>
          </body></html>
        ''';

        final extractor = GenericExtractor(allowPrivateHosts: true);
        await expectLater(
          extractor.extract(server.urlFor('/protected')),
          throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'DRM_PROTECTED')),
        );
      },
    );

    test('a DASH .mpd whose body carries <ContentProtection> raises DRM_PROTECTED', () async {
      final drmMpdServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => drmMpdServer.close(force: true));
      drmMpdServer.listen((request) async {
        request.response.headers.set('Content-Type', 'application/dash+xml');
        request.response.write(
          '<MPD><Period><AdaptationSet><ContentProtection '
          'schemeIdUri="urn:mpeg:dash:mp4protection:2011"/></AdaptationSet></Period></MPD>',
        );
        await request.response.close();
      });

      server.body = '''
        <html><body>
          <source src="http:\\/\\/127.0.0.1:${drmMpdServer.port}\\/manifest.mpd">
        </body></html>
      ''';

      final extractor = GenericExtractor(allowPrivateHosts: true);
      await expectLater(
        extractor.extract(server.urlFor('/protected-dash')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'DRM_PROTECTED')),
      );
    });

    test('a plain AES-128 HLS stream (ffmpeg-decryptable, not DRM) still produces a downloadable format', () async {
      final aes128Server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => aes128Server.close(force: true));
      aes128Server.listen((request) async {
        request.response.headers.set('Content-Type', 'application/vnd.apple.mpegurl');
        request.response.write(
          '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example.com/key.bin"\n'
          '#EXTINF:6.0,\nseg0.ts\n#EXT-X-ENDLIST\n',
        );
        await request.response.close();
      });

      server.body = '''
        <html><body>
          <video src="http:\\/\\/127.0.0.1:${aes128Server.port}\\/master.m3u8"></video>
        </body></html>
      ''';

      final extractor = GenericExtractor(allowPrivateHosts: true);
      final info = await extractor.extract(server.urlFor('/aes128'));

      expect(info.formats, hasLength(1));
      expect(info.formats.single.container, 'm3u8');
    });

    test(
      'every emitted variant is checked (not just the first) - a master with two variants where only the '
      'SECOND carries a PlayReady KEYFORMAT drops just that one, keeping the clean first variant as a format',
      () async {
        final variantServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => variantServer.close(force: true));
        variantServer.listen((request) async {
          request.response.headers.set('Content-Type', 'application/vnd.apple.mpegurl');
          if (request.uri.path == '/master.m3u8') {
            request.response.write(
              '#EXTM3U\n'
              '#EXT-X-STREAM-INF:BANDWIDTH=200000,RESOLUTION=640x360\n'
              'clean.m3u8\n'
              '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720\n'
              'protected.m3u8\n',
            );
          } else if (request.uri.path == '/protected.m3u8') {
            request.response.write(
              '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,KEYFORMAT="urn:uuid:9a04f079-9840-4286-ab92-e65be0885f95"\n'
              '#EXTINF:6.0,\nseg0.ts\n#EXT-X-ENDLIST\n',
            );
          } else {
            request.response.write('#EXTM3U\n#EXTINF:6.0,\nseg0.ts\n#EXT-X-ENDLIST\n');
          }
          await request.response.close();
        });

        server.body = '''
          <html><body>
            <video src="http:\\/\\/127.0.0.1:${variantServer.port}\\/master.m3u8"></video>
          </body></html>
        ''';

        final extractor = GenericExtractor(allowPrivateHosts: true);
        final info = await extractor.extract(server.urlFor('/mixed-protection'));

        expect(info.formats, hasLength(1));
        expect(info.formats.single.height, 360);
        expect(info.formats.any((f) => f.height == 720), isFalse);
      },
    );

    test('if every variant turns out DRM, the whole candidate raises DRM_PROTECTED', () async {
      final variantServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => variantServer.close(force: true));
      variantServer.listen((request) async {
        request.response.headers.set('Content-Type', 'application/vnd.apple.mpegurl');
        if (request.uri.path == '/master.m3u8') {
          request.response.write(
            '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=200000,RESOLUTION=640x360\nlow.m3u8\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720\nhigh.m3u8\n',
          );
        } else {
          request.response.write('#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES\n#EXTINF:6.0,\nseg0.ts\n#EXT-X-ENDLIST\n');
        }
        await request.response.close();
      });

      server.body = '''
        <html><body>
          <video src="http:\\/\\/127.0.0.1:${variantServer.port}\\/master.m3u8"></video>
        </body></html>
      ''';

      final extractor = GenericExtractor(allowPrivateHosts: true);
      await expectLater(
        extractor.extract(server.urlFor('/all-protected')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'DRM_PROTECTED')),
      );
    });

    test(
      'variant checks are capped at 8 fetches; variants beyond the cap are trusted (fail-open) rather than '
      'fetched unboundedly',
      () async {
        var variantFetchCount = 0;
        final variantServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => variantServer.close(force: true));
        variantServer.listen((request) async {
          request.response.headers.set('Content-Type', 'application/vnd.apple.mpegurl');
          if (request.uri.path == '/master.m3u8') {
            final variantLines = [
              for (var i = 0; i < 10; i++) '#EXT-X-STREAM-INF:BANDWIDTH=100000\nv$i.m3u8',
            ].join('\n');
            request.response.write('#EXTM3U\n$variantLines\n');
          } else {
            variantFetchCount++;
            // Every variant that actually gets checked is DRM-protected.
            request.response.write('#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES\n#EXTINF:6.0,\nseg0.ts\n#EXT-X-ENDLIST\n');
          }
          await request.response.close();
        });

        server.body = '''
          <html><body>
            <video src="http:\\/\\/127.0.0.1:${variantServer.port}\\/master.m3u8"></video>
          </body></html>
        ''';

        final extractor = GenericExtractor(allowPrivateHosts: true);
        final info = await extractor.extract(server.urlFor('/ten-variants'));

        expect(variantFetchCount, 8, reason: 'only 8 of the 10 variants are ever fetched for DRM verification');
        // The 8 checked variants are all confirmed DRM and dropped; the 2
        // beyond the cap were never checked, so they are trusted (kept).
        expect(info.formats, hasLength(2));
      },
    );

    // Guard-can-fail evidence (verified, see report): temporarily reverting
    // `expandFormats` to check only `variants.first` (the pre-fix
    // behavior) made the "only the SECOND carries a PlayReady KEYFORMAT"
    // test above fail: it returned 2 formats (both variants) instead of 1,
    // since the first (clean) variant's own check never noticed the
    // second variant was encrypted. Reverted immediately after confirming
    // the failure.

    // Guard-can-fail evidence (verified, see report): temporarily making
    // `FormatExpander.expandFormats` skip the
    // `DrmPlaylistScanner.isHlsDrmProtected(fetch.body)` check entirely
    // made the SAMPLE-AES test above fail: instead of throwing
    // DRM_PROTECTED, `extract()` returned a normal `MediaInfo` with one
    // m3u8 format pointing at the encrypted stream. Reverted immediately
    // after confirming the failure.
  });
}
