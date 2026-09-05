import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/generic_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';

import 'generic_test_support.dart';

void main() {
  group('GenericExtractor.canHandle', () {
    test('accepts any http(s) URL', () {
      final extractor = GenericExtractor(allowPrivateHosts: true);
      expect(extractor.canHandle(Uri.parse('https://totally-unknown-site.example/watch/1')), isTrue);
      expect(extractor.canHandle(Uri.parse('http://totally-unknown-site.example/watch/1')), isTrue);
    });

    test('rejects non-http(s) schemes', () {
      final extractor = GenericExtractor(allowPrivateHosts: true);
      expect(extractor.canHandle(Uri.parse('ftp://example.com/file')), isFalse);
    });
  });

  group('GenericExtractor.extract against a local HttpServer', () {
    late FakePageServer server;

    setUp(() async {
      server = await FakePageServer.start();
    });

    tearDown(() async {
      await server.close();
    });

    test('step 0: a URL ending in .mp4 is treated as a direct format without fetching HTML', () async {
      final extractor = GenericExtractor(allowPrivateHosts: true);
      final info = await extractor.extract(server.urlFor('/clip.mp4'));

      expect(info.formats, hasLength(1));
      expect(info.formats.single.container, 'mp4');
      expect(info.formats.single.hasVideo, isTrue);
      expect(info.formats.single.hasAudio, isTrue);
    });

    test('step 0: a Content-Type of video/webm on an extensionless URL is treated as direct media', () async {
      server
        ..path = '/stream'
        ..contentType = 'video/webm';
      final extractor = GenericExtractor(allowPrivateHosts: true);
      final info = await extractor.extract(server.urlFor('/stream'));

      expect(info.formats, hasLength(1));
      expect(info.formats.single.container, 'webm');
    });

    test('step 1: an HTML page with a <video src> yields one mp4 format and a title', () async {
      server.body = '''
        <html><head><title>Local Demo</title></head>
        <body><video src="/media/demo.mp4"></video></body></html>
      ''';
      final extractor = GenericExtractor(allowPrivateHosts: true);
      final info = await extractor.extract(server.urlFor('/post/1'));

      expect(info.title, 'Local Demo');
      expect(info.formats, hasLength(1));
      expect(info.formats.single.url, server.urlFor('/media/demo.mp4').toString());
    });

    test(
      'step 2 (no headless browser step anymore): a JS-only shell with nothing to sniff and no embed '
      'candidates raises NO_MEDIA_FOUND directly, without needing any browser argument wired up '
      '(security/architecture follow-up: rendering is the browser-capture fallback tier\'s job now)',
      () async {
        server.body = '<html><body><div id="app"></div></body></html>'; // JS-only shell, nothing to sniff
        final extractor = GenericExtractor(allowPrivateHosts: true);

        await expectLater(
          extractor.extract(server.urlFor('/js-only')),
          throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NO_MEDIA_FOUND')),
        );
      },
    );

    test('step 2: DRM markers with no media anywhere raise DRM_PROTECTED', () async {
      server.body = '<html><body>Protected by Widevine DRM.</body></html>';
      final extractor = GenericExtractor(allowPrivateHosts: true);

      await expectLater(
        extractor.extract(server.urlFor('/movie')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'DRM_PROTECTED')),
      );
    });

    test('step 2: no media and no DRM markers raise NO_MEDIA_FOUND', () async {
      server.body = '<html><body>Just an article, nothing to see.</body></html>';
      final extractor = GenericExtractor(allowPrivateHosts: true);

      await expectLater(
        extractor.extract(server.urlFor('/article')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NO_MEDIA_FOUND')),
      );
    });

    test(
      'false-positive guard end to end: a real <video src> and a bare ad/tracker .mp4 URL (raw-text-only, no '
      'player context) both get sniffed, but only the real one survives into the final formats - the ad URL '
      'fails its reachability probe against a local fake ad server',
      () async {
        final adServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => adServer.close(force: true));
        adServer.listen((request) async {
          request.response.headers.set('Content-Type', 'text/html');
          if (request.method != 'HEAD') request.response.write('not video');
          await request.response.close();
        });
        final adUrl = 'http://127.0.0.1:${adServer.port}/creative.mp4';

        server.body = '''
          <html><body>
            <video src="/media/real.mp4"></video>
            <script>var trackerBeacon = "$adUrl";</script>
          </body></html>
        ''';

        final extractor = GenericExtractor(allowPrivateHosts: true);
        final info = await extractor.extract(server.urlFor('/post'));

        expect(info.formats, hasLength(1));
        expect(info.formats.single.url, server.urlFor('/media/real.mp4').toString());
        expect(info.formats.any((f) => f.url == adUrl), isFalse);
      },
    );

    // Guard-can-fail evidence (verified, see report): temporarily making
    // `_rankAndFilterCandidates` return every candidate unfiltered (as if
    // the false-positive guard did not exist) made the test above fail:
    // `info.formats` came back with 2 entries instead of 1, including the
    // ad server's URL. Reverted immediately after confirming the failure.

    test('HLS master playlist found in HTML is expanded into one format per variant', () async {
      const playlist = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=200000,RESOLUTION=640x360
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720
high/index.m3u8
''';
      // Two servers, since a page GET and the playlist GET it triggers
      // need different bodies; the shared `FakePageServer` above answers
      // every path identically, which would not work here.
      final playlistServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => playlistServer.close(force: true));
      playlistServer.listen((request) async {
        request.response.headers.set('Content-Type', 'application/vnd.apple.mpegurl');
        request.response.write(playlist);
        await request.response.close();
      });

      final pageServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => pageServer.close(force: true));
      pageServer.listen((request) async {
        request.response.headers.set('Content-Type', 'text/html; charset=utf-8');
        request.response.write(
          '<html><body><video src="http://127.0.0.1:${playlistServer.port}/master.m3u8"></video></body></html>',
        );
        await request.response.close();
      });

      final extractor = GenericExtractor(allowPrivateHosts: true);
      final info = await extractor.extract(Uri.parse('http://127.0.0.1:${pageServer.port}/post'));

      expect(info.formats, hasLength(2));
      expect(info.formats.map((f) => f.height), containsAll(<int?>[360, 720]));
    });

    group('embedded-player follow (step 1.5)', () {
      test(
        'an <iframe> to an embed page with an escaped m3u8 is followed; formats carry the embed Referer',
        () async {
          String? refererSeenByEmbedPage;
          String? refererSeenByPlaylist;

          final embedServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => embedServer.close(force: true));
          embedServer.listen((request) async {
            if (request.uri.path == '/embed') {
              refererSeenByEmbedPage = request.headers.value('referer');
              request.response.headers.set('Content-Type', 'text/html; charset=utf-8');
              request.response.write('''
                <html><head><title>Embed Player</title></head>
                <body>
                  <script>
                    var playerConfig = {
                      "hls": "http:\\/\\/127.0.0.1:${embedServer.port}\\/media\\/index.m3u8"
                    };
                  </script>
                </body></html>
              ''');
            } else {
              refererSeenByPlaylist = request.headers.value('referer');
              request.response.headers.set('Content-Type', 'application/vnd.apple.mpegurl');
              request.response.write('#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\nseg0.ts\n#EXT-X-ENDLIST\n');
            }
            await request.response.close();
          });
          final embedPageUrl = 'http://127.0.0.1:${embedServer.port}/embed';

          server.body =
              File('test/fixtures/generic_iframe_outer_page.html').readAsStringSync().replaceAll(
                    'EMBED_URL_PLACEHOLDER',
                    embedPageUrl,
                  );

          final extractor = GenericExtractor(allowPrivateHosts: true);
          final outerPageUrl = server.urlFor('/outer-shell');
          final info = await extractor.extract(outerPageUrl);

          expect(info.formats, hasLength(1));
          expect(info.formats.single.container, 'm3u8');
          expect(info.formats.single.url, 'http://127.0.0.1:${embedServer.port}/media/index.m3u8');

          expect(refererSeenByEmbedPage, outerPageUrl.toString(), reason: 'the embed page GET must carry the outer page as Referer');
          expect(
            refererSeenByPlaylist,
            embedPageUrl,
            reason: 'the playlist GET must carry the embed page as Referer (Vimeo CDN measurement)',
          );
          expect(info.requestHeaders['Referer'], embedPageUrl);
        },
      );

      // Guard-can-fail evidence (see report): temporarily making
      // `IframeFollower.findEmbedCandidates` always return `const []`
      // (simulating "iframe following disabled") made this test fail:
      // `info.formats` was empty and `GenericExtractor.extract` instead
      // raised `NO_MEDIA_FOUND` directly (no browser fallback step exists
      // in this extractor anymore - see the class doc), proving this test
      // only passes because the iframe-follow step actually runs.

      test(
        'network budget (security follow-up): oEmbed is never fetched when a direct <iframe> candidate '
        'already yields media',
        () async {
          var oembedRequests = 0;
          final embedServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => embedServer.close(force: true));
          embedServer.listen((request) async {
            request.response.headers.set('Content-Type', 'text/html; charset=utf-8');
            request.response.write('<video src="/clip.mp4"></video>');
            await request.response.close();
          });
          final oembedServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => oembedServer.close(force: true));
          oembedServer.listen((request) async {
            oembedRequests++;
            request.response.headers.set('Content-Type', 'application/json');
            request.response.write('{"html":"<iframe src=\\"http://127.0.0.1:9/never\\"></iframe>"}');
            await request.response.close();
          });

          server.body = '''
            <html><head>
              <link rel="alternate" type="application/json+oembed" href="http://127.0.0.1:${oembedServer.port}/oembed">
            </head><body><iframe src="http://127.0.0.1:${embedServer.port}/embed"></iframe></body></html>
          ''';

          final extractor = GenericExtractor(allowPrivateHosts: true);
          final info = await extractor.extract(server.urlFor('/direct-wins'));

          expect(info.formats, hasLength(1));
          expect(oembedRequests, 0, reason: 'oEmbed discovery must only be tried after direct candidates yield nothing');
        },
      );

      test(
        'network budget (security follow-up): the shared 6-fetch budget across iframe candidates and oEmbed '
        'stops the oEmbed-derived iframe from ever being fetched once exhausted',
        () async {
          var embedRequests = 0;
          final embedServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => embedServer.close(force: true));
          embedServer.listen((request) async {
            embedRequests++;
            request.response.headers.set('Content-Type', 'text/html; charset=utf-8');
            request.response.write('<html><body>no media here</body></html>');
            await request.response.close();
          });

          var oembedJsonRequests = 0;
          var neverReachedRequests = 0;
          final neverReachedServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => neverReachedServer.close(force: true));
          neverReachedServer.listen((request) async {
            neverReachedRequests++;
            request.response.write('<html><body>should never be reached</body></html>');
            await request.response.close();
          });
          final oembedServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => oembedServer.close(force: true));
          oembedServer.listen((request) async {
            oembedJsonRequests++;
            request.response.headers.set('Content-Type', 'application/json');
            request.response.write(
              '{"html":"<iframe src=\\"http://127.0.0.1:${neverReachedServer.port}/late\\"></iframe>"}',
            );
            await request.response.close();
          });

          // IframeFollower.maxCandidates is 5, so all 5 of these are found
          // (and all fail to sniff, forcing the fallback to oEmbed).
          final iframeTags = [
            for (var i = 0; i < 5; i++) '<iframe src="http://127.0.0.1:${embedServer.port}/iframe$i"></iframe>',
          ].join();
          server.body = '''
            <html><head>
              <link rel="alternate" type="application/json+oembed" href="http://127.0.0.1:${oembedServer.port}/oembed">
            </head><body>$iframeTags</body></html>
          ''';

          final extractor = GenericExtractor(allowPrivateHosts: true);
          await expectLater(
            extractor.extract(server.urlFor('/budget-exhausted')),
            throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NO_MEDIA_FOUND')),
          );

          expect(embedRequests, 5, reason: 'all 5 iframe candidates are tried before falling back to oEmbed');
          expect(oembedJsonRequests, 1, reason: 'oEmbed is tried once the 5 direct candidates all fail');
          expect(
            neverReachedRequests,
            0,
            reason: 'the 6-fetch shared budget (5 iframes + 1 oEmbed JSON) is exhausted before the '
                'oEmbed-derived iframe would be the 7th fetch',
          );
        },
      );

      // Guard-can-fail evidence (verified, see report): temporarily
      // constructing `NetworkBudget` with `maxFetches: 100` in
      // `GenericExtractor._followEmbeds` (simulating "no shared budget")
      // made the test above fail: `neverReachedRequests` came back `1`
      // instead of `0`, since nothing stopped the oEmbed-derived iframe
      // from being fetched too. Reverted immediately after confirming the
      // failure.
    });

  });
}
