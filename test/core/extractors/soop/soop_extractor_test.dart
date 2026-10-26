// A loopback TLS handshake per request is cheap, but on a machine busy with
// other test runs the default 30 s per-test limit has been seen to fire, so
// these hermetic suites get headroom. Deadline behavior is tested with the
// client's own (short) timeout, not this limit.
@Timeout(Duration(minutes: 3))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/soop/soop_extractor.dart';

import '../native_http/fake_https_server.dart';

Matcher _throwsStatus(String status) =>
    throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', status));

const _api = 'api.m.sooplive.co.kr/station/video/a/view';
const _cdn = 'vod-archive.sooplive.co.kr/vod/';

String _fx(String name) => fixture('soop', name);

void main() {
  late FakeHttpsServer server;

  setUp(() async => server = await FakeHttpsServer.start());
  tearDown(() => server.close());

  SoopExtractor extractor() => SoopExtractor(httpClient: server.httpClient('SOOP'));
  final playerUrl = Uri.parse('https://vod.sooplive.co.kr/player/123456789');

  group('SoopExtractor.canHandle', () {
    test('accepts VOD player URLs on both hosts', () {
      final e = SoopExtractor();
      for (final ok in [
        'https://vod.sooplive.co.kr/player/123456789',
        'https://vod.sooplive.co.kr/player/123456789/',
        'https://vod.sooplive.co.kr/player/123456789?change_second=30',
        'https://vod.afreecatv.com/player/987654321',
        'http://vod.afreecatv.com/player/1',
      ]) {
        expect(e.canHandle(Uri.parse(ok)), isTrue, reason: ok);
      }
    });

    test('rejects lives, station pages, bad ids and look-alike hosts', () {
      final e = SoopExtractor();
      for (final bad in [
        'https://play.sooplive.co.kr/streamer/123456789',
        'https://www.sooplive.co.kr/player/123',
        'https://vod.sooplive.co.kr/player/',
        'https://vod.sooplive.co.kr/player/abc',
        'https://vod.sooplive.co.kr/player/12345678901234',
        'https://vod.sooplive.co.kr/player/123/extra',
        'https://vod.sooplive.co.kr.evil.test/player/123',
        'https://evilvod.afreecatv.com/player/123',
        'https://vod.afreecatv.com/station/123',
      ]) {
        expect(e.canHandle(Uri.parse(bad)), isFalse, reason: bad);
      }
    });
  });

  group('SoopExtractor.extract (hermetic, loopback TLS)', () {
    test('single-part VOD: per-quality HLS formats, metadata, exact POST form', () async {
      server.route(_api, FakeRoute(body: _fx('soop_view.json')));
      server.route('${_cdn}part1/original/playlist.m3u8', FakeRoute(body: _fx('media_playlist.m3u8')));
      server.route('${_cdn}part1/hd/playlist.m3u8', FakeRoute(body: _fx('media_playlist.m3u8')));

      final info = await extractor().extract(playerUrl);

      expect(info.id, '123456789');
      expect(info.title, 'Friday night ranked games', reason: 'single part: no part note');
      expect(info.author, 'StreamerNick');
      expect(info.thumbnailUrl, startsWith('https://videoimg.sooplive.co.kr/'));
      expect(info.duration, const Duration(hours: 1));
      expect(info.formats, hasLength(2), reason: 'the broken quality entry is dropped; the top-level file duplicates original');
      final original = info.formats.firstWhere((f) => f.height == 1080);
      expect(original.width, 1920);
      expect(original.bitrate, 6000000, reason: 'kbit/s from the API becomes bit/s');
      expect(original.container, 'm3u8');
      final hd = info.formats.firstWhere((f) => f.height == 720);
      expect(hd.url, startsWith('https://'), reason: 'http quality URL is upgraded');
      expect(info.requestHeaders['Referer'], 'https://vod.sooplive.co.kr/');

      final post = server.requests.first;
      expect(post.method, 'POST');
      expect(post.host, 'api.m.sooplive.co.kr');
      expect(post.body, 'nTitleNo=123456789&nApiLevel=10&nPlaylistIdx=0');
      expect(post.headers.contentType?.mimeType, 'application/x-www-form-urlencoded');
      expect(post.headers.value('referer'), 'https://vod.sooplive.co.kr/player/123456789');
      expect(post.headers.value('user-agent'), contains('Windows NT 10.0'));
      expect(post.headers.value('cookie'), isNull);
    });

    test('the legacy afreecatv.com URL posts the same id to the same API', () async {
      server.route(_api, FakeRoute(body: _fx('soop_file_master.json')));
      server.route('${_cdn}fm/master.m3u8', FakeRoute(body: _fx('master_two_variants.m3u8')));
      server.route('${_cdn}fm/v720/playlist.m3u8', FakeRoute(body: _fx('media_playlist.m3u8')));
      server.route('${_cdn}fm/v360/playlist.m3u8', FakeRoute(body: _fx('media_playlist.m3u8')));

      final info = await extractor().extract(Uri.parse('https://vod.afreecatv.com/player/555000111'));

      expect(server.requests.first.body, startsWith('nTitleNo=555000111&'));
      expect(info.title, 'Master only');
      expect(info.author, 'someone', reason: 'bj_id when there is no nick');
      expect(info.duration, const Duration(seconds: 90));
      expect(info.formats.map((f) => f.height), unorderedEquals([720, 360]), reason: 'master expanded into its variants');
      expect(info.sourceUrl.host, 'vod.afreecatv.com');
    });

    test('multi-part VOD: first part only, noted in the title, other parts never fetched', () async {
      server.route(_api, FakeRoute(body: _fx('soop_multipart.json')));
      server.route('${_cdn}mp1/playlist.m3u8', FakeRoute(body: _fx('media_playlist.m3u8')));
      server.route('${_cdn}mp2/playlist.m3u8', FakeRoute(body: _fx('media_playlist.m3u8')));

      final info = await extractor().extract(Uri.parse('https://vod.sooplive.co.kr/player/222333444'));

      expect(info.title, 'Long marathon (part 1 of 2)');
      expect(info.duration, const Duration(hours: 1), reason: 'first part, not total_file_duration');
      expect(info.formats.single.url, contains('/mp1/'));
      expect(server.requests.any((r) => r.uri.path.contains('/mp2/')), isFalse);
    });

    test('adult-gated and password VODs: LOGIN_REQUIRED', () async {
      for (final name in ['soop_adult.json', 'soop_password.json', 'soop_login_message.json']) {
        server.route(_api, FakeRoute(body: _fx(name)));
        await expectLater(extractor().extract(Uri.parse('https://vod.sooplive.co.kr/player/777')), _throwsStatus('LOGIN_REQUIRED'),
            reason: name);
      }
    });

    test('deleted VODs: NOT_FOUND (Korean and English messages)', () async {
      for (final name in ['soop_deleted.json', 'soop_deleted_en.json']) {
        server.route(_api, FakeRoute(body: _fx(name)));
        await expectLater(extractor().extract(Uri.parse('https://vod.sooplive.co.kr/player/777')), _throwsStatus('NOT_FOUND'),
            reason: name);
      }
    });

    test('login wording beats absence wording: "cannot watch unless logged in" is LOGIN_REQUIRED, never NOT_FOUND', () async {
      for (final name in ['soop_login_cannot_view.json', 'soop_login_and_deleted.json']) {
        server.route(_api, FakeRoute(body: _fx(name)));
        await expectLater(extractor().extract(playerUrl), _throwsStatus('LOGIN_REQUIRED'), reason: name);
      }
    });

    test('"no permission" wording is LOGIN_REQUIRED', () async {
      server.route(_api, FakeRoute(body: _fx('soop_no_permission.json')));
      await expectLater(extractor().extract(playerUrl), _throwsStatus('LOGIN_REQUIRED'));
    });

    test('a string-named code beats wording; numeric codes are not interpreted', () async {
      const expected = {
        'soop_code_login_vs_message.json': 'LOGIN_REQUIRED',
        'soop_code_gone.json': 'NOT_FOUND',
        'soop_code_numeric.json': 'PARSE_ERROR',
      };
      for (final entry in expected.entries) {
        server.route(_api, FakeRoute(body: _fx(entry.key)));
        await expectLater(extractor().extract(playerUrl), _throwsStatus(entry.value), reason: entry.key);
      }
    });

    test('a server-supplied result value never appears in the error text', () async {
      server.route(_api, FakeRoute(body: _fx('soop_result_string.json')));
      await expectLater(
        extractor().extract(playerUrl),
        throwsA(isA<MediaExtractionException>()
            .having((e) => e.status, 'status', 'PARSE_ERROR')
            .having((e) => e.reason, 'reason', allOf(isNot(contains('SECRET9')), isNot(contains('evil'))))),
      );
    });

    test('a vague absence message ("cannot be viewed") is nonterminal PARSE_ERROR, not NOT_FOUND', () async {
      server.route(_api, FakeRoute(body: _fx('soop_vague_absence.json')));
      await expectLater(extractor().extract(playerUrl), _throwsStatus('PARSE_ERROR'));
    });

    test('media hosts: off-list and look-alike stream URLs are never requested nor offered', () async {
      server.route(_api, FakeRoute(body: _fx('soop_offlist.json')));
      server.route('${_cdn}ok/playlist.m3u8', FakeRoute(body: _fx('media_playlist.m3u8')));
      server.route('evil.test/vod/a.m3u8', FakeRoute(body: _fx('media_playlist.m3u8')));

      final info = await extractor().extract(playerUrl);

      expect(info.formats.single.url, 'https://vod-archive.sooplive.co.kr/vod/ok/playlist.m3u8');
      expect(server.hosts.toSet(), {'api.m.sooplive.co.kr', 'vod-archive.sooplive.co.kr'});
    });

    test('media hosts: an HLS master listing an off-list variant: that variant is absent and never requested', () async {
      server.route(_api, FakeRoute(body: _fx('soop_file_master.json')));
      server.route('${_cdn}fm/master.m3u8', FakeRoute(body: _fx('master_offlist_variant.m3u8')));
      server.route('${_cdn}fm/v720/playlist.m3u8', FakeRoute(body: _fx('media_playlist.m3u8')));
      final info = await extractor().extract(Uri.parse('https://vod.sooplive.co.kr/player/555000111'));
      expect(info.formats.map((f) => f.height), [720]);
      expect(server.hosts.contains('evil.test'), isFalse);
    });

    test('media hosts: an HLS playlist redirecting off the SOOP domains is refused before the target is requested', () async {
      server.route(_api, FakeRoute(body: _fx('soop_multipart.json')));
      server.route('${_cdn}mp1/playlist.m3u8', const FakeRoute(status: 302, location: 'https://evil.test/p.m3u8'));
      server.route('evil.test/p.m3u8', FakeRoute(body: _fx('media_playlist.m3u8')));
      await expectLater(
        extractor().extract(Uri.parse('https://vod.sooplive.co.kr/player/222333444')),
        _throwsStatus('NO_MEDIA_FOUND'),
      );
      expect(server.hosts.contains('evil.test'), isFalse);
    });

    test('unknown result code, wrong shape, malformed JSON, HTML: PARSE_ERROR', () async {
      for (final name in ['soop_unknown_result.json', 'soop_malformed.json', 'soop_not_json.html']) {
        server.route(_api, FakeRoute(body: _fx(name)));
        await expectLater(extractor().extract(playerUrl), _throwsStatus('PARSE_ERROR'), reason: name);
      }
    });

    test('an answer for a different title is refused', () async {
      server.route(_api, FakeRoute(body: _fx('soop_other_title.json')));
      await expectLater(extractor().extract(playerUrl), _throwsStatus('PARSE_ERROR'));
      expect(server.requests.any((r) => r.uri.path.contains('/other/')), isFalse);
    });

    test('no files: NO_MEDIA_FOUND', () async {
      server.route(_api, FakeRoute(body: _fx('soop_no_files.json')));
      await expectLater(extractor().extract(playerUrl), _throwsStatus('NO_MEDIA_FOUND'));
    });

    test('DRM-flagged playlists only: DRM_PROTECTED', () async {
      server.route(_api, FakeRoute(body: _fx('soop_multipart.json')));
      server.route('${_cdn}mp1/playlist.m3u8', FakeRoute(body: _fx('drm_playlist.m3u8')));
      await expectLater(
        extractor().extract(Uri.parse('https://vod.sooplive.co.kr/player/222333444')),
        _throwsStatus('DRM_PROTECTED'),
      );
    });

    test('HTTP statuses map to the shared table; a redirect answer is NETWORK', () async {
      const expected = {404: 'NOT_FOUND', 429: 'RATE_LIMITED', 403: 'CHALLENGE_FAILED', 500: 'NETWORK', 302: 'NETWORK'};
      for (final entry in expected.entries) {
        server.route(_api, FakeRoute(status: entry.key, body: '{}', location: entry.key == 302 ? 'https://api.m.sooplive.co.kr/x' : null));
        await expectLater(extractor().extract(playerUrl), _throwsStatus(entry.value), reason: 'HTTP ${entry.key}');
      }
    });
  });
}
