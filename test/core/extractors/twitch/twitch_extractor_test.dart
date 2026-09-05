import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/twitch/twitch_extractor.dart';
import 'package:mida/core/extractors/twitch/twitch_gql_client.dart';

/// One local server per real Twitch host this extractor talks to
/// (`www.twitch.tv` for the page, `gql.twitch.tv` for GraphQL,
/// `usher.ttvnw.net` for the master playlist) - each independently
/// injectable on [TwitchExtractor], same seam pattern as
/// `TwitterExtractor.endpointBuilder`.
class _FixedResponseServer {
  final HttpServer server;
  int statusCode = 200;
  String body = '';

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

void main() {
  late _FixedResponseServer pageServer;
  late _FixedResponseServer gqlServer;
  late _FixedResponseServer usherServer;

  setUp(() async {
    pageServer = await _FixedResponseServer.start();
    gqlServer = await _FixedResponseServer.start();
    usherServer = await _FixedResponseServer.start();
  });
  tearDown(() async {
    await pageServer.close();
    await gqlServer.close();
    await usherServer.close();
  });

  TwitchExtractor buildExtractor() => TwitchExtractor(
        gqlClient: TwitchGqlClient(endpointBuilder: (path) => gqlServer.baseUri.replace(path: path)),
        pageRequestUrlBuilder: (url) => pageServer.baseUri.replace(path: url.path),
        usherRequestUrlBuilder: (url) => usherServer.baseUri.replace(path: url.path, query: url.query),
      );

  group('TwitchExtractor.canHandle', () {
    test('accepts VOD URLs and clip URLs on both hosts', () {
      final extractor = buildExtractor();
      expect(extractor.canHandle(Uri.parse('https://www.twitch.tv/videos/2863640137')), isTrue);
      expect(extractor.canHandle(Uri.parse('https://clips.twitch.tv/InsaneClip')), isTrue);
      expect(extractor.canHandle(Uri.parse('https://www.twitch.tv/shroud/clip/InsaneClip')), isTrue);
    });

    test('rejects channel/videos-index/unrelated-host URLs', () {
      final extractor = buildExtractor();
      expect(extractor.canHandle(Uri.parse('https://www.twitch.tv/shroud')), isFalse);
      expect(extractor.canHandle(Uri.parse('https://evil.example/videos/123')), isFalse);
    });
  });

  group('TwitchExtractor.extract VOD path against local fake servers', () {
    test('parses page meta + playback token + usher playlist into a MediaInfo', () async {
      pageServer.body = '<meta property="og:title" content="cool stream - shroud on Twitch">'
          '<meta property="og:image" content="https://static-cdn.jtvnw.net/thumb.jpg">'
          '<meta property="og:video:duration" content="120">';
      gqlServer.body = jsonEncode({
        'data': {
          'videoPlaybackAccessToken': {'value': 'tokval', 'signature': 'tokssig'},
        },
      });
      usherServer.body = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=100,CODECS="avc1.4D401F,mp4a.40.2",RESOLUTION=640x360\n'
          'https://cdn.example/chunked/index-dvr.m3u8\n';

      final info = await buildExtractor().extract(Uri.parse('https://www.twitch.tv/videos/123'));
      expect(info.id, '123');
      expect(info.title, 'cool stream');
      expect(info.author, 'shroud');
      expect(info.duration, const Duration(seconds: 120));
      expect(info.formats, hasLength(1));
      expect(info.formats.single.container, 'm3u8');
    });

    test('throws CHALLENGE_FAILED (fall-through eligible) when videoPlaybackAccessToken is null', () async {
      pageServer.body = '<meta property="og:title" content="x - y on Twitch">';
      gqlServer.body = jsonEncode({
        'data': {'videoPlaybackAccessToken': null},
      });

      await expectLater(
        buildExtractor().extract(Uri.parse('https://www.twitch.tv/videos/999')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'CHALLENGE_FAILED')),
      );
    });

    test('maps a page 404 to NETWORK (fall-through eligible), not terminal NOT_FOUND', () async {
      // Guard-can-fail: a bare 404 here must not be trusted as
      // authoritative - Twitch's real watch page answers 200 even for a
      // nonexistent VOD id (see TwitchExtractor._fetchPageMeta's doc), so
      // a 404 is more likely an intermediary/WAF than Twitch itself.
      pageServer.statusCode = 404;
      await expectLater(
        buildExtractor().extract(Uri.parse('https://www.twitch.tv/videos/999')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NETWORK')),
      );
    });
  });
}
