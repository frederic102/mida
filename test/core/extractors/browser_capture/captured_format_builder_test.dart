import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/browser_capture/captured_format_builder.dart';
import 'package:mida/core/extractors/browser_capture/captured_media_classifier.dart';
import 'package:mida/core/extractors/media_models.dart';

void main() {
  group('CapturedFormatBuilder.expandFormats', () {
    test('a non-m3u8 candidate is returned as a single format with no fetch at all', () async {
      final builder = CapturedFormatBuilder();
      final formats = await builder.expandFormats(
        const CapturedMediaCandidate(url: 'https://cdn.example.com/clip.mp4', container: 'mp4'),
        const {},
      );

      expect(formats, hasLength(1));
      expect(formats.single.container, 'mp4');
      expect(formats.single.url, 'https://cdn.example.com/clip.mp4');
    });

    // Phase 6 P3: a direct mp4/webm candidate whose caps came only from
    // FormatCapabilities.fromMimeType's unconfirmed muxed guess (no decisive
    // audio/* mimeType) is flagged capabilitiesUnknown so
    // FormatCapabilityResolver's byte-sniffing selector can pick it up.
    test('a direct mp4 candidate with no mimeType is flagged capabilitiesUnknown (P3 selector signal)', () async {
      final builder = CapturedFormatBuilder();
      final formats = await builder.expandFormats(
        const CapturedMediaCandidate(url: 'https://cdn.example.com/clip.mp4', container: 'mp4'),
        const {},
      );
      expect(formats.single.capabilitiesUnknown, isTrue);
    });

    test('a direct mp4 candidate with a decisive audio/* mimeType is NOT flagged capabilitiesUnknown '
        '(guard: the mimeType already confirmed audio-only, nothing left to sniff)', () async {
      final builder = CapturedFormatBuilder();
      final formats = await builder.expandFormats(
        const CapturedMediaCandidate(url: 'https://cdn.example.com/clip.mp4', container: 'mp4', mimeType: 'audio/mp4'),
        const {},
      );
      expect(formats.single.capabilitiesUnknown, isFalse);
      expect(formats.single.isAudioOnly, isTrue);
    });

    // Round 2 P-R7 (Vigil#2): a direct .m4a candidate is just as
    // unconfirmed as an .mp4/.webm one when its mimeType did not already
    // say audio/* - FormatCapabilityResolver's byte-sniffing selector
    // needs the same signal for it.
    test('a direct m4a candidate with no mimeType is flagged capabilitiesUnknown (guard: round 1 only listed '
        'mp4/webm here, so an m4a candidate silently kept the unconfirmed muxed guess with no way for the '
        'resolver to pick it up)', () async {
      final builder = CapturedFormatBuilder();
      final formats = await builder.expandFormats(
        const CapturedMediaCandidate(url: 'https://cdn.example.com/clip.m4a', container: 'm4a'),
        const {},
      );
      expect(formats.single.capabilitiesUnknown, isTrue);
    });

    test('a direct m4a candidate with a decisive audio/* mimeType is NOT flagged capabilitiesUnknown', () async {
      final builder = CapturedFormatBuilder();
      final formats = await builder.expandFormats(
        const CapturedMediaCandidate(url: 'https://cdn.example.com/clip.m4a', container: 'm4a', mimeType: 'audio/mp4'),
        const {},
      );
      expect(formats.single.capabilitiesUnknown, isFalse);
      expect(formats.single.isAudioOnly, isTrue);
    });

    test('an m3u8 master playlist expands into one format per #EXT-X-STREAM-INF variant', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.set('Content-Type', 'application/vnd.apple.mpegurl');
        request.response.write('''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=400000,RESOLUTION=640x360,CODECS="avc1.42c01e,mp4a.40.2"
low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=1280x720,CODECS="avc1.4d401f"
high.m3u8
''');
        await request.response.close();
      });

      final builder = CapturedFormatBuilder(allowPrivateHosts: true);
      final formats = await builder.expandFormats(
        CapturedMediaCandidate(url: 'http://127.0.0.1:${server.port}/master.m3u8', container: 'm3u8'),
        const {},
      );

      expect(formats, hasLength(2));
      expect(formats[0].height, 360);
      expect(formats[0].hasAudio, isTrue); // CODECS lists an audio fourcc
      expect(formats[1].height, 720);
      expect(formats[1].hasAudio, isFalse); // CODECS lists a video fourcc only
    });

    // Phase 6 (docs/plan-phase6-av-pairing.md, Lane P, P2/DONE): a
    // pinterest/ted-shaped master (split alternate-audio rendition group)
    // maps through HlsMasterFormatMapper to video-only + audio-only, not
    // one muxed format per variant.
    test('an m3u8 master whose variants reference a split #EXT-X-MEDIA audio group expands to video-only + '
        'audio-only formats (guard: without HlsMasterFormatMapper, CODECS alone reads avc1+mp4a as muxed)',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.set('Content-Type', 'application/vnd.apple.mpegurl');
        request.response.write('''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="main",DEFAULT=YES,URI="audio/en.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.42c01e,mp4a.40.2",AUDIO="aud1"
video_360p.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aud1"
video_720p.m3u8
''');
        await request.response.close();
      });

      final builder = CapturedFormatBuilder(allowPrivateHosts: true);
      final formats = await builder.expandFormats(
        CapturedMediaCandidate(url: 'http://127.0.0.1:${server.port}/master.m3u8', container: 'm3u8'),
        const {},
      );

      expect(formats.where((f) => f.isVideoOnly), hasLength(2));
      expect(formats.where((f) => f.isAudioOnly), hasLength(1));
      expect(formats.any((f) => f.isMuxed), isFalse);
    });

    group('round 2 P-R6 (Codex#18): manifest fetch is bounded to 1MB, streamed', () {
      test('guard-can-fail: real playlist content placed AFTER the 1MB cap is never seen - the truncated body maps '
          'to nothing, not to the master it would parse as if fully read', () async {
        // 1MB+ of an oversized single comment line (never matches
        // #EXT-X-STREAM-INF) followed by a real, otherwise-valid two-variant
        // master. If the fetch is unbounded, `HlsMasterFormatMapper` still
        // finds `#EXT-X-STREAM-INF` (it scans the whole string regardless of
        // position) and returns 2 formats; bounded to 1MB, the cut lands
        // inside the padding and the real variants are never read at all.
        final padding = '#${'p' * (1024 * 1024 + 4096)}';
        const realTail = '''

#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.42c01e,mp4a.40.2"
low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=1280x720,CODECS="avc1.4d401f"
high.m3u8
''';
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          request.response.write(padding);
          request.response.write(realTail);
          await request.response.close();
        });

        final builder = CapturedFormatBuilder(allowPrivateHosts: true);
        final formats = await builder.expandFormats(
          CapturedMediaCandidate(url: 'http://127.0.0.1:${server.port}/master.m3u8', container: 'm3u8'),
          const {},
        );

        // Truncated body has no #EXT-X-STREAM-INF at all within the first
        // 1MB, so HlsMasterFormatMapper finds no variants and the builder
        // falls back to its single-placeholder-format path.
        expect(formats, hasLength(1), reason: 'guard can fail: an unbounded read would see the real 2-variant tail '
            'past the 1MB mark and return 2 formats instead');
        expect(formats.single.url, 'http://127.0.0.1:${server.port}/master.m3u8');
      });

      test('a real playlist entirely under 1MB is unaffected by the cap', () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          request.response.write('''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=400000,RESOLUTION=640x360,CODECS="avc1.42c01e,mp4a.40.2"
low.m3u8
''');
          await request.response.close();
        });

        final builder = CapturedFormatBuilder(allowPrivateHosts: true);
        final formats = await builder.expandFormats(
          CapturedMediaCandidate(url: 'http://127.0.0.1:${server.port}/master.m3u8', container: 'm3u8'),
          const {},
        );
        expect(formats, hasLength(1));
        expect(formats.single.height, 360);
      });
    });

    group('SSRF guard (HostPolicy.guardedRequest)', () {
      test('a loopback master-playlist URL is rejected, and the server it points at is never contacted', () async {
        var requestCount = 0;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          requestCount++;
          request.response.write('should never be reached');
          await request.response.close();
        });

        final builder = CapturedFormatBuilder(); // allowPrivateHosts defaults to false
        await expectLater(
          builder.expandFormats(
            CapturedMediaCandidate(url: 'http://127.0.0.1:${server.port}/master.m3u8', container: 'm3u8'),
            const {},
          ),
          throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL')),
        );

        expect(requestCount, 0, reason: 'the blocked master-playlist URL must never actually be contacted');
      });

      // Guard-can-fail evidence (see report): temporarily changing
      // `_fetchText`'s `guardedRequest` call to pass `allowPrivateHosts:
      // true` unconditionally (ignoring the instance field) made this
      // test fail: `requestCount` became 1 and no exception was thrown.
      // Also verified that removing the `on MediaExtractionException {
      // rethrow; }` branch in `expandFormats` (letting the generic catch
      // swallow it) makes this test fail differently: no exception at
      // all, `formats` comes back as a single placeholder pointing at the
      // still-blocked URL, but `requestCount` stays 0 either way, so the
      // exception-surfacing behavior needed its own explicit check above.
    });
  });
}
