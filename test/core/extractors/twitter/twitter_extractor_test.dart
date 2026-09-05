import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/twitter/twitter_extractor.dart';

/// Minimal local HTTP server standing in for
/// `cdn.syndication.twimg.com`, so the extractor's request assembly and
/// HTTP-status-to-exception mapping can be exercised without touching the
/// network (same pattern as `test/core/download/stream_downloader_test.dart`).
class _FixedResponseServer {
  final HttpServer server;
  int statusCode = 200;
  String body = '{}';
  String? lastUserAgent;
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
    lastUserAgent = request.headers.value('user-agent');
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

  TwitterExtractor buildExtractor() => TwitterExtractor(
        endpointBuilder: (tweetId, token) => server.baseUri.replace(
          path: '/tweet-result',
          queryParameters: {'id': tweetId, 'token': token},
        ),
      );

  group('TwitterExtractor.canHandle / extractTweetId', () {
    test('accepts twitter.com, x.com and mobile.twitter.com status URLs', () {
      final extractor = buildExtractor();
      expect(extractor.canHandle(Uri.parse('https://twitter.com/nasa/status/123')), isTrue);
      expect(extractor.canHandle(Uri.parse('https://x.com/nasa/status/123')), isTrue);
      expect(extractor.canHandle(Uri.parse('https://mobile.twitter.com/nasa/status/123')), isTrue);
      expect(extractor.canHandle(Uri.parse('https://x.com/i/status/123')), isTrue);
    });

    test('rejects non-status URLs, non-numeric ids and unrelated hosts', () {
      final extractor = buildExtractor();
      expect(extractor.canHandle(Uri.parse('https://x.com/nasa')), isFalse);
      expect(extractor.canHandle(Uri.parse('https://x.com/nasa/status/abc')), isFalse);
      expect(extractor.canHandle(Uri.parse('https://evil.example/status/123')), isFalse);
    });
  });

  group('TwitterExtractor.extract() URL validation', () {
    test('throws UNSUPPORTED_URL for a non-status URL', () async {
      await expectLater(
        buildExtractor().extract(Uri.parse('https://x.com/nasa')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL')),
      );
    });
  });

  group('TwitterExtractor.extractById against a local fake syndication server', () {
    test('sends the Googlebot header and parses a successful response', () async {
      server.body = jsonEncode({
        'id_str': '719944021058060289',
        'text': 'hello',
        'user': {'screen_name': 'CaptainAmerica'},
        'mediaDetails': [
          {
            'media_url_https': 'https://pbs.twimg.com/thumb.jpg',
            'video_info': {
              'duration_millis': 3170,
              'variants': [
                {
                  'content_type': 'video/mp4',
                  'bitrate': 2176000,
                  'url': 'https://video.twimg.com/vid/1280x720/a.mp4',
                },
              ],
            },
          },
        ],
      });

      final info = await buildExtractor().extractById('719944021058060289');
      expect(info.title, 'hello');
      expect(info.formats.single.bitrate, 2176000);
      expect(server.lastUserAgent, 'Googlebot');
      expect(server.lastRequestUri?.path, '/tweet-result');
      expect(server.lastRequestUri?.queryParameters['id'], '719944021058060289');
    });

    test('maps HTTP 404 to NOT_FOUND', () async {
      server.statusCode = 404;
      server.body = 'not json';
      await expectLater(
        buildExtractor().extractById('1'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NOT_FOUND')),
      );
    });

    test('maps HTTP 429 to RATE_LIMITED', () async {
      server.statusCode = 429;
      await expectLater(
        buildExtractor().extractById('1'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'RATE_LIMITED')),
      );
    });

    test('maps an unexpected status code to NETWORK', () async {
      server.statusCode = 500;
      await expectLater(
        buildExtractor().extractById('1'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NETWORK')),
      );
    });

    test('maps a non-JSON 200 body to PARSE_ERROR', () async {
      server.statusCode = 200;
      server.body = 'this is not json';
      await expectLater(
        buildExtractor().extractById('1'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR')),
      );
    });

    test('a card tweet body (no mediaDetails) surfaces as UNSUPPORTED_MEDIA', () async {
      server.body = jsonEncode({'id_str': '1', 'text': 'card tweet', 'user': {'screen_name': 'x'}});
      await expectLater(
        buildExtractor().extractById('1'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_MEDIA')),
      );
    });
  });
}
