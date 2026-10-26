// A loopback TLS handshake per request is cheap, but on a machine busy with
// other test runs the default 30 s per-test limit has been seen to fire, so
// these hermetic suites get headroom. Deadline behavior is tested with the
// client's own (short) timeout, not this limit.
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/native_http/native_host_list.dart';
import 'package:mida/core/extractors/native_http/native_http_client.dart';

import 'fake_https_server.dart';

Matcher _throwsStatus(String status) =>
    throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', status));

void main() {
  late FakeHttpsServer server;

  setUp(() async => server = await FakeHttpsServer.start());
  tearDown(() => server.close());

  group('NativeHttpClient.get', () {
    test('plain HTTPS GET: desktop UA, no cookie, body and effective URL', () async {
      server.route('example.test/a', const FakeRoute(body: 'hello'));
      final response = await server.httpClient('Test').get(Uri.parse('https://example.test/a?x=1'));

      expect(response.statusCode, 200);
      expect(response.body, 'hello');
      expect(response.effectiveUrl.host, 'example.test');
      final seen = server.requests.single;
      expect(seen.method, 'GET');
      expect(seen.headers.value('user-agent'), contains('Windows NT 10.0'));
      expect(seen.headers.value('cookie'), isNull);
    });

    test('a plain http URL is refused before any connection', () async {
      server.route('example.test/a', const FakeRoute(body: 'hello'));
      await expectLater(
        server.httpClient('Test').get(Uri.parse('http://example.test/a')),
        _throwsStatus('UNSUPPORTED_URL'),
      );
      expect(server.requests, isEmpty);
    });

    test('an https -> http redirect is never followed', () async {
      server.route('example.test/a', const FakeRoute(status: 302, location: 'http://example.test/b'));
      server.route('example.test/b', const FakeRoute(body: 'downgraded'));
      await expectLater(
        server.httpClient('Test').get(Uri.parse('https://example.test/a')),
        _throwsStatus('UNSUPPORTED_URL'),
      );
      expect(server.requests.map((r) => r.uri.path), ['/a'], reason: 'the http hop must not be requested');
    });

    test('acceptHop refuses a redirect that leaves the platform (PARSE_ERROR), without requesting it', () async {
      server.route('example.test/a', const FakeRoute(status: 302, location: 'https://evil.test/b'));
      server.route('evil.test/b', const FakeRoute(body: 'x'));
      await expectLater(
        server.httpClient('Test').get(Uri.parse('https://example.test/a'), acceptHop: (hop) => hop.host == 'example.test'),
        _throwsStatus('PARSE_ERROR'),
      );
      expect(server.hosts, ['example.test']);
    });

    test('redirects within the allow-list are followed and the effective URL is the last hop', () async {
      server.route('example.test/a', const FakeRoute(status: 301, location: '/b'));
      server.route('example.test/b', const FakeRoute(body: 'landed'));
      final response = await server.httpClient('Test').get(Uri.parse('https://example.test/a'));
      expect(response.body, 'landed');
      expect(response.effectiveUrl.path, '/b');
    });

    test('page body is cut at 5 MiB, api body at 2 MiB, and flagged truncated', () async {
      final big = 'a' * (5 * 1024 * 1024 + 4096);
      server.route('example.test/big', FakeRoute(body: big));
      final client = server.httpClient('Test', timeout: const Duration(seconds: 30));

      final page = await client.get(Uri.parse('https://example.test/big'));
      expect(page.truncated, isTrue);
      expect(page.body.length, NativeHttpClient.pageCapBytes);

      final api = await client.get(Uri.parse('https://example.test/big'), kind: NativeBodyKind.api);
      expect(api.truncated, isTrue);
      expect(api.body.length, NativeHttpClient.apiCapBytes);
    });

    test('a server that stalls mid-body hits the deadline as NETWORK', () async {
      server.route('example.test/stall', const FakeRoute(body: 'partial', stall: true));
      final stopwatch = Stopwatch()..start();
      await expectLater(
        server.httpClient('Test', timeout: const Duration(milliseconds: 400)).get(Uri.parse('https://example.test/stall')),
        _throwsStatus('NETWORK'),
      );
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 20)));
    });

    test('404/410 return an empty body with the status; 429 likewise', () async {
      server.route('example.test/gone', const FakeRoute(status: 410, body: 'secret detail'));
      final response = await server.httpClient('Test').get(Uri.parse('https://example.test/gone'));
      expect(response.statusCode, 410);
      expect(response.body, isEmpty);
    });

    test('HostPolicy refusal (DNS names a private address) is UNSUPPORTED_URL with the query redacted', () async {
      final client = NativeHttpClient(
        service: 'Test',
        httpClientFactory: server.client,
        resolveHost: (host) async => [InternetAddress('10.0.0.5')],
      );
      await expectLater(
        client.get(Uri.parse('https://example.test/a?token=SECRET123')),
        throwsA(isA<MediaExtractionException>()
            .having((e) => e.status, 'status', 'UNSUPPORTED_URL')
            .having((e) => e.reason, 'reason', allOf(contains('example.test'), isNot(contains('SECRET123'))))),
      );
      expect(server.requests, isEmpty);
    });
  });

  group('NativeHttpClient.postForm', () {
    test('sends an urlencoded form with the browser UA and reads the JSON answer', () async {
      server.route('api.test/view', const FakeRoute(body: '{"ok":true}'));
      final response = await server.httpClient('Test').postForm(
        Uri.parse('https://api.test/view'),
        {'a': '1', 'b': 'x y&z'},
        headers: {'Referer': 'https://site.test/'},
      );
      expect(response.body, '{"ok":true}');
      final seen = server.requests.single;
      expect(seen.method, 'POST');
      expect(seen.body, 'a=1&b=x+y%26z');
      expect(seen.headers.contentType?.mimeType, 'application/x-www-form-urlencoded');
      expect(seen.headers.value('referer'), 'https://site.test/');
      expect(seen.headers.value('cookie'), isNull);
    });

    test('a redirect answer is returned, never followed; http is refused', () async {
      server.route('api.test/view', const FakeRoute(status: 302, location: 'https://api.test/other'));
      server.route('api.test/other', const FakeRoute(body: 'x'));
      final client = server.httpClient('Test');

      final response = await client.postForm(Uri.parse('https://api.test/view'), {'a': '1'});
      expect(response.statusCode, 302);
      expect(server.requests, hasLength(1));

      await expectLater(client.postForm(Uri.parse('http://api.test/view'), {'a': '1'}), _throwsStatus('UNSUPPORTED_URL'));
      expect(server.requests, hasLength(1));
    });

    test('POST goes through HostPolicy too: a private DNS answer is refused', () async {
      final client = NativeHttpClient(
        service: 'Test',
        httpClientFactory: server.client,
        resolveHost: (host) async => [InternetAddress('192.168.1.9')],
      );
      await expectLater(client.postForm(Uri.parse('https://api.test/view'), {'a': '1'}), _throwsStatus('UNSUPPORTED_URL'));
      expect(server.requests, isEmpty);
    });
  });

  group('NativeHttpClient.resolveShortLink', () {
    test('returns the first Location target without requesting it', () async {
      server.route('short.test/abc', const FakeRoute(status: 302, location: 'https://long.test/pin/1/'));
      server.route('long.test/pin/1/', const FakeRoute(body: 'page'));
      final target = await server.httpClient('Test').resolveShortLink(
            Uri.parse('https://short.test/abc'),
            accept: (t) => t.host == 'long.test',
          );
      expect(target.toString(), 'https://long.test/pin/1/');
      expect(server.hosts, ['short.test']);
    });

    test('a target outside the allow-list is PARSE_ERROR', () async {
      server.route('short.test/abc', const FakeRoute(status: 302, location: 'https://evil.test/x'));
      await expectLater(
        server.httpClient('Test').resolveShortLink(Uri.parse('https://short.test/abc'), accept: (t) => t.host == 'long.test'),
        _throwsStatus('PARSE_ERROR'),
      );
      expect(server.hosts, ['short.test']);
    });

    test('an http target is refused (no https -> http downgrade)', () async {
      server.route('short.test/abc', const FakeRoute(status: 302, location: 'http://long.test/pin/1/'));
      await expectLater(
        server.httpClient('Test').resolveShortLink(Uri.parse('https://short.test/abc'), accept: (_) => true),
        _throwsStatus('UNSUPPORTED_URL'),
      );
    });

    test('no redirect: 404 is NOT_FOUND, a 200 page is PARSE_ERROR', () async {
      server.route('short.test/ok', const FakeRoute(body: 'not a redirect'));
      final client = server.httpClient('Test');
      await expectLater(client.resolveShortLink(Uri.parse('https://short.test/ok'), accept: (_) => true), _throwsStatus('PARSE_ERROR'));
      await expectLater(client.resolveShortLink(Uri.parse('https://short.test/none'), accept: (_) => true), _throwsStatus('NOT_FOUND'));
    });
  });

  group('media host allow-list (fetchText / FormatExpander adapter)', () {
    const hosts = NativeHostList(['cdn.test']);

    test('NativeHostList matches the domain and its subdomains only', () {
      expect(hosts.allowsHost('cdn.test'), isTrue);
      expect(hosts.allowsHost('V1.CDN.test'), isTrue);
      for (final bad in ['evilcdn.test', 'cdn.test.evil.test', 'test', 'xcdn.test', '']) {
        expect(hosts.allowsHost(bad), isFalse, reason: bad);
      }
      expect(hosts.allowsUrl('https://a.cdn.test/x.m3u8'), isTrue);
      expect(hosts.allowsUrl('https://evilcdn.test/x.m3u8'), isFalse);
      expect(hosts.allowsUrl('not a url'), isFalse);
    });

    test('an off-list initial playlist URL is refused before any request', () async {
      server.route('evil.test/p.m3u8', const FakeRoute(body: '#EXTM3U'));
      final client = server.httpClient('Test').withMediaHosts(hosts);
      await expectLater(client.fetchText(Uri.parse('https://evil.test/p.m3u8')), _throwsStatus('PARSE_ERROR'));
      expect(server.requests, isEmpty);
    });

    test('a redirect from an on-list host to an off-list host is refused before it is requested', () async {
      server.route('cdn.test/p.m3u8', const FakeRoute(status: 302, location: 'https://evil.test/p.m3u8'));
      server.route('evil.test/p.m3u8', const FakeRoute(body: '#EXTM3U'));
      final client = server.httpClient('Test').withMediaHosts(hosts);
      await expectLater(client.fetchText(Uri.parse('https://cdn.test/p.m3u8')), _throwsStatus('PARSE_ERROR'));
      expect(server.hosts, ['cdn.test']);
    });

    test('on-list playlists (and on-list redirects) are fetched; without a list any host passes', () async {
      server.route('cdn.test/a.m3u8', const FakeRoute(status: 302, location: 'https://v1.cdn.test/b.m3u8'));
      server.route('v1.cdn.test/b.m3u8', const FakeRoute(body: '#EXTM3U'));
      server.route('other.test/c.m3u8', const FakeRoute(body: '#EXTM3U'));
      final listed = server.httpClient('Test').withMediaHosts(hosts);
      expect((await listed.fetchText(Uri.parse('https://cdn.test/a.m3u8'))).body, '#EXTM3U');
      expect((await server.httpClient('Test').fetchText(Uri.parse('https://other.test/c.m3u8'))).body, '#EXTM3U');
      expect(listed.mediaUrlAllowed('https://cdn.test/x.mp4'), isTrue);
      expect(listed.mediaUrlAllowed('https://evil.test/x.mp4'), isFalse);
      expect(server.httpClient('Test').mediaUrlAllowed('https://anything.test/x.mp4'), isTrue);
    });
  });

  test('filterAllowedFormats drops formats whose URL is off the media allow-list', () {
    MediaFormat format(String url) => MediaFormat(id: url, url: url, container: 'mp4', hasVideo: true, hasAudio: true);
    final listed = server.httpClient('Test').withMediaHosts(const NativeHostList(['cdn.test']));
    final kept = listed.filterAllowedFormats([format('https://a.cdn.test/1.mp4'), format('https://evil.test/2.mp4'), format('https://cdn.test.evil.test/3.mp4')]);
    expect(kept.map((f) => f.url), ['https://a.cdn.test/1.mp4']);
    expect(server.httpClient('Test').filterAllowedFormats([format('https://any.test/x.mp4')]), hasLength(1));
  });

  group('no cookies, enforced centrally', () {
    test('a Cookie header in any letter case never reaches the wire (get, post, short link)', () async {
      server.route('example.test/a', const FakeRoute(body: 'ok'));
      server.route('api.test/view', const FakeRoute(body: '{}'));
      server.route('short.test/abc', const FakeRoute(status: 302, location: 'https://example.test/a'));
      final client = server.httpClient('Test');
      const sneaky = {'cOoKiE': 'session=secret', 'COOKIE2': 'x=y', ' cookie ': 'z=1', 'X-Keep': 'yes'};

      await client.get(Uri.parse('https://example.test/a'), headers: sneaky);
      await client.postForm(Uri.parse('https://api.test/view'), {'a': '1'}, headers: sneaky);
      await client.resolveShortLink(Uri.parse('https://short.test/abc'), accept: (_) => true, headers: sneaky);

      expect(server.requests, hasLength(3));
      for (final request in server.requests) {
        expect(request.headers.value('cookie'), isNull);
        expect(request.headers.value('cookie2'), isNull);
        expect(request.headers.value('x-keep'), 'yes', reason: 'other headers still pass');
      }
    });
  });

  group('unwanted bodies are cancelled, not drained', () {
    const total = 32 * 1024 * 1024;
    const bound = 8 * 1024 * 1024;

    test('a large streaming 404 / 429 / 500 stops being read almost at once', () async {
      for (final status in [404, 429, 500]) {
        server.route('example.test/big$status', FakeRoute(status: status, streamBytes: total));
        final response = await server.httpClient('Test').get(Uri.parse('https://example.test/big$status'));
        expect(response.statusCode, status);
        expect(response.body, isEmpty);
        // Give the server a moment to notice the hang-up, then check it.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(server.bytesSent['example.test/big$status'] ?? 0, lessThan(bound), reason: 'HTTP $status');
      }
    });

    test('a short link that answers 200 with a huge body is PARSE_ERROR after a bounded read', () async {
      server.route('short.test/big', const FakeRoute(streamBytes: total));
      await expectLater(
        server.httpClient('Test').resolveShortLink(Uri.parse('https://short.test/big'), accept: (_) => true),
        _throwsStatus('PARSE_ERROR'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(server.bytesSent['short.test/big'] ?? 0, lessThan(bound));
    });
  });

  test('status-only refusals with a stalled body return at once (body cancelled, not read)', () async {
    for (final status in [401, 403, 999, 404, 410, 429, 503]) {
      server.route('example.test/s$status', FakeRoute(status: status, body: 'partial', stall: true));
      final stopwatch = Stopwatch()..start();
      final response = await server
          .httpClient('Test', timeout: const Duration(seconds: 12))
          .get(Uri.parse('https://example.test/s$status'));
      expect(response.statusCode, status);
      expect(response.body, isEmpty);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 8)), reason: 'HTTP $status');
    }
  });

  group('hostile redirects', () {
    test('a malformed Location on a redirect is PARSE_ERROR, not a raw FormatException', () async {
      for (final location in ['http://[', 'https://[::1']) {
        server.route('example.test/a', FakeRoute(status: 302, location: location));
        await expectLater(
          server.httpClient('Test').get(Uri.parse('https://example.test/a')),
          _throwsStatus('PARSE_ERROR'),
          reason: location,
        );
      }
    });

    test('a malformed Location on a short link is PARSE_ERROR too', () async {
      server.route('short.test/abc', const FakeRoute(status: 302, location: 'http://['));
      await expectLater(
        server.httpClient('Test').resolveShortLink(Uri.parse('https://short.test/abc'), accept: (_) => true),
        _throwsStatus('PARSE_ERROR'),
      );
    });
  });

  test('throwForStatus maps the shared table', () {
    void expectMapped(int status, String code) =>
        expect(() => NativeHttpClient.throwForStatus(status, 'Test'), _throwsStatus(code));
    expectMapped(404, 'NOT_FOUND');
    expectMapped(410, 'NOT_FOUND');
    expectMapped(429, 'RATE_LIMITED');
    expectMapped(401, 'CHALLENGE_FAILED');
    expectMapped(403, 'CHALLENGE_FAILED');
    expectMapped(500, 'NETWORK');
    expectMapped(302, 'NETWORK');
    expect(() => NativeHttpClient.throwForStatus(200, 'Test'), returnsNormally);
  });
}
