import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/browser_capture/browser_capture_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';

import 'fake_devtools_session.dart';

void main() {
  group('BrowserCaptureExtractor (fake DevtoolsSession, no browser)', () {
    test('captures a network-observed mp4 and assembles page-level metadata/headers', () async {
      late FakeDevtoolsSession session;
      session = FakeDevtoolsSession(
        onSend: (method, params) async {
          if (method == 'Page.navigate') {
            session.emit('Network.responseReceived', {
              'response': {'url': 'https://cdn.example.com/video.mp4', 'mimeType': 'video/mp4'}
            });
            return {};
          }
          if (method == 'Runtime.evaluate') {
            final expression = params?['expression'] as String? ?? '';
            if (expression.contains('JSON.stringify')) {
              return jsonEvalResult({'title': 'Real Title', 'ogTitle': null, 'ogImage': 'https://img.example.com/t.jpg'});
            }
            return {};
          }
          if (method == 'Network.getCookies') {
            return {
              'cookies': [
                {'name': 'sid', 'value': 'abc123', 'domain': 'cdn.example.com', 'path': '/', 'secure': true},
              ]
            };
          }
          return {};
        },
        onSendBrowserLevel: (method, params) async {
          if (method == 'Browser.getVersion') return {'userAgent': 'TestUA/1.0'};
          return {};
        },
      );

      final extractor = BrowserCaptureExtractor(
        sessionLauncher: ({connectTimeout = const Duration()}) async => session,
        loadTimeout: const Duration(milliseconds: 30),
        postLoadDelay: const Duration(milliseconds: 5),
        autoplayRetryDelay: const Duration(milliseconds: 5),
        firstCandidateTimeout: const Duration(milliseconds: 20),
        variantSettleDelay: const Duration(milliseconds: 5),
        pollInterval: const Duration(milliseconds: 5),
      );

      final info = await extractor.extract(Uri.parse('https://example.com/page'));

      expect(info.formats, hasLength(1));
      expect(info.formats.single.container, 'mp4');
      expect(info.formats.single.url, 'https://cdn.example.com/video.mp4');
      expect(info.title, 'Real Title');
      expect(info.thumbnailUrl, 'https://img.example.com/t.jpg');
      expect(info.requestHeaders['User-Agent'], 'TestUA/1.0');
      expect(info.requestHeaders['Referer'], 'https://example.com/page');
      // Lane A hardening (cookie domain scoping): requestHeaders carries
      // only UA/Referer now - the cookie is exposed structured, scoped to
      // the domain it was actually captured for, not flattened in here.
      expect(info.requestHeaders.containsKey('Cookie'), isFalse);
      expect(info.cookiesByDomain['cdn.example.com']?.single.name, 'sid');
      expect(info.cookiesByDomain['cdn.example.com']?.single.value, 'abc123');
      expect(session.closed, isTrue);
    });

    test('expands a captured HLS master playlist into one format per variant', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      const playlist = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\n'
          'low.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=1600000,RESOLUTION=1280x720\n'
          'high.m3u8\n';
      server.listen((request) async {
        request.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        request.response.write(playlist);
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));

      // The candidate URL must look like a public host to pass
      // BrowserCaptureExtractor's SSRF guard (HostPolicy rejects a
      // literal 127.0.0.1 candidate on principle - that guard is exactly
      // as strict for a same-process test fixture as for a real hostile
      // page). A custom `connectionFactory` redirects the *actual* socket
      // to our local fixture server regardless of the requested host,
      // which is the correct way to test this without weakening the
      // guard under test. A literal public IP, not a hostname: HostPolicy
      // now also resolves a hostname via real DNS and fails closed if
      // that fails, which `cdn.example.com` (no real A/AAAA record) does -
      // a literal IP skips that resolution entirely (already an address).
      const masterUrl = 'https://93.184.216.34/master.m3u8';
      HttpClient pinnedToFixtureServer() {
        final client = HttpClient();
        client.connectionFactory = (uri, proxyHost, proxyPort) => Socket.startConnect(InternetAddress.loopbackIPv4, server.port);
        return client;
      }

      late FakeDevtoolsSession session;
      session = FakeDevtoolsSession(
        onSend: (method, params) async {
          if (method == 'Page.navigate') {
            session.emit('Network.responseReceived', {
              'response': {'url': masterUrl, 'mimeType': 'application/vnd.apple.mpegurl'}
            });
            return {};
          }
          if (method == 'Runtime.evaluate') {
            final expression = params?['expression'] as String? ?? '';
            if (expression.contains('JSON.stringify')) {
              return jsonEvalResult({'title': null, 'ogTitle': null, 'ogImage': null});
            }
            return {};
          }
          return {};
        },
      );

      final extractor = BrowserCaptureExtractor(
        sessionLauncher: ({connectTimeout = const Duration()}) async => session,
        httpClientFactory: pinnedToFixtureServer,
        loadTimeout: const Duration(milliseconds: 30),
        postLoadDelay: const Duration(milliseconds: 5),
        autoplayRetryDelay: const Duration(milliseconds: 5),
        firstCandidateTimeout: const Duration(milliseconds: 20),
        variantSettleDelay: const Duration(milliseconds: 5),
        pollInterval: const Duration(milliseconds: 5),
      );

      final info = await extractor.extract(Uri.parse('https://example.com/page'));

      expect(info.formats, hasLength(2));
      expect(info.formats.every((f) => f.container == 'm3u8'), isTrue);
      expect(info.formats.map((f) => f.height), containsAll(<int?>[360, 720]));
    });

    test('falls back to Runtime.evaluate outerHTML + HtmlMediaSniffer when no network media is observed', () async {
      const fallbackHtml = '<html><head><title>Fallback Title</title></head>'
          '<body><video src="https://cdn.example.com/fallback.mp4"></video></body></html>';

      final session = FakeDevtoolsSession(
        onSend: (method, params) async {
          if (method == 'Runtime.evaluate') {
            final expression = params?['expression'] as String? ?? '';
            if (expression.contains('JSON.stringify')) {
              return jsonEvalResult({'title': null, 'ogTitle': null, 'ogImage': null});
            }
            if (expression.contains('outerHTML')) {
              return stringEvalResult(fallbackHtml);
            }
            return {}; // the play() nudge
          }
          return {};
        },
      );

      final extractor = BrowserCaptureExtractor(
        sessionLauncher: ({connectTimeout = const Duration()}) async => session,
        loadTimeout: const Duration(milliseconds: 30),
        postLoadDelay: const Duration(milliseconds: 5),
        autoplayRetryDelay: const Duration(milliseconds: 5),
        firstCandidateTimeout: const Duration(milliseconds: 20),
        variantSettleDelay: const Duration(milliseconds: 5),
        pollInterval: const Duration(milliseconds: 5),
      );

      final info = await extractor.extract(Uri.parse('https://example.com/page'));

      expect(info.formats, hasLength(1));
      expect(info.formats.single.url, 'https://cdn.example.com/fallback.mp4');
      expect(info.title, 'Fallback Title');
    });

    test('throws NO_MEDIA_FOUND when network, autoplay nudge, and DOM fallback all find nothing', () async {
      final session = FakeDevtoolsSession(
        onSend: (method, params) async {
          if (method == 'Runtime.evaluate') {
            final expression = params?['expression'] as String? ?? '';
            if (expression.contains('outerHTML')) {
              return stringEvalResult('<html><body>nothing here</body></html>');
            }
            return {};
          }
          return {};
        },
      );

      final extractor = BrowserCaptureExtractor(
        sessionLauncher: ({connectTimeout = const Duration()}) async => session,
        loadTimeout: const Duration(milliseconds: 30),
        postLoadDelay: const Duration(milliseconds: 5),
        autoplayRetryDelay: const Duration(milliseconds: 5),
        firstCandidateTimeout: const Duration(milliseconds: 20),
        variantSettleDelay: const Duration(milliseconds: 5),
        pollInterval: const Duration(milliseconds: 5),
      );

      await expectLater(
        extractor.extract(Uri.parse('https://example.com/page')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NO_MEDIA_FOUND')),
      );
      expect(session.closed, isTrue);
    });

    test('canHandle accepts only http(s) URLs', () {
      final extractor = BrowserCaptureExtractor(
        sessionLauncher: ({connectTimeout = const Duration()}) async => FakeDevtoolsSession(),
      );
      expect(extractor.canHandle(Uri.parse('https://example.com')), isTrue);
      expect(extractor.canHandle(Uri.parse('http://example.com')), isTrue);
      expect(extractor.canHandle(Uri.parse('ftp://example.com')), isFalse);
    });
  });
}
