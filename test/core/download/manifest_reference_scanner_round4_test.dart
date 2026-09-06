import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/manifest_reference_scanner.dart';
import 'package:mida/core/extractors/media_models.dart';

/// Phase 6 round 4 additions to `ManifestReferenceScanner`, split out of
/// `manifest_reference_scanner_test.dart` so both stay under this
/// project's 400-line cap:
///  - B-R4-1: a playlist body is parsed against the LAST hop it actually
///    came from, not the pre-redirect URL it was requested at.
///  - B-R4-2: a redirect hop outside the cookie's scope is reported even
///    when nothing IN the redirected body is.
///  - B-R4-6: the old "the manifest's own host is always in scope"
///    shortcut is gone - even a same-host reference is checked against
///    `CookieScope.headerFor` when `cookiesByDomain` is known.
///  - B-R4-7: `declaredDuration` is scoped to what is actually being
///    downloaded (the root URL's own signal wins outright; sibling
///    variants disagreeing by more than 10% report null instead of an
///    arbitrary pick).
Future<List<InternetAddress>> _fakePublicResolver(String host) async => [InternetAddress('93.184.216.34')];

const _mpegurl = 'application/vnd.apple.mpegurl';

/// Serves one body per request path. Every fixture here is a loopback
/// server the scanner reaches only because the test passes
/// `allowPrivateHosts: true`, which exempts the root manifest's own
/// origin (scheme + host + port) and nothing else.
Future<HttpServer> _serve(Map<String, String> bodiesByPath) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final body = bodiesByPath[request.uri.path];
    if (body == null) {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    request.response.headers.contentType = ContentType.parse(_mpegurl);
    request.response.write(body);
    await request.response.close();
  });
  return server;
}

/// Like [_serve], but every connection - regardless of the host/scheme the
/// client believes it is talking to - is pinned to this one loopback
/// server (same technique `hls_ffmpeg_downloader_cookie_containment_test
/// .dart`'s `_pinnedClientServing` uses), and [redirectsByPath] paths
/// answer with a 302 to the given `Location` instead of a body. Lets a
/// test use realistic-looking (fake) hostnames for a redirect target and
/// the references inside it, with no real DNS or network involved.
Future<HttpClient Function()> _pinnedClientServing(
  Map<String, String> bodiesByPath, {
  Map<String, String> redirectsByPath = const {},
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final redirect = redirectsByPath[request.uri.path];
    if (redirect != null) {
      request.response.statusCode = 302;
      request.response.headers.set('location', redirect);
      await request.response.close();
      return;
    }
    final body = bodiesByPath[request.uri.path];
    if (body == null) {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    request.response.headers.contentType = ContentType.parse(_mpegurl);
    request.response.write(body);
    await request.response.close();
  });
  return () {
    final client = HttpClient();
    client.connectionFactory =
        (uri, proxyHost, proxyPort) => Socket.startConnect(InternetAddress.loopbackIPv4, server.port);
    return client;
  };
}

