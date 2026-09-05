import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/odysee/odysee_extractor.dart';

/// Real-network verification for `OdyseeExtractor`. Only runs when
/// `MIDA_LIVE=1` is set.
///
/// Run with: `MIDA_LIVE=1 flutter test test/live/odysee_live_test.dart`
void main() {
  final isLive = Platform.environment['MIDA_LIVE'] == '1';

  test(
    'resolves the real @lbry:3f/odysee:7 claim with a Range-GETable master.m3u8',
    () async {
      final info = await OdyseeExtractor().extract(Uri.parse('https://odysee.com/@lbry:3f/odysee:7'));
      expect(info.formats, isNotEmpty);
      expect(info.formats.single.container, 'm3u8');

      final httpClient = HttpClient();
      try {
        final request = await httpClient.getUrl(Uri.parse(info.formats.single.url));
        info.requestHeaders.forEach(request.headers.set);
        request.headers.set('Range', 'bytes=0-1023');
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, anyOf(200, 206));
      } finally {
        httpClient.close(force: true);
      }
    },
    skip: isLive ? false : 'set MIDA_LIVE=1 to run this against the real network',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
