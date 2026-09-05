import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/douyin/douyin_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';

class _FixedResponseServer {
  final HttpServer server;
  int statusCode = 200;
  String body = '';
  bool setCookie = false;
  String? lastCookieHeaderSeenOnPageRequest;

  _FixedResponseServer(this.server);

  static Future<_FixedResponseServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _FixedResponseServer(server);
    server.listen(instance._handle);
    return instance;
  }

  Uri get baseUri => Uri(scheme: 'http', host: '127.0.0.1', port: server.port);

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path == '/') {
      if (setCookie) {
        request.response.cookies.add(Cookie('ttwid', 'fake-ttwid-value'));
      }
      await request.response.close();
      return;
    }
    lastCookieHeaderSeenOnPageRequest = request.headers.value('cookie');
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

  DouyinExtractor buildExtractor() => DouyinExtractor(
        bootstrapRequestUrlBuilder: (url) => server.baseUri.replace(path: url.path),
        pageRequestUrlBuilder: (url) => server.baseUri.replace(path: url.path),
      );

  group('DouyinExtractor.canHandle', () {
    test('accepts /video/<id> URLs', () {
      expect(
        buildExtractor().canHandle(Uri.parse('https://www.douyin.com/video/7318947853764676900')),
        isTrue,
      );
    });

    test('rejects unrelated paths/hosts', () {
      final extractor = buildExtractor();
      expect(extractor.canHandle(Uri.parse('https://www.douyin.com/user/x')), isFalse);
      expect(extractor.canHandle(Uri.parse('https://evil.example/video/1')), isFalse);
    });
  });

  group('DouyinExtractor.extract against a local fake bootstrap + page server', () {
    test('bootstraps a cookie then sends it back on the page request, then parses RENDER_DATA', () async {
      server.setCookie = true;
      final renderData = jsonEncode({
        '1': {
          'aweme': {
            'detail': {
              'aweme_id': '7318947853764676900',
              'desc': 'caption',
              'video': {
                'play_addr': {
                  'url_list': ['https://aweme.snssdk.com/x.mp4'],
                },
              },
            },
          },
        },
      });
      server.body = '<html><body>'
          '<script id="RENDER_DATA" type="application/json">${Uri.encodeComponent(renderData)}</script>'
          '</body></html>';

      final info = await buildExtractor().extract(
        Uri.parse('https://www.douyin.com/video/7318947853764676900'),
      );
      expect(info.id, '7318947853764676900');
      expect(info.title, 'caption');
      expect(server.lastCookieHeaderSeenOnPageRequest, contains('ttwid=fake-ttwid-value'));
    });

    test('detects the JS-VM anti-bot shell and throws CHALLENGE_FAILED', () async {
      server.body = r'<html><script>var glb;(glb=window)._$jsvmprt=function(){};</script></html>';
      await expectLater(
        buildExtractor().extract(Uri.parse('https://www.douyin.com/video/1')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'CHALLENGE_FAILED')),
      );
    });

    test('throws PARSE_ERROR when the page has neither RENDER_DATA nor the challenge marker', () async {
      server.body = '<html><body>something unexpected</body></html>';
      await expectLater(
        buildExtractor().extract(Uri.parse('https://www.douyin.com/video/1')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR')),
      );
    });

    test('maps HTTP 404 on the page to NETWORK (fall-through eligible), not terminal NOT_FOUND', () async {
      // Guard-can-fail: Douyin's real watch page answers 200 even for a
      // nonexistent video id from this network, so a bare 404 is more
      // likely a WAF/proxy synthesizing one than Douyin itself.
      server.statusCode = 404;
      await expectLater(
        buildExtractor().extract(Uri.parse('https://www.douyin.com/video/1')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NETWORK')),
      );
    });
  });
}
