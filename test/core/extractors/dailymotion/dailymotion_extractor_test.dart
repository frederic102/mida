import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/dailymotion/dailymotion_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';

/// Minimal local HTTP server standing in for
/// `www.dailymotion.com/player/metadata/video/<xid>`, so the extractor's
/// request assembly and HTTP-status-to-exception mapping can be exercised
/// without touching the network (same pattern as
/// `test/core/extractors/twitter/twitter_extractor_test.dart`).
class _FixedResponseServer {
  final HttpServer server;
  int statusCode = 200;
  String body = '{}';
  String? lastUserAgent;
  String? lastPath;

  _FixedResponseServer(this.server);

  static Future<_FixedResponseServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _FixedResponseServer(server);
    server.listen(instance._handle);
    return instance;
  }

  Uri get baseUri => Uri(scheme: 'http', host: '127.0.0.1', port: server.port);

  Future<void> _handle(HttpRequest request) async {
    lastUserAgent = request.headers.value('user-agent');
    lastPath = request.uri.path;
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

  DailymotionExtractor buildExtractor() => DailymotionExtractor(
        endpointBuilder: (xid) => server.baseUri.replace(path: '/player/metadata/video/$xid'),
      );

  group('DailymotionExtractor.canHandle', () {
    test('accepts dailymotion.com/video and dai.ly short links', () {
      final extractor = buildExtractor();
      expect(extractor.canHandle(Uri.parse('https://www.dailymotion.com/video/x2mjb0x')), isTrue);
      expect(
        extractor.canHandle(Uri.parse('https://www.dailymotion.com/video/x2mjb0x_some-title')),
        isTrue,
      );
      expect(extractor.canHandle(Uri.parse('https://dai.ly/x2mjb0x')), isTrue);
    });

    test('rejects unrelated hosts and paths', () {
      final extractor = buildExtractor();
      expect(extractor.canHandle(Uri.parse('https://www.dailymotion.com/jayasikachantika')), isFalse);
      expect(extractor.canHandle(Uri.parse('https://evil.example/video/x2mjb0x')), isFalse);
    });
  });

  group('DailymotionExtractor.extractById against a local fake metadata server', () {
    test('sends a desktop User-Agent and parses a real fixture into formats', () async {
      server.body = await File('test/fixtures/dailymotion_metadata.json').readAsString();

      final info = await buildExtractor().extractById('x2mjb0x');
      expect(info.id, 'x2mjb0x');
      expect(info.title, 'Download Vivian Maier By Vivian Maier PDF');
      expect(info.author, 'jayasikachantika');
      expect(info.duration, const Duration(seconds: 54));
      expect(info.formats, hasLength(3));
      expect(info.formats.any((f) => f.container == 'm3u8'), isTrue);
      expect(info.formats.where((f) => f.container == 'mp4'), hasLength(2));
      expect(server.lastUserAgent, contains('Chrome'));
      expect(server.lastPath, '/player/metadata/video/x2mjb0x');
    });

    test('maps a 404 error object to NOT_FOUND', () async {
      server.body = jsonEncode({
        'error': {'code': '404', 'message': "Can't find object video"},
      });
      await expectLater(
        buildExtractor().extractById('deadbeef'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NOT_FOUND')),
      );
    });

    test('maps is_password_protected to LOGIN_REQUIRED', () async {
      server.body = jsonEncode({'id': 'x1', 'title': 't', 'is_password_protected': true});
      await expectLater(
        buildExtractor().extractById('x1'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'LOGIN_REQUIRED')),
      );
    });

    test('empty qualities surfaces as UNSUPPORTED_MEDIA', () async {
      server.body = jsonEncode({'id': 'x1', 'title': 't', 'qualities': <String, dynamic>{}});
      await expectLater(
        buildExtractor().extractById('x1'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_MEDIA')),
      );
    });

    test('maps HTTP 429 to RATE_LIMITED and other non-200 to NETWORK', () async {
      server.statusCode = 429;
      await expectLater(
        buildExtractor().extractById('x1'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'RATE_LIMITED')),
      );

      server.statusCode = 500;
      await expectLater(
        buildExtractor().extractById('x1'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NETWORK')),
      );
    });

    test('maps a non-JSON 200 body to PARSE_ERROR', () async {
      server.statusCode = 200;
      server.body = 'not json';
      await expectLater(
        buildExtractor().extractById('x1'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR')),
      );
    });
  });
}
