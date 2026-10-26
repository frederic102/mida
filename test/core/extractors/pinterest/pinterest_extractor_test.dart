// A loopback TLS handshake per request is cheap, but on a machine busy with
// other test runs the default 30 s per-test limit has been seen to fire, so
// these hermetic suites get headroom. Deadline behavior is tested with the
// client's own (short) timeout, not this limit.
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/pinterest/pinterest_extractor.dart';

import '../native_http/fake_https_server.dart';

Matcher _throwsStatus(String status) =>
    throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', status));

const _apiRoute = 'www.pinterest.com/resource/PinResource/get/';
const _hlsBase = 'v1.pinimg.com/videos/mc/hls/ab/cd/';

String _fx(String name) => fixture('pinterest', name);

void main() {
  late FakeHttpsServer server;

  setUp(() async => server = await FakeHttpsServer.start());
  tearDown(() => server.close());

  PinterestExtractor extractor() => PinterestExtractor(httpClient: server.httpClient('Pinterest'));

  void routeVideoPin() {
    server.route(_apiRoute, FakeRoute(body: _fx('pin_video.json')));
    server.route('${_hlsBase}ramen_v4.m3u8', FakeRoute(body: _fx('ramen_v4.m3u8')));
    server.route('${_hlsBase}ramen_v4_720.m3u8', FakeRoute(body: _fx('media_playlist.m3u8')));
    server.route('${_hlsBase}ramen_v4_480.m3u8', FakeRoute(body: _fx('media_playlist.m3u8')));
  }

  group('PinterestExtractor.canHandle', () {
    test('accepts pin URLs on pinterest hosts and pin.it short links', () {
      final e = PinterestExtractor();
      for (final ok in [
        'https://www.pinterest.com/pin/1234567890123456/',
        'https://pinterest.com/pin/1234567890123456',
        'https://uk.pinterest.com/pin/123/',
        'https://www.pinterest.fr/pin/123/',
        'https://www.pinterest.co.uk/pin/123/',
        'https://www.pinterest.com.au/pin/123/',
        'https://www.pinterest.co.kr/pin/123/',
        'https://pinterest.ru/pin/123/',
        'https://pin.it/AbC123x',
      ]) {
        expect(e.canHandle(Uri.parse(ok)), isTrue, reason: ok);
      }
    });

    test('rejects other shapes, look-alike hosts and non-numeric ids', () {
      final e = PinterestExtractor();
      for (final bad in [
        'https://www.pinterest.com/someuser/someboard/',
        'https://www.pinterest.com/pin/abc/',
        'https://www.pinterest.com/pin/123/extra/',
        'https://evilpinterest.com/pin/123/',
        'https://pinterest.com.evil.test/pin/123/',
        'https://example.com/pin/123/',
        'https://www.pinterest.cn/pin/123/',
        'https://www.pinterest.zz/pin/123/',
        'https://www.pinterest.co.jp/pin/123/',
        'https://api.pinterest.com.evil.test/pin/123/',
        'https://pin.it/',
        'https://pin.it/a/b',
        'https://pin.it/ab',
        'ftp://www.pinterest.com/pin/123/',
      ]) {
        expect(e.canHandle(Uri.parse(bad)), isFalse, reason: bad);
      }
    });
  });

  group('PinterestExtractor.extract (hermetic, loopback TLS)', () {
    test('video pin: metadata, HLS variants, progressive mp4 with https upgrade, exact API request', () async {
      routeVideoPin();

      final info = await extractor().extract(Uri.parse('https://www.pinterest.com/pin/1234567890123456/'));

      expect(info.id, '1234567890123456');
      expect(info.title, 'Slow cooked ramen', reason: 'title wins over grid_title and description');
      expect(info.author, 'Ramen Fan');
      expect(info.thumbnailUrl, 'https://i.pinimg.com/originals/aa/bb/thumb_orig.jpg');
      expect(info.duration, const Duration(milliseconds: 42500));

      final hls = info.formats.where((f) => f.container == 'm3u8').toList();
      expect(hls, hasLength(2), reason: 'two variants of the V_HLSV4 master');
      expect(hls.map((f) => f.height), containsAll([720, 480]));
      final mp4 = info.formats.where((f) => f.container == 'mp4').toList();
      expect(mp4.map((f) => f.id), ['v_720p', 'v_exp4']);
      expect(mp4.first.height, 1280);
      expect(mp4.first.capabilitiesUnknown, isTrue);
      expect(mp4.last.url, startsWith('https://v1.pinimg.com/'), reason: 'http URL from the API is upgraded');
      expect(info.formats.every((f) => f.url.startsWith('https://')), isTrue);
      expect(info.formats.any((f) => f.url.contains('ramen_v3m')), isFalse,
          reason: 'V_HLSV3_MOBILE is only a fallback when V_HLSV4 yields nothing');
      expect(info.requestHeaders['Referer'], 'https://www.pinterest.com/');

      final api = server.requests.first;
      expect(api.host, 'www.pinterest.com');
      expect(api.uri.path, '/resource/PinResource/get/');
      final data = jsonDecode(api.uri.queryParameters['data']!) as Map<String, dynamic>;
      expect(data['options'], {'field_set_key': 'unauth_react_main_pin', 'id': '1234567890123456'});
      expect(api.uri.queryParameters['source_url'], '/pin/1234567890123456/', reason: 'the web client sends the pin path too');
      expect(api.headers.value('x-pinterest-pws-handler'), 'www/pin/[id].js');
      expect(api.headers.value('x-requested-with'), 'XMLHttpRequest');
      expect(api.headers.value('user-agent'), contains('Windows NT 10.0'));
      expect(api.headers.value('cookie'), isNull);
    });

    test('V_HLSV4 playlist unreachable: falls back to V_HLSV3_MOBILE', () async {
      server.route(_apiRoute, FakeRoute(body: _fx('pin_video.json')));
      server.route('${_hlsBase}ramen_v3m.m3u8', FakeRoute(body: _fx('media_playlist.m3u8')));

      final info = await extractor().extract(Uri.parse('https://www.pinterest.com/pin/1234567890123456/'));

      final hls = info.formats.where((f) => f.container == 'm3u8').toList();
      expect(hls.single.url, contains('ramen_v3m'));
      expect(info.formats.where((f) => f.container == 'mp4'), hasLength(2));
    });

    test('story pin: only the first video block is used, never another block', () async {
      server.route(_apiRoute, FakeRoute(body: _fx('pin_story.json')));

      final info = await extractor().extract(Uri.parse('https://pinterest.com/pin/2222222222222222/'));

      expect(info.title, 'Story pin about a garden', reason: 'first description line when no title');
      expect(info.author, 'gardener', reason: 'empty full_name falls back to username');
      expect(info.thumbnailUrl, contains('story736.jpg'));
      expect(info.duration, const Duration(seconds: 15));
      expect(info.formats.single.url, contains('story_p2.mp4'));
      expect(info.formats.single.height, 1920);
      expect(info.formats.any((f) => f.url.contains('must_not_be_used')), isFalse);
    });

    test('image pin: NO_MEDIA_FOUND', () async {
      server.route(_apiRoute, FakeRoute(body: _fx('pin_image.json')));
      await expectLater(
        extractor().extract(Uri.parse('https://www.pinterest.com/pin/3333333333333333/')),
        _throwsStatus('NO_MEDIA_FOUND'),
      );
    });

    test('private pin: LOGIN_REQUIRED; missing pin: NOT_FOUND', () async {
      server.route(_apiRoute, FakeRoute(body: _fx('pin_private.json')));
      await expectLater(extractor().extract(Uri.parse('https://www.pinterest.com/pin/111/')), _throwsStatus('LOGIN_REQUIRED'));
      server.route(_apiRoute, FakeRoute(body: _fx('pin_not_found.json')));
      await expectLater(extractor().extract(Uri.parse('https://www.pinterest.com/pin/111/')), _throwsStatus('NOT_FOUND'));
    });

    test('malformed or wrong-shape answers: PARSE_ERROR', () async {
      for (final name in ['pin_malformed.json', 'pin_wrong_shape.json']) {
        server.route(_apiRoute, FakeRoute(body: _fx(name)));
        await expectLater(
          extractor().extract(Uri.parse('https://www.pinterest.com/pin/4444444444444444/')),
          _throwsStatus('PARSE_ERROR'),
          reason: name,
        );
      }
    });

    test('an incomplete envelope is PARSE_ERROR, never the terminal NOT_FOUND', () async {
      for (final name in ['pin_empty_envelope.json', 'pin_success_no_data.json', 'pin_text_only_not_found.json']) {
        server.route(_apiRoute, FakeRoute(body: _fx(name)));
        await expectLater(extractor().extract(Uri.parse('https://www.pinterest.com/pin/111/')), _throwsStatus('PARSE_ERROR'),
            reason: name);
      }
    });

    test('a structured 403 wins over "not found" wording: CHALLENGE_FAILED (as the transport), never NOT_FOUND', () async {
      server.route(_apiRoute, FakeRoute(body: _fx('pin_403_not_found_text.json')));
      await expectLater(extractor().extract(Uri.parse('https://www.pinterest.com/pin/111/')), _throwsStatus('CHALLENGE_FAILED'));
    });

    test('a 403 whose message says log in / private stays LOGIN_REQUIRED', () async {
      server.route(_apiRoute, FakeRoute(body: _fx('pin_private.json')));
      await expectLater(extractor().extract(Uri.parse('https://www.pinterest.com/pin/111/')), _throwsStatus('LOGIN_REQUIRED'));
    });

    test('media hosts: off-list playlist and mp4 URLs are never requested nor offered', () async {
      server.route(_apiRoute, FakeRoute(body: _fx('pin_offlist.json')));
      server.route('evil.test/hls/x.m3u8', FakeRoute(body: _fx('media_playlist.m3u8')));

      final info = await extractor().extract(Uri.parse('https://www.pinterest.com/pin/6666666666666666/'));

      expect(info.formats.map((f) => f.url), ['https://v1.pinimg.com/videos/mc/expmp4/ok/ok.mp4']);
      expect(server.hosts, ['www.pinterest.com'], reason: 'no request to evil.test or the look-alike host');
    });

    test('media hosts: an HLS playlist that redirects off pinimg.com is refused before the redirect target is requested', () async {
      routeVideoPin();
      server.route('${_hlsBase}ramen_v4.m3u8', const FakeRoute(status: 302, location: 'https://evil.test/ramen.m3u8'));
      server.route('evil.test/ramen.m3u8', FakeRoute(body: _fx('media_playlist.m3u8')));

      final info = await extractor().extract(Uri.parse('https://www.pinterest.com/pin/1234567890123456/'));

      expect(info.formats.where((f) => f.container == 'm3u8'), isEmpty);
      expect(server.hosts.contains('evil.test'), isFalse);
    });

    test('media hosts: an HLS master on pinimg.com listing an off-list variant: that variant is absent and never requested', () async {
      routeVideoPin();
      server.route('${_hlsBase}ramen_v4.m3u8', FakeRoute(body: _fx('master_offlist_variant.m3u8')));
      final info = await extractor().extract(Uri.parse('https://www.pinterest.com/pin/1234567890123456/'));
      expect(info.formats.where((f) => f.container == 'm3u8').map((f) => f.height), [720]);
      expect(server.hosts.contains('evil.test'), isFalse);
    });

    test('an answer for a different pin id is refused, its formats never returned', () async {
      server.route(_apiRoute, FakeRoute(body: _fx('pin_other_id.json')));
      await expectLater(
        extractor().extract(Uri.parse('https://www.pinterest.com/pin/1234567890123456/')),
        _throwsStatus('PARSE_ERROR'),
      );
    });

    test('DRM-flagged HLS and nothing else: DRM_PROTECTED', () async {
      server.route(_apiRoute, FakeRoute(body: _fx('pin_drm.json')));
      server.route('v1.pinimg.com/videos/mc/hls/dr/m0/drm_master.m3u8', FakeRoute(body: _fx('drm_master.m3u8')));
      await expectLater(
        extractor().extract(Uri.parse('https://www.pinterest.com/pin/5555555555555555/')),
        _throwsStatus('DRM_PROTECTED'),
      );
    });

    test('HTTP statuses map to the shared table', () async {
      const expected = {404: 'NOT_FOUND', 410: 'NOT_FOUND', 429: 'RATE_LIMITED', 403: 'CHALLENGE_FAILED', 401: 'CHALLENGE_FAILED', 500: 'NETWORK'};
      for (final entry in expected.entries) {
        server.route(_apiRoute, FakeRoute(status: entry.key, body: '{}'));
        await expectLater(
          extractor().extract(Uri.parse('https://www.pinterest.com/pin/111/')),
          _throwsStatus(entry.value),
          reason: 'HTTP ${entry.key}',
        );
      }
    });

    test('an oversized answer is not parsed as if it were whole', () async {
      final pad = 'a' * (2 * 1024 * 1024 + 100);
      server.route(_apiRoute, FakeRoute(body: '{"resource_response":{"status":"success","data":{"pad":"$pad"}}}'));
      await expectLater(extractor().extract(Uri.parse('https://www.pinterest.com/pin/111/')), _throwsStatus('PARSE_ERROR'));
    });
  });

  group('PinterestExtractor short links', () {
    test('pin.it/<code> resolves through Location to the pin id, then calls the API only', () async {
      routeVideoPin();
      server.route(
        'pin.it/AbC123x',
        const FakeRoute(status: 302, location: 'https://www.pinterest.com/pin/1234567890123456/sent/?invite_code=zz&sfo=1'),
      );

      final info = await extractor().extract(Uri.parse('https://pin.it/AbC123x'));

      expect(info.id, '1234567890123456');
      expect(server.requests.first.host, 'pin.it');
      expect(server.requests[1].uri.path, '/resource/PinResource/get/', reason: 'the landing page is never fetched');
      expect(server.requests.where((r) => r.uri.path.startsWith('/pin/')), isEmpty);
    });

    test('a short link that lands off Pinterest is refused without requesting the target', () async {
      server.route('pin.it/Evil123', const FakeRoute(status: 302, location: 'https://evil.test/pin/1234567890123456/'));
      server.route('evil.test/pin/1234567890123456/', const FakeRoute(body: 'x'));
      await expectLater(extractor().extract(Uri.parse('https://pin.it/Evil123')), _throwsStatus('PARSE_ERROR'));
      expect(server.hosts, ['pin.it']);
    });

    test('a short link that lands on a pinterest page that is not a pin is refused', () async {
      server.route('pin.it/Board12', const FakeRoute(status: 302, location: 'https://www.pinterest.com/someone/board/'));
      server.route('www.pinterest.com/someone/board/', const FakeRoute(body: 'a board page'));
      await expectLater(extractor().extract(Uri.parse('https://pin.it/Board12')), _throwsStatus('PARSE_ERROR'));
      expect(server.requests.any((r) => r.uri.path.contains('PinResource')), isFalse, reason: 'never reaches the API');
    });

    test('the real chain pin.it -> api.pinterest.com redirector -> pin resolves, each hop requested once', () async {
      routeVideoPin();
      server.route('pin.it/Chain12', const FakeRoute(status: 302, location: 'https://api.pinterest.com/url_shortener/Chain12/redirect/'));
      server.route(
        'api.pinterest.com/url_shortener/Chain12/redirect/',
        const FakeRoute(status: 302, location: 'https://www.pinterest.com/pin/1234567890123456/sent/?invite_code=zz'),
      );

      final info = await extractor().extract(Uri.parse('https://pin.it/Chain12'));

      expect(info.id, '1234567890123456');
      expect(server.hosts.take(3), ['pin.it', 'api.pinterest.com', 'www.pinterest.com']);
      expect(server.requests[2].uri.path, '/resource/PinResource/get/');
    });

    test('a chain that leaves Pinterest-owned hosts mid-way never requests the off-list host', () async {
      server.route('pin.it/Chain34', const FakeRoute(status: 302, location: 'https://api.pinterest.com/url_shortener/Chain34/redirect/'));
      server.route('api.pinterest.com/url_shortener/Chain34/redirect/', const FakeRoute(status: 302, location: 'https://evil.test/pin/1234567890123456/'));
      server.route('evil.test/pin/1234567890123456/', const FakeRoute(body: 'x'));
      await expectLater(extractor().extract(Uri.parse('https://pin.it/Chain34')), _throwsStatus('PARSE_ERROR'));
      expect(server.hosts, ['pin.it', 'api.pinterest.com']);
    });

    test('more than three Location hops are refused', () async {
      server.route('pin.it/Loop123', const FakeRoute(status: 302, location: 'https://api.pinterest.com/a'));
      server.route('api.pinterest.com/a', const FakeRoute(status: 302, location: 'https://api.pinterest.com/b'));
      server.route('api.pinterest.com/b', const FakeRoute(status: 302, location: 'https://api.pinterest.com/c'));
      server.route('api.pinterest.com/c', const FakeRoute(status: 302, location: 'https://www.pinterest.com/pin/1234567890123456/'));
      await expectLater(extractor().extract(Uri.parse('https://pin.it/Loop123')), _throwsStatus('PARSE_ERROR'));
      expect(server.hosts, ['pin.it', 'api.pinterest.com', 'api.pinterest.com'], reason: 'the third intermediate hop is never requested');
    });

    test('a short link redirecting to plain http is refused (no downgrade)', () async {
      server.route('pin.it/Down123', const FakeRoute(status: 302, location: 'http://www.pinterest.com/pin/1234567890123456/'));
      await expectLater(extractor().extract(Uri.parse('https://pin.it/Down123')), _throwsStatus('UNSUPPORTED_URL'));
      expect(server.hosts, ['pin.it']);
    });

    test('an expired short link (404) is NOT_FOUND', () async {
      await expectLater(extractor().extract(Uri.parse('https://pin.it/Gone123')), _throwsStatus('NOT_FOUND'));
    });
  });
}
