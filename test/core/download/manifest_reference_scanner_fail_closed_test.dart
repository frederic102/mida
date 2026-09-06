import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/manifest_reference_scanner.dart';
import 'package:mida/core/extractors/media_models.dart';

/// Phase 6 round 3, Lane B. What this file pins:
///  - B-R3-1: a playlist fetch that fails, answers non-2xx, or returns a
///    body that is not a manifest refuses the WHOLE scan. There is no
///    "skip that one and carry on" path left, for root or for children.
///  - B-R3-2: the scanner re-scopes credentials per redirect hop, so a
///    variant that redirects to another origin never carries the
///    manifest's Cookie/Authorization there.
///  - B-R3-3: one whole scan has a deadline.
///  - B-R3-4: DASH attributes may be single- or double-quoted and are
///    XML-entity decoded.
///  - B-R3-7: the scan reports the DECLARED duration.
Future<List<InternetAddress>> _fakePublicResolver(String host) async => [InternetAddress('93.184.216.34')];

const _mpegurl = 'application/vnd.apple.mpegurl';

/// Serves one body per request path from a loopback fixture server the
/// scanner reaches only because the test passes `allowPrivateHosts:
/// true`, which exempts the root manifest's own origin and nothing else.
Future<HttpServer> _serve(Map<String, String> bodiesByPath) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    final body = bodiesByPath[request.uri.path];
    if (body == null) {
      request.response.statusCode = 404;
      request.response.write('Not found');
      await request.response.close();
      return;
    }
    request.response.headers.contentType = ContentType.parse(_mpegurl);
    request.response.write(body);
    await request.response.close();
  });
  return server;
}

Future<ManifestScanResult> _scan(
  HttpServer server,
  String path, {
  Duration timeout = ManifestReferenceScanner.defaultTimeout,
}) {
  return ManifestReferenceScanner().scanAndCheck(
    Uri.parse('http://127.0.0.1:${server.port}$path'),
    const {},
    allowPrivateHosts: true,
    resolveHost: _fakePublicResolver,
    timeout: timeout,
  );
}

Matcher _parseErrorContaining(String fragment) => throwsA(isA<MediaExtractionException>()
    .having((e) => e.status, 'status', 'PARSE_ERROR')
    .having((e) => e.reason, 'reason', contains(fragment)));

