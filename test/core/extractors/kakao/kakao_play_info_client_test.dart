import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/kakao/kakao_play_info_client.dart';
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

  KakaoPlayInfoClient buildClient() => KakaoPlayInfoClient(
        endpointBuilder: (clipId) => server.baseUri.replace(path: '/katz/v3/ft/cliplink/$clipId/readyNplay'),
      );

  group('KakaoPlayInfoClient.fetchFormats against a local fake backend', () {
    test('a captured live ServiceEnded (HTTP 422) response maps to NOT_FOUND', () async {
      server.statusCode = 422;
      server.body = _fixture('kakao_service_ended.json');

      await expectLater(
        buildClient().fetchFormats('450674252'),
        throwsA(isA<MediaExtractionException>()
            .having((e) => e.status, 'status', 'NOT_FOUND')
            .having((e) => e.reason, 'reason', contains('discontinued'))),
      );
    });

    test('a plain HTTP 429 maps to RATE_LIMITED (checked before the JSON code)', () async {
      server.statusCode = 429;
      server.body = '{}';
      await expectLater(
        buildClient().fetchFormats('1'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'RATE_LIMITED')),
      );
    });

    test('an unrecognized non-200 status maps to NETWORK', () async {
      server.statusCode = 503;
      server.body = '{}';
      await expectLater(
        buildClient().fetchFormats('1'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NETWORK')),
      );
    });

    test('parses a hypothetical videoLocation success shape', () async {
      server.body = jsonEncode({
        'videoLocation': [
          {'url': 'https://example.com/a.mp4', 'width': 1280, 'height': 720, 'bitRate': 2000},
        ],
      });
      final formats = await buildClient().fetchFormats('1');
      expect(formats, hasLength(1));
      expect(formats.single.height, 720);
      expect(formats.single.url, 'https://example.com/a.mp4');
    });

    test('a 200 response with no recognizable rendition list maps to NO_MEDIA_FOUND', () async {
      server.body = jsonEncode({'unexpectedShape': true});
      await expectLater(
        buildClient().fetchFormats('1'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NO_MEDIA_FOUND')),
      );
    });

    test('a non-JSON body maps to PARSE_ERROR', () async {
      server.body = 'not json';
      await expectLater(
        buildClient().fetchFormats('1'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR')),
      );
    });
  });
}
