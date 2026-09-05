import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/naver/naver_clip_info_client.dart';
import 'package:mida/core/extractors/naver/naver_extractor.dart';
import 'package:mida/core/extractors/naver_shared/naver_vod_play_client.dart';

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
  group('NaverExtractor.canHandle', () {
    final extractor = NaverExtractor();

    test('accepts /v/<id> and /embed/<id> on tv.naver.com', () {
      expect(extractor.canHandle(Uri.parse('https://tv.naver.com/v/72311805')), isTrue);
      expect(extractor.canHandle(Uri.parse('https://tv.naver.com/embed/72311805')), isTrue);
    });

    test('rejects unrelated hosts and paths', () {
      expect(extractor.canHandle(Uri.parse('https://tv.naver.com/')), isFalse);
      expect(extractor.canHandle(Uri.parse('https://evil.example/v/1')), isFalse);
      expect(extractor.canHandle(Uri.parse('https://tv.naver.com/v/abc')), isFalse);
    });
  });

  group('NaverExtractor.extract against local fake clip-info and vod-play backends', () {
    late _FixedResponseServer clipInfoServer;
    late _FixedResponseServer vodPlayServer;

    setUp(() async {
      clipInfoServer = await _FixedResponseServer.start();
      vodPlayServer = await _FixedResponseServer.start();
    });
    tearDown(() async {
      await clipInfoServer.close();
      await vodPlayServer.close();
    });

    NaverExtractor buildExtractor() => NaverExtractor(
          clipInfoClient: NaverClipInfoClient(
            endpointBuilder: (clipId) => clipInfoServer.baseUri.replace(path: '/v1/clips/$clipId/play-info'),
            fixedNowMillis: 1,
          ),
          vodPlayClient: NaverVodPlayClient(
            endpointBuilder: (videoId, inKey) => vodPlayServer.baseUri.replace(
              path: '/rmcnmv/vod/play/v2.0/$videoId',
              queryParameters: {'key': inKey},
            ),
          ),
        );

    test('resolves a clip end to end into a MediaInfo with formats', () async {
      clipInfoServer.body = _fixture('naver_clip_play_info.json');
      vodPlayServer.body = _fixture('naver_vod_play_v2.json');

      final info = await buildExtractor().extract(Uri.parse('https://tv.naver.com/v/105228483'));

      expect(info.id, '105228483');
      expect(info.title, '클로징');
      expect(info.formats, hasLength(3));
      expect(info.sourceUrl, Uri.parse('https://tv.naver.com/v/105228483'));
    });

    test('a CLIP_NOT_FOUND clip-info response surfaces as NOT_FOUND, not a crash', () async {
      clipInfoServer.body = _fixture('naver_clip_not_found.json');

      await expectLater(
        buildExtractor().extract(Uri.parse('https://tv.naver.com/v/72311805')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NOT_FOUND')),
      );
    });

    test('throws UNSUPPORTED_URL for a non-clip URL', () async {
      await expectLater(
        buildExtractor().extract(Uri.parse('https://tv.naver.com/')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL')),
      );
    });
  });
}
