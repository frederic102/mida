import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';

import 'facebook_fake_server.dart';

Matcher _throwsStatus(String status) =>
    throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', status));

void main() {
  late FakeFacebookServer server;

  setUp(() async => server = await FakeFacebookServer.start());
  tearDown(() => server.close());

  group('FacebookExtractor.extract (hermetic, loopback proxy)', () {
    test('hd+sd progressive page: picks the requested video, honest muxed-unknown formats, metadata', () async {
      server.route('www.facebook.com/NatGeoAnimals/videos/reindeer/1234567890123/',
          FakeRoute(body: fixture('facebook_video_hd_sd.html')));

      final info = await server.extractor().extract(
            Uri.parse('http://m.facebook.com/NatGeoAnimals/videos/reindeer/1234567890123/'),
          );

      expect(info.id, '1234567890123');
      expect(info.title, 'Reindeer migration', reason: 'JSON title wins over og:title');
      expect(info.author, 'Nat Geo Animals');
      expect(info.duration, const Duration(milliseconds: 95500));
      expect(info.thumbnailUrl, contains('thumb_target.jpg'));
      expect(info.formats.map((f) => f.id), ['progressive-hd', 'progressive-sd']);
      expect(info.formats.first.url, contains('target_hd.mp4'));
      expect(info.formats.first.url, contains('&oh=sig1'), reason: 'JSON \\/ and query must survive decoding');
      // The HD URL's efg tag says `gen2_720p`; the efg decoder would call
      // that video-only. Progressive files must stay muxed-but-unknown so
      // the capability resolver sniffs them instead.
      for (final f in info.formats) {
        expect(f.isMuxed, isTrue);
        expect(f.capabilitiesUnknown, isTrue);
        expect(f.container, 'mp4');
      }
      expect(info.formats.any((f) => f.url.contains('related_hd')), isFalse,
          reason: 'a related video on the same page must never be picked');
      expect(info.requestHeaders['User-Agent'], contains('Chrome'));
      expect(info.requestHeaders['Referer'], 'https://www.facebook.com/');

      // Fetched on www (desktop), with a desktop UA and no cookie at all.
      expect(server.requested.single.host, 'www.facebook.com');
      final headers = server.requestHeaders.single;
      expect(headers.value('user-agent'), contains('Windows NT 10.0'));
      expect(headers.value('cookie'), isNull);
    });

    test('dash-only page: video-only and audio-only halves from the manifest', () async {
      server.route('www.facebook.com/watch/', FakeRoute(body: fixture('facebook_video_dash_only.html')));

      final info = await server.extractor().extract(Uri.parse('http://www.facebook.com/watch/?v=2222222222222'));

      expect(info.id, '2222222222222');
      expect(info.title, 'Dash clip "live"', reason: 'og:title fallback, entities decoded');
      expect(info.duration, isNull);
      expect(info.formats, hasLength(3));
      final v720 = info.formats.firstWhere((f) => f.height == 720);
      expect(v720.isVideoOnly, isTrue);
      expect(v720.capabilitiesUnknown, isFalse);
      expect(v720.bitrate, 1800000);
      expect(v720.url, contains('&oh=s1'), reason: '&amp; in BaseURL must be unescaped');
      expect(v720.url, isNot(contains('&amp;')));
      final audio = info.formats.where((f) => f.isAudioOnly).toList();
      expect(audio, hasLength(1));
      expect(audio.single.audioCodec, 'mp4a.40.5');
      expect(info.formats.where((f) => f.isMuxed), isEmpty);
    });

    test('fb.watch short link: follows Location, reads the reel page (raw inline JS shape)', () async {
      server.route('fb.watch/aBc12_x/', const FakeRoute(status: 302, location: 'https://www.facebook.com/reel/3333333333333'));
      server.route('www.facebook.com/reel/3333333333333', FakeRoute(body: fixture('facebook_reel_inline_js.html')));

      final info = await server.extractor().extract(Uri.parse('http://fb.watch/aBc12_x/'));

      expect(info.id, '3333333333333');
      expect(info.title, 'Short reel');
      expect(info.formats.map((f) => f.url).toList(), [
        'https://video.xx.fbcdn.net/v/t42/reel_hd.mp4?oh=sig5',
        'https://video.xx.fbcdn.net/v/t42/reel_sd.mp4?oh=sig4&_nc_cat=1',
      ]);
      expect(server.requested.map((u) => u.host), ['fb.watch', 'www.facebook.com']);
      expect(info.sourceUrl.host, 'fb.watch');
    });

    test('/share/v/ link resolved through its redirect', () async {
      server.route('www.facebook.com/share/v/1AbCdEf/',
          const FakeRoute(status: 301, location: '/NatGeoAnimals/videos/1234567890123/'));
      server.route('www.facebook.com/NatGeoAnimals/videos/1234567890123/',
          FakeRoute(body: fixture('facebook_video_hd_sd.html')));

      final info = await server.extractor().extract(Uri.parse('http://www.facebook.com/share/v/1AbCdEf/'));
      expect(info.id, '1234567890123');
      expect(info.formats.first.url, contains('target_hd.mp4'));
    });

    test('login wall page (login_form, "Log in" title, no data) is LOGIN_REQUIRED', () async {
      // Flip-proof: with FacebookPageStateDetector.isLoginWall forced to
      // false this page classifies as unknown and the status reads
      // PARSE_ERROR instead (verified once by hand, see lane report).
      server.route('www.facebook.com/reel/4444444444444', FakeRoute(body: fixture('facebook_login_wall.html')));
      await expectLater(
        server.extractor().extract(Uri.parse('http://www.facebook.com/reel/4444444444444')),
        _throwsStatus('LOGIN_REQUIRED'),
      );
    });

    test('redirect to /login.php is LOGIN_REQUIRED', () async {
      server.route('www.facebook.com/watch/',
          const FakeRoute(status: 302, location: 'https://www.facebook.com/login.php?next=secret-token'));
      server.route('www.facebook.com/login.php', const FakeRoute(body: '<html><title>Facebook</title></html>'));
      await expectLater(
        server.extractor().extract(Uri.parse('http://www.facebook.com/watch/?v=5555555555555')),
        _throwsStatus('LOGIN_REQUIRED'),
      );
    });

    test('"content isn\'t available" page WITH a login form is LOGIN_REQUIRED (group/friends-only video)', () async {
      server.route('www.facebook.com/reel/6666666666666', FakeRoute(body: fixture('facebook_not_found.html')));
      await expectLater(
        server.extractor().extract(Uri.parse('http://www.facebook.com/reel/6666666666666')),
        _throwsStatus('LOGIN_REQUIRED'),
      );
    });

    test('"content isn\'t available" page with no sign-in prompt at all stays NOT_FOUND', () async {
      final noForm = fixture('facebook_not_found.html').replaceFirst(RegExp(r'<form id="login_form".*?</form>'), '');
      server.route('www.facebook.com/reel/6666666666667', FakeRoute(body: noForm));
      await expectLater(
        server.extractor().extract(Uri.parse('http://www.facebook.com/reel/6666666666667')),
        _throwsStatus('NOT_FOUND'),
      );
    });

    test('only a related video on the page: never returns it', () async {
      server.route('www.facebook.com/reel/7777777777777', FakeRoute(body: fixture('facebook_video_hd_sd.html')));
      await expectLater(
        server.extractor().extract(Uri.parse('http://www.facebook.com/reel/7777777777777')),
        _throwsStatus('LOGIN_REQUIRED'),
      );
    });

    test('HTTP status mapping: 404 NOT_FOUND, 429 RATE_LIMITED, 403 CHALLENGE_FAILED, 500 NETWORK', () async {
      const cases = {404: 'NOT_FOUND', 429: 'RATE_LIMITED', 403: 'CHALLENGE_FAILED', 500: 'NETWORK'};
      for (final entry in cases.entries) {
        server.route('www.facebook.com/reel/1', FakeRoute(status: entry.key, body: 'x'));
        await expectLater(
          server.extractor().extract(Uri.parse('http://www.facebook.com/reel/1')),
          _throwsStatus(entry.value),
          reason: 'HTTP ${entry.key}',
        );
      }
    });

    test('unrecognized page shape is PARSE_ERROR (falls through to other tiers)', () async {
      server.route('www.facebook.com/reel/8', const FakeRoute(body: '<html><title>Video</title><div>hi</div></html>'));
      await expectLater(
        server.extractor().extract(Uri.parse('http://www.facebook.com/reel/8')),
        _throwsStatus('PARSE_ERROR'),
      );
    });

    test('short link landing off Facebook is PARSE_ERROR, and the off-site page is never requested', () async {
      server.route('fb.watch/zz', const FakeRoute(status: 302, location: 'https://example.com/landing'));
      server.route('example.com/landing', FakeRoute(body: fixture('facebook_video_hd_sd.html')));
      await expectLater(server.extractor().extract(Uri.parse('http://fb.watch/zz')), _throwsStatus('PARSE_ERROR'));
      expect(server.requested.map((u) => u.host), ['fb.watch'], reason: 'onHop refuses the off-site hop before it is fetched');
    });

    test('redirect to a private address is refused by HostPolicy, query redacted', () async {
      server.route('fb.watch/evil', const FakeRoute(status: 302, location: 'https://127.0.0.1/admin?token=SECRET'));
      try {
        await server.extractor().extract(Uri.parse('http://fb.watch/evil'));
        fail('expected a refusal');
      } on MediaExtractionException catch (e) {
        expect(e.status, 'UNSUPPORTED_URL');
        expect(e.reason, isNot(contains('SECRET')));
      }
      expect(server.requested.map((u) => u.host), ['fb.watch'], reason: 'the private hop is never requested');
    });

    test('body cap: video data past 5 MiB is not read', () async {
      final page = fixture('facebook_video_hd_sd.html');
      final padded = page.replaceFirst('<body>', '<body><!--${'x' * (5 * 1024 * 1024 + 10)}-->');
      server.route('www.facebook.com/reel/1234567890123', FakeRoute(body: padded));
      await expectLater(
        server.extractor().extract(Uri.parse('http://www.facebook.com/reel/1234567890123')),
        throwsA(isA<MediaExtractionException>()
            .having((e) => e.status, 'status', 'PARSE_ERROR')
            .having((e) => e.reason, 'reason', contains('read limit'))),
      );
    });

    test('DRM-only DASH manifest is DRM_PROTECTED', () async {
      const mpd = '<MPD><Period><AdaptationSet mimeType=\\"video/mp4\\"><ContentProtection schemeIdUri=\\"urn:uuid:edef8ba9\\"/>'
          '<Representation id=\\"v\\" height=\\"720\\"><BaseURL>https:\\/\\/video.xx.fbcdn.net\\/v.mp4</BaseURL>'
          '</Representation></AdaptationSet></Period></MPD>';
      const body = '<script type="application/json">{"video":{"id":"10","dash_manifest":"$mpd"}}</script>';
      server.route('www.facebook.com/reel/10', const FakeRoute(body: body));
      await expectLater(
        server.extractor().extract(Uri.parse('http://www.facebook.com/reel/10')),
        _throwsStatus('DRM_PROTECTED'),
      );
    });

    test('dash_manifest_url shape: one mpd format (manifest DRM scan fails open)', () async {
      const body = '<script type="application/json">{"video":{"id":"11",'
          '"dash_manifest_url":"https:\\/\\/video.xx.fbcdn.net\\/m.mpd?oh=1"}}</script>';
      server.route('www.facebook.com/reel/11', const FakeRoute(body: body));
      final info = await server.extractor().extract(Uri.parse('http://www.facebook.com/reel/11'));
      expect(info.formats.single.container, 'mpd');
      expect(info.formats.single.url, 'https://video.xx.fbcdn.net/m.mpd?oh=1');
    });

    test('unsupported URL is rejected without any request', () async {
      await expectLater(
        server.extractor().extract(Uri.parse('http://www.facebook.com/NatGeoAnimals')),
        _throwsStatus('UNSUPPORTED_URL'),
      );
      expect(server.requested, isEmpty);
    });
  });
}
