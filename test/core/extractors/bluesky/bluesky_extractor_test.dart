import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/bluesky/bluesky_extractor.dart';
import 'package:mida/core/extractors/bluesky/bluesky_url_matcher.dart';
import 'package:mida/core/extractors/media_models.dart';

import '../native_http/fake_https_server.dart';

Matcher _throwsStatus(String status) =>
    throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', status));

String _f(String name) => fixture('bluesky', name);

const _api = 'public.api.bsky.app';
const _resolve = '$_api/xrpc/com.atproto.identity.resolveHandle';
const _thread = '$_api/xrpc/app.bsky.feed.getPostThread';
const _did = 'did:plc:z72i7hdynmk6r22z27h6tvur';
const _playlist =
    'video.bsky.app/watch/did%3Aplc%3Az72i7hdynmk6r22z27h6tvur/bafkreivideo/playlist.m3u8';
const _mediaPlaylist =
    'video.bsky.app/watch/did%3Aplc%3Az72i7hdynmk6r22z27h6tvur/bafkreimedia/playlist.m3u8';

void main() {
  late FakeHttpsServer server;

  setUp(() async => server = await FakeHttpsServer.start());
  tearDown(() => server.close());

  BlueskyExtractor extractor() => BlueskyExtractor(httpClient: server.httpClient('Bluesky', timeout: const Duration(seconds: 30)));

  Uri post(String rkey, {String actor = 'alice.bsky.social'}) =>
      Uri.parse('https://bsky.app/profile/$actor/post/$rkey');

  group('BlueskyExtractor.extract (hermetic, loopback TLS)', () {
    test('handle URL: resolveHandle, then getPostThread, then the expanded HLS master', () async {
      server.route(_resolve, FakeRoute(body: _f('bluesky_resolve_handle.json')));
      server.route(_thread, FakeRoute(body: _f('bluesky_thread_video.json')));
      server.route(_playlist, FakeRoute(body: _f('bluesky_playlist_master.m3u8')));

      final info = await extractor().extract(post('3kxyzabcd2345', actor: 'Alice.Bsky.Social'));

      expect(info.id, '3kxyzabcd2345');
      expect(info.title, 'Look at this clip', reason: 'first line of the post text');
      expect(info.author, 'Alice Example');
      expect(info.thumbnailUrl, endsWith('/bafkreivideo/thumbnail.jpg'));
      expect(info.formats.map((f) => f.height), unorderedEquals([360, 720]));
      expect(info.formats.every((f) => f.container == 'm3u8' && f.url.startsWith('https://video.bsky.app/')), isTrue);
      expect(info.formats.firstWhere((f) => f.height == 720).width, 1280);
      expect(info.requestHeaders['User-Agent'], contains('Windows NT 10.0'));

      final resolve = server.requests[0];
      expect(resolve.host, _api);
      expect(resolve.uri.queryParameters, {'handle': 'alice.bsky.social'}, reason: 'handle lowercased');
      final thread = server.requests[1];
      expect(thread.uri.queryParameters, {
        'uri': 'at://$_did/app.bsky.feed.post/3kxyzabcd2345',
        'depth': '0',
      });
      expect(thread.headers.value('cookie'), isNull);
      expect(thread.headers.value('authorization'), isNull);
    });

    test('DID URL skips the handle lookup', () async {
      server.route(_thread, FakeRoute(body: _f('bluesky_thread_video.json')));
      server.route(_playlist, FakeRoute(body: _f('bluesky_playlist_master.m3u8')));
      final info = await extractor().extract(post('3kxyzabcd2345', actor: _did));
      expect(info.formats, isNotEmpty);
      expect(server.requests.where((r) => r.uri.path.contains('resolveHandle')), isEmpty);
    });

    test('recordWithMedia: the post own media video, never the quoted post video', () async {
      server.route(_resolve, FakeRoute(body: _f('bluesky_resolve_handle.json')));
      server.route(_thread, FakeRoute(body: _f('bluesky_thread_record_with_media.json')));
      server.route(_mediaPlaylist, FakeRoute(body: _f('bluesky_playlist_master.m3u8')));

      final info = await extractor().extract(post('3kmedia222222'));

      expect(info.title, 'Bluesky video by @alice.bsky.social', reason: 'empty text falls back to the handle');
      expect(info.author, 'alice.bsky.social');
      expect(server.requests.map((r) => r.uri.path), contains(contains('bafkreimedia')));
      expect(server.requests.any((r) => r.uri.path.contains('quoted')), isFalse);
    });

    test('quote of a video post and image posts are NO_MEDIA_FOUND', () async {
      server.route(_resolve, FakeRoute(body: _f('bluesky_resolve_handle.json')));
      server.route(_thread, FakeRoute(body: _f('bluesky_thread_quote_only.json')));
      await expectLater(extractor().extract(post('3kquote333333')), _throwsStatus('NO_MEDIA_FOUND'));
      server.route(_thread, FakeRoute(body: _f('bluesky_thread_images.json')));
      await expectLater(extractor().extract(post('3kimages44444')), _throwsStatus('NO_MEDIA_FOUND'));
    });

    test('an account hidden from signed-out viewers is LOGIN_REQUIRED', () async {
      server.route(_resolve, FakeRoute(body: _f('bluesky_resolve_handle.json')));
      server.route(_thread, FakeRoute(body: _f('bluesky_thread_signed_in_only.json')));
      await expectLater(extractor().extract(post('3khidden55555')), _throwsStatus('LOGIN_REQUIRED'));
    });

    test('notFoundPost and a NotFound 400 on the thread are NOT_FOUND', () async {
      server.route(_resolve, FakeRoute(body: _f('bluesky_resolve_handle.json')));
      server.route(_thread, FakeRoute(body: _f('bluesky_thread_not_found.json')));
      await expectLater(extractor().extract(post('3kgone6666666')), _throwsStatus('NOT_FOUND'));

      server.route(_thread, FakeRoute(status: 400, body: _f('bluesky_error_not_found.json')));
      await expectLater(extractor().extract(post('3kgone6666666')), _throwsStatus('NOT_FOUND'));

    });

    test('HTTP 400 is NOT_FOUND only for XRPC error NotFound; InvalidRequest, unknown and unreadable bodies are PARSE_ERROR', () async {
      // Flip-proof: treating every 400 as NOT_FOUND turns the PARSE_ERROR lines red.
      server.route(_resolve, FakeRoute(body: _f('bluesky_resolve_handle.json')));
      server.route(_thread, FakeRoute(status: 400, body: _f('bluesky_error_not_found.json')));
      await expectLater(extractor().extract(post('3kgone6666666')), _throwsStatus('NOT_FOUND'));
      for (final body in [_f('bluesky_error_handle.json'), '{"error":"SomethingNew"}', 'not json', '[]']) {
        server.route(_thread, FakeRoute(status: 400, body: body));
        await expectLater(extractor().extract(post('3kgone6666666')), _throwsStatus('PARSE_ERROR'), reason: body);
      }
      server.route(_resolve, FakeRoute(status: 400, body: _f('bluesky_error_handle.json')));
      await expectLater(extractor().extract(post('3kgone6666666', actor: 'nobody.example.com')), _throwsStatus('PARSE_ERROR'));
      server.route(_resolve, const FakeRoute(status: 400, body: '{"error":"NotFound","message":"x"}'));
      await expectLater(extractor().extract(post('3kgone6666666', actor: 'nobody.example.com')), _throwsStatus('NOT_FOUND'));
    });

    test('blockedPost is LOGIN_REQUIRED (access, not gone) while a genuine notFoundPost stays NOT_FOUND', () async {
      server.route(_resolve, FakeRoute(body: _f('bluesky_resolve_handle.json')));
      // Flip-proof: mapping #blockedPost back to NOT_FOUND turns the first
      // expectation red; mapping notFoundPost to LOGIN_REQUIRED turns the second.
      server.route(_thread, FakeRoute(body: _f('bluesky_thread_blocked.json')));
      await expectLater(extractor().extract(post('3kblocked7777')), _throwsStatus('LOGIN_REQUIRED'));
      server.route(_thread, FakeRoute(body: _f('bluesky_thread_not_found.json')));
      await expectLater(extractor().extract(post('3kgone6666666')), _throwsStatus('NOT_FOUND'));
    });

    test('look-alike envelope type names are not the lexicon identifiers: PARSE_ERROR, never terminal, never read', () async {
      server.route(_resolve, FakeRoute(body: _f('bluesky_resolve_handle.json')));
      server.route(_thread, FakeRoute(body: _f('bluesky_thread_lookalike_blocked.json')));
      await expectLater(extractor().extract(post('3klookalike77')), _throwsStatus('PARSE_ERROR'));
      server.route(_thread, FakeRoute(body: _f('bluesky_thread_lookalike_view.json')));
      await expectLater(extractor().extract(post('3klookalike66')), _throwsStatus('PARSE_ERROR'));
      expect(server.requests.any((r) => r.host == 'video.bsky.app'), isFalse);
    });

    test('a playlist on a host outside Bluesky, or one that redirects there, is never requested', () async {
      server.route(_resolve, FakeRoute(body: _f('bluesky_resolve_handle.json')));
      server.route(_thread, FakeRoute(body: _f('bluesky_thread_offlist_playlist.json')));
      server.route('evil.test/watch/x/y/playlist.m3u8', FakeRoute(body: _f('bluesky_playlist_master.m3u8')));
      // Flip-proof: dropping withMediaHosts in the constructor lets the
      // playlist be fetched (and formats returned) from evil.test.
      await expectLater(extractor().extract(post('3koffhost2222')), _throwsStatus('PARSE_ERROR'));
      expect(server.hosts.where((h) => h.contains('evil')), isEmpty);

      server.route(_thread, FakeRoute(body: _f('bluesky_thread_video.json')));
      server.route(_playlist, const FakeRoute(status: 302, location: 'https://evil.test/watch/x/y/playlist.m3u8'));
      await expectLater(extractor().extract(post('3kxyzabcd2345')), _throwsStatus('PARSE_ERROR'));
      expect(server.hosts.where((h) => h.contains('evil')), isEmpty);
    });

    test('a thread whose post is a different record is PARSE_ERROR (never borrowed)', () async {
      server.route(_resolve, FakeRoute(body: _f('bluesky_resolve_handle.json')));
      server.route(_thread, FakeRoute(body: _f('bluesky_thread_other_post.json')));
      // Flip-proof: dropping the `post['uri'] != expectedUri` check in
      // BlueskyPostParser returns the other post's playlist instead.
      await expectLater(extractor().extract(post('3kxyzabcd2345')), _throwsStatus('PARSE_ERROR'));
      expect(server.requests.any((r) => r.host == 'video.bsky.app'), isFalse);
    });

    test('malformed JSON and a handle lookup returning a non-DID are PARSE_ERROR', () async {
      server.route(_resolve, FakeRoute(body: _f('bluesky_resolve_handle.json')));
      server.route(_thread, FakeRoute(body: _f('bluesky_malformed.json')));
      await expectLater(extractor().extract(post('3kxyzabcd2345')), _throwsStatus('PARSE_ERROR'));

      server.route(_resolve, const FakeRoute(body: '{"did":"did:plc:../../etc"}'));
      await expectLater(extractor().extract(post('3kxyzabcd2345')), _throwsStatus('PARSE_ERROR'));
      expect(server.requests.where((r) => r.uri.path.contains('getPostThread')), hasLength(1),
          reason: 'the bad DID must never reach the thread URL');
    });

    test('DRM playlist is DRM_PROTECTED; an unreadable playlist is PARSE_ERROR', () async {
      server.route(_resolve, FakeRoute(body: _f('bluesky_resolve_handle.json')));
      server.route(_thread, FakeRoute(body: _f('bluesky_thread_video.json')));
      server.route(_playlist, FakeRoute(body: _f('bluesky_playlist_drm.m3u8')));
      await expectLater(extractor().extract(post('3kxyzabcd2345')), _throwsStatus('DRM_PROTECTED'));

      server.route(_playlist, const FakeRoute(status: 404));
      await expectLater(extractor().extract(post('3kxyzabcd2345')), _throwsStatus('PARSE_ERROR'));
    });

    test('429 is RATE_LIMITED, 403 CHALLENGE_FAILED, 502 NETWORK', () async {
      server.route(_resolve, FakeRoute(body: _f('bluesky_resolve_handle.json')));
      server.route(_thread, const FakeRoute(status: 429));
      await expectLater(extractor().extract(post('3kxyzabcd2345')), _throwsStatus('RATE_LIMITED'));
      server.route(_thread, const FakeRoute(status: 403, body: 'blocked'));
      await expectLater(extractor().extract(post('3kxyzabcd2345')), _throwsStatus('CHALLENGE_FAILED'));
      server.route(_thread, const FakeRoute(status: 502));
      await expectLater(extractor().extract(post('3kxyzabcd2345')), _throwsStatus('NETWORK'));
    });

    test('an API redirect to plain http or off the API host is refused without requesting it', () async {
      server.route(_resolve, const FakeRoute(status: 302, location: 'http://public.api.bsky.app/x'));
      await expectLater(extractor().extract(post('3kxyzabcd2345')), _throwsStatus('UNSUPPORTED_URL'));
      server.route(_resolve, const FakeRoute(status: 302, location: 'https://evil.test/x'));
      await expectLater(extractor().extract(post('3kxyzabcd2345')), _throwsStatus('PARSE_ERROR'));
      expect(server.hosts, [_api, _api]);
    });
  });

  test('an HLS master on the allowed host that lists an off-list variant: that variant is absent and never requested', () async {
    server.route(_resolve, FakeRoute(body: _f('bluesky_resolve_handle.json')));
    server.route(_thread, FakeRoute(body: _f('bluesky_thread_video.json')));
    server.route(_playlist, FakeRoute(body: _f('bluesky_playlist_offlist_variant.m3u8')));
    final info = await extractor().extract(post('3kxyzabcd2345'));
    expect(info.formats.map((f) => f.height), [360]);
    expect(server.hosts.contains('evil.test'), isFalse);
  });

  group('BlueskyUrlMatcher', () {
    test('undecodable percent bytes never throw: no match', () {
      expect(BlueskyUrlMatcher.match(Uri.parse('https://bsky.app/profile/alice.bsky.social/post/%FF')), isNull);
      expect(BlueskyUrlMatcher.match(Uri.parse('https://bsky.app/profile/%FF/post/3kxyzabcd2345')), isNull);
    });

    test('accepts handle and DID post URLs', () {
      final byHandle = BlueskyUrlMatcher.match(post('3kxyzabcd2345', actor: 'Alice.Bsky.Social'));
      expect(byHandle!.actor, 'alice.bsky.social');
      expect(byHandle.rkey, '3kxyzabcd2345');
      expect(BlueskyUrlMatcher.match(post('3kxyzabcd2345', actor: _did))!.actorIsDid, isTrue);
      expect(BlueskyUrlMatcher.match(Uri.parse('https://www.bsky.app/profile/did:web:example.com/post/3kxyzabcd2345/')),
          isNotNull);
      expect(BlueskyUrlMatcher.match(Uri.parse('https://bsky.app/profile/alice.bsky.social/post/3kxyzabcd2345?x=1')),
          isNotNull);
    });

    test('rejects profiles, feeds, bad rkeys, bad actors and foreign hosts', () {
      for (final input in [
        'https://bsky.app/profile/alice.bsky.social',
        'https://bsky.app/profile/alice.bsky.social/feed/abc',
        'https://bsky.app/profile/alice.bsky.social/post/short',
        'https://bsky.app/profile/alice.bsky.social/post/3kxyzabcd234A',
        'https://bsky.app/profile/alice.bsky.social/post/3kxyzabcd2345/extra',
        'https://bsky.app/profile/alice/post/3kxyzabcd2345',
        'https://bsky.app/profile/-alice.bsky.social/post/3kxyzabcd2345',
        'https://bsky.app/profile/alice.bsky.social%2F..%2Fx/post/3kxyzabcd2345',
        'https://bsky.app/profile/did:plc:short/post/3kxyzabcd2345',
        'https://bsky.app/profile/did:plc:z72i7hdynmk6r22z27h6tvu1/post/3kxyzabcd2345',
        'https://bsky.app/profile/did:key:abc/post/3kxyzabcd2345',
        'https://bsky.social/profile/alice.bsky.social/post/3kxyzabcd2345',
        'https://bsky.app.evil.test/profile/alice.bsky.social/post/3kxyzabcd2345',
        'ftp://bsky.app/profile/alice.bsky.social/post/3kxyzabcd2345',
      ]) {
        expect(BlueskyUrlMatcher.match(Uri.parse(input)), isNull, reason: input);
      }
    });
  });
}
