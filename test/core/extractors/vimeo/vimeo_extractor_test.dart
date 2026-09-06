import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/vimeo/vimeo_extractor.dart';

/// Minimal local HTTP server standing in for
/// `player.vimeo.com/video/<id>/config`, so the extractor's request
/// assembly and HTTP-status-to-exception mapping can be exercised without
/// touching the network (same pattern as
/// `test/core/extractors/dailymotion/dailymotion_extractor_test.dart`).
class _FixedResponseServer {
  final HttpServer server;
  int statusCode = 200;
  String body = '{}';
  String? lastUserAgent;
  String? lastReferer;
  String? lastPath;
  Map<String, String>? lastQuery;

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
    lastReferer = request.headers.value('referer');
    lastPath = request.uri.path;
    lastQuery = request.uri.queryParameters;
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

  VimeoExtractor buildExtractor() => VimeoExtractor(
        configRequestUrlBuilder: (url) => server.baseUri.replace(path: url.path, queryParameters: url.queryParameters.isEmpty ? null : url.queryParameters),
        allowPrivateHosts: true,
      );

  group('VimeoExtractor.canHandle', () {
    test('accepts vimeo.com/<id> and vimeo.com/<id>/<hash>', () {
      final extractor = buildExtractor();
      expect(extractor.canHandle(Uri.parse('https://vimeo.com/22439234')), isTrue);
      expect(extractor.canHandle(Uri.parse('https://vimeo.com/22439234/')), isTrue);
      expect(extractor.canHandle(Uri.parse('https://vimeo.com/22439234/abcdef1234')), isTrue);
      expect(extractor.canHandle(Uri.parse('https://www.vimeo.com/22439234')), isTrue);
    });

    test('accepts player.vimeo.com/video/<id>', () {
      final extractor = buildExtractor();
      expect(extractor.canHandle(Uri.parse('https://player.vimeo.com/video/22439234')), isTrue);
      expect(
        extractor.canHandle(Uri.parse('https://player.vimeo.com/video/22439234?h=abc')),
        isTrue,
      );
    });

    test('rejects non-video vimeo pages and unrelated hosts', () {
      final extractor = buildExtractor();
      // Guard can fail: without the numeric-id requirement in
      // `_vimeoComIdPattern`, a channel/showcase/user page like this would
      // wrongly match and this assertion would fail.
      expect(extractor.canHandle(Uri.parse('https://vimeo.com/channels/staffpicks')), isFalse);
      expect(extractor.canHandle(Uri.parse('https://vimeo.com/someusername')), isFalse);
      expect(extractor.canHandle(Uri.parse('https://vimeo.com/')), isFalse);
      expect(extractor.canHandle(Uri.parse('https://evil.example/22439234')), isFalse);
      expect(extractor.canHandle(Uri.parse('ftp://vimeo.com/22439234')), isFalse, reason: 'scheme gate');
      expect(extractor.canHandle(Uri.parse('https://foo.vimeo.com/22439234')), isFalse, reason: 'host allowlist');
      expect(extractor.canHandle(Uri.parse('https://x.player.vimeo.com/video/22439234')), isFalse);
      expect(extractor.canHandle(Uri.parse('https://player.vimeo.com/video/22439234/config')), isFalse,
          reason: 'only the video page itself, never its config or sub-paths');
      expect(extractor.canHandle(Uri.parse('https://player.vimeo.com/video/22439234junk')), isFalse);
    });
  });

