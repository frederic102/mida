import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/browser_capture/segment_manifest_prober.dart';

void main() {
  group('SegmentManifestProber.looksLikeSegmentUrl', () {
    test('.ts and .m4s fragments match', () {
      expect(SegmentManifestProber.looksLikeSegmentUrl('https://93.184.216.34/hls/seg-000.ts'), isTrue);
      expect(SegmentManifestProber.looksLikeSegmentUrl('https://93.184.216.34/dash/chunk_0.m4s'), isTrue);
    });

    test('a seg-prefixed .mp4 chunk matches', () {
      expect(SegmentManifestProber.looksLikeSegmentUrl('https://93.184.216.34/hls/seg-042.mp4'), isTrue);
    });

    test('a whole downloadable .mp4 with no seg- prefix does not match', () {
      expect(SegmentManifestProber.looksLikeSegmentUrl('https://93.184.216.34/movie.mp4'), isFalse);
    });

    test('a manifest URL itself does not match', () {
      expect(SegmentManifestProber.looksLikeSegmentUrl('https://93.184.216.34/hls/master.m3u8'), isFalse);
    });
  });

  group('SegmentManifestProber.directoryOf', () {
    test('drops the file name and query string, keeps the directory (trailing slash)', () {
      expect(
        SegmentManifestProber.directoryOf('https://93.184.216.34/hls/720p/seg-000.ts?token=abc'),
        'https://93.184.216.34/hls/720p/',
      );
    });

    test('a root-level file yields the bare origin', () {
      expect(SegmentManifestProber.directoryOf('https://93.184.216.34/seg-000.ts'), 'https://93.184.216.34');
    });

    test('an unparseable URL returns null', () {
      expect(SegmentManifestProber.directoryOf('::not a uri::'), isNull);
    });
  });

  group('SegmentManifestProber.probe (live HEAD requests)', () {
    HttpClient pinnedTo(HttpServer server) {
      final client = HttpClient();
      client.connectionFactory = (uri, proxyHost, proxyPort) => Socket.startConnect(InternetAddress.loopbackIPv4, server.port);
      return client;
    }

    test('recovers the first conventional manifest name that answers 200', () async {
      final requestedPaths = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requestedPaths.add(request.uri.path);
        // master.m3u8 (tried first) is missing; playlist.m3u8 (tried second)
        // exists - proves the prober tries names in order and stops at the
        // first hit rather than always taking the first name in the list.
        request.response.statusCode = request.uri.path.endsWith('playlist.m3u8') ? 200 : 404;
        await request.response.close();
      });

      final prober = SegmentManifestProber(httpClientFactory: () => pinnedTo(server));
      final recovered = await prober.probe('https://93.184.216.34/hls/720p/seg-000.ts', const {});

      expect(recovered, isNotNull);
      expect(recovered!.url, 'https://93.184.216.34/hls/720p/playlist.m3u8');
      expect(recovered.container, 'm3u8');
      expect(requestedPaths, ['/hls/720p/master.m3u8', '/hls/720p/playlist.m3u8']);
    });

    test('a .mpd guess that answers 200 is recovered with the mpd container', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = request.uri.path.endsWith('manifest.mpd') ? 200 : 404;
        await request.response.close();
      });

      final prober = SegmentManifestProber(httpClientFactory: () => pinnedTo(server));
      final recovered = await prober.probe('https://93.184.216.34/dash/chunk_0.m4s', const {});

      expect(recovered!.container, 'mpd');
    });

    test('none of the conventional names answer 200 -> null, not a throw', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = 404;
        await request.response.close();
      });

      final prober = SegmentManifestProber(httpClientFactory: () => pinnedTo(server));
      final recovered = await prober.probe('https://93.184.216.34/hls/seg-000.ts', const {});

      expect(recovered, isNull);
    });

    test('recoverFirst only probes each distinct directory once', () async {
      var requestCount = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requestCount++;
        request.response.statusCode = 404;
        await request.response.close();
      });

      final prober = SegmentManifestProber(httpClientFactory: () => pinnedTo(server));
      await prober.recoverFirst(
        [
          'https://93.184.216.34/hls/720p/seg-000.ts',
          'https://93.184.216.34/hls/720p/seg-001.ts', // same directory as above
        ],
        const {},
      );

      // 5 conventional names + 2 basename-derived guesses ('seg-000.m3u8',
      // 'seg-000.mpd', round 5), one directory: exactly 7 requests, not 14.
      expect(requestCount, 7);
    });

    test('guard can fail: recoverFirst stops after 4 distinct directories, never tries a 5th', () async {
      var requestCount = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requestCount++;
        request.response.statusCode = 404;
        await request.response.close();
      });

      final prober = SegmentManifestProber(httpClientFactory: () => pinnedTo(server));
      await prober.recoverFirst(
        [
          for (var i = 0; i < 6; i++) 'https://93.184.216.34/hls/$i/seg-000.ts', // 6 distinct directories
        ],
        const {},
      );

      // 4 directories x 7 names each (5 conventional + 2 basename-derived,
      // round 5) = 28, not 42 (6 dirs) - proves the cap actually stops
      // iteration rather than merely deduping. This is the fix for
      // Bilibili's own dozens-of-directories DASH shape turning a single
      // capture attempt into dozens of HTTP round trips
      // (docs/plan-phase5-coverage.md).
      expect(requestCount, 28);
    });

    test('recoverFirst snapshots segmentUrls before iterating, so a Set mutated concurrently '
        "during its own network probes does not throw ConcurrentModificationError", () async {
      // Guard can fail: this is the exact live bug (Bilibili diagnostic
      // run) - a caller's own still-growing Set (fed by an active
      // CdpEvent listener) being iterated directly by recoverFirst threw
      // ConcurrentModificationError, an Error (not an Exception) that
      // skipped every `on Exception` handler between here and the
      // extractor's caller entirely.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = 404;
        await request.response.close();
      });

      final liveSet = <String>{'https://93.184.216.34/hls/a/seg-000.ts'};
      final prober = SegmentManifestProber(httpClientFactory: () => pinnedTo(server));

      // Mutates the same Set recoverFirst is iterating, mid-flight -
      // matches a live CdpEvent listener still `add`-ing new segment URLs
      // while the async HTTP probes below are in flight.
      unawaited(Future<void>.delayed(const Duration(milliseconds: 1), () {
        liveSet.add('https://93.184.216.34/hls/b/seg-000.ts');
      }));

      await expectLater(prober.recoverFirst(liveSet, const {}), completes);
    });
  });

  group('SegmentManifestProber SSRF guard (host policy)', () {
    test('never sends a request for a directory that resolves to a disallowed (loopback) host', () async {
      var requestCount = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requestCount++;
        request.response.statusCode = 200;
        await request.response.close();
      });

      final prober = SegmentManifestProber();
      final recovered = await prober.probe('http://127.0.0.1:${server.port}/hls/seg-000.ts', const {});

      expect(recovered, isNull);
      expect(requestCount, 0);
    });

    // Guard-can-fail evidence: the only difference between this test and
    // the one above is `allowPrivateHosts: true` - proving the guard
    // above is actually what kept the request count at 0, not some
    // unrelated reason (server down, wrong path, etc). Production code
    // must never set this flag; it exists only so this file's own guard
    // can be shown to actually do something when disabled.
    test('guard can fail: allowPrivateHosts disables the loopback check and lets the request through', () async {
      var requestCount = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requestCount++;
        request.response.statusCode = request.uri.path.endsWith('master.m3u8') ? 200 : 404;
        await request.response.close();
      });

      final prober = SegmentManifestProber(allowPrivateHosts: true);
      final recovered = await prober.probe('http://127.0.0.1:${server.port}/hls/seg-000.ts', const {});

      expect(recovered, isNotNull);
      expect(requestCount, greaterThan(0));
    });
  });
}
