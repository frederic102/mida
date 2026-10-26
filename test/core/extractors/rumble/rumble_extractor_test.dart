import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/rumble/rumble_extractor.dart';

import '../native_http/fake_https_server.dart';

Matcher _throwsStatus(String status) =>
    throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', status));

String _f(String name) => fixture('rumble', name);

void main() {
  late FakeHttpsServer server;

  setUp(() async => server = await FakeHttpsServer.start());
  tearDown(() => server.close());

  RumbleExtractor extractor() => RumbleExtractor(httpClient: server.httpClient('Rumble', timeout: const Duration(seconds: 30)));

  void routeVideo(String body, {int status = 200}) =>
      server.route('rumble.com/embedJS/u3/', FakeRoute(status: status, body: body));

  group('RumbleExtractor.extract (hermetic, loopback TLS)', () {
    test('page URL: embed id from the matching JSON-LD node, then embedJS; progressive + HLS formats', () async {
      server.route('rumble.com/v5demo1-demo-clip.html', FakeRoute(body: _f('rumble_page.html')));
      routeVideo(_f('rumble_embedjs_video.json'));
      server.route('sp.rmbl.ws/s8/2/demo/playlist.m3u8', FakeRoute(body: _f('rumble_hls_master.m3u8')));

      final info = await extractor().extract(Uri.parse('https://rumble.com/v5demo1-demo-clip.html?ref=x'));

      // Flip-proof: taking the first embedUrl on the page (instead of the
      // node whose url is this slug) picks v7relat and fails this line.
      expect(info.id, 'v5demo');
      expect(info.title, 'Demo clip');
      expect(info.author, 'Demo Channel');
      expect(info.thumbnailUrl, 'https://1a-1791.com/video/fww1/aa/s8/1/demo.jpg');
      expect(info.duration, const Duration(seconds: 125));

      final byId = {for (final f in info.formats) f.id: f};
      expect(byId['mp4-360p']!.url, 'https://1a-1791.com/video/fww1/aa/demo_360.mp4?r_file=a.mp4');
      expect(byId['mp4-720p']!.height, 720);
      expect(byId['mp4-720p']!.width, 1280);
      expect(byId['mp4-720p']!.bitrate, 2500000);
      expect(byId['mp4-720p']!.contentLength, 39000000);
      expect(byId['mp4-1080p']!.container, 'mp4');
      expect(byId['webm-480p']!.container, 'webm');
      expect(byId['mp4-1080p']!.isMuxed, isTrue);
      expect(byId['mp4-1080p']!.capabilitiesUnknown, isTrue);
      expect(info.formats.where((f) => f.container == 'm3u8'), hasLength(2), reason: 'expanded HLS variants');
      expect(info.formats.where((f) => f.container == 'm3u8').map((f) => f.height), containsAll([360, 720]));
      expect(info.formats.any((f) => f.url.contains('demo_u.mp4')), isFalse, reason: 'u is only a fallback for ua');
      expect(info.requestHeaders['Referer'], 'https://rumble.com/');
      expect(info.sourceUrl.toString(), 'https://rumble.com/v5demo1-demo-clip.html?ref=x');

      final page = server.requests.first;
      expect(page.uri.path, '/v5demo1-demo-clip.html');
      expect(page.uri.hasQuery, isFalse, reason: 'the user query is not forwarded');
      final api = server.requests[1];
      expect(api.uri.path, '/embedJS/u3/');
      expect(api.uri.queryParameters, {'request': 'video', 'ver': '2', 'v': 'v5demo'});
      expect(api.headers.value('cookie'), isNull);
    });

    test('embed URL: skips the page and goes straight to embedJS', () async {
      routeVideo(_f('rumble_embedjs_video.json'));
      server.route('sp.rmbl.ws/s8/2/demo/playlist.m3u8', FakeRoute(body: _f('rumble_hls_master.m3u8')));
      final info = await extractor().extract(Uri.parse('https://rumble.com/embed/v5demo/?pub=4'));
      expect(info.id, 'v5demo');
      expect(server.requests.first.uri.path, '/embedJS/u3/');
      expect(server.requests.first.uri.queryParameters['v'], 'v5demo');
    });

    test('page without JSON-LD: raw escaped embedUrl, then the oEmbed link', () async {
      server.route('rumble.com/v1raw-x.html', FakeRoute(body: _f('rumble_page_raw_embed.html')));
      server.route('rumble.com/v1oemb-x.html', FakeRoute(body: _f('rumble_page_oembed_only.html')));
      routeVideo(_f('rumble_embedjs_http_url.json'));

      await extractor().extract(Uri.parse('https://rumble.com/v1raw-x.html'));
      await extractor().extract(Uri.parse('https://rumble.com/v1oemb-x.html'));
      final ids = server.requests.where((r) => r.uri.path == '/embedJS/u3/').map((r) => r.uri.queryParameters['v']);
      expect(ids, ['v5raw99', 'v5oemb']);
    });

    test('ambiguous pages are PARSE_ERROR and never reach embedJS: two url-less nodes, a related embed before the player', () async {
      server.route('rumble.com/v1two-x.html', FakeRoute(body: _f('rumble_page_two_unlinked.html')));
      server.route('rumble.com/v1rel-x.html', FakeRoute(body: _f('rumble_page_related_first.html')));
      routeVideo(_f('rumble_embedjs_video.json'));

      // Flip-proof: letting the first candidate win (instead of requiring one
      // distinct id) returns v1aaaa / v7relat here and requests embedJS.
      await expectLater(extractor().extract(Uri.parse('https://rumble.com/v1two-x.html')), _throwsStatus('PARSE_ERROR'));
      await expectLater(extractor().extract(Uri.parse('https://rumble.com/v1rel-x.html')), _throwsStatus('PARSE_ERROR'));
      expect(server.requests.where((r) => r.uri.path == '/embedJS/u3/'), isEmpty);
    });

    test('media on hosts outside the Rumble CDN list is never offered or requested (file, playlist, redirect hop)', () async {
      routeVideo(_f('rumble_embedjs_offlist.json'));
      server.route('evil.test/p/playlist.m3u8', FakeRoute(body: _f('rumble_hls_master.m3u8')));
      final info = await extractor().extract(Uri.parse('https://rumble.com/embed/v5off/'));
      expect(info.formats.map((f) => f.url), ['https://1a-1791.com/video/ok_720.mp4']);
      expect(server.hosts.where((h) => h.contains('evil')), isEmpty);

      // An allowed playlist host that redirects off the list: refused before the hop is requested.
      routeVideo(_f('rumble_embedjs_hls_only.json'));
      server.route('sp.rmbl.ws/s8/2/drm/playlist.m3u8',
          const FakeRoute(status: 302, location: 'https://evil.test/p/playlist.m3u8'));
      await expectLater(extractor().extract(Uri.parse('https://rumble.com/embed/v5off/')), _throwsStatus('NO_MEDIA_FOUND'));
      expect(server.hosts.where((h) => h.contains('evil')), isEmpty);
    });

    test('JSON-LD owned by another page is ignored in every quote style and never raw-scanned', () async {
      // Flip-proof: a double-quote-only type pattern lets the single/unquoted blocks into the raw fallback.
      for (final style in ['single', 'double', 'unquoted']) {
        server.route('rumble.com/v1own-$style.html', FakeRoute(body: _f('rumble_page_jsonld_$style.html')));
        await expectLater(extractor().extract(Uri.parse('https://rumble.com/v1own-$style.html')), _throwsStatus('PARSE_ERROR'),
            reason: style);
      }
      expect(server.requests.where((r) => r.uri.path == '/embedJS/u3/'), isEmpty);
    });

    test('JSON-LD closed with "</script >" is still a JSON-LD block: its other-page embed id is never returned', () async {
      server.route('rumble.com/wanted.html', FakeRoute(body: _f('rumble_page_jsonld_spaced_close.html')));
      // Flip-proof: an exact "</script>" close lets the block into the raw fallback and returns wrong123.
      await expectLater(extractor().extract(Uri.parse('https://rumble.com/wanted.html')), _throwsStatus('PARSE_ERROR'));
      expect(server.requests.where((r) => r.uri.path == '/embedJS/u3/'), isEmpty);
    });

    test('a script tag with ">" inside an attribute value is still JSON-LD: its foreign embed id is never returned', () async {
      server.route('rumble.com/wanted.html', FakeRoute(body: _f('rumble_page_jsonld_gt_attr.html')));
      // Flip-proof: an unquoted open-tag match ends at the ">" in data-note and leaks wrong123.
      await expectLater(extractor().extract(Uri.parse('https://rumble.com/wanted.html')), _throwsStatus('PARSE_ERROR'));
      expect(server.requests.where((r) => r.uri.path == '/embedJS/u3/'), isEmpty);
    });

    test('a plain http media URL is upgraded to https, never kept as http', () async {
      routeVideo(_f('rumble_embedjs_http_url.json'));
      final info = await extractor().extract(Uri.parse('https://rumble.com/embed/v5demo/'));
      expect(info.formats.every((f) => f.url.startsWith('https://')), isTrue);
      expect(info.formats.map((f) => f.id), ['mp4-720p', 'mp4-360p']);
    });

    test('embedJS answering false, HTTP 404 and a not-found error are NOT_FOUND', () async {
      routeVideo('false');
      await expectLater(extractor().extract(Uri.parse('https://rumble.com/embed/v5gone/')), _throwsStatus('NOT_FOUND'));
      routeVideo(_f('rumble_embedjs_error_gone.json'));
      await expectLater(extractor().extract(Uri.parse('https://rumble.com/embed/v5gone/')), _throwsStatus('NOT_FOUND'));
      // Unrouted page: the fake answers 404.
      await expectLater(extractor().extract(Uri.parse('https://rumble.com/v0none-x.html')), _throwsStatus('NOT_FOUND'));
    });

    test('"unavailable for guests" is an access status, not NOT_FOUND (so the browser tier still gets a turn)', () async {
      routeVideo(_f('rumble_embedjs_error_guest.json'));
      await expectLater(extractor().extract(Uri.parse('https://rumble.com/embed/v5gst/')), _throwsStatus('LOGIN_REQUIRED'));
    });

    test('a sign-in / members error is LOGIN_REQUIRED', () async {
      routeVideo(_f('rumble_embedjs_error_login.json'));
      await expectLater(extractor().extract(Uri.parse('https://rumble.com/embed/v5priv/')), _throwsStatus('LOGIN_REQUIRED'));
    });

    test('malformed JSON, unknown shape and a page with no embed id are PARSE_ERROR', () async {
      routeVideo(_f('rumble_embedjs_malformed.json'));
      await expectLater(extractor().extract(Uri.parse('https://rumble.com/embed/v5bad/')), _throwsStatus('PARSE_ERROR'));
      routeVideo(_f('rumble_embedjs_unknown_shape.json'));
      await expectLater(extractor().extract(Uri.parse('https://rumble.com/embed/v5bad/')), _throwsStatus('PARSE_ERROR'));
      server.route('rumble.com/v2none-x.html', FakeRoute(body: _f('rumble_page_no_embed.html')));
      await expectLater(extractor().extract(Uri.parse('https://rumble.com/v2none-x.html')), _throwsStatus('PARSE_ERROR'));
    });

    test('DRM-flagged HLS only is DRM_PROTECTED; a live stream with no VOD is NO_MEDIA_FOUND', () async {
      routeVideo(_f('rumble_embedjs_hls_only.json'));
      server.route('sp.rmbl.ws/s8/2/drm/playlist.m3u8', FakeRoute(body: _f('rumble_hls_master_drm.m3u8')));
      await expectLater(extractor().extract(Uri.parse('https://rumble.com/embed/v5drm/')), _throwsStatus('DRM_PROTECTED'));
      routeVideo(_f('rumble_embedjs_live_only.json'));
      await expectLater(extractor().extract(Uri.parse('https://rumble.com/embed/v5live/')), _throwsStatus('NO_MEDIA_FOUND'));
    });

    test('429 is RATE_LIMITED, 403 CHALLENGE_FAILED, 502 NETWORK', () async {
      routeVideo('', status: 429);
      await expectLater(extractor().extract(Uri.parse('https://rumble.com/embed/v5aaa/')), _throwsStatus('RATE_LIMITED'));
      routeVideo('blocked', status: 403);
      await expectLater(extractor().extract(Uri.parse('https://rumble.com/embed/v5aaa/')), _throwsStatus('CHALLENGE_FAILED'));
      routeVideo('', status: 502);
      await expectLater(extractor().extract(Uri.parse('https://rumble.com/embed/v5aaa/')), _throwsStatus('NETWORK'));
    });

    test('a page that redirects off Rumble or to http is refused without requesting the target', () async {
      server.route('rumble.com/v3off-x.html', const FakeRoute(status: 302, location: 'https://evil.test/embed'));
      server.route('rumble.com/v3dwn-x.html', const FakeRoute(status: 302, location: 'http://rumble.com/v3dwn-y.html'));
      await expectLater(extractor().extract(Uri.parse('https://rumble.com/v3off-x.html')), _throwsStatus('PARSE_ERROR'));
      await expectLater(extractor().extract(Uri.parse('https://rumble.com/v3dwn-x.html')), _throwsStatus('UNSUPPORTED_URL'));
      expect(server.hosts, ['rumble.com', 'rumble.com']);
    });

    test('URL recognition: pages and embeds only', () {
      final e = extractor();
      expect(e.canHandle(Uri.parse('https://rumble.com/v5demo1-demo-clip.html')), isTrue);
      expect(e.canHandle(Uri.parse('https://www.rumble.com/embed/v5demo/')), isTrue);
      expect(e.canHandle(Uri.parse('https://rumble.com/c/Demo')), isFalse);
      expect(e.canHandle(Uri.parse('https://rumble.com/embed/v5/..%2Fx')), isFalse);
      expect(e.canHandle(Uri.parse('https://rumble.com.evil.test/v5demo1-x.html')), isFalse);
      expect(e.canHandle(Uri.parse('https://rumble.com/embed/')), isFalse);
    });
  });
}
