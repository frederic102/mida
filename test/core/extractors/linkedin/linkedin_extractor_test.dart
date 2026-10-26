// A loopback TLS handshake per request is cheap, but on a machine busy with
// other test runs the default 30 s per-test limit has been seen to fire, so
// these hermetic suites get headroom. Deadline behavior is tested with the
// client's own (short) timeout, not this limit.
@Timeout(Duration(minutes: 3))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/linkedin/linkedin_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';

import '../native_http/fake_https_server.dart';

Matcher _throwsStatus(String status) =>
    throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', status));

String _fx(String name) => fixture('linkedin', name);

const _postSlug = 'jane-doe_shipping-our-first-robot-arm-activity-7123456789012345678-AbCd';
const _postHost = 'www.linkedin.com';

void main() {
  late FakeHttpsServer server;

  setUp(() async => server = await FakeHttpsServer.start());
  tearDown(() => server.close());

  LinkedInExtractor extractor() => LinkedInExtractor(httpClient: server.httpClient('LinkedIn'));

  group('LinkedInExtractor.canHandle', () {
    test('accepts posts, feed updates and embeds', () {
      final e = LinkedInExtractor();
      for (final ok in [
        'https://www.linkedin.com/posts/$_postSlug',
        'https://linkedin.com/posts/$_postSlug/?utm_source=share',
        'https://uk.linkedin.com/posts/$_postSlug',
        'https://www.linkedin.com/feed/update/urn:li:activity:7123456789012345678',
        'https://www.linkedin.com/feed/update/urn:li:activity:7123456789012345678/',
        'https://www.linkedin.com/feed/update/urn:li:ugcPost:7123456789012345678/',
        'https://www.linkedin.com/embed/feed/update/urn:li:share:7123456789012345678',
      ]) {
        expect(e.canHandle(Uri.parse(ok)), isTrue, reason: ok);
      }
    });

    test('rejects courses, profiles, bad urns and look-alike hosts', () {
      final e = LinkedInExtractor();
      for (final bad in [
        'https://www.linkedin.com/learning/some-course/lesson',
        'https://www.linkedin.com/in/someone/',
        'https://www.linkedin.com/company/acme/',
        'https://www.linkedin.com/pulse/some-article/',
        'https://www.linkedin.com/posts/',
        'https://www.linkedin.com/posts/a/b',
        'https://www.linkedin.com/feed/update/urn:li:activity:abc',
        'https://www.linkedin.com/feed/update/urn:li:person:7123456789012345678',
        'https://www.linkedin.com/feed/update/urn:li:activity:7123456789012345678/extra',
        'https://notlinkedin.com/posts/$_postSlug',
        'https://linkedin.com.evil.test/posts/$_postSlug',
        'https://www.linkedin.com.evil.test/feed/update/urn:li:activity:7123456789012345678',
      ]) {
        expect(e.canHandle(Uri.parse(bad)), isFalse, reason: bad);
      }
    });
  });

  group('LinkedInExtractor.extract (hermetic, loopback TLS)', () {
    test('/posts/ page: HLS expanded, https-upgraded mp4, poster, og:title split into author and title', () async {
      server.route('$_postHost/posts/$_postSlug', FakeRoute(body: _fx('post_video.html')));
      server.route('dms.licdn.com/playlist/vid/v2/abc/playlist.m3u8', FakeRoute(body: _fx('media_playlist.m3u8')));

      final info = await extractor().extract(Uri.parse('https://linkedin.com/posts/$_postSlug?utm_source=share&utm_medium=member_desktop'));

      expect(info.id, '7123456789012345678');
      expect(info.title, 'Shipping our first robot arm & what we learned', reason: 'entities decoded, name stripped');
      expect(info.author, 'Jane Doe');
      expect(info.thumbnailUrl, 'https://media.licdn.com/dms/image/poster_abc.jpg?e=1&t=sig', reason: 'data-poster-url beats og:image');
      final mp4 = info.formats.singleWhere((f) => f.container == 'mp4');
      expect(mp4.url, 'https://dms.licdn.com/playlist/vid/v2/abc/mp4-720p.mp4');
      expect(mp4.bitrate, 1800000);
      expect(mp4.capabilitiesUnknown, isTrue);
      expect(info.formats.where((f) => f.container == 'm3u8'), hasLength(1));
      expect(info.formats.any((f) => f.url.endsWith('.mpd')), isFalse, reason: 'DASH sources are not offered');

      final page = server.requests.first;
      expect(page.host, _postHost);
      expect(page.uri.path, '/posts/$_postSlug');
      expect(page.uri.hasQuery, isFalse, reason: 'tracking query is dropped');
      expect(page.headers.value('cookie'), isNull);
      expect(page.headers.value('user-agent'), contains('Windows NT 10.0'));
    });

    test('a percent-encoded (non-ASCII) slug is fetched as is, not re-encoded to %25', () async {
      const slug = '%ED%95%9C%EA%B8%80-activity-7123456789012345678-AbCd';
      server.route('$_postHost/posts/$slug', FakeRoute(body: _fx('post_video.html')));

      final info = await extractor().extract(Uri.parse('https://www.linkedin.com/posts/$slug'));

      expect(info.id, '7123456789012345678');
      expect(server.requests.first.uri.path, '/posts/$slug');
      expect(server.requests.first.uri.path, isNot(contains('%25')));
    });

    test('feed/update URL with an entity-encoded double-quoted data-sources attribute', () async {
      server.route(
        '$_postHost/feed/update/urn:li:activity:7123456789012345678',
        FakeRoute(body: _fx('post_video_entities.html')),
      );

      final info = await extractor().extract(Uri.parse('https://www.linkedin.com/feed/update/urn:li:activity:7123456789012345678/'));

      expect(info.id, '7123456789012345678');
      expect(info.formats.single.url, 'https://dms.licdn.com/playlist/vid/v2/xyz/mp4-480p.mp4?e=1&v=beta');
      expect(info.author, 'Acme Corp');
      expect(info.title, 'Launch day');
      expect(info.thumbnailUrl, contains('poster_xyz.jpg'));
    });

    test('a page with two videos: only the one next to the post id in the URL', () async {
      server.route('$_postHost/embed/feed/update/urn:li:ugcPost:7222222222222222222', FakeRoute(body: _fx('post_two_videos.html')));
      final info = await extractor().extract(Uri.parse('https://www.linkedin.com/embed/feed/update/urn:li:ugcPost:7222222222222222222'));
      expect(info.formats.single.url, contains('/second/'));
      expect(info.thumbnailUrl, contains('second.jpg'));
      expect(info.formats.any((f) => f.url.contains('/first/')), isFalse);
    });

    test('a page with two videos and no id match is PARSE_ERROR, never a guess', () async {
      server.route('$_postHost/feed/update/urn:li:activity:7999999999999999999', FakeRoute(body: _fx('post_two_videos.html')));
      await expectLater(
        extractor().extract(Uri.parse('https://www.linkedin.com/feed/update/urn:li:activity:7999999999999999999')),
        _throwsStatus('PARSE_ERROR'),
      );
    });

    test('requested id in the header, an unrelated first player and a longer-id player: only the exact-id container is used', () async {
      const slug = 'jane-doe_the-real-post-activity-7123456789012345678-AbCd';
      server.route('$_postHost/posts/$slug', FakeRoute(body: _fx('post_header_trap.html')));

      final info = await extractor().extract(Uri.parse('https://www.linkedin.com/posts/$slug'));

      expect(info.formats.single.url, 'https://dms.licdn.com/playlist/vid/v2/real/mp4.mp4');
      expect(info.thumbnailUrl, contains('real.jpg'));
      expect(info.formats.any((f) => f.url.contains('sponsored') || f.url.contains('longer-id')), isFalse);
    });

    test('a lone player inside another post container is never taken, even with the id in the header and canonical', () async {
      const slug = 'jane-doe_a-text-post-activity-7123456789012345678-AbCd';
      server.route('$_postHost/posts/$slug', FakeRoute(body: _fx('post_header_only_trap.html')));
      await expectLater(extractor().extract(Uri.parse('https://www.linkedin.com/posts/$slug')), _throwsStatus('PARSE_ERROR'));
    });

    test('no container: a single unowned player needs the page canonical to name this exact post', () async {
      const slug = 'jane-doe_canonical-only-activity-7123456789012345678-AbCd';
      server.route('$_postHost/posts/$slug', FakeRoute(body: _fx('post_canonical_single.html')));
      final info = await extractor().extract(Uri.parse('https://www.linkedin.com/posts/$slug'));
      expect(info.formats.single.url, contains('/canon/'));

      // Same page served for a different post id: the canonical no longer proves ownership.
      server.route('$_postHost/feed/update/urn:li:activity:7123456789012345999', FakeRoute(body: _fx('post_canonical_single.html')));
      await expectLater(
        extractor().extract(Uri.parse('https://www.linkedin.com/feed/update/urn:li:activity:7123456789012345999')),
        _throwsStatus('PARSE_ERROR'),
      );

      server.route('$_postHost/posts/$slug', FakeRoute(body: _fx('post_no_proof_single.html')));
      await expectLater(extractor().extract(Uri.parse('https://www.linkedin.com/posts/$slug')), _throwsStatus('PARSE_ERROR'),
          reason: 'a single video with no ownership signal');
    });

    test('no container and two different unowned players: PARSE_ERROR even with a matching canonical', () async {
      const slug = 'jane-doe_two-activity-7123456789012345678-AbCd';
      server.route('$_postHost/posts/$slug', FakeRoute(body: _fx('post_canonical_two.html')));
      await expectLater(extractor().extract(Uri.parse('https://www.linkedin.com/posts/$slug')), _throwsStatus('PARSE_ERROR'));
    });

    test('slug URL without an id: the canonical path must equal the requested path', () async {
      server.route('$_postHost/posts/pat_slug-only-share-abc', FakeRoute(body: _fx('post_slug_ok.html')));
      final info = await extractor().extract(Uri.parse('https://www.linkedin.com/posts/pat_slug-only-share-abc'));
      expect(info.formats.single.url, contains('/slug/'));

      server.route('$_postHost/posts/pat_slug-only-share-abc', FakeRoute(body: _fx('post_slug_mismatch.html')));
      await expectLater(
        extractor().extract(Uri.parse('https://www.linkedin.com/posts/pat_slug-only-share-abc')),
        _throwsStatus('PARSE_ERROR'),
      );
    });

    test('media hosts: off-list and look-alike source URLs are never requested nor offered', () async {
      server.route('$_postHost/posts/$_postSlug', FakeRoute(body: _fx('post_offlist.html')));
      server.route('evil.test/p.m3u8', FakeRoute(body: _fx('media_playlist.m3u8')));
      final info = await extractor().extract(Uri.parse('https://www.linkedin.com/posts/$_postSlug'));
      expect(info.formats.single.url, 'https://dms.licdn.com/playlist/vid/v2/ok/mp4.mp4');
      expect(server.hosts, [_postHost]);
    });

    test('media hosts: an HLS master listing an off-list variant: that variant is absent and never requested', () async {
      server.route('$_postHost/posts/$_postSlug', FakeRoute(body: _fx('post_video.html')));
      server.route('dms.licdn.com/playlist/vid/v2/abc/playlist.m3u8', FakeRoute(body: _fx('master_offlist_variant.m3u8')));
      server.route('dms.licdn.com/playlist/vid/v2/abc/v720.m3u8', FakeRoute(body: _fx('media_playlist.m3u8')));
      final info = await extractor().extract(Uri.parse('https://www.linkedin.com/posts/$_postSlug'));
      expect(info.formats.where((f) => f.container == 'm3u8').map((f) => f.height), [720]);
      expect(server.hosts.contains('evil.test'), isFalse);
    });

    test('a slug that is not valid UTF-8 after unescaping still extracts (the post id never needs decoding)', () async {
      const slug = 'abc-%FF%FE-def';
      server.route('$_postHost/posts/$slug', FakeRoute(body: _fx('post_slug_ff.html')));
      final info = await extractor().extract(Uri.parse('https://www.linkedin.com/posts/$slug'));
      expect(info.id, slug);
      expect(info.formats.single.url, contains('/ff/'));
    });

    test('media hosts: an HLS playlist redirecting off licdn.com is refused before the target is requested', () async {
      server.route('$_postHost/posts/$_postSlug', FakeRoute(body: _fx('post_video.html')));
      server.route('dms.licdn.com/playlist/vid/v2/abc/playlist.m3u8', const FakeRoute(status: 302, location: 'https://evil.test/p.m3u8'));
      server.route('evil.test/p.m3u8', FakeRoute(body: _fx('media_playlist.m3u8')));
      final info = await extractor().extract(Uri.parse('https://www.linkedin.com/posts/$_postSlug'));
      expect(info.formats.where((f) => f.container == 'm3u8'), isEmpty);
      expect(server.hosts.contains('evil.test'), isFalse);
    });

    test('redirect to /authwall or /checkpoint: CHALLENGE_FAILED (an anonymous wall, not an account wall)', () async {
      for (final path in ['/authwall?trk=bf&sessionRedirect=x', '/checkpoint/challenge?x=1']) {
        server.route('$_postHost/posts/$_postSlug', FakeRoute(status: 302, location: 'https://www.linkedin.com$path'));
        server.route('$_postHost/authwall', FakeRoute(body: _fx('post_authwall.html')));
        server.route('$_postHost/checkpoint/challenge', FakeRoute(body: _fx('post_authwall.html')));
        await expectLater(extractor().extract(Uri.parse('https://www.linkedin.com/posts/$_postSlug')), _throwsStatus('CHALLENGE_FAILED'),
            reason: path);
      }
    });

    test('an inline authwall page with no video: CHALLENGE_FAILED', () async {
      server.route('$_postHost/posts/$_postSlug', FakeRoute(body: _fx('post_authwall.html')));
      await expectLater(extractor().extract(Uri.parse('https://www.linkedin.com/posts/$_postSlug')), _throwsStatus('CHALLENGE_FAILED'));
    });

    test('only an explicit redirect to the /login form is LOGIN_REQUIRED', () async {
      for (final path in ['/login?session_redirect=x', '/uas/login?x=1']) {
        server.route('$_postHost/posts/$_postSlug', FakeRoute(status: 302, location: 'https://www.linkedin.com$path'));
        server.route('$_postHost/login', FakeRoute(body: _fx('post_authwall.html')));
        server.route('$_postHost/uas/login', FakeRoute(body: _fx('post_authwall.html')));
        await expectLater(extractor().extract(Uri.parse('https://www.linkedin.com/posts/$_postSlug')), _throwsStatus('LOGIN_REQUIRED'),
            reason: path);
      }
    });

    test('source bitrate: data-bitrate wins, bitrate is the fallback, none stays 0', () async {
      server.route('$_postHost/posts/$_postSlug', FakeRoute(body: _fx('post_bitrate.html')));
      final info = await extractor().extract(Uri.parse('https://www.linkedin.com/posts/$_postSlug'));
      final byName = {for (final f in info.formats) f.url.split('/').last: f.bitrate};
      expect(byName, {'a.mp4': 2500000, 'b.mp4': 800000, 'c.mp4': 1200000, 'd.mp4': 0});
    });

    test('a redirect off LinkedIn is refused (PARSE_ERROR) without requesting it', () async {
      server.route('$_postHost/posts/$_postSlug', const FakeRoute(status: 302, location: 'https://evil.test/x'));
      await expectLater(extractor().extract(Uri.parse('https://www.linkedin.com/posts/$_postSlug')), _throwsStatus('PARSE_ERROR'));
      expect(server.hosts, [_postHost]);
    });

    test('text post: NO_MEDIA_FOUND; unreadable sources: PARSE_ERROR', () async {
      final url = Uri.parse('https://www.linkedin.com/posts/$_postSlug');
      server.route('$_postHost/posts/$_postSlug', FakeRoute(body: _fx('post_no_video.html')));
      await expectLater(extractor().extract(url), _throwsStatus('NO_MEDIA_FOUND'));
      for (final name in ['post_malformed.html', 'post_unknown_types.html']) {
        server.route('$_postHost/posts/$_postSlug', FakeRoute(body: _fx(name)));
        await expectLater(extractor().extract(url), _throwsStatus('PARSE_ERROR'), reason: name);
      }
    });

    test('DRM-flagged playlist only: DRM_PROTECTED', () async {
      server.route('$_postHost/posts/$_postSlug', FakeRoute(body: _fx('post_drm.html')));
      server.route('dms.licdn.com/playlist/vid/v2/drm/playlist.m3u8', FakeRoute(body: _fx('drm_playlist.m3u8')));
      await expectLater(extractor().extract(Uri.parse('https://www.linkedin.com/posts/$_postSlug')), _throwsStatus('DRM_PROTECTED'));
    });

    test('401/403/999 with a body that stalls past the deadline is still CHALLENGE_FAILED, promptly', () async {
      for (final status in [401, 403, 999]) {
        server.route('$_postHost/posts/$_postSlug', FakeRoute(status: status, body: 'x', stall: true));
        final stopwatch = Stopwatch()..start();
        final quick = LinkedInExtractor(httpClient: server.httpClient('LinkedIn', timeout: const Duration(seconds: 12)));
        await expectLater(quick.extract(Uri.parse('https://www.linkedin.com/posts/$_postSlug')), _throwsStatus('CHALLENGE_FAILED'),
            reason: 'HTTP $status');
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 8)), reason: 'HTTP $status');
      }
    });

    test('HTTP statuses: 404/410 nonterminal CHALLENGE_FAILED, 429 RATE_LIMITED, 403 and 999 CHALLENGE_FAILED, 500 NETWORK', () async {
      const expected = {404: 'CHALLENGE_FAILED', 410: 'CHALLENGE_FAILED', 429: 'RATE_LIMITED', 403: 'CHALLENGE_FAILED', 999: 'CHALLENGE_FAILED', 500: 'NETWORK'};
      for (final entry in expected.entries) {
        server.route('$_postHost/posts/$_postSlug', FakeRoute(status: entry.key, body: 'x'));
        await expectLater(
          extractor().extract(Uri.parse('https://www.linkedin.com/posts/$_postSlug')),
          _throwsStatus(entry.value),
          reason: 'HTTP ${entry.key}',
        );
      }
    });
  });
}
