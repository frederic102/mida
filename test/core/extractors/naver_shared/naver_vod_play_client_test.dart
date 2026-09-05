import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/naver_shared/naver_vod_play_client.dart';

/// Minimal local HTTP server standing in for `apis.naver.com`, same
/// pattern as `test/core/extractors/twitter/twitter_extractor_test.dart`.
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

void main() {
  late _FixedResponseServer server;

  setUp(() async => server = await _FixedResponseServer.start());
  tearDown(() => server.close());

  NaverVodPlayClient buildClient() => NaverVodPlayClient(
        endpointBuilder: (videoId, inKey) =>
            server.baseUri.replace(path: '/rmcnmv/vod/play/v2.0/$videoId', queryParameters: {'key': inKey}),
      );

  group('NaverVodPlayClient.fetchFormats against a local fake backend', () {
    test('parses a successful response into MediaFormats', () async {
      server.body = jsonEncode({
        'videos': {
          'list': [
            {
              'id': 'abc',
              'source': 'https://example.com/a.mp4',
              'encodingOption': {'id': '360P', 'width': 640, 'height': 360},
              'bitrate': {'video': 500, 'audio': 96},
              'size': 12345,
            },
          ],
        },
      });

      final formats = await buildClient().fetchFormats('videoId1', 'inKey1');
      expect(formats, hasLength(1));
      expect(formats.single.height, 360);
      expect(server.lastRequestUri?.path, '/rmcnmv/vod/play/v2.0/videoId1');
      expect(server.lastRequestUri?.queryParameters['key'], 'inKey1');
    });

    test('maps HTTP 404 to NOT_FOUND', () async {
      server.statusCode = 404;
      server.body = '{}';
      await expectLater(
        buildClient().fetchFormats('v', 'k'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NOT_FOUND')),
      );
    });

    test('maps HTTP 429 to RATE_LIMITED', () async {
      server.statusCode = 429;
      await expectLater(
        buildClient().fetchFormats('v', 'k'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'RATE_LIMITED')),
      );
    });

    test('maps an unexpected status code to NETWORK', () async {
      server.statusCode = 500;
      await expectLater(
        buildClient().fetchFormats('v', 'k'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NETWORK')),
      );
    });

    test('maps a non-JSON 200 body to PARSE_ERROR', () async {
      server.body = 'not json';
      await expectLater(
        buildClient().fetchFormats('v', 'k'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR')),
      );
    });

    test('a response with no renditions returns an empty list, not an exception', () async {
      server.body = jsonEncode({'videos': {'list': <dynamic>[]}});
      final formats = await buildClient().fetchFormats('v', 'k');
      expect(formats, isEmpty);
    });
  });
}
