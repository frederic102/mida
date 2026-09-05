import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/chzzk/chzzk_video_info_client.dart';
import 'package:mida/core/extractors/media_models.dart';

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

  ChzzkVideoInfoClient buildClient() => ChzzkVideoInfoClient(
        endpointBuilder: (videoNo) => server.baseUri.replace(path: '/service/v3/videos/$videoNo'),
      );

  group('ChzzkVideoInfoClient.fetch against a local fake backend', () {
    test('parses a captured successful response into a ChzzkVideoInfo', () async {
      server.body = _fixture('chzzk_video_info.json');
      final info = await buildClient().fetch('14834019');

      expect(info.videoId, '8CD1894FC89CFF321EF81D020D5BC0559F8A');
      expect(info.inKey, isNotEmpty);
      expect(info.title, '룩삼 주말 발라드 월드컵');
      expect(info.author, '룩삼');
      expect(info.duration, const Duration(seconds: 32528));
      expect(server.lastRequestUri?.path, '/service/v3/videos/14834019');
    });

    test('maps a captured code:404 response to NOT_FOUND', () async {
      server.statusCode = 404;
      server.body = _fixture('chzzk_video_not_found.json');
      await expectLater(
        buildClient().fetch('2412'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NOT_FOUND')),
      );
    });

    test('an adult-flagged video maps to LOGIN_REQUIRED', () async {
      server.body = jsonEncode({
        'code': 200,
        'content': {
          'videoId': 'v',
          'inKey': 'k',
          'videoTitle': 't',
          'adult': true,
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

    test('a code:200 body missing content maps to PARSE_ERROR', () async {
      server.body = jsonEncode({'code': 200});
      await expectLater(
        buildClient().fetch('1'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR')),
      );
    });
  });
}
