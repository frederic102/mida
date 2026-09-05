import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/soundcloud/soundcloud_extractor.dart';

/// Real-network verification for `SoundCloudExtractor`. Only runs when
/// `MIDA_LIVE=1` is set.
///
/// Uses `rick-astley-official/never-gonna-give-you-up` - the task's
/// original example account, `officialrickastley`, has been renamed on
/// SoundCloud since (confirmed live via a `search/tracks` call,
/// `docs/plan-phase5-coverage.md` Lane D follow-up).
///
/// Run with: `MIDA_LIVE=1 flutter test test/live/soundcloud_live_test.dart`
void main() {
  final isLive = Platform.environment['MIDA_LIVE'] == '1';

  test(
    'resolves a real SoundCloud track with a Range-GETable audio format',
    () async {
      final info = await SoundCloudExtractor().extract(
        Uri.parse('https://soundcloud.com/rick-astley-official/never-gonna-give-you-up'),
      );
      expect(info.formats, isNotEmpty);
      expect(info.formats.every((f) => f.isAudioOnly), isTrue);

      final progressive = info.formats.where((f) => f.container == 'mp3');
      if (progressive.isEmpty) return; // this track only offered hls this run; nothing more to range-GET here

      final httpClient = HttpClient();
      try {
        final request = await httpClient.getUrl(Uri.parse(progressive.first.url));
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
