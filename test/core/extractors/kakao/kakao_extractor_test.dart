import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/kakao/kakao_extractor.dart';
import 'package:mida/core/extractors/kakao/kakao_play_info_client.dart';
import 'package:mida/core/extractors/media_models.dart';

class _FixedResponseServer {
  final HttpServer server;
  int statusCode = 200;
  String body = '{}';

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

String _fixture(String name) => File('test/fixtures/$name').readAsStringSync();

void main() {
  group('KakaoExtractor.canHandle', () {
    final extractor = KakaoExtractor();

    test('accepts /channel/<id>/cliplink/<id> and /v/<id> on tv.kakao.com', () {
      expect(
        extractor.canHandle(Uri.parse('https://tv.kakao.com/channel/3150758/cliplink/450674252')),
        isTrue,
      );
      expect(extractor.canHandle(Uri.parse('https://tv.kakao.com/v/450674252')), isTrue);
    });

    test('rejects unrelated hosts and paths', () {
      expect(extractor.canHandle(Uri.parse('https://tv.kakao.com/')), isFalse);
      expect(extractor.canHandle(Uri.parse('https://evil.example/v/1')), isFalse);
      expect(extractor.canHandle(Uri.parse('https://tv.kakao.com/v/abc')), isFalse);
    });
  });

  group('KakaoExtractor.extract against a local fake backend', () {
    late _FixedResponseServer server;
    setUp(() async => server = await _FixedResponseServer.start());
    tearDown(() => server.close());

    KakaoExtractor buildExtractor() => KakaoExtractor(
          playInfoClient: KakaoPlayInfoClient(
            endpointBuilder: (clipId) => server.baseUri.replace(path: '/katz/v3/ft/cliplink/$clipId/readyNplay'),
          ),
        );

    test('a captured live ServiceEnded response surfaces as NOT_FOUND, not a crash', () async {
      server.statusCode = 422;
      server.body = _fixture('kakao_service_ended.json');

      await expectLater(
        buildExtractor().extract(Uri.parse('https://tv.kakao.com/channel/3150758/cliplink/450674252')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NOT_FOUND')),
      );
    });

    test('throws UNSUPPORTED_URL for a non-clip URL', () async {
      await expectLater(
        buildExtractor().extract(Uri.parse('https://tv.kakao.com/')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL')),
      );
    });
  });
}
