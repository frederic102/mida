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
