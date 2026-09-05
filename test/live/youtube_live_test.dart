import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/youtube/youtube_extractor.dart';

/// Real-network verification against the actual YouTube API. Only runs
/// when `MIDA_LIVE=1` is set, since it depends on YouTube being reachable
/// and not bot-checking this specific run (see plan doc risk section).
///
/// Run with: `MIDA_LIVE=1 flutter test test/live`
void main() {
  final isLive = Platform.environment['MIDA_LIVE'] == '1';

  group('YoutubeExtractor live', () {
    test(
      'extracts dQw4w9WgXcQ with 20+ formats, a 1080p rendition, and a working Range GET',
      () async {
        final extractor = YoutubeExtractor();
        final info = await extractor.extractById('dQw4w9WgXcQ');

        expect(info.formats.length, greaterThanOrEqualTo(20));

        final has1080p = info.formats.any((f) => f.height == 1080);
        expect(has1080p, isTrue, reason: 'expected at least one 1080p rendition');

        final withUrl = info.formats.firstWhere((f) => f.height == 1080);
        final httpClient = HttpClient();
        try {
          final request = await httpClient.getUrl(Uri.parse(withUrl.url));
          info.requestHeaders.forEach(request.headers.set);
          request.headers.set('Range', 'bytes=0-1023');
          final response = await request.close();
          await response.drain();
          expect(response.statusCode, 206);
        } finally {
          httpClient.close(force: true);
        }
      },
      skip: isLive ? false : 'set MIDA_LIVE=1 to run this against the real network',
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
