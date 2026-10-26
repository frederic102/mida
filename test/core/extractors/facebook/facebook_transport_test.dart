import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/facebook/facebook_page_fetcher.dart';
import 'package:mida/core/extractors/facebook/facebook_url_matcher.dart';
import 'package:mida/core/extractors/media_models.dart';

import '../generic/stall_server.dart';
import 'facebook_fake_server.dart';

Matcher _throwsStatus(String status) =>
    throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', status));

/// Transport rules of the native Facebook path (HTTPS only, Facebook hosts
/// only, bounded time and bytes). Hermetic: loopback servers only.
void main() {
  group('HTTPS only', () {
    late FakeFacebookServer server;
    setUp(() async => server = await FakeFacebookServer.start());
    tearDown(() => server.close());

    test('matcher: http input always yields an https fetch URL (page and short link)', () {
      for (final url in [
        'http://www.facebook.com/reel/1234567890',
        'http://m.facebook.com/watch/?v=42',
        'http://www.facebook.com/share/v/1AbCdEf/',
        'http://fb.watch/aBc12_x/',
      ]) {
        expect(FacebookUrlMatcher.match(Uri.parse(url))!.fetchUrl.scheme, 'https', reason: url);
      }
    });

    test('an http input is requested over https, never in the clear', () async {
      server.route('www.facebook.com/reel/3333333333333', FakeRoute(body: fixture('facebook_reel_inline_js.html')));
      final info = await server.extractor().extract(Uri.parse('http://www.facebook.com/reel/3333333333333'));
      expect(info.formats, isNotEmpty);
      expect(server.requested.map((u) => u.scheme), ['https']);
    });

    test('an HTTPS to HTTP redirect is refused before the HTTP request is made', () async {
      server.route('fb.watch/dg', const FakeRoute(status: 302, location: 'http://www.facebook.com/reel/3333333333333'));
      server.route('www.facebook.com/reel/3333333333333', FakeRoute(body: fixture('facebook_reel_inline_js.html')));
      await expectLater(server.extractor().extract(Uri.parse('https://fb.watch/dg')), _throwsStatus('UNSUPPORTED_URL'));
      expect(server.requested.map((u) => '${u.scheme}://${u.host}'), ['https://fb.watch']);
    });

    test('the fetcher itself refuses an http URL without any request', () async {
      await expectLater(
        server.fetcher().fetchPage(Uri.parse('http://www.facebook.com/reel/1')),
        _throwsStatus('UNSUPPORTED_URL'),
      );
      expect(server.requested, isEmpty);
    });

    test('a manifest fetch (fbcdn host) is allowed off facebook.com but stays HTTPS only', () async {
      server.route('video.xx.fbcdn.net/m.mpd', const FakeRoute(body: '<MPD></MPD>'));
      final ok = await server.fetcher().fetchText(Uri.parse('https://video.xx.fbcdn.net/m.mpd'));
      expect(ok.body, '<MPD></MPD>');
      await expectLater(
        server.fetcher().fetchText(Uri.parse('http://video.xx.fbcdn.net/m.mpd')),
        _throwsStatus('UNSUPPORTED_URL'),
      );
      expect(server.requested.map((u) => u.scheme), ['https']);
    });

    test('body cap is 5 MiB: playback data past 2 MiB is still read', () async {
      final page = fixture('facebook_video_hd_sd.html');
      final padded = page.replaceFirst('<body>', '<body><!--${'x' * (2 * 1024 * 1024 + 10)}-->');
      server.route('www.facebook.com/reel/1234567890123', FakeRoute(body: padded));
      final info = await server.extractor().extract(Uri.parse('https://www.facebook.com/reel/1234567890123'));
      expect(info.formats.first.url, contains('target_hd.mp4'));
      expect(FacebookPageFetcher.maxBodyBytes, 5 * 1024 * 1024);
    });
  });

  group('bounded time', () {
    test('a 429 whose body never finishes completes at once and the connection is closed', () async {
      final stall = await StallServer.start(
        head: 'HTTP/1.1 429 Too Many Requests\r\nContent-Length: 1000000\r\n\r\npartial',
      );
      addTearDown(stall.close);
      final fetcher = FacebookPageFetcher(httpClientFactory: stall.client, resolveHost: FakeFacebookServer.publicAddress);

      final watch = Stopwatch()..start();
      final page = await fetcher.fetchPage(Uri.parse('https://www.facebook.com/reel/1')).timeout(const Duration(seconds: 3));
      expect(page.statusCode, 429);
      expect(page.body, isEmpty);
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      await stall.closedByClient.single.future.timeout(const Duration(seconds: 2));
    });

    test('a 200 page body that stalls is cut off by the fetch deadline, connection closed', () async {
      final stall = await StallServer.start(
        head: 'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 1000000\r\n\r\n<html>',
      );
      addTearDown(stall.close);
      final fetcher = FacebookPageFetcher(
        httpClientFactory: stall.client,
        resolveHost: FakeFacebookServer.publicAddress,
        timeout: const Duration(milliseconds: 300),
      );
      await expectLater(
        fetcher.fetchPage(Uri.parse('https://www.facebook.com/reel/1')).timeout(const Duration(seconds: 3)),
        _throwsStatus('NETWORK'),
      );
      await stall.closedByClient.single.future.timeout(const Duration(seconds: 2));
    });
  });
}