  group('VimeoExtractor.extractById against a local fake config server', () {
    test('sends the required Referer and desktop User-Agent', () async {
      server.body = await File('test/fixtures/vimeo_config.json').readAsString();
      await buildExtractor().extractById('22439234');

      // Guard can fail: if the extractor stopped sending this header (the
      // real endpoint requires it), this would read null instead.
      expect(server.lastReferer, 'https://vimeo.com/');
      expect(server.lastUserAgent, contains('Chrome'));
      expect(server.lastPath, '/video/22439234/config');
    });

    test('parses a real fixture into progressive mp4 + hls master formats', () async {
      server.body = await File('test/fixtures/vimeo_config.json').readAsString();

      final info = await buildExtractor().extractById('22439234');
      expect(info.id, '22439234');
      expect(info.title, "Kenya's Digital Divide");
      expect(info.author, 'Vimeo Video School');
      expect(info.duration, const Duration(seconds: 596));
      expect(info.thumbnailUrl, 'https://i.vimeocdn.com/video/000000_1280.jpg');

      expect(info.formats.where((f) => f.container == 'mp4'), hasLength(2));
      expect(
        info.formats.where((f) => f.container == 'mp4'),
        everyElement(isA<MediaFormat>().having((f) => f.isMuxed, 'isMuxed', isTrue)),
      );

      final hls = info.formats.where((f) => f.container == 'm3u8');
      expect(hls, hasLength(1));
      expect(hls.single.isMuxed, isTrue);
      expect(hls.single.url, contains('master.json'));

      expect(info.requestHeaders['Referer'], 'https://vimeo.com/');
    });

    test('maps a 403 carrying the Vimeo privacy JSON to LOGIN_REQUIRED (terminal)', () async {
      server.statusCode = 403;
      server.body = jsonEncode({
        'errors': [
          {'message': 'This video is private.'},
        ],
      });
      await expectLater(
        buildExtractor().extractById('22439234'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'LOGIN_REQUIRED')),
      );
    });

    test('guard can fail: a 403 with a non-privacy body (WAF/address-ban page) is CHALLENGE_FAILED so the '
        'registry still falls through to the generic and browser tiers', () async {
      server.statusCode = 403;
      server.body = '<html><body><h1>Sorry</h1><p>You have been blocked.</p></body></html>';
      await expectLater(
        buildExtractor().extractById('22439234'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'CHALLENGE_FAILED')),
      );
    });

    test('an unlisted hash from the page URL is forwarded as the config endpoint h parameter', () async {
      server.body = jsonEncode({
        'request': {
          'files': {
            'progressive': [
              {'url': 'https://vod.example.invalid/720.mp4', 'width': 1280, 'height': 720},
            ],
          },
        },
        'video': {'id': 22439234, 'title': 'Unlisted', 'duration': 10},
      });
      await buildExtractor().extract(Uri.parse('https://vimeo.com/22439234/abcdef1234'));
      expect(server.lastQuery?['h'], 'abcdef1234',
          reason: 'guard can fail: dropping the hash makes every unlisted link come back as private');
      await buildExtractor().extract(Uri.parse('https://player.vimeo.com/video/22439234?h=zz99'));
      expect(server.lastQuery?['h'], 'zz99');
    });

    test('maps a body-level errors array to LOGIN_REQUIRED', () async {
      server.body = jsonEncode({
        'errors': [
          {'message': 'This video is password protected'},
        ],
      });
      await expectLater(
        buildExtractor().extractById('22439234'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'LOGIN_REQUIRED')),
      );
    });

    test('maps 404 to NOT_FOUND and 429 to RATE_LIMITED', () async {
      server.statusCode = 404;
      await expectLater(
        buildExtractor().extractById('1'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NOT_FOUND')),
      );

      server.statusCode = 429;
      await expectLater(
        buildExtractor().extractById('1'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'RATE_LIMITED')),
      );
    });

    test('no progressive or hls entries surfaces as UNSUPPORTED_MEDIA', () async {
      server.body = jsonEncode({
        'request': {
          'files': <String, dynamic>{},
        },
        'video': {'id': 1, 'title': 't'},
      });
      await expectLater(
        buildExtractor().extractById('1'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_MEDIA')),
      );
    });

    test('other non-200 maps to NETWORK', () async {
      server.statusCode = 500;
      await expectLater(
        buildExtractor().extractById('1'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NETWORK')),
      );
    });

    test('unparseable body maps to PARSE_ERROR', () async {
      server.body = 'not json';
      await expectLater(
        buildExtractor().extractById('1'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR')),
      );
    });
  });

  group('VimeoExtractor.extract with a real Uri', () {
    test('throws UNSUPPORTED_URL when canHandle would reject', () async {
      await expectLater(
        buildExtractor().extract(Uri.parse('https://evil.example/22439234')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL')),
      );
    });
  });
}
