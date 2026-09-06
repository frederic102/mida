import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/manifest_reference_scanner.dart';
import 'package:mida/core/extractors/media_models.dart';

/// Covers `ManifestReferenceScanner`'s own internals - the read-time size
/// cap, the leaf DNS-answer check, the bounded playlist queue and its
/// fail-closed budget (phase 6 B-R2), and the segment-framing signal
/// (B-R4). What the scanner is *used for* end to end lives in
/// `hls_ffmpeg_downloader_manifest_security_test.dart`; both files are
/// kept under this project's 400-line cap.
Future<List<InternetAddress>> _fakePublicResolver(String host) async => [InternetAddress('93.184.216.34')];

const _mpegurl = 'application/vnd.apple.mpegurl';

/// Serves one body per request path. Every fixture here is a loopback
/// server the scanner reaches only because the test passes
/// `allowPrivateHosts: true`, which exempts the root manifest's own
/// origin (scheme + host + port) and nothing else.
Future<HttpServer> _serve(Map<String, String> bodiesByPath, {String? fallback}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final body = bodiesByPath[request.uri.path] ?? fallback;
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

void main() {
  group('B-R3-6: the byte cap is per playlist and is enforced while reading', () {
    test('a manifest response larger than maxBytesPerPlaylist is rejected with PARSE_ERROR, not read to '
        'completion and accepted', () async {
      final chunk = List<int>.filled(64 * 1024, 0x41);
      const chunkCount = 40; // ~2.6MB, over the 2MB per-playlist cap
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.contentType = ContentType.parse(_mpegurl);
        for (var i = 0; i < chunkCount; i++) {
          request.response.add(chunk);
        }
        await request.response.close();
      });

      await expectLater(
        ManifestReferenceScanner()
            .scanAndCheck(Uri.parse('http://127.0.0.1:${server.port}/master.m3u8'), const {}, allowPrivateHosts: true),
        throwsA(isA<MediaExtractionException>()
            .having((e) => e.status, 'status', 'PARSE_ERROR')
            .having((e) => e.reason, 'reason', contains('while being read'))),
      );
    });

    test('a manifest body under maxBytesPerPlaylist is read normally', () async {
      final server = await _serve(const {
        '/master.m3u8': '#EXTM3U\n#EXTINF:10,\nhttps://cdn.example.invalid/segment.ts\n',
      });
      addTearDown(() => server.close(force: true));

      final result = await ManifestReferenceScanner().scanAndCheck(
        Uri.parse('http://127.0.0.1:${server.port}/master.m3u8'),
        const {},
        allowPrivateHosts: true,
        resolveHost: _fakePublicResolver,
      );
      expect(result.references, [Uri.parse('https://cdn.example.invalid/segment.ts')]);
      expect(result.playlistsFetched, 1);
    });
  });

  group('leaf DNS-answer (rebinding) check', () {
    test('guard can fail: a segment host that is syntactically public but resolves to 10.0.0.1 is rejected',
        () async {
      final server = await _serve(const {
        '/master.m3u8': '#EXTM3U\n#EXTINF:10,\nhttps://looks-public.example.test/segment.ts\n',
      });
      addTearDown(() => server.close(force: true));

      var lookupCalls = 0;
      await expectLater(
        ManifestReferenceScanner().scanAndCheck(
          Uri.parse('http://127.0.0.1:${server.port}/master.m3u8'),
          const {},
          allowPrivateHosts: true,
          resolveHost: (host) async {
            lookupCalls++;
            return [InternetAddress('10.0.0.1')];
          },
        ),
        throwsA(isA<MediaExtractionException>()
            .having((e) => e.status, 'status', 'UNSUPPORTED_URL')
            .having((e) => e.reason, 'reason', contains('10.0.0.1'))),
      );
      expect(lookupCalls, 1);
      // Guard can fail (see report): dropping the
      // `HostPolicy.assertResolvesToPublicHost` call from `_ReferenceGate.check`
      // (leaving only the syntactic `assertAllowedHost`) made this test
      // fail - the scan returned normally and `lookupCalls` stayed 0.
    });

    test('duplicate segment hosts are resolved only once', () async {
      final server = await _serve(const {
        '/master.m3u8': '#EXTM3U\n#EXTINF:10,\nhttps://cdn.example.invalid/seg1.ts\n'
            '#EXTINF:10,\nhttps://cdn.example.invalid/seg2.ts\n',
      });
      addTearDown(() => server.close(force: true));

      var lookupCalls = 0;
      await ManifestReferenceScanner().scanAndCheck(
        Uri.parse('http://127.0.0.1:${server.port}/master.m3u8'),
        const {},
        allowPrivateHosts: true,
        resolveHost: (host) async {
          lookupCalls++;
          return [InternetAddress('93.184.216.34')];
        },
      );
      expect(lookupCalls, 1);
    });
  });

  group('B-R2: the playlist queue is bounded and fails CLOSED when a bound is hit', () {
    test('guard can fail: exhausting the playlist count budget with work still queued refuses the manifest '
        'instead of silently stopping the scan', () async {
      const variantCount = ManifestReferenceScanner.maxPlaylists + 12;
      final master = StringBuffer('#EXTM3U\n');
      final bodies = <String, String>{};
      for (var i = 0; i < variantCount; i++) {
        master.write('#EXT-X-STREAM-INF:BANDWIDTH=${100000 + i}\nvariant$i.m3u8\n');
        bodies['/variant$i.m3u8'] = '#EXTM3U\n#EXTINF:10,\nhttps://cdn.example.invalid/seg$i.ts\n';
      }
      bodies['/master.m3u8'] = master.toString();
      final server = await _serve(bodies);
      addTearDown(() => server.close(force: true));

      await expectLater(
        ManifestReferenceScanner().scanAndCheck(
          Uri.parse('http://127.0.0.1:${server.port}/master.m3u8'),
          const {},
          allowPrivateHosts: true,
          resolveHost: _fakePublicResolver,
        ),
        throwsA(isA<MediaExtractionException>()
            .having((e) => e.status, 'status', 'PARSE_ERROR')
            .having((e) => e.reason, 'reason', contains('scan budget'))
            .having((e) => e.reason, 'reason', contains('still unchecked'))),
      );
      // Guard can fail (see report): replacing that `throw` with the
      // pre-phase-6 `break` (the silent stop this item exists to remove)
      // made this test fail - the scan returned a partial, half-checked
      // reference list as if nothing were wrong.
    });

    test('B-R3-6: a long VOD master (12 variants x ~400KB of #EXTINF lines) is scanned, not refused for '
        'its aggregate size', () async {
      const variantCount = 12;
      final master = StringBuffer('#EXTM3U\n');
      final bodies = <String, String>{};
      // ~400KB per media playlist: comfortably under the 2MB per-playlist
      // cap, but ~5MB in total - which the old shared budget refused.
      final segmentLines = StringBuffer('#EXTM3U\n');
      for (var i = 0; i < 8000; i++) {
        segmentLines.write('#EXTINF:10.0,\nhttps://cdn.example.invalid/seg-$i.ts\n');
      }
      final mediaPlaylist = segmentLines.toString();
      expect(mediaPlaylist.length, greaterThan(350 * 1024));
      expect(mediaPlaylist.length, lessThan(ManifestReferenceScanner.maxBytesPerPlaylist));
      for (var i = 0; i < variantCount; i++) {
        master.write('#EXT-X-STREAM-INF:BANDWIDTH=${100000 + i}\nvariant$i.m3u8\n');
        bodies['/variant$i.m3u8'] = mediaPlaylist;
      }
      bodies['/master.m3u8'] = master.toString();
      expect(mediaPlaylist.length * variantCount, greaterThan(4 * 1024 * 1024));
      final server = await _serve(bodies);
      addTearDown(() => server.close(force: true));

      final result = await ManifestReferenceScanner().scanAndCheck(
        Uri.parse('http://127.0.0.1:${server.port}/master.m3u8'),
        const {},
        allowPrivateHosts: true,
        resolveHost: _fakePublicResolver,
        timeout: const Duration(seconds: 60),
      );
      expect(result.playlistsFetched, variantCount + 1);
      expect(result.references, hasLength(8000 * variantCount));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('a playlist chain nested deeper than maxDepth is refused', () async {
      final bodies = <String, String>{};
      for (var level = 0; level <= ManifestReferenceScanner.maxDepth + 1; level++) {
        bodies['/level$level.m3u8'] = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nlevel${level + 1}.m3u8\n';
      }
      final server = await _serve(bodies);
      addTearDown(() => server.close(force: true));

      await expectLater(
        ManifestReferenceScanner().scanAndCheck(
          Uri.parse('http://127.0.0.1:${server.port}/level0.m3u8'),
          const {},
          allowPrivateHosts: true,
          resolveHost: _fakePublicResolver,
        ),
        throwsA(isA<MediaExtractionException>()
            .having((e) => e.status, 'status', 'PARSE_ERROR')
            .having((e) => e.reason, 'reason', contains('nests deeper'))),
      );
    });

    test('an #EXT-X-MEDIA audio rendition playlist is walked too, so ITS references are checked', () async {
      final server = await _serve({
        '/master.m3u8': '#EXTM3U\n'
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",URI="audio.m3u8"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO="aud"\nvideo.m3u8\n',
        '/audio.m3u8': '#EXTM3U\n#EXTINF:10,\nhttps://cdn.example.invalid/audio-seg.aac\n',
        '/video.m3u8': '#EXTM3U\n#EXTINF:10,\nhttps://cdn.example.invalid/video-seg.ts\n',
      });
      addTearDown(() => server.close(force: true));

      final result = await ManifestReferenceScanner().scanAndCheck(
        Uri.parse('http://127.0.0.1:${server.port}/master.m3u8'),
        const {},
        allowPrivateHosts: true,
        resolveHost: _fakePublicResolver,
      );
      expect(result.playlistsFetched, 3);
      expect(
        result.references,
        containsAll([
          Uri.parse('https://cdn.example.invalid/audio-seg.aac'),
          Uri.parse('https://cdn.example.invalid/video-seg.ts'),
        ]),
      );
    });
  });

  group('B-R4: segment framing is decided from the media playlists actually scanned', () {
    Future<bool?> framingFor(String mediaPlaylistBody) async {
      final server = await _serve({'/media.m3u8': mediaPlaylistBody});
      addTearDown(() => server.close(force: true));
      final result = await ManifestReferenceScanner().scanAndCheck(
        Uri.parse('http://127.0.0.1:${server.port}/media.m3u8'),
        const {},
        allowPrivateHosts: true,
        resolveHost: _fakePublicResolver,
      );
      return result.segmentsAreTransportStream;
    }

    test('#EXT-X-MAP present means fMP4 (no aac_adtstoasc)', () async {
      expect(
        await framingFor('#EXTM3U\n#EXT-X-MAP:URI="https://cdn.example.invalid/init.mp4"\n'
            '#EXTINF:10,\nhttps://cdn.example.invalid/seg1.m4s\n'),
        isFalse,
      );
    });

    for (final ext in ['m4s', 'mp4', 'cmfa', 'cmfv', 'm4a']) {
      test('.$ext segments mean fMP4 even with no #EXT-X-MAP', () async {
        expect(
          await framingFor('#EXTM3U\n#EXTINF:10,\nhttps://cdn.example.invalid/seg1.$ext\n'),
          isFalse,
        );
      });
    }

    for (final ext in ['ts', 'aac']) {
      test('.$ext segments mean MPEG-TS/ADTS (apply aac_adtstoasc)', () async {
        expect(
          await framingFor('#EXTM3U\n#EXTINF:10,\nhttps://cdn.example.invalid/seg1.$ext\n'),
          isTrue,
        );
      });
    }

    test('an unrecognizable segment name leaves the framing unknown (caller keeps its own default)', () async {
      expect(
        await framingFor('#EXTM3U\n#EXTINF:10,\nhttps://cdn.example.invalid/seg1?token=abc\n'),
        isNull,
      );
    });

    test('a query string after a known extension does not hide it', () async {
      expect(
        await framingFor('#EXTM3U\n#EXTINF:10,\nhttps://cdn.example.invalid/seg1.ts?token=abc\n'),
        isTrue,
      );
    });

    test('a master whose variants are fMP4 reports fMP4 (the signal survives one level of recursion)', () async {
      final server = await _serve({
        '/master.m3u8': '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nvariant.m3u8\n',
        '/variant.m3u8': '#EXTM3U\n#EXT-X-MAP:URI="https://cdn.example.invalid/init.mp4"\n'
            '#EXTINF:10,\nhttps://cdn.example.invalid/seg1.m4s\n',
      });
      addTearDown(() => server.close(force: true));

      final result = await ManifestReferenceScanner().scanAndCheck(
        Uri.parse('http://127.0.0.1:${server.port}/master.m3u8'),
        const {},
        allowPrivateHosts: true,
        resolveHost: _fakePublicResolver,
      );
      expect(result.segmentsAreTransportStream, isFalse);
    });
  });
}
