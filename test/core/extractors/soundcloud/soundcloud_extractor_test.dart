import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/soundcloud/soundcloud_client_id_resolver.dart';
import 'package:mida/core/extractors/soundcloud/soundcloud_extractor.dart';

/// Single local server backing every request this extractor makes (the
/// client_id page + script scan, the resolve API, and each transcoding
/// resolution), routed by path.
class _FakeSoundCloudServer {
  final HttpServer server;
  String pageHtml = '';
  String scriptBody = '';
  String resolveBody = '{}';
  int resolveStatusCode = 200;
  String? resolveContentType;
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
    if (request.uri.path == '/resolve') {
      request.response.statusCode = resolveStatusCode;
      if (resolveContentType != null) {
        request.response.headers.contentType = ContentType.parse(resolveContentType!);
      }
      request.response.write(resolveBody);
      await request.response.close();
      return;
    }
    if (request.uri.path.startsWith('/media/')) {
      final key = request.uri.path.substring('/media/'.length);
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

  setUp(() async {
    server = await _FakeSoundCloudServer.start();
    SoundCloudClientIdResolver.reset();
  });
  tearDown(() => server.close());

  SoundCloudExtractor buildExtractor() => SoundCloudExtractor(
        clientIdResolver: SoundCloudClientIdResolver(
          pageRequestUrlBuilder: (url) => server.baseUri.replace(path: url.path),
          scriptRequestUrlBuilder: (url) => server.baseUri.replace(path: '/bundle.js'),
        ),
        resolveRequestUrlBuilder: (url) => server.baseUri.replace(path: '/resolve', query: url.query),
        transcodingRequestUrlBuilder: (url) =>
            server.baseUri.replace(path: '/media${Uri.parse(url.path).path}', query: url.query),
      );

  group('SoundCloudExtractor.canHandle', () {
    test('accepts a two-segment track URL and rejects reserved routes', () {
      final extractor = buildExtractor();
      expect(
        extractor.canHandle(Uri.parse('https://soundcloud.com/rick-astley-official/never-gonna-give-you-up')),
        isTrue,
      );
      expect(extractor.canHandle(Uri.parse('https://soundcloud.com/search/sounds?q=x')), isFalse);
      expect(extractor.canHandle(Uri.parse('https://soundcloud.com/rick-astley-official')), isFalse);
    });

    test('accepts www. and m. subdomains and the bare host', () {
      final extractor = buildExtractor();
      expect(
        extractor.canHandle(Uri.parse('https://www.soundcloud.com/rick-astley-official/never-gonna-give-you-up')),
        isTrue,
      );
      expect(
        extractor.canHandle(Uri.parse('https://m.soundcloud.com/rick-astley-official/never-gonna-give-you-up')),
        isTrue,
      );
      expect(
        extractor.canHandle(Uri.parse('https://soundcloud.com/rick-astley-official/never-gonna-give-you-up')),
        isTrue,
      );
    });
  });

  group('SoundCloudExtractor.extract against local fake client-id/resolve/media servers', () {
    test('resolves client_id, the track, and each transcoding into playable audio-only formats', () async {
      server.pageHtml = '<script crossorigin src="${server.baseUri.replace(path: '/bundle.js')}"></script>';
      server.scriptBody = 'x={client_id:"AbCdEf0123456789AbCdEf0123456789"}';
      server.resolveBody = jsonEncode({
        'id': 253508261,
        'title': 'Never Gonna Give You Up',
        'full_duration': 213603,
        'artwork_url': 'https://i1.sndcdn.com/artworks-EXAMPLE-large.jpg',
        'user': {'username': 'Rick Astley'},
        'media': {
          'transcodings': [
            {
              'url': '${server.baseUri}/progressive',
              'format': {'protocol': 'progressive', 'mime_type': 'audio/mpeg'},
            },
            {
              'url': '${server.baseUri}/hls',
              'format': {'protocol': 'hls', 'mime_type': 'audio/mpeg'},
            },
          ],
        },
      });
      server.transcodingResponses = {
        'progressive': jsonEncode({'url': 'https://cf-media.sndcdn.com/progressive-signed.mp3'}),
        'hls': jsonEncode({'url': 'https://cf-hls-media.sndcdn.com/hls-signed.m3u8'}),
      };

      final info = await buildExtractor().extract(
        Uri.parse('https://soundcloud.com/rick-astley-official/never-gonna-give-you-up'),
      );
      expect(info.id, '253508261');
      expect(info.title, 'Never Gonna Give You Up');
      expect(info.author, 'Rick Astley');
      expect(info.duration, const Duration(milliseconds: 213603));
      expect(info.formats, hasLength(2));
      expect(info.formats.any((f) => f.container == 'mp3'), isTrue);
      expect(info.formats.any((f) => f.container == 'm3u8'), isTrue);
      expect(info.formats.every((f) => f.isAudioOnly), isTrue);
    });

    test('maps a JSON-content-type 404 resolve response to NOT_FOUND', () async {
      server.pageHtml = '<script crossorigin src="${server.baseUri.replace(path: '/bundle.js')}"></script>';
      server.scriptBody = 'x={client_id:"AbCdEf0123456789AbCdEf0123456789"}';
      server.resolveStatusCode = 404;
      server.resolveContentType = 'application/json; charset=utf-8';
      server.resolveBody = '{}'; // the real shape verified live for this endpoint

      await expectLater(
        buildExtractor().extract(Uri.parse('https://soundcloud.com/rick-astley-official/gone')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NOT_FOUND')),
      );
    });

    test('maps an HTML-content-type 404 resolve response to CHALLENGE_FAILED, not NOT_FOUND', () async {
      // Guard-can-fail: a WAF/proxy synthesizing a bare 404 with its own
      // HTML page must not be mistaken for SoundCloud's own "not found".
      server.pageHtml = '<script crossorigin src="${server.baseUri.replace(path: '/bundle.js')}"></script>';
      server.scriptBody = 'x={client_id:"AbCdEf0123456789AbCdEf0123456789"}';
      server.resolveStatusCode = 404;
      server.resolveContentType = 'text/html; charset=utf-8';
      server.resolveBody = '<html><body>blocked</body></html>';

      await expectLater(
        buildExtractor().extract(Uri.parse('https://soundcloud.com/rick-astley-official/gone')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'CHALLENGE_FAILED')),
      );
    });

    test('throws PARSE_ERROR (fall-through eligible), not UNSUPPORTED_MEDIA, when every '
        'transcoding-resolve call fails despite the track having real transcodings', () async {
      // Guard-can-fail: reverting the fix (throwing UNSUPPORTED_MEDIA
      // here instead) makes this test fail - this is exactly the
      // registry-gate bug reported live: a track with real
      // media.transcodings whose per-rendition resolve calls all fail
      // (rejected client_id, transient network error) must not be
      // treated the same as SoundCloudTrackParser's genuinely-empty-list
      // terminal case.
      server.pageHtml = '<script crossorigin src="${server.baseUri.replace(path: '/bundle.js')}"></script>';
      server.scriptBody = 'x={client_id:"AbCdEf0123456789AbCdEf0123456789"}';
      server.resolveBody = jsonEncode({
        'id': 1,
        'title': 't',
        'media': {
          'transcodings': [
            {
              'url': '${server.baseUri}/progressive',
              'format': {'protocol': 'progressive', 'mime_type': 'audio/mpeg'},
            },
          ],
        },
      });
      server.transcodingResponses = {'progressive': 'not json'}; // every resolve call fails to parse

      await expectLater(
        buildExtractor().extract(Uri.parse('https://soundcloud.com/rick-astley-official/never-gonna-give-you-up-7')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR')),
      );
    });
  });
}
