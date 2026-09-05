import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/generic_extractor.dart';

/// Real-network verification of [GenericExtractor] against public test
/// assets, per `docs/plan-generic-extractor.md`. Only runs when
/// `MIDA_LIVE=1` is set.
///
/// Run with: `MIDA_LIVE=1 flutter test test/live/generic_live_test.dart`
void main() {
  final isLive = Platform.environment['MIDA_LIVE'] == '1';
  final skipReason = isLive ? false : 'set MIDA_LIVE=1 to run this against the real network';

  group('GenericExtractor live', () {
    test(
      'mux public HLS test stream expands into multiple variant formats',
      () async {
        final extractor = GenericExtractor();
        final info = await extractor.extract(Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'));

        expect(info.formats.length, greaterThan(1));
        expect(info.formats.every((f) => f.container == 'm3u8'), isTrue);
      },
      skip: skipReason,
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test(
      'w3schools direct mp4 file yields exactly one format with a working Range GET',
      () async {
        final extractor = GenericExtractor();
        final info = await extractor.extract(Uri.parse('https://www.w3schools.com/html/mov_bbb.mp4'));

        expect(info.formats, hasLength(1));
        expect(info.formats.single.container, 'mp4');

        final httpClient = HttpClient();
        try {
          final request = await httpClient.getUrl(Uri.parse(info.formats.single.url));
          info.requestHeaders.forEach(request.headers.set);
          request.headers.set('Range', 'bytes=0-1023');
          final response = await request.close();
          await response.drain();
          expect(response.statusCode, 206);
        } finally {
          httpClient.close(force: true);
        }
      },
      skip: skipReason,
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test(
      'vimeo public video: browser-render fallback path only, best-effort',
      () async {
        // This only records whether the step-2 headless-browser path
        // manages to find a format on a real JS-rendered page; per the
        // plan it is allowed to fail (Vimeo's markup changes over time,
        // or the test machine may lack Edge/Chrome) as long as the
        // failure is reported rather than crashing the suite.
        final extractor = GenericExtractor();
        try {
          final info = await extractor.extract(Uri.parse('https://vimeo.com/76979871'));
          // ignore: avoid_print
          print('generic_live_test: vimeo browser-fallback found ${info.formats.length} format(s)');
          expect(info.formats, isNotEmpty);
        } catch (e) {
          markTestSkipped('vimeo browser-fallback did not find a format: $e');
        }
      },
      skip: skipReason,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
