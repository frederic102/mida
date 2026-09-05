import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/niconico/niconico_dmc_session_client.dart';
import 'package:mida/core/extractors/niconico/niconico_extractor.dart';

class _FixedResponseServer {
  final HttpServer server;
  int statusCode = 200;
  String body = '';

  _FixedResponseServer(this.server);

  static Future<_FixedResponseServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _FixedResponseServer(server);
    server.listen(instance._handle);
    return instance;
  }

  Uri get baseUri => Uri(scheme: 'http', host: '127.0.0.1', port: server.port);

  Future<void> _handle(HttpRequest request) async {
    request.response.statusCode = statusCode;
    request.response.write(body);
    await request.response.close();
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  late _FixedResponseServer pageServer;
  late _FixedResponseServer sessionServer;

  setUp(() async {
    pageServer = await _FixedResponseServer.start();
    sessionServer = await _FixedResponseServer.start();
  });
  tearDown(() async {
    await pageServer.close();
    await sessionServer.close();
  });

  NiconicoExtractor buildExtractor() => NiconicoExtractor(
        pageRequestUrlBuilder: (url) => pageServer.baseUri.replace(path: url.path),
        sessionClient: NiconicoDmcSessionClient(
          requestUrlBuilder: (url) => sessionServer.baseUri.replace(path: '/api/sessions'),
        ),
      );

  group('NiconicoExtractor.canHandle', () {
    test('accepts /watch/<id> URLs', () {
      expect(buildExtractor().canHandle(Uri.parse('https://www.nicovideo.jp/watch/sm9')), isTrue);
    });

    test('rejects unrelated paths/hosts', () {
      final extractor = buildExtractor();
      expect(extractor.canHandle(Uri.parse('https://www.nicovideo.jp/mylist/1')), isFalse);
      expect(extractor.canHandle(Uri.parse('https://evil.example/watch/sm9')), isFalse);
    });
  });

  group('NiconicoExtractor.extract against local fake page + DMC session servers', () {
    test('resolves page data + a DMC session into a MediaInfo', () async {
      pageServer.body = await File('test/fixtures/niconico_watch_data.html').readAsString();
      sessionServer.body = jsonEncode({
        'data': {
          'session': {'content_uri': 'https://dmc.nico/example/master.m3u8'},
        },
      });

      final info = await buildExtractor().extract(Uri.parse('https://www.nicovideo.jp/watch/sm9'));
      expect(info.id, 'sm9');
      expect(info.title, 'Example Niconico Video');
      expect(info.formats.single.url, 'https://dmc.nico/example/master.m3u8');
      expect(info.formats.single.container, 'm3u8');
    });

    test('throws PARSE_ERROR when the page has no watch data (current site shape)', () async {
      pageServer.body = '<html><body>react app shell, no js-initial-watch-data</body></html>';
      await expectLater(
        buildExtractor().extract(Uri.parse('https://www.nicovideo.jp/watch/sm9')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR')),
      );
    });

    test('maps a 404 with Niconico\'s own real not-found marker to NOT_FOUND', () async {
      // Real marker captured live from an actual nonexistent sm id
      // (docs/plan-phase5-coverage.md Lane D review round 2).
      pageServer.statusCode = 404;
      pageServer.body = '<script>window.__remixContext = {&quot;statusCode&quot;:404,'
          '&quot;code&quot;:&quot;NOT_FOUND&quot;};</script>';
      await expectLater(
        buildExtractor().extract(Uri.parse('https://www.nicovideo.jp/watch/sm9')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NOT_FOUND')),
      );
    });

    test('maps a bare 404 with no corroborating marker to CHALLENGE_FAILED (fall-through eligible)', () async {
      // Guard-can-fail: a WAF/proxy synthesizing a 404 would not
      // reproduce Niconico's own embedded marker - this must not be
      // treated as terminal.
      pageServer.statusCode = 404;
      pageServer.body = '<html><body>some other 404 page</body></html>';
      await expectLater(
        buildExtractor().extract(Uri.parse('https://www.nicovideo.jp/watch/sm9')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'CHALLENGE_FAILED')),
      );
    });
  });
}
