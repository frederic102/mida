import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/reddit/reddit_extractor.dart';

/// Single local server standing in for both `www.reddit.com` (the
/// `.json` listing) and `v.redd.it` (the DASH manifest), routed by path -
/// [RedditExtractor] hits both through independently overridable
/// `Uri Function(Uri)` builders, so one fake server can back both.
class _FakeRedditServer {
  final HttpServer server;
  String listingBody = '[]';
  String dashBody = '<MPD></MPD>';
  int listingStatusCode = 200;
  int dashStatusCode = 200;
  String? listingContentType;

  _FakeRedditServer(this.server);

  static Future<_FakeRedditServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _FakeRedditServer(server);
    server.listen(instance._handle);
    return instance;
  }

  Uri get baseUri => Uri(scheme: 'http', host: '127.0.0.1', port: server.port);

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path.endsWith('.mpd')) {
      request.response.statusCode = dashStatusCode;
      request.response.write(dashBody);
      await request.response.close();
      return;
    }
    request.response.statusCode = listingStatusCode;
    if (listingContentType != null) {
      request.response.headers.contentType = ContentType.parse(listingContentType!);
    }
    request.response.write(listingBody);
    await request.response.close();
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  late _FakeRedditServer server;

  setUp(() async => server = await _FakeRedditServer.start());
  tearDown(() => server.close());

  RedditExtractor buildExtractor() => RedditExtractor(
        listingRequestUrlBuilder: (url) => server.baseUri.replace(path: url.path, query: url.query),
        dashRequestUrlBuilder: (url) => server.baseUri.replace(path: url.path),
      );

  group('RedditExtractor.canHandle', () {
    test('accepts /r/<sub>/comments/<id> URLs', () {
      final extractor = buildExtractor();
      expect(
        extractor.canHandle(Uri.parse('https://www.reddit.com/r/aww/comments/1c0xhqk/some_title/')),
        isTrue,
      );
    });

    test('rejects subreddit-listing and unrelated-host URLs', () {
      final extractor = buildExtractor();
      expect(extractor.canHandle(Uri.parse('https://www.reddit.com/r/aww/')), isFalse);
      expect(extractor.canHandle(Uri.parse('https://evil.example/r/aww/comments/1/x/')), isFalse);
    });
  });

  group('RedditExtractor.extract against local fake listing + DASH servers', () {
    test('resolves a video post end to end into video-only + audio-only formats', () async {
      server.listingBody = '''
        [
          {"data": {"children": [
            {"data": {
              "id": "1c0xhqk",
              "title": "My dog discovers snow",
              "author": "example_user",
              "secure_media": {"reddit_video": {
                "dash_url": "https://v.redd.it/abc123/DASHPlaylist.mpd",
                "duration": 14
              }}
            }}
          ]}}
        ]
      ''';
      server.dashBody = '''
        <MPD>
          <Period>
            <AdaptationSet mimeType="video/mp4">
              <Representation id="0" bandwidth="4500000" width="1280" height="720" codecs="avc1.640028">
                <BaseURL>DASH_720.mp4</BaseURL>
              </Representation>
            </AdaptationSet>
            <AdaptationSet mimeType="audio/mp4">
              <Representation id="a" bandwidth="128000" codecs="mp4a.40.2">
                <BaseURL>DASH_audio.mp4</BaseURL>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
      ''';

      final info = await buildExtractor().extract(
        Uri.parse('https://www.reddit.com/r/aww/comments/1c0xhqk/my_dog/'),
      );
      expect(info.id, '1c0xhqk');
      expect(info.title, 'My dog discovers snow');
      expect(info.duration, const Duration(seconds: 14));
      expect(info.formats, hasLength(2));
      expect(info.formats.any((f) => f.isVideoOnly), isTrue);
      expect(info.formats.any((f) => f.isAudioOnly), isTrue);
    });

    test('maps HTTP 403 on the listing to CHALLENGE_FAILED', () async {
      server.listingStatusCode = 403;
      await expectLater(
        buildExtractor().extract(Uri.parse('https://www.reddit.com/r/aww/comments/1/x/')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'CHALLENGE_FAILED')),
      );
    });

    test('maps a JSON-content-type 404 listing to NOT_FOUND', () async {
      server.listingStatusCode = 404;
      server.listingContentType = 'application/json; charset=utf-8';
      server.listingBody = '{"message": "Not Found", "error": 404}';
      await expectLater(
        buildExtractor().extract(Uri.parse('https://www.reddit.com/r/aww/comments/1/x/')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NOT_FOUND')),
      );
    });

    test('maps an HTML-content-type 404 listing (WAF shell) to CHALLENGE_FAILED, not NOT_FOUND', () async {
      // Guard-can-fail: a WAF/proxy synthesizing a bare 404 with its own
      // HTML page must not be mistaken for Reddit's own "not found".
      server.listingStatusCode = 404;
      server.listingContentType = 'text/html; charset=utf-8';
      server.listingBody = '<html><body>blocked</body></html>';
      await expectLater(
        buildExtractor().extract(Uri.parse('https://www.reddit.com/r/aww/comments/1/x/')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'CHALLENGE_FAILED')),
      );
    });

    test('maps a DASH manifest 404 to CHALLENGE_FAILED (fall-through eligible), never NOT_FOUND', () async {
      server.listingBody = '''
        [
          {"data": {"children": [
            {"data": {
              "id": "1c0xhqk",
              "title": "My dog discovers snow",
              "secure_media": {"reddit_video": {"dash_url": "https://v.redd.it/abc123/DASHPlaylist.mpd"}}
            }}
          ]}}
        ]
      ''';
      server.dashStatusCode = 404;
      await expectLater(
        buildExtractor().extract(Uri.parse('https://www.reddit.com/r/aww/comments/1c0xhqk/my_dog/')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'CHALLENGE_FAILED')),
      );
    });

    test('throws UNSUPPORTED_MEDIA for a non-video post', () async {
      server.listingBody = '''
        [{"data": {"children": [{"data": {"id": "1", "title": "text post"}}]}}]
      ''';
      await expectLater(
        buildExtractor().extract(Uri.parse('https://www.reddit.com/r/aww/comments/1/x/')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_MEDIA')),
      );
    });
  });
}
