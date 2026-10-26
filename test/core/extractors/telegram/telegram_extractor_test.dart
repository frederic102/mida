import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/telegram/telegram_extractor.dart';

import '../native_http/fake_https_server.dart';

Matcher _throwsStatus(String status) =>
    throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', status));

void main() {
  late FakeHttpsServer server;

  setUp(() async => server = await FakeHttpsServer.start());
  tearDown(() => server.close());

  TelegramExtractor extractor() => TelegramExtractor(httpClient: server.httpClient('Telegram', timeout: const Duration(seconds: 30)));

  group('TelegramExtractor.extract (hermetic, loopback TLS)', () {
    test('single video post: one muxed-unknown mp4, metadata, embed endpoint with no cookie', () async {
      server.route('t.me/mida_demo/101', FakeRoute(body: fixture('telegram', 'telegram_post_video.html')));

      final info = await extractor().extract(Uri.parse('https://t.me/s/mida_demo/101'));

      expect(info.id, 'mida_demo_101');
      expect(info.title, 'First line <b> of the caption second line with link');
      expect(info.author, 'MiDa & Friends');
      expect(info.duration, const Duration(hours: 1, minutes: 2, seconds: 3));
      expect(info.thumbnailUrl, 'https://cdn4.cdn-telegram.org/file/thumb101.jpg?token=abc&x=1');
      final format = info.formats.single;
      expect(format.url, 'https://cdn4.cdn-telegram.org/file/video101.mp4?token=sig&e=2');
      expect(format.container, 'mp4');
      expect(format.isMuxed, isTrue);
      expect(format.capabilitiesUnknown, isTrue);
      expect(info.sourceUrl.toString(), 'https://t.me/s/mida_demo/101');
      expect(info.requestHeaders['User-Agent'], contains('Windows NT 10.0'));

      final seen = server.requests.single;
      expect(seen.host, 't.me');
      expect(seen.uri.path, '/mida_demo/101');
      expect(seen.uri.queryParameters, {'embed': '1', 'mode': 'tme'});
      expect(seen.headers.value('cookie'), isNull);
    });

    test('album: only the player whose own link names the requested post, caption not borrowed', () async {
      server.route('t.me/mida_demo/201', FakeRoute(body: fixture('telegram', 'telegram_post_album.html')));

      final info = await extractor().extract(Uri.parse('https://t.me/mida_demo/201'));

      // Flip-proof: replacing the linked-post match in TelegramExtractor._pick
      // with "first video" returns video200 here and fails this test.
      expect(info.formats.single.url, endsWith('/video201.mp4'));
      expect(info.duration, const Duration(seconds: 20));
      expect(info.thumbnailUrl, endsWith('/thumb201.jpg'));
      expect(info.title, 'Telegram video mida_demo/201', reason: 'the caption belongs to mida_demo/200');
      expect(info.author, 'MiDa Demo');
    });

    test('album leader: the first video and its caption', () async {
      server.route('t.me/mida_demo/200', FakeRoute(body: fixture('telegram', 'telegram_post_album.html')));
      final info = await extractor().extract(Uri.parse('https://t.me/mida_demo/200'));
      expect(info.formats.single.url, endsWith('/video200.mp4'));
      expect(info.title, 'Album caption belongs to the first message');
    });

    test('album member that is not in the embed: NO_MEDIA_FOUND, never a sibling video', () async {
      server.route('t.me/mida_demo/202', FakeRoute(body: fixture('telegram', 'telegram_post_album.html')));
      await expectLater(extractor().extract(Uri.parse('https://t.me/mida_demo/202')), _throwsStatus('NO_MEDIA_FOUND'));
    });

    test('two message containers, only the second has a video: the first is NO_MEDIA_FOUND, the second keeps its own fields', () async {
      server.route('t.me/chan_x/1', FakeRoute(body: fixture('telegram', 'telegram_two_messages.html')));
      server.route('t.me/chan_x/2', FakeRoute(body: fixture('telegram', 'telegram_two_messages.html')));

      // Flip-proof: scanning players across the whole document (instead of
      // the message's own container) hands message two's video to message one.
      await expectLater(extractor().extract(Uri.parse('https://t.me/chan_x/1')), _throwsStatus('NO_MEDIA_FOUND'));

      final second = await extractor().extract(Uri.parse('https://t.me/chan_x/2'));
      expect(second.formats.single.url, endsWith('/video2.mp4'));
      expect(second.author, 'Author Two');
      expect(second.title, 'Caption of message two', reason: 'not message one caption');
      expect(second.duration, const Duration(seconds: 30));
    });

    test('a player after the requested container has closed is never its video', () async {
      server.route('t.me/chan_x/60', FakeRoute(body: fixture('telegram', 'telegram_external_player.html')));
      // Flip-proof: ending the span at EOF instead of the element's close hands it the outsider.
      await expectLater(extractor().extract(Uri.parse('https://t.me/chan_x/60')), _throwsStatus('NO_MEDIA_FOUND'));
    });

    test('tags inside comments and script bodies do not extend the message element: the neighbor player is never returned', () async {
      server.route('t.me/news/1', FakeRoute(body: fixture('telegram', 'telegram_comment_depth.html')));
      // Flip-proof: counting comment/script tags as structure keeps depth open past the neighbor.
      await expectLater(extractor().extract(Uri.parse('https://t.me/news/1')), _throwsStatus('NO_MEDIA_FOUND'));
    });

    test('data-post inside comments and script bodies is not a message: exactly one message owns the player', () async {
      server.route('t.me/chan_x/1', FakeRoute(body: fixture('telegram', 'telegram_comment_datapost.html')));
      // Flip-proof: discovering data-post by raw text scan creates phantom messages chan_x/2 and chan_x/3.
      final info = await extractor().extract(Uri.parse('https://t.me/chan_x/1'));
      expect(info.formats.single.url, endsWith('/own.mp4'));
      server.route('t.me/chan_x/2', FakeRoute(body: fixture('telegram', 'telegram_comment_datapost.html')));
      await expectLater(extractor().extract(Uri.parse('https://t.me/chan_x/2')), _throwsStatus('NO_MEDIA_FOUND'));
    });

    test('ambiguous ownership is NO_MEDIA_FOUND: several unlinked players, or a player linked to another post', () async {
      server.route('t.me/chan_x/9', FakeRoute(body: fixture('telegram', 'telegram_ambiguous_players.html')));
      server.route('t.me/chan_x/7', FakeRoute(body: fixture('telegram', 'telegram_linked_elsewhere.html')));
      await expectLater(extractor().extract(Uri.parse('https://t.me/chan_x/9')), _throwsStatus('NO_MEDIA_FOUND'));
      await expectLater(extractor().extract(Uri.parse('https://t.me/chan_x/7')), _throwsStatus('NO_MEDIA_FOUND'));
      // The player linked to chan_x/8 is still returned for chan_x/8 itself.
      server.route('t.me/chan_x/8', FakeRoute(body: fixture('telegram', 'telegram_linked_elsewhere.html')));
      final eight = await extractor().extract(Uri.parse('https://t.me/chan_x/8'));
      expect(eight.formats.single.url, endsWith('/eight.mp4'));
    });

    test('post without a video is NO_MEDIA_FOUND; a source-less player says why', () async {
      server.route('t.me/mida_demo/102', FakeRoute(body: fixture('telegram', 'telegram_post_text_only.html')));
      server.route('t.me/mida_demo/103', FakeRoute(body: fixture('telegram', 'telegram_post_sourceless_player.html')));
      await expectLater(extractor().extract(Uri.parse('https://t.me/mida_demo/102')), _throwsStatus('NO_MEDIA_FOUND'));
      await expectLater(
        extractor().extract(Uri.parse('https://t.me/mida_demo/103')),
        throwsA(isA<MediaExtractionException>()
            .having((e) => e.status, 'status', 'NO_MEDIA_FOUND')
            .having((e) => e.reason, 'reason', contains('too large'))),
      );
    });

    test('Telegram "Post not found" box and HTTP 404 are NOT_FOUND', () async {
      server.route('t.me/mida_demo/104', FakeRoute(body: fixture('telegram', 'telegram_post_not_found.html')));
      await expectLater(extractor().extract(Uri.parse('https://t.me/mida_demo/104')), _throwsStatus('NOT_FOUND'));
      // No route registered: the fake answers 404.
      await expectLater(extractor().extract(Uri.parse('https://t.me/mida_demo/105')), _throwsStatus('NOT_FOUND'));
    });

    test('a channel landing page is CHALLENGE_FAILED (falls through); only explicit "private" wording is LOGIN_REQUIRED', () async {
      server.route('t.me/chan_land/7', FakeRoute(body: fixture('telegram', 'telegram_landing_page.html')));
      server.route('t.me/secret_chan/7', FakeRoute(body: fixture('telegram', 'telegram_explicit_private.html')));
      // Flip-proof: mapping noPreview back to LOGIN_REQUIRED turns the first line red.
      await expectLater(extractor().extract(Uri.parse('https://t.me/chan_land/7')), _throwsStatus('CHALLENGE_FAILED'));
      await expectLater(extractor().extract(Uri.parse('https://t.me/secret_chan/7')), _throwsStatus('LOGIN_REQUIRED'));
      // Only Telegram's explicit "Post not found" is terminal.
      server.route('t.me/chan_land/8', FakeRoute(body: fixture('telegram', 'telegram_post_not_found.html')));
      await expectLater(extractor().extract(Uri.parse('https://t.me/chan_land/8')), _throwsStatus('NOT_FOUND'));
    });

    test('a video or thumbnail host outside the Telegram CDN list is refused, never offered', () async {
      server.route('t.me/chan_x/50', FakeRoute(body: fixture('telegram', 'telegram_offlist_video.html')));
      await expectLater(extractor().extract(Uri.parse('https://t.me/chan_x/50')), _throwsStatus('PARSE_ERROR'));
      // On-list fixtures keep working, thumbnail included.
      server.route('t.me/mida_demo/101', FakeRoute(body: fixture('telegram', 'telegram_post_video.html')));
      final ok = await extractor().extract(Uri.parse('https://t.me/mida_demo/101'));
      expect(ok.thumbnailUrl, isNotNull);
    });

    test('unrecognized page is PARSE_ERROR; 429 RATE_LIMITED; 403 CHALLENGE_FAILED; 503 NETWORK', () async {
      server.route('t.me/mida_demo/110', FakeRoute(body: fixture('telegram', 'telegram_malformed.html')));
      server.route('t.me/mida_demo/111', const FakeRoute(status: 429));
      server.route('t.me/mida_demo/112', const FakeRoute(status: 403, body: 'blocked'));
      server.route('t.me/mida_demo/113', const FakeRoute(status: 503));
      await expectLater(extractor().extract(Uri.parse('https://t.me/mida_demo/110')), _throwsStatus('PARSE_ERROR'));
      await expectLater(extractor().extract(Uri.parse('https://t.me/mida_demo/111')), _throwsStatus('RATE_LIMITED'));
      await expectLater(extractor().extract(Uri.parse('https://t.me/mida_demo/112')), _throwsStatus('CHALLENGE_FAILED'));
      await expectLater(extractor().extract(Uri.parse('https://t.me/mida_demo/113')), _throwsStatus('NETWORK'));
    });

    test('a redirect to plain http or off Telegram is refused without requesting the target', () async {
      server.route('t.me/mida_demo/120', const FakeRoute(status: 302, location: 'http://t.me/mida_demo/121'));
      server.route('t.me/mida_demo/130', const FakeRoute(status: 302, location: 'https://evil.test/x'));
      server.route('evil.test/x', FakeRoute(body: fixture('telegram', 'telegram_post_video.html')));
      await expectLater(extractor().extract(Uri.parse('https://t.me/mida_demo/120')), _throwsStatus('UNSUPPORTED_URL'));
      await expectLater(extractor().extract(Uri.parse('https://t.me/mida_demo/130')), _throwsStatus('PARSE_ERROR'));
      expect(server.hosts, ['t.me', 't.me'], reason: 'neither redirect target may be requested');
    });

    test('a non-Telegram URL is UNSUPPORTED_URL and canHandle is false', () async {
      final e = extractor();
      expect(e.canHandle(Uri.parse('https://t.me/mida_demo/101')), isTrue);
      expect(e.canHandle(Uri.parse('https://t.me/c/1/2')), isFalse);
      await expectLater(e.extract(Uri.parse('https://example.com/a/1')), _throwsStatus('UNSUPPORTED_URL'));
    });
  });
}