void main() {
  group('B-R4-1: a playlist body is parsed against the LAST hop it actually came from', () {
    test('guard can fail: a relative reference in a redirected playlist resolves against the redirect target, '
        'not the pre-redirect URL', () async {
      final clientFactory = await _pinnedClientServing(
        {'/path/final.m3u8': '#EXTM3U\n#EXTINF:10,\nseg.ts\n'},
        redirectsByPath: {'/root.m3u8': 'https://evil.example.invalid/path/final.m3u8'},
      );
      final result = await ManifestReferenceScanner(httpClientFactory: clientFactory).scanAndCheck(
        Uri.parse('http://root.example.invalid/root.m3u8'),
        const {},
        resolveHost: _fakePublicResolver,
      );
      expect(result.references, [Uri.parse('https://evil.example.invalid/path/seg.ts')]);
      // Guard can fail (see report): parsing against `pending.uri` (the
      // pre-redirect root URL) instead of the last hop resolves "seg.ts"
      // to http://root.example.invalid/seg.ts - a completely different
      // host, and one this relative reference was never actually served
      // from.
    });
  });

  group('B-R4-2: a redirect hop outside the cookie scope is reported even when nothing IN the body is', () {
    test('guard can fail: a root manifest that redirects to an out-of-scope host is flagged even though the '
        'redirected playlist has no segments for an in-body check to catch', () async {
      final clientFactory = await _pinnedClientServing(
        {'/final.m3u8': '#EXTM3U\n'}, // no references at all inside the body
        redirectsByPath: {'/root.m3u8': 'https://evil.example.invalid/final.m3u8'},
      );
      final result = await ManifestReferenceScanner(httpClientFactory: clientFactory).scanAndCheck(
        Uri.parse('http://root.example.invalid/root.m3u8'),
        const {'Cookie': 'sid=secret'},
        resolveHost: _fakePublicResolver,
      );
      expect(result.hostsOutsideCookieScope, contains('evil.example.invalid'));
      // Guard can fail (see report): without feeding every hop
      // `HostPolicy.guardedRequest`'s `onHop` reports into the cookie-scope
      // gate, this scan finds zero in-body references to check (the
      // redirected playlist has no segments) and hostsOutsideCookieScope
      // stays empty - even though ffmpeg's own request would follow this
      // exact redirect and send the cookie there, since ffmpeg (unlike
      // this scanner) never re-scopes its one flattened header per hop.
    });
  });

  group('B-R4-6: with cookiesByDomain known, even the manifest\'s own host is checked, not waved through', () {
    test('guard can fail: a Path-scoped cookie does not follow a same-host reference outside that Path',
        () async {
      // Deliberately NOT a loopback + allowPrivateHosts fixture: that
      // combination makes `ManifestCookieGate.isExemptOrigin` short-circuit
      // `check()` before it ever reaches `recordCookieScope` for a
      // same-host reference, which would let a test pass for the wrong
      // reason. A fake-but-ordinary public hostname, pinned to the
      // loopback fixture server, exercises the real leaf-reference path.
      //
      // The root itself is under the cookie's own Path (`/private/...`),
      // so its own hop-0 recording stays in scope either way - isolating
      // this assertion to the in-body leaf reference under `/public/...`,
      // which the cookie's Path does not cover.
      final clientFactory = await _pinnedClientServing(
        {'/private/root.m3u8': '#EXTM3U\n#EXTINF:10,\nhttp://root.example.invalid/public/seg.ts\n'},
      );
      final result = await ManifestReferenceScanner(httpClientFactory: clientFactory).scanAndCheck(
        Uri.parse('http://root.example.invalid/private/root.m3u8'),
        const {'Cookie': 'sid=secret'},
        resolveHost: _fakePublicResolver,
        cookiesByDomain: {
          'root.example.invalid': const [
            CookieEntry(domain: 'root.example.invalid', path: '/private', secure: false, name: 'sid', value: 'secret'),
          ],
        },
      );
      expect(result.hostsOutsideCookieScope, contains('root.example.invalid'));
      // Guard can fail (see report): restoring the old unconditional
      // "the manifest's own host is always in scope" shortcut (returning
      // before ever consulting CookieScope.headerFor for a same-host
      // reference) makes this list empty - a cookie scoped to
      // `/private` would ride along onto this same host's `/public` path
      // regardless.
    });
  });

  group('B-R4-7: declared duration is scoped to what is actually downloaded', () {
    test('guard can fail: when the root URL is itself a media playlist, its own EXTINF sum is used even if a '
        'sibling rendition wildly disagrees', () async {
      final server = await _serve({
        '/root.m3u8': '#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",URI="audio.m3u8"\n'
            '#EXTINF:10,\nhttps://cdn.example.invalid/seg.ts\n',
        '/audio.m3u8': '#EXTM3U\n#EXTINF:999,\nhttps://cdn.example.invalid/aud.aac\n',
      });
      addTearDown(() => server.close(force: true));

      final result = await ManifestReferenceScanner().scanAndCheck(
        Uri.parse('http://127.0.0.1:${server.port}/root.m3u8'),
        const {},
        allowPrivateHosts: true,
        resolveHost: _fakePublicResolver,
      );
      expect(result.declaredDuration, const Duration(seconds: 10));
      // Guard can fail (see report): reconciling across every playlist
      // seen (root's own 10s pooled with the audio rendition's 999s, a
      // >10% disagreement) instead of preferring the root's own signal
      // makes this null - discarding a duration this scan was actually
      // certain of.
    });

    test('two media-playlist variants of a master agreeing within 10% report the first seen', () async {
      final server = await _serve({
        '/master.m3u8': '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2\nhigh.m3u8\n',
        '/low.m3u8': '#EXTM3U\n#EXTINF:100,\nhttps://cdn.example.invalid/low.ts\n',
        '/high.m3u8': '#EXTM3U\n#EXTINF:104,\nhttps://cdn.example.invalid/high.ts\n',
      });
      addTearDown(() => server.close(force: true));

      final result = await ManifestReferenceScanner().scanAndCheck(
        Uri.parse('http://127.0.0.1:${server.port}/master.m3u8'),
        const {},
        allowPrivateHosts: true,
        resolveHost: _fakePublicResolver,
      );
      expect(result.declaredDuration, const Duration(seconds: 100));
    });

    test('guard can fail: two variants of a master disagreeing by more than 10% report null rather than an '
        'arbitrary pick', () async {
      final server = await _serve({
        '/master.m3u8': '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2\nhigh.m3u8\n',
        '/low.m3u8': '#EXTM3U\n#EXTINF:100,\nhttps://cdn.example.invalid/low.ts\n',
        '/high.m3u8': '#EXTM3U\n#EXTINF:200,\nhttps://cdn.example.invalid/high.ts\n',
      });
      addTearDown(() => server.close(force: true));

      final result = await ManifestReferenceScanner().scanAndCheck(
        Uri.parse('http://127.0.0.1:${server.port}/master.m3u8'),
        const {},
        allowPrivateHosts: true,
        resolveHost: _fakePublicResolver,
      );
      expect(result.declaredDuration, isNull);
      // Guard can fail (see report): always taking "the first playlist
      // with a declared duration" (the pre-B-R4-7 behavior) reports 100s
      // here as if it were trustworthy, even though the master's other
      // variant claims exactly double that.
    });
  });
}
