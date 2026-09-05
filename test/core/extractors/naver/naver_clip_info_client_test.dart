import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/naver/naver_clip_info_client.dart';

class _FixedResponseServer {
  final HttpServer server;
  int statusCode = 200;
  String body = '{}';
  Uri? lastRequestUri;

  _FixedResponseServer(this.server);

  static Future<_FixedResponseServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _FixedResponseServer(server);
    server.listen(instance._handle);
    return instance;
  }

  Uri get baseUri => Uri(scheme: 'http', host: '127.0.0.1', port: server.port);

  Future<void> _handle(HttpRequest request) async {
    lastRequestUri = request.uri;
    request.response.statusCode = statusCode;
    request.response.write(body);
    await request.response.close();
  }

  Future<void> close() => server.close(force: true);
}

String _fixture(String name) => File('test/fixtures/$name').readAsStringSync();

void main() {
  late _FixedResponseServer server;

  setUp(() async => server = await _FixedResponseServer.start());
  tearDown(() => server.close());

  NaverClipInfoClient buildClient() => NaverClipInfoClient(
        endpointBuilder: (clipId) => server.baseUri.replace(path: '/v1/clips/$clipId/play-info'),
        fixedNowMillis: 1788609332593,
      );

  group('NaverClipInfoClient.fetch against a local fake backend', () {
    test('parses a captured SUCCESS response into a NaverClipInfo', () async {
      server.body = _fixture('naver_clip_play_info.json');
      final info = await buildClient().fetch('105228483');

      expect(info.videoId, 'D5305FD77CCF037973A0B9822D7AE024021C');
      expect(info.inKey, isNotEmpty);
      expect(info.title, '클로징');
      expect(info.author, 'SBS뉴스');
      expect(info.duration, const Duration(seconds: 7));
      // The signed request still reaches the real path even though this
      // server does not check the signature itself (that is
      // NaverApiSigner's own unit test's job).
      expect(server.lastRequestUri?.path, '/v1/clips/105228483/play-info');
      expect(server.lastRequestUri?.queryParameters['msgpad'], isNotNull);
      expect(server.lastRequestUri?.queryParameters['md'], isNotNull);
    });

    test('maps a captured CLIP_NOT_FOUND response to NOT_FOUND', () async {
      server.body = _fixture('naver_clip_not_found.json');
      await expectLater(
        buildClient().fetch('72311805'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NOT_FOUND')),
      );
    });

    test('maps a non-PLAYABLE clip to LOGIN_REQUIRED', () async {
      server.body = jsonEncode({
        'statusCode': 'SUCCESS',
        'result': {
          'clip': {'videoId': 'v', 'title': 't', 'adultVideo': true},
          'play': {'inKey': 'k', 'playable': 'NEED_AGE_VERIFICATION'},
        },
      });
      await expectLater(
        buildClient().fetch('1'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'LOGIN_REQUIRED')),
      );
    });

    test('maps HTTP 429 to RATE_LIMITED', () async {
      server.statusCode = 429;
      await expectLater(
        buildClient().fetch('1'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'RATE_LIMITED')),
      );
    });

    test('maps a 5xx to NETWORK', () async {
      server.statusCode = 500;
      await expectLater(
        buildClient().fetch('1'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NETWORK')),
      );
    });

    test('maps a non-JSON body to PARSE_ERROR', () async {
      server.body = 'not json';
      await expectLater(
        buildClient().fetch('1'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR')),
      );
    });

    test('a SUCCESS body missing videoId/inKey maps to PARSE_ERROR', () async {
      server.body = jsonEncode({
        'statusCode': 'SUCCESS',
        'result': {
          'clip': {'title': 't'},
          'play': {},
        },
      });
      await expectLater(
        buildClient().fetch('1'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR')),
      );
    });
  });
}
