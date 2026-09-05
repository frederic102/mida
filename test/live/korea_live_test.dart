import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/chzzk/chzzk_extractor.dart';
import 'package:mida/core/extractors/kakao/kakao_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/naver/naver_extractor.dart';

/// Real-network verification for the three Korean platform extractors
/// added in `docs/plan-phase5-coverage.md` Lane C. Only runs when
/// `MIDA_LIVE=1` is set.
///
/// Run with: `MIDA_LIVE=1 flutter test test/live/korea_live_test.dart`
///
/// The clip/video ids below are deliberately NOT the ones originally
/// supplied in the Lane C brief (`tv.naver.com/v/72311805`,
/// `tv.kakao.com/channel/3150758/cliplink/450674252`,
/// `chzzk.naver.com/video/2412`): all three were confirmed live
/// 2026-09-05 to no longer exist server-side (`CLIP_NOT_FOUND` /
/// `ServiceEnded` / `code: 404` respectively - see the "still resolves
/// dead links cleanly" group below, which uses the original ids on
/// purpose). The ids used for the positive (DONE bar) assertions were
/// found live via search on the same date and may themselves go stale
/// later - VOD content on either platform can be taken down - but they
/// prove the extraction technique works end to end at the time this was
/// written, which is what a live test can promise.
void main() {
  final isLive = Platform.environment['MIDA_LIVE'] == '1';

  Future<void> expectRangeableFormat(MediaInfo info) async {
    expect(info.formats, isNotEmpty);
    final best = info.formats.reduce((a, b) => a.bitrate > b.bitrate ? a : b);
    final httpClient = HttpClient();
    try {
      final request = await httpClient.getUrl(Uri.parse(best.url));
      info.requestHeaders.forEach(request.headers.set);
      request.headers.set('Range', 'bytes=0-1023');
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, anyOf(200, 206));
    } finally {
      httpClient.close(force: true);
    }
  }

  group('NaverExtractor live', () {
    test(
      'resolves a live Naver TV clip with a rangeable mp4 format',
      () async {
        final info = await NaverExtractor().extract(Uri.parse('https://tv.naver.com/v/105228483'));
        await expectRangeableFormat(info);
      },
      skip: isLive ? false : 'set MIDA_LIVE=1 to run this against the real network',
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('ChzzkExtractor live', () {
    test(
      'resolves a live CHZZK VOD with a rangeable mp4 format',
      () async {
        final info = await ChzzkExtractor().extract(Uri.parse('https://chzzk.naver.com/video/14834019'));
        await expectRangeableFormat(info);
      },
      skip: isLive ? false : 'set MIDA_LIVE=1 to run this against the real network',
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('Korea extractors still resolve the Lane C brief\'s original (now-dead) links cleanly', () {
    test(
      'Naver TV clip 72311805 (deleted) surfaces NOT_FOUND, not a crash or a hang',
      () async {
        await expectLater(
          NaverExtractor().extract(Uri.parse('https://tv.naver.com/v/72311805')),
          throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NOT_FOUND')),
        );
      },
      skip: isLive ? false : 'set MIDA_LIVE=1 to run this against the real network',
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'CHZZK video 2412 (deleted) surfaces NOT_FOUND, not a crash or a hang',
      () async {
        await expectLater(
          ChzzkExtractor().extract(Uri.parse('https://chzzk.naver.com/video/2412')),
          throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NOT_FOUND')),
        );
      },
      skip: isLive ? false : 'set MIDA_LIVE=1 to run this against the real network',
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'KakaoTV clip 450674252 surfaces NOT_FOUND because the whole service is discontinued',
      () async {
        await expectLater(
          KakaoExtractor().extract(Uri.parse('https://tv.kakao.com/channel/3150758/cliplink/450674252')),
          throwsA(isA<MediaExtractionException>()
              .having((e) => e.status, 'status', 'NOT_FOUND')
              .having((e) => e.reason, 'reason', contains('discontinued'))),
        );
      },
      skip: isLive ? false : 'set MIDA_LIVE=1 to run this against the real network',
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
