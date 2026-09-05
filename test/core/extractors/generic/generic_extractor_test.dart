import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/generic_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/services/browser_page_fetcher.dart';

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

    test('step 2: falls back to the headless browser when plain HTML has no media, then sniffs the DOM', () async {
      server.body = '<html><body><div id="app"></div></body></html>'; // JS-only shell, nothing to sniff
      final workDir = await Directory.systemTemp.createTemp('mida_generic_browser_');
      addTearDown(() => workDir.deleteSync(recursive: true));
      final bat = writeFakeBrowser(
        workDir,
        '^<html^>^<video src="https://cdn.example.com/rendered.mp4"^>^</video^>^</html^>',
      );

      final extractor = GenericExtractor(
        browserFetcher: BrowserPageFetcher(candidatePaths: () => [bat.path], allowPrivateHosts: true),
        allowPrivateHosts: true,
      );
      final info = await extractor.extract(server.urlFor('/js-only'));

      expect(info.formats, hasLength(1));
      expect(info.formats.single.url, 'https://cdn.example.com/rendered.mp4');
    });

    test('step 3: DRM markers with no media anywhere raise DRM_PROTECTED', () async {
      server.body = '<html><body>Protected by Widevine DRM.</body></html>';
      final workDir = await Directory.systemTemp.createTemp('mida_generic_browser_');
      addTearDown(() => workDir.deleteSync(recursive: true));
      final bat = writeFakeBrowser(workDir, '^<html^>still nothing^</html^>');

      final extractor = GenericExtractor(
        browserFetcher: BrowserPageFetcher(candidatePaths: () => [bat.path], allowPrivateHosts: true),
        allowPrivateHosts: true,
      );

      await expectLater(
        extractor.extract(server.urlFor('/movie')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'DRM_PROTECTED')),
      );
    });

    test('step 3: no media and no DRM markers raise NO_MEDIA_FOUND', () async {
      server.body = '<html><body>Just an article, nothing to see.</body></html>';
      final workDir = await Directory.systemTemp.createTemp('mida_generic_browser_');
      addTearDown(() => workDir.deleteSync(recursive: true));
      final bat = writeFakeBrowser(workDir, '^<html^>still nothing^</html^>');

      final extractor = GenericExtractor(
        browserFetcher: BrowserPageFetcher(candidatePaths: () => [bat.path], allowPrivateHosts: true),
        allowPrivateHosts: true,
      );

      await expectLater(
        extractor.extract(server.urlFor('/article')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NO_MEDIA_FOUND')),
      );
    });

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
      // fell through to the headless-browser step (which then throws
      // BROWSER_MISSING/NO_MEDIA_FOUND in this hermetic test, since no
      // real browser argument is wired up here), proving this test only
      // passes because the iframe-follow step actually runs.
    });

  });
}
