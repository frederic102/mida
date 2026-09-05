import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/twitter/twitter_extractor.dart';

/// Real-network verification against X's public syndication endpoint.
/// Only runs when `MIDA_LIVE=1` is set.
///
/// Run with: `MIDA_LIVE=1 flutter test test/live/twitter_live_test.dart`
void main() {
  final isLive = Platform.environment['MIDA_LIVE'] == '1';

  group('TwitterExtractor live', () {
    test(
      'extracts the captainamerica test tweet with an mp4 format and a working Range GET',
      () async {
        final extractor = TwitterExtractor();
        final info = await extractor.extract(
          Uri.parse('https://twitter.com/captainamerica/status/719944021058060289'),
        );

        expect(info.formats, isNotEmpty);
        final mp4Formats = info.formats.where((f) => f.container == 'mp4').toList();
        expect(mp4Formats, isNotEmpty, reason: 'expected at least one mp4 format');

        final best = mp4Formats.reduce((a, b) => a.bitrate > b.bitrate ? a : b);
        final httpClient = HttpClient();
        try {
          final request = await httpClient.getUrl(Uri.parse(best.url));
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