void main() {
  group('B-R3-1: every playlist must be fetchable, 2xx, and manifest-shaped', () {
    test('guard can fail: a variant playlist that 404s refuses the whole scan instead of being skipped',
        () async {
      final server = await _serve({
        '/master.m3u8': '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nmissing.m3u8\n',
      });
      await expectLater(_scan(server, '/master.m3u8'), _parseErrorContaining('answered HTTP 404'));
      // Guard can fail (see report): restoring the round-2 behaviour
      // (`_fetchBounded` not checking `response.statusCode` at all) made
      // this test fail - the 404 body carried no references, the walker
      // reported "nothing to check", and the scan returned a clean
      // result for a manifest whose only variant nothing had read.
    });

    test('guard can fail: a variant playlist that returns an HTML login wall refuses the scan', () async {
      final server = await _serve({
        '/master.m3u8': '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nvariant.m3u8\n',
        '/variant.m3u8': '<!DOCTYPE html><html><body>Please sign in</body></html>',
      });
      await expectLater(_scan(server, '/master.m3u8'), _parseErrorContaining('not a playlist at all'));
      // Guard can fail (see report): dropping the
      // `ManifestReferenceWalker.looksLikeManifest` check from
      // `_fetchBounded` made this test fail - an HTML page parses as an
      // HLS playlist with zero references, which is indistinguishable
      // from a clean manifest.
    });

    test('a root manifest that is not manifest-shaped refuses too', () async {
      final server = await _serve({'/media.m3u8': '<!DOCTYPE html><html><body>nope</body></html>'});
      await expectLater(_scan(server, '/media.m3u8'), _parseErrorContaining('not a playlist at all'));
    });

    test('a root manifest that 404s refuses with the same PARSE_ERROR', () async {
      final server = await _serve(const {});
      await expectLater(_scan(server, '/media.m3u8'), _parseErrorContaining('answered HTTP 404'));
    });

    test('a variant this scanner genuinely cannot read (transport failure) now refuses too: a playlist '
        'nobody could read is a playlist nobody CHECKED', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        if (request.uri.path == '/broken.m3u8') {
          // A truncated response: an IOException on the client side.
          final socket = await request.response.detachSocket(writeHeaders: false);
          socket.destroy();
          return;
        }
        request.response.headers.contentType = ContentType.parse(_mpegurl);
        request.response.write('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nbroken.m3u8\n');
        await request.response.close();
      });

      await expectLater(_scan(server, '/master.m3u8'), _parseErrorContaining('could not be read'));
    });
  });

  group('B-R3-2: credentials are re-scoped per redirect hop', () {
    test('guard can fail: a variant that redirects to another origin does not carry the manifest cookie or '
        'Authorization header there', () async {
      final seen = <String, HttpHeaders>{};
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        seen['${request.headers.host}${request.uri.path}'] = request.headers;
        switch (request.uri.path) {
          case '/variant.m3u8':
            request.response.statusCode = 302;
            request.response.headers.set('location', 'http://cdn.other.invalid/final.m3u8');
            await request.response.close();
          case '/final.m3u8':
            request.response.headers.contentType = ContentType.parse(_mpegurl);
            request.response.write('#EXTM3U\n#EXTINF:10,\nhttp://media.example.invalid/seg.ts\n');
            await request.response.close();
          default:
            request.response.headers.contentType = ContentType.parse(_mpegurl);
            request.response.write(
              '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nhttp://media.example.invalid/variant.m3u8\n',
            );
            await request.response.close();
        }
      });

      HttpClient pinnedToFixture() {
        final client = HttpClient();
        client.connectionFactory =
            (uri, proxyHost, proxyPort) => Socket.startConnect(InternetAddress.loopbackIPv4, server.port);
        return client;
      }

      await ManifestReferenceScanner(httpClientFactory: pinnedToFixture).scanAndCheck(
        Uri.parse('http://media.example.invalid/master.m3u8'),
        const {'Authorization': 'Bearer t0ken', 'Cookie': 'sid=secret'},
        cookiesByDomain: const {
          'media.example.invalid': [
            CookieEntry(domain: 'media.example.invalid', path: '/', secure: false, name: 'sid', value: 'secret'),
          ],
        },
        resolveHost: _fakePublicResolver,
      );

      expect(seen.keys, containsAll(['media.example.invalid/master.m3u8', 'cdn.other.invalid/final.m3u8']));
      expect(seen['media.example.invalid/master.m3u8']!.value('cookie'), 'sid=secret');
      expect(seen['media.example.invalid/master.m3u8']!.value('authorization'), 'Bearer t0ken');
      expect(seen['cdn.other.invalid/final.m3u8']!.value('cookie'), isNull);
      expect(seen['cdn.other.invalid/final.m3u8']!.value('authorization'), isNull);
      // Guard can fail (see report): replacing `PerHopCredentials.apply`
      // in `_fetchBounded` with the round-2 `headers.forEach(
      // request.headers.set)` made this test fail - the redirected
      // request to cdn.other.invalid arrived carrying both `sid=secret`
      // and `Bearer t0ken`.
    });
  });

  group('B-R3-3: one scan has a whole-scan deadline', () {
    test('a manifest server that never finishes its response body is refused at the deadline', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.contentType = ContentType.parse(_mpegurl);
        request.response.write('#EXTM3U\n');
        await request.response.flush();
        // Deliberately never closed.
      });

      await expectLater(
        _scan(server, '/media.m3u8', timeout: const Duration(milliseconds: 300)),
        _parseErrorContaining('did not finish within'),
      );
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  group('B-R3-4: DASH attributes accept either quote style and are entity-decoded', () {
    test('single-quoted attributes and &amp; entities resolve to the URLs ffmpeg will actually open',
        () async {
      const mpd = '<?xml version="1.0"?>'
          "<MPD mediaPresentationDuration='PT30S'><Period><AdaptationSet>"
          "<SegmentTemplate media='https://cdn.example.invalid/seg.m4s?a=1&amp;b=2' "
          "initialization='https://cdn.example.invalid/init.mp4'/>"
          '</AdaptationSet></Period></MPD>';
      final server = await _serve({'/manifest.mpd': mpd});

      final result = await _scan(server, '/manifest.mpd');
      expect(
        result.references,
        containsAll([
          Uri.parse('https://cdn.example.invalid/seg.m4s?a=1&b=2'),
          Uri.parse('https://cdn.example.invalid/init.mp4'),
        ]),
      );
      expect(result.declaredDuration, const Duration(seconds: 30));
      expect(result.segmentsAreTransportStream, isFalse);
    });
  });

  group('B-R3-7: the scan reports the duration the manifest declares', () {
    test('an HLS media playlist reports the sum of its #EXTINF durations', () async {
      final server = await _serve({
        '/media.m3u8': '#EXTM3U\n#EXTINF:10,\nhttps://cdn.example.invalid/a.ts\n'
            '#EXTINF:10.5,\nhttps://cdn.example.invalid/b.ts\n'
            '#EXTINF:4.5,\nhttps://cdn.example.invalid/c.ts\n',
      });
      expect((await _scan(server, '/media.m3u8')).declaredDuration, const Duration(seconds: 25));
    });

    test('a master takes the duration from the first variant that declares one', () async {
      final server = await _serve({
        '/master.m3u8': '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nvariant.m3u8\n',
        '/variant.m3u8': '#EXTM3U\n#EXTINF:6,\nhttps://cdn.example.invalid/a.ts\n'
            '#EXTINF:6,\nhttps://cdn.example.invalid/b.ts\n',
      });
      expect((await _scan(server, '/master.m3u8')).declaredDuration, const Duration(seconds: 12));
    });

    test('a DASH MPD reports its mediaPresentationDuration', () async {
      final server = await _serve({
        '/manifest.mpd': '<?xml version="1.0"?><MPD mediaPresentationDuration="PT1H2M3.5S">'
            '<Period><AdaptationSet><Representation>'
            '<BaseURL>https://cdn.example.invalid/seg.mp4</BaseURL>'
            '</Representation></AdaptationSet></Period></MPD>',
      });
      expect(
        (await _scan(server, '/manifest.mpd')).declaredDuration,
        const Duration(hours: 1, minutes: 2, seconds: 3, milliseconds: 500),
      );
    });

    test('a manifest that declares nothing reports null rather than a guess', () async {
      final server = await _serve({
        '/master.m3u8': '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nvariant.m3u8\n',
        '/variant.m3u8': '#EXTM3U\n#EXT-X-TARGETDURATION:10\nhttps://cdn.example.invalid/seg.ts\n',
      });
      // The master declares nothing by construction, and the media
      // playlist carries no #EXTINF at all.
      expect((await _scan(server, '/master.m3u8')).declaredDuration, isNull);
    });
  });
}
