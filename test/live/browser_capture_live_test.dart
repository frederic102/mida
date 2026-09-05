import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/browser_capture/browser_capture_extractor.dart';

/// Real-network, real-headless-browser verification of
/// [BrowserCaptureExtractor], per `docs/plan-browser-capture.md`'s DONE
/// bullet ("라이브 3사이트 결과 보고"). Only runs when `MIDA_LIVE=1` is set.
///
/// Each site must independently produce at least one format whose first
/// entry answers a Range GET (using `MediaInfo.requestHeaders`) with 200 or
/// 206. Per the plan, a failing site stays a real test failure here (not a
/// swallowed/skip result) so the report reflects what actually happened.
///
/// Run with: `MIDA_LIVE=1 flutter test test/live/browser_capture_live_test.dart`
void main() {
  final isLive = Platform.environment['MIDA_LIVE'] == '1';
  final skipReason = isLive ? false : 'set MIDA_LIVE=1 to run this against the real network and a real browser';

  for (final url in [
    'https://vimeo.com/76979871',
    'https://www.tiktok.com/@hankgreen1/video/7047596209028074758',
    'https://www.instagram.com/reel/Chunk8-jurw/',
  ]) {
    test(
      'BrowserCaptureExtractor live: $url',
      () async {
        final extractor = BrowserCaptureExtractor();
        final info = await extractor.extract(Uri.parse(url));

        stdout.writeln('browser_capture_live: $url title="${info.title}" formats=${info.formats.length}');
        for (final format in info.formats.take(4)) {
          stdout.writeln('   ${format.container} ${format.height}p ${format.url.substring(0, format.url.length.clamp(0, 100))}');
        }

        expect(info.formats, isNotEmpty, reason: 'expected at least one captured media format for $url');

        final httpClient = HttpClient();
        try {
          final request = await httpClient.getUrl(Uri.parse(info.formats.first.url));
          info.requestHeaders.forEach(request.headers.set);
          request.headers.set('Range', 'bytes=0-1023');
          final response = await request.close();
          await response.drain<void>();
          stdout.writeln('   range GET -> HTTP ${response.statusCode}');
          expect(response.statusCode, anyOf(200, 206), reason: 'Range GET against the first captured format for $url');
        } finally {
          httpClient.close(force: true);
        }
      },
      skip: skipReason,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
