import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/streamable/streamable_extractor.dart';
import 'package:mida/core/extractors/streamable/streamable_url_matcher.dart';

import '../native_http/fake_https_server.dart';

Matcher _throwsStatus(String status) =>
    throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', status));

String _f(String name) => fixture('streamable', name);

void main() {
  late FakeHttpsServer server;

  setUp(() async => server = await FakeHttpsServer.start());
  tearDown(() => server.close());

  StreamableExtractor extractor() => StreamableExtractor(httpClient: server.httpClient('Streamable', timeout: const Duration(seconds: 30)));

  group('StreamableExtractor.extract (hermetic, loopback TLS)', () {
    test('ready video: mp4 and mp4-mobile with dimensions, protocol-relative URLs forced to https', () async {
      server.route('api.streamable.com/videos/abc12', FakeRoute(body: _f('streamable_video.json')));

      final info = await extractor().extract(Uri.parse('https://streamable.com/abc12'));

      expect(info.id, 'abc12');
      expect(info.title, 'Demo goal');
      expect(info.duration, const Duration(milliseconds: 12480));
      expect(info.thumbnailUrl, 'https://cdn-cf-east.streamable.com/image/abc12.jpg?Expires=1&Signature=s');
      expect(info.formats.map((f) => f.id), ['mp4', 'mp4-mobile'], reason: 'the original-quality key is not offered');
      final hd = info.formats.first;
      expect(hd.url, 'https://cdn-cf-east.streamable.com/video/mp4/abc12.mp4?Expires=1&Signature=a');
      expect([hd.width, hd.height, hd.fps, hd.bitrate, hd.contentLength], [1280, 720, 30.0, 2500000, 3500000]);
      expect(hd.container, 'mp4');
      expect(hd.isMuxed, isTrue);
      expect(hd.capabilitiesUnknown, isTrue);
      expect(info.formats.last.height, 360);
      expect(info.requestHeaders['User-Agent'], contains('Windows NT 10.0'));

      final seen = server.requests.single;
      expect(seen.host, 'api.streamable.com');
      expect(seen.uri.path, '/videos/abc12');
      expect(seen.headers.value('cookie'), isNull);
    });

    test('embed URL form resolves the same code', () async {
      server.route('api.streamable.com/videos/abc12', FakeRoute(body: _f('streamable_video.json')));
      final info = await extractor().extract(Uri.parse('https://streamable.com/e/abc12?autoplay=1'));
      expect(info.id, 'abc12');
      expect(server.requests.single.uri.hasQuery, isFalse);
    });

    test('only the files that are ready are offered', () async {
      server.route('api.streamable.com/videos/part1', FakeRoute(body: _f('streamable_partial_files.json')));
      final info = await extractor().extract(Uri.parse('https://streamable.com/part1'));
      expect(info.formats.map((f) => f.id), ['mp4']);
      expect(info.title, 'One rendition pending');
    });

    test('status other than 2 is PARSE_ERROR saying the video is still processing', () async {
      server.route('api.streamable.com/videos/slow1', FakeRoute(body: _f('streamable_processing.json')));
      server.route('api.streamable.com/videos/bad11', FakeRoute(body: _f('streamable_failed.json')));
      for (final code in ['slow1', 'bad11']) {
        await expectLater(
          extractor().extract(Uri.parse('https://streamable.com/$code')),
          throwsA(isA<MediaExtractionException>()
              .having((e) => e.status, 'status', 'PARSE_ERROR')
              .having((e) => e.reason, 'reason', contains('still processing'))),
          reason: code,
        );
      }
    });

    test('files on hosts outside streamable.com are refused; a mixed answer keeps only the on-list file', () async {
      server.route('api.streamable.com/videos/offl1', FakeRoute(body: _f('streamable_offlist.json')));
      server.route('api.streamable.com/videos/mixd1', FakeRoute(body: _f('streamable_mixed_hosts.json')));
      // Flip-proof: dropping withMediaHosts/mediaUrlAllowed offers evil.test.
      await expectLater(extractor().extract(Uri.parse('https://streamable.com/offl1')), _throwsStatus('PARSE_ERROR'));
      final mixed = await extractor().extract(Uri.parse('https://streamable.com/mixd1'));
      expect(mixed.formats.map((f) => f.id), ['mp4-mobile']);
      expect(mixed.thumbnailUrl, isNull, reason: 'off-list thumbnail dropped');
    });

    test('HTTP 404 is NOT_FOUND', () async {
      server.route('api.streamable.com/videos/gone1', FakeRoute(status: 404, body: _f('streamable_not_found.json')));
      await expectLater(extractor().extract(Uri.parse('https://streamable.com/gone1')), _throwsStatus('NOT_FOUND'));
    });

    test('ready but no usable file is NO_MEDIA_FOUND', () async {
      server.route('api.streamable.com/videos/empt1', FakeRoute(body: _f('streamable_no_files.json')));
      await expectLater(extractor().extract(Uri.parse('https://streamable.com/empt1')), _throwsStatus('NO_MEDIA_FOUND'));
    });

    test('unknown shape and malformed JSON are PARSE_ERROR', () async {
      server.route('api.streamable.com/videos/unkn1', FakeRoute(body: _f('streamable_unknown_shape.json')));
      server.route('api.streamable.com/videos/malf1', FakeRoute(body: _f('streamable_malformed.json')));
      server.route('api.streamable.com/videos/list1', const FakeRoute(body: '[1,2]'));
      for (final code in ['unkn1', 'malf1', 'list1']) {
        await expectLater(extractor().extract(Uri.parse('https://streamable.com/$code')), _throwsStatus('PARSE_ERROR'),
            reason: code);
      }
    });

    test('429 is RATE_LIMITED, 403 CHALLENGE_FAILED, 500 NETWORK', () async {
      server.route('api.streamable.com/videos/rate1', const FakeRoute(status: 429));
      server.route('api.streamable.com/videos/forb1', const FakeRoute(status: 403, body: 'denied'));
      server.route('api.streamable.com/videos/boom1', const FakeRoute(status: 500));
      await expectLater(extractor().extract(Uri.parse('https://streamable.com/rate1')), _throwsStatus('RATE_LIMITED'));
      await expectLater(extractor().extract(Uri.parse('https://streamable.com/forb1')), _throwsStatus('CHALLENGE_FAILED'));
      await expectLater(extractor().extract(Uri.parse('https://streamable.com/boom1')), _throwsStatus('NETWORK'));
    });

    test('an API redirect to plain http or to another site is refused without requesting it', () async {
      server.route('api.streamable.com/videos/down1', const FakeRoute(status: 302, location: 'http://api.streamable.com/videos/x'));
      server.route('api.streamable.com/videos/offs1', const FakeRoute(status: 302, location: 'https://evil.test/videos/x'));
      await expectLater(extractor().extract(Uri.parse('https://streamable.com/down1')), _throwsStatus('UNSUPPORTED_URL'));
      await expectLater(extractor().extract(Uri.parse('https://streamable.com/offs1')), _throwsStatus('PARSE_ERROR'));
      expect(server.hosts, ['api.streamable.com', 'api.streamable.com']);
    });
  });

  group('StreamableUrlMatcher', () {
    test('accepts video and embed codes only', () {
      expect(StreamableUrlMatcher.match(Uri.parse('https://streamable.com/abc12')), 'abc12');
      expect(StreamableUrlMatcher.match(Uri.parse('https://www.streamable.com/e/abc12/')), 'abc12');
      expect(StreamableUrlMatcher.match(Uri.parse('http://streamable.com/AbC123')), 'AbC123');
      for (final input in [
        'https://streamable.com/',
        'https://streamable.com/login',
        'https://streamable.com/about',
        'https://streamable.com/abc',
        'https://streamable.com/abcdefghijk',
        'https://streamable.com/ab-cd',
        'https://streamable.com/abc12/extra',
        'https://streamable.com/e/abc12/extra',
        'https://streamable.com/x/abc12',
        'https://streamable.com/abc12%2F..%2Fx',
        'https://api.streamable.com/abc12',
        'https://streamable.com.evil.test/abc12',
        'ftp://streamable.com/abc12',
      ]) {
        expect(StreamableUrlMatcher.match(Uri.parse(input)), isNull, reason: input);
      }
    });
  });
}
