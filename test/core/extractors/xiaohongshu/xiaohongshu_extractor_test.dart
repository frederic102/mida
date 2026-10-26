// A loopback TLS handshake per request is cheap, but on a machine busy with
// other test runs the default 30 s per-test limit has been seen to fire, so
// these hermetic suites get headroom. Deadline behavior is tested with the
// client's own (short) timeout, not this limit.
@Timeout(Duration(minutes: 3))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/xiaohongshu/xiaohongshu_extractor.dart';
import 'package:mida/core/extractors/xiaohongshu/xiaohongshu_state_reader.dart';

import '../native_http/fake_https_server.dart';

Matcher _throwsStatus(String status) =>
    throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', status));

String _fx(String name) => fixture('xiaohongshu', name);

const _id = '64f1a2b3c4d5e6f708192a3b';
const _host = 'www.xiaohongshu.com';

void main() {
  late FakeHttpsServer server;

  setUp(() async => server = await FakeHttpsServer.start());
  tearDown(() => server.close());

  XiaohongshuExtractor extractor() => XiaohongshuExtractor(httpClient: server.httpClient('Xiaohongshu'));
  final exploreUrl = Uri.parse('https://www.xiaohongshu.com/explore/$_id');

  group('XiaohongshuExtractor.canHandle', () {
    test('accepts explore, discovery/item and xhslink short links', () {
      final e = XiaohongshuExtractor();
      for (final ok in [
        'https://www.xiaohongshu.com/explore/$_id',
        'https://xiaohongshu.com/explore/$_id/',
        'https://www.xiaohongshu.com/explore/$_id?xsec_token=AB12cd&xsec_source=pc_feed',
        'https://www.xiaohongshu.com/discovery/item/$_id',
        'http://xhslink.com/AbCd12',
        'https://xhslink.com/a/AbCd12Ef',
      ]) {
        expect(e.canHandle(Uri.parse(ok)), isTrue, reason: ok);
      }
    });

    test('rejects other shapes, non-hex or wrong-length ids and look-alike hosts', () {
      final e = XiaohongshuExtractor();
      for (final bad in [
        'https://www.xiaohongshu.com/user/profile/$_id',
        'https://www.xiaohongshu.com/explore/${_id}0',
        'https://www.xiaohongshu.com/explore/64F1A2B3C4D5E6F708192A3B',
        'https://www.xiaohongshu.com/explore/64f1a2b3c4d5e6f708192a3',
        'https://www.xiaohongshu.com/explore/zzzzzzzzzzzzzzzzzzzzzzzz',
        'https://www.xiaohongshu.com/explore/',
        'https://www.xiaohongshu.com/discovery/item/$_id/extra',
        'https://xiaohongshu.com.evil.test/explore/$_id',
        'https://notxiaohongshu.com/explore/$_id',
        'https://xhslink.com/',
        'https://xhslink.com/a/b/c',
        'https://xhslink.com/ab',
      ]) {
        expect(e.canHandle(Uri.parse(bad)), isFalse, reason: bad);
      }
    });
  });

  group('XiaohongshuStateReader', () {
    test('turns bare undefined into null but leaves undefined inside strings alone', () {
      final state = XiaohongshuStateReader.extract(
        'x<script>window.__INITIAL_STATE__={"a":undefined,"b":"say \\"undefined\\" here","c":[undefined,1],"d":{"e":undefined}};</script>',
      )!;
      expect(state['a'], isNull);
      expect(state.containsKey('a'), isTrue);
      expect(state['b'], 'say "undefined" here');
      expect(state['c'], [null, 1]);
      expect((state['d'] as Map)['e'], isNull);
    });

    test('no state blob is null; an undecodable one is PARSE_ERROR', () {
      expect(XiaohongshuStateReader.extract('<html></html>'), isNull);
      expect(() => XiaohongshuStateReader.extract('window.__INITIAL_STATE__={"a":</script>'), throwsA(isA<MediaExtractionException>()));
    });
  });

  group('XiaohongshuExtractor.extract (hermetic, loopback TLS)', () {
    test('video note: only the requested note, streams per codec, origin file, https upgrade', () async {
      server.route('$_host/explore/$_id', FakeRoute(body: _fx('note_video.html')));

      final info = await extractor().extract(exploreUrl);

      expect(info.id, _id);
      expect(info.title, 'The undefined trick for noodles', reason: 'a string containing undefined survives');
      expect(info.author, 'NoodleMaster');
      expect(info.thumbnailUrl, 'https://sns-webpic-qc.xhscdn.com/202510/cover_default.jpg');
      expect(info.duration, const Duration(seconds: 38));

      final h264 = info.formats.where((f) => f.videoCodec == 'h264').toList();
      expect(h264, hasLength(2));
      expect(h264.first.url, 'https://sns-video-bd.xhscdn.com/stream/110/258/h264_1080.mp4');
      expect(h264.first.width, 1080);
      expect(h264.first.height, 1920);
      expect(h264.first.bitrate, 2400000);
      expect(h264.first.contentLength, 11400000);
      expect(h264.first.audioCodec, 'aac');
      expect(h264.first.capabilitiesUnknown, isFalse, reason: 'the entry names an audio codec');
      expect(h264.last.capabilitiesUnknown, isTrue, reason: 'no audioCodec reported');
      expect(info.formats.where((f) => f.videoCodec == 'hevc'), hasLength(1));
      expect(info.formats.any((f) => f.url.contains('h266_ignored')), isFalse);
      final origin = info.formats.singleWhere((f) => f.id == 'origin');
      expect(origin.url, 'https://sns-video-bd.xhscdn.com/spectrum/1040g0000abcdef');
      expect(info.formats.every((f) => f.url.startsWith('https://') && f.container == 'mp4'), isTrue);

      expect(info.formats.any((f) => f.url.contains('must_not_be_used')), isFalse,
          reason: 'a different note in the same state must never contribute');
      expect(info.requestHeaders['Referer'], 'https://www.xiaohongshu.com/');

      final page = server.requests.single;
      expect(page.uri.path, '/explore/$_id');
      expect(page.headers.value('cookie'), isNull);
      expect(page.headers.value('user-agent'), contains('Windows NT 10.0'));
    });

    test('discovery/item URL fetches the canonical explore page and forwards the share token only', () async {
      server.route('$_host/explore/$_id', FakeRoute(body: _fx('note_video.html')));

      await extractor().extract(Uri.parse(
          'https://www.xiaohongshu.com/discovery/item/$_id?source=webshare&xsec_token=AB12-cd_ef%3D&xsec_source=pc_share&utm=1'));

      final query = server.requests.single.uri.queryParameters;
      expect(query, {'xsec_token': 'AB12-cd_ef=', 'xsec_source': 'pc_share'});
    });

    test('a token with characters outside the allowed set is dropped, not forwarded', () async {
      server.route('$_host/explore/$_id', FakeRoute(body: _fx('note_video.html')));
      await extractor().extract(Uri.parse('https://www.xiaohongshu.com/explore/$_id?xsec_token=a%26evil%3D1%20x'));
      expect(server.requests.single.uri.hasQuery, isFalse);
    });

    test('a query that is not valid UTF-8 never makes canHandle or extract throw; it just carries no token', () async {
      final bad = Uri.parse('https://www.xiaohongshu.com/explore/$_id?xsec_token=%FF&xsec_source=pc_feed');
      expect(extractor().canHandle(bad), isTrue);

      server.route('$_host/explore/$_id', FakeRoute(body: _fx('note_video.html')));
      final info = await extractor().extract(bad);
      expect(info.id, _id);
      expect(server.requests.single.uri.hasQuery, isFalse);
    });

    test('xhslink.com short link: Location resolved, target note fetched with its token', () async {
      server.route(
        'xhslink.com/a/AbCd12Ef',
        const FakeRoute(
          status: 302,
          location: 'https://www.xiaohongshu.com/discovery/item/$_id?source=webshare&xhsshare=pc_web&xsec_token=TOK123&xsec_source=pc_share',
        ),
      );
      server.route('$_host/explore/$_id', FakeRoute(body: _fx('note_video.html')));

      final info = await extractor().extract(Uri.parse('https://xhslink.com/a/AbCd12Ef'));

      expect(info.id, _id);
      expect(server.hosts, ['xhslink.com', _host]);
      expect(server.requests[1].uri.queryParameters['xsec_token'], 'TOK123');
    });

    test('a short link landing off the site, on a non-note page, or on http is refused', () async {
      final url = Uri.parse('https://xhslink.com/Evil123');
      for (final (location, status) in [
        ('https://evil.test/explore/$_id', 'PARSE_ERROR'),
        ('https://www.xiaohongshu.com/user/profile/abc', 'PARSE_ERROR'),
        ('http://www.xiaohongshu.com/explore/$_id', 'UNSUPPORTED_URL'),
      ]) {
        server.requests.clear();
        server.route('xhslink.com/Evil123', FakeRoute(status: 302, location: location));
        await expectLater(extractor().extract(url), _throwsStatus(status), reason: location);
        expect(server.hosts, ['xhslink.com'], reason: 'the target must not be requested: $location');
      }
    });

    test('image-only note: NO_MEDIA_FOUND', () async {
      server.route('$_host/explore/$_id', FakeRoute(body: _fx('note_image.html')));
      await expectLater(extractor().extract(exploreUrl), _throwsStatus('NO_MEDIA_FOUND'));
    });

    test('empty note shell (no token / anti-bot): CHALLENGE_FAILED; only an explicit /login redirect is LOGIN_REQUIRED', () async {
      for (final name in ['note_login_empty_map.html', 'note_empty_shell.html']) {
        server.route('$_host/explore/$_id', FakeRoute(body: _fx(name)));
        await expectLater(extractor().extract(exploreUrl), _throwsStatus('CHALLENGE_FAILED'), reason: name);
      }
      server.route('$_host/explore/$_id', const FakeRoute(status: 302, location: 'https://www.xiaohongshu.com/login?redirectPath=x'));
      server.route('$_host/login', FakeRoute(body: _fx('note_no_state.html')));
      await expectLater(extractor().extract(exploreUrl), _throwsStatus('LOGIN_REQUIRED'));
    });

    test('the site 404 page and HTTP 404: NOT_FOUND', () async {
      server.route('$_host/explore/$_id', const FakeRoute(status: 302, location: 'https://www.xiaohongshu.com/404?source=x'));
      server.route('$_host/404', FakeRoute(body: _fx('note_no_state.html')));
      await expectLater(extractor().extract(exploreUrl), _throwsStatus('NOT_FOUND'));
      server.route('$_host/explore/$_id', const FakeRoute(status: 404, body: 'gone'));
      await expectLater(extractor().extract(exploreUrl), _throwsStatus('NOT_FOUND'));
    });

    test('a state that only describes another note, or whose noteId disagrees: PARSE_ERROR', () async {
      for (final name in ['note_other_only.html', 'note_id_mismatch.html']) {
        server.route('$_host/explore/$_id', FakeRoute(body: _fx(name)));
        await expectLater(extractor().extract(exploreUrl), _throwsStatus('PARSE_ERROR'), reason: name);
      }
    });

    test('malformed state, missing state: PARSE_ERROR', () async {
      for (final name in ['note_malformed.html', 'note_no_state.html']) {
        server.route('$_host/explore/$_id', FakeRoute(body: _fx(name)));
        await expectLater(extractor().extract(exploreUrl), _throwsStatus('PARSE_ERROR'), reason: name);
      }
    });

    test('originVideoKey is validated: a traversal key yields NO_MEDIA_FOUND, a clean key one origin format', () async {
      server.route('$_host/explore/$_id', FakeRoute(body: _fx('note_origin_only.html')));
      await expectLater(extractor().extract(exploreUrl), _throwsStatus('NO_MEDIA_FOUND'));

      server.route('$_host/explore/$_id', FakeRoute(body: _fx('note_origin_ok.html')));
      final info = await extractor().extract(exploreUrl);
      expect(info.formats.single.url, 'https://sns-video-bd.xhscdn.com/spectrum/1040g0000zzzz');
      expect(info.title, 'Xiaohongshu note $_id');
    });

    test('media hosts: off-list and look-alike stream URLs are never offered; none left is NO_MEDIA_FOUND', () async {
      server.route('$_host/explore/$_id', FakeRoute(body: _fx('note_offlist.html')));
      final info = await extractor().extract(exploreUrl);
      expect(info.formats.single.url, 'https://sns-video-hw.xhscdn.com/stream/ok.mp4');

      server.route('$_host/explore/$_id', FakeRoute(body: _fx('note_all_offlist.html')));
      await expectLater(extractor().extract(exploreUrl), _throwsStatus('NO_MEDIA_FOUND'));
    });

    test('HTTP statuses map to the shared table', () async {
      const expected = {429: 'RATE_LIMITED', 403: 'CHALLENGE_FAILED', 401: 'CHALLENGE_FAILED', 500: 'NETWORK'};
      for (final entry in expected.entries) {
        server.route('$_host/explore/$_id', FakeRoute(status: entry.key, body: 'x'));
        await expectLater(extractor().extract(exploreUrl), _throwsStatus(entry.value), reason: 'HTTP ${entry.key}');
      }
    });

    test('a redirect off the site is refused without requesting it', () async {
      server.route('$_host/explore/$_id', const FakeRoute(status: 302, location: 'https://evil.test/x'));
      await expectLater(extractor().extract(exploreUrl), _throwsStatus('PARSE_ERROR'));
      expect(server.hosts, [_host]);
    });
  });
}
