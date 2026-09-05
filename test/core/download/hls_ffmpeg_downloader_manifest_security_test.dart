import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/hls_ffmpeg_downloader.dart';
import 'package:mida/core/extractors/media_models.dart';

/// A fixed public IP for every hostname this file's fixtures use
/// (`cdn.example.invalid`, ...) - keeps the manifest scanner's leaf DNS-
/// answer check (see `manifest_reference_scanner.dart`) from depending on
/// whatever this sandbox's real DNS resolver happens to answer for a
/// `.invalid` hostname (guaranteed NXDOMAIN by RFC 2606, which would
/// otherwise fail this fail-closed check even for a 'clean' fixture).
Future<List<InternetAddress>> _fakePublicResolver(String host) async => [InternetAddress('93.184.216.34')];

/// Covers `HlsFfmpegDownloader.downloadVerified`'s manifest/segment host
/// check (SSRF hardening) - split out of `hls_ffmpeg_downloader_test.dart`
/// to keep both files under the 400-line cap. See
/// `lib/core/download/manifest_reference_scanner.dart` for what is being
/// exercised here: HLS tag-attribute URI extraction, one-level
/// master-to-variant recursion, and DASH MPD XML reference extraction.
void main() {
  group('HlsFfmpegDownloader.downloadVerified manifest/segment host check (security)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('mida_hls_manifest_');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('a manifest whose own host is private/loopback is refused without ever fetching it', () async {
      final downloader = HlsFfmpegDownloader(
        ffmpegPathResolver: () async => 'irrelevant.exe',
        resolveHost: _fakePublicResolver,
      );
      await expectLater(
        downloader.downloadVerified(url: 'http://127.0.0.1:9/master.m3u8', outputPath: '${tempDir.path}/out.mp4'),
        throwsA(isA<MediaExtractionException>()),
      );
    });

    test('guard-can-fail: a media playlist whose own segment is a loopback host is rejected, '
        'even though the manifest itself is served from a (test-exempted) loopback fixture server', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        // No #EXT-X-STREAM-INF: this is a media playlist, so its plain
        // line is a segment (a leaf, always checked), not a variant
        // playlist reference (fetched/recursed into instead).
        request.response.write('#EXTM3U\n#EXTINF:10,\nhttp://127.0.0.1:1/segment.ts\n');
        await request.response.close();
      });

      try {
        // allowPrivateHosts exempts only the manifest URL's OWN host (so
        // the fixture server above is reachable at all); the referenced
        // segment line is a distinct check that must still fire.
        final downloader = HlsFfmpegDownloader(
          allowPrivateHosts: true,
          resolveHost: _fakePublicResolver,
          ffmpegPathResolver: () async => 'irrelevant.exe',
        );
        await expectLater(
          downloader.downloadVerified(
            url: 'http://127.0.0.1:${server.port}/media.m3u8',
            outputPath: '${tempDir.path}/out.mp4',
          ),
          throwsA(isA<MediaExtractionException>().having(
            (e) => e.reason,
            'reason',
            contains('segment/key/map'),
          )),
        );
      } finally {
        await server.close(force: true);
      }
    });

    test('a media playlist referencing only a public-looking segment passes the check '
        '(ffmpeg itself is never actually invoked here: ffmpegPathResolver points at nothing)', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        request.response.write('#EXTM3U\n#EXTINF:10,\nhttps://cdn.example.invalid/segment.ts\n');
        await request.response.close();
      });

      try {
        final downloader = HlsFfmpegDownloader(
          allowPrivateHosts: true,
          resolveHost: _fakePublicResolver,
          ffmpegPathResolver: () async => throw StateError('should not reach ffmpeg in this test'),
        );
        // The host check must pass silently (the segment is never
        // actually fetched, only host-checked) and then proceed to
        // actually try running ffmpeg (which fails here for an unrelated
        // reason - ffmpegPathResolver throws - proving the host check
        // did not block it).
        await expectLater(
          downloader.downloadVerified(
            url: 'http://127.0.0.1:${server.port}/media.m3u8',
            outputPath: '${tempDir.path}/out.mp4',
          ),
          throwsA(isA<StateError>()),
        );
      } finally {
        await server.close(force: true);
      }
    });

    test('guard-can-fail: a media playlist referencing a syntactically-public segment host whose DNS answer '
        'is 10.0.0.1 (rebinding) is rejected', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        request.response.write('#EXTM3U\n#EXTINF:10,\nhttps://looks-public.example.test/segment.ts\n');
        await request.response.close();
      });

      try {
        final downloader = HlsFfmpegDownloader(
          allowPrivateHosts: true,
          ffmpegPathResolver: () async => 'irrelevant.exe',
          resolveHost: (host) async => [InternetAddress('10.0.0.1')],
        );
        await expectLater(
          downloader.downloadVerified(
            url: 'http://127.0.0.1:${server.port}/media.m3u8',
            outputPath: '${tempDir.path}/out.mp4',
          ),
          throwsA(isA<MediaExtractionException>().having((e) => e.reason, 'reason', contains('10.0.0.1'))),
        );
        // Guard can fail (see report): temporarily skipping the leaf
        // DNS-answer check (only running `HostPolicy.assertAllowedHost`,
        // the syntactic one) made this test fail - `downloadVerified`
        // proceeded straight to `run`, which then threw for the unrelated
        // reason of `irrelevant.exe` not being a real ffmpeg binary,
        // instead of the expected `MediaExtractionException`.
      } finally {
        await server.close(force: true);
      }
    });

    final hlsTagLines = {
      '#EXT-X-KEY': '#EXT-X-KEY:METHOD=AES-128,URI="http://127.0.0.1:1/key.bin"',
      '#EXT-X-MAP': '#EXT-X-MAP:URI="http://127.0.0.1:1/init.mp4"',
      '#EXT-X-MEDIA': '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",URI="http://127.0.0.1:1/audio.m3u8"',
      '#EXT-X-I-FRAME-STREAM-INF': '#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1000,URI="http://127.0.0.1:1/iframe.m3u8"',
      '#EXT-X-SESSION-KEY': '#EXT-X-SESSION-KEY:METHOD=AES-128,URI="http://127.0.0.1:1/session.bin"',
    };
    for (final entry in hlsTagLines.entries) {
      test('guard-can-fail: a loopback URI="..." on ${entry.key} is rejected', () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          request.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
          request.response.write(
            '#EXTM3U\n${entry.value}\n#EXTINF:10,\nhttps://cdn.example.invalid/segment.ts\n',
          );
          await request.response.close();
        });
        try {
          final downloader = HlsFfmpegDownloader(
            allowPrivateHosts: true,
          resolveHost: _fakePublicResolver,
            ffmpegPathResolver: () async => 'irrelevant.exe',
          );
          await expectLater(
            downloader.downloadVerified(
              url: 'http://127.0.0.1:${server.port}/media.m3u8',
              outputPath: '${tempDir.path}/out.mp4',
            ),
            throwsA(isA<MediaExtractionException>().having(
              (e) => e.reason,
              'reason',
              contains('segment/key/map'),
            )),
          );
        } finally {
          await server.close(force: true);
        }
      });
    }

    test('guard-can-fail: a master whose variant playlist (fetched only via recursion) '
        'references a loopback segment is rejected', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        if (request.uri.path.endsWith('variant.m3u8')) {
          // A media playlist: its plain line is a segment, host-checked
          // as a leaf. Never referenced anywhere except from the master
          // below, so this is only ever fetched via recursion.
          request.response.write('#EXTM3U\n#EXTINF:10,\nhttp://127.0.0.1:1/segment.ts\n');
        } else {
          request.response.write(
            '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000\n'
            'http://127.0.0.1:${server.port}/variant.m3u8\n',
          );
        }
        await request.response.close();
      });
      try {
        final downloader = HlsFfmpegDownloader(
          allowPrivateHosts: true,
          resolveHost: _fakePublicResolver,
          ffmpegPathResolver: () async => 'irrelevant.exe',
        );
        await expectLater(
          downloader.downloadVerified(
            url: 'http://127.0.0.1:${server.port}/master.m3u8',
            outputPath: '${tempDir.path}/out.mp4',
          ),
          throwsA(isA<MediaExtractionException>().having(
            (e) => e.reason,
            'reason',
            contains('segment/key/map'),
          )),
        );
      } finally {
        await server.close(force: true);
      }
    });

    test('a clean master playlist (variant fetched via recursion, every reference clean) passes the check', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        if (request.uri.path.endsWith('variant.m3u8')) {
          request.response.write('#EXTM3U\n#EXTINF:10,\nhttps://cdn.example.invalid/segment.ts\n');
        } else {
          request.response.write(
            '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000\n'
            'http://127.0.0.1:${server.port}/variant.m3u8\n',
          );
        }
        await request.response.close();
      });
      try {
        final downloader = HlsFfmpegDownloader(
          allowPrivateHosts: true,
          resolveHost: _fakePublicResolver,
          ffmpegPathResolver: () async => throw StateError('should not reach ffmpeg in this test'),
        );
        await expectLater(
          downloader.downloadVerified(
            url: 'http://127.0.0.1:${server.port}/master.m3u8',
            outputPath: '${tempDir.path}/out.mp4',
          ),
          throwsA(isA<StateError>()),
        );
      } finally {
        await server.close(force: true);
      }
    });

    test('guard-can-fail: an MPD whose BaseURL is loopback is rejected', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.contentType = ContentType('application', 'dash+xml');
        request.response.write(
          '<?xml version="1.0"?>\n'
          '<MPD><Period><AdaptationSet><Representation>'
          '<BaseURL>http://127.0.0.1:1/seg.mp4</BaseURL>'
          '</Representation></AdaptationSet></Period></MPD>\n',
        );
        await request.response.close();
      });
      try {
        final downloader = HlsFfmpegDownloader(
          allowPrivateHosts: true,
          resolveHost: _fakePublicResolver,
          ffmpegPathResolver: () async => 'irrelevant.exe',
        );
        await expectLater(
          downloader.downloadVerified(
            url: 'http://127.0.0.1:${server.port}/manifest.mpd',
            outputPath: '${tempDir.path}/out.mp4',
          ),
          throwsA(isA<MediaExtractionException>().having(
            (e) => e.reason,
            'reason',
            contains('segment/key/map'),
          )),
        );
      } finally {
        await server.close(force: true);
      }
    });

    test('a clean MPD (all DASH references clean) passes the check', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.contentType = ContentType('application', 'dash+xml');
        request.response.write(
          '<?xml version="1.0"?>\n'
          '<MPD><Period><AdaptationSet><Representation>'
          '<BaseURL>https://cdn.example.invalid/seg.mp4</BaseURL>'
          '</Representation></AdaptationSet></Period></MPD>\n',
        );
        await request.response.close();
      });
      try {
        final downloader = HlsFfmpegDownloader(
          allowPrivateHosts: true,
          resolveHost: _fakePublicResolver,
          ffmpegPathResolver: () async => throw StateError('should not reach ffmpeg in this test'),
        );
        await expectLater(
          downloader.downloadVerified(
            url: 'http://127.0.0.1:${server.port}/manifest.mpd',
            outputPath: '${tempDir.path}/out.mp4',
          ),
          throwsA(isA<StateError>()),
        );
      } finally {
        await server.close(force: true);
      }
    });

    test('an MPD-looking manifest with no <MPD> root refuses with PARSE_ERROR rather than passing through unchecked',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.contentType = ContentType('application', 'dash+xml');
        request.response.write('<?xml version="1.0"?>\n<NotAnMpdRoot></NotAnMpdRoot>\n');
        await request.response.close();
      });
      try {
        final downloader = HlsFfmpegDownloader(
          allowPrivateHosts: true,
          resolveHost: _fakePublicResolver,
          ffmpegPathResolver: () async => 'irrelevant.exe',
        );
        await expectLater(
          downloader.downloadVerified(
            url: 'http://127.0.0.1:${server.port}/manifest.mpd',
            outputPath: '${tempDir.path}/out.mp4',
          ),
          throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR')),
        );
      } finally {
        await server.close(force: true);
      }
    });
  });
}
