import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/soundcloud/soundcloud_extractor.dart';

/// Single local server backing every request this extractor makes (page,
/// script bundle, transcoding resolution), routed by path.
class _FakeSoundCloudServer {
  final HttpServer server;
  String pageHtml = '';
  String scriptBody = '';
  Map<String, String> transcodingResponses = {};

  _FakeSoundCloudServer(this.server);

  static Future<_FakeSoundCloudServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _FakeSoundCloudServer(server);
    server.listen(instance._handle);
    return instance;
  }

  Uri get baseUri => Uri(scheme: 'http', host: '127.0.0.1', port: server.port);

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path == '/bundle.js') {
      request.response.write(scriptBody);
      await request.response.close();
      return;
    }
    if (request.uri.path.startsWith('/resolve/')) {
      final key = request.uri.path.substring('/resolve/'.length);
      request.response.write(transcodingResponses[key] ?? '{}');
      await request.response.close();
      return;
    }
    request.response.write(pageHtml);
    await request.response.close();
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  late _FakeSoundCloudServer server;

  setUp(() async => server = await _FakeSoundCloudServer.start());
  tearDown(() => server.close());

  SoundCloudExtractor buildExtractor() => SoundCloudExtractor(
        pageRequestUrlBuilder: (url) => server.baseUri.replace(path: url.path),
        transcodingRequestUrlBuilder: (url) =>
            server.baseUri.replace(path: '/resolve${Uri.parse(url.path).path}', query: url.query),
      );

  group('SoundCloudExtractor.canHandle', () {
    test('accepts a two-segment track URL and rejects reserved routes', () {
      final extractor = buildExtractor();
      expect(
        extractor.canHandle(Uri.parse('https://soundcloud.com/officialrickastley/never-gonna-give-you-up-7')),
        isTrue,
      );
      expect(extractor.canHandle(Uri.parse('https://soundcloud.com/search/sounds?q=x')), isFalse);
      expect(extractor.canHandle(Uri.parse('https://soundcloud.com/officialrickastley')), isFalse);
    });
  });

  group('SoundCloudExtractor.extract against local fake page/script/resolve servers', () {
    test('resolves hydration + client_id + transcodings into playable formats', () async {
      final progressiveUrl = '${server.baseUri}/media/progressive';
      final hlsUrl = '${server.baseUri}/media/hls';
      server.pageHtml = '<html><head>'
          '<script crossorigin src="${server.baseUri.replace(path: '/bundle.js')}"></script>'
          '</head><body><script>window.__sc_hydration = ${jsonEncode([
            {
              'hydratable': 'sound',
              'data': {
                'id': 1,
                'title': 'Track title',
                'duration': 5000,
                'artwork_url': 'https://i1.sndcdn.com/art.jpg',
                'user': {'username': 'artist'},
                'media': {
                  'transcodings': [
                    {
                      'url': progressiveUrl,
                      'format': {'protocol': 'progressive', 'mime_type': 'audio/mpeg'},
                    },
                    {
                      'url': hlsUrl,
                      'format': {'protocol': 'hls', 'mime_type': 'audio/mpeg'},
                    },
                  ],
                },
              },
            },
          ])}; </script></body></html>';
      server.scriptBody = 'x={client_id:"AbCdEf0123456789AbCdEf0123456789"}';
      server.transcodingResponses = {
        'media/progressive': jsonEncode({'url': 'https://cf-media.sndcdn.com/progressive-signed.mp3'}),
        'media/hls': jsonEncode({'url': 'https://cf-hls-media.sndcdn.com/hls-signed.m3u8'}),
      };

      final info = await buildExtractor().extract(
        Uri.parse('https://soundcloud.com/artist/track-title'),
      );
      expect(info.id, '1');
      expect(info.title, 'Track title');
      expect(info.author, 'artist');
      expect(info.duration, const Duration(milliseconds: 5000));
      expect(info.formats, hasLength(2));
      expect(info.formats.any((f) => f.container == 'mp3'), isTrue);
      expect(info.formats.any((f) => f.container == 'm3u8'), isTrue);
      expect(info.formats.every((f) => f.isAudioOnly), isTrue);
    });

    test('throws PARSE_ERROR when the page has no __sc_hydration blob', () async {
      server.pageHtml = '<html><body>nothing here</body></html>';
      await expectLater(
        buildExtractor().extract(Uri.parse('https://soundcloud.com/artist/track-title')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR')),
      );
    });
  });
}
