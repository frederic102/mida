import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/chzzk/chzzk_extractor.dart';
import 'package:mida/core/extractors/chzzk/chzzk_video_info_client.dart';
import 'package:mida/core/extractors/media_models.dart';
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
  group('ChzzkExtractor.canHandle', () {
    final extractor = ChzzkExtractor();

    test('accepts /video/<id> on chzzk.naver.com', () {
      expect(extractor.canHandle(Uri.parse('https://chzzk.naver.com/video/2412')), isTrue);
    });

    test('rejects /live/<id> (live streams are out of scope) and unrelated hosts', () {
      expect(extractor.canHandle(Uri.parse('https://chzzk.naver.com/live/abc123')), isFalse);
      expect(extractor.canHandle(Uri.parse('https://evil.example/video/2412')), isFalse);
      expect(extractor.canHandle(Uri.parse('https://chzzk.naver.com/video/abc')), isFalse);
    });
  });

  group('ChzzkExtractor.extract against local fake video-info and vod-play backends', () {
    late _FixedResponseServer videoInfoServer;
    late _FixedResponseServer vodPlayServer;

    setUp(() async {
      videoInfoServer = await _FixedResponseServer.start();
      vodPlayServer = await _FixedResponseServer.start();
    });
    tearDown(() async {
      await videoInfoServer.close();
      await vodPlayServer.close();
    });

    ChzzkExtractor buildExtractor() => ChzzkExtractor(
          videoInfoClient: ChzzkVideoInfoClient(
            endpointBuilder: (videoNo) => videoInfoServer.baseUri.replace(path: '/service/v3/videos/$videoNo'),
          ),
          vodPlayClient: NaverVodPlayClient(
            endpointBuilder: (videoId, inKey) => vodPlayServer.baseUri.replace(
              path: '/rmcnmv/vod/play/v2.0/$videoId',
              queryParameters: {'key': inKey},
            ),
          ),
        );

    test('resolves a VOD end to end into a MediaInfo with formats', () async {
      videoInfoServer.body = _fixture('chzzk_video_info.json');
      vodPlayServer.body = _fixture('naver_vod_play_v2.json');

      final info = await buildExtractor().extract(Uri.parse('https://chzzk.naver.com/video/14834019'));

      expect(info.id, '14834019');
      expect(info.title, '룩삼 주말 발라드 월드컵');
      expect(info.author, '룩삼');
      expect(info.formats, hasLength(3));
    });

    test('a code:404 video-info response surfaces as NOT_FOUND, not a crash', () async {
      videoInfoServer.statusCode = 404;
      videoInfoServer.body = _fixture('chzzk_video_not_found.json');

      await expectLater(
        buildExtractor().extract(Uri.parse('https://chzzk.naver.com/video/2412')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NOT_FOUND')),
      );
    });

    test('throws UNSUPPORTED_URL for a non-VOD URL', () async {
      await expectLater(
        buildExtractor().extract(Uri.parse('https://chzzk.naver.com/live/abc123')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL')),
      );
    });
  });
}
