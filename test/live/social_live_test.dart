import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/instagram/instagram_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/tiktok/tiktok_extractor.dart';

/// Real-network verification of the TikTok and Instagram extractors. Only
/// runs when `MIDA_LIVE=1` is set.
///
/// Run with: `MIDA_LIVE=1 flutter test test/live/social_live_test.dart`
void main() {
  final isLive = Platform.environment['MIDA_LIVE'] == '1';
  final skipReason = isLive ? false : 'set MIDA_LIVE=1 to run this against the real network';

  Future<void> expectPlayableMp4(Uri sourceUrl, MediaInfo info) async {
    expect(info.formats, isNotEmpty);
    final mp4Formats = info.formats.where((f) => f.container == 'mp4').toList();
    expect(mp4Formats, isNotEmpty, reason: 'expected at least one mp4 format for $sourceUrl');

    final best = mp4Formats.reduce((a, b) => a.bitrate > b.bitrate ? a : b);
    final httpClient = HttpClient();
    try {
      final request = await httpClient.getUrl(Uri.parse(best.url));
      info.requestHeaders.forEach(request.headers.set);
      request.headers.set('Range', 'bytes=0-1023');
      final response = await request.close();
      await response.drain();
      expect(response.statusCode, 206, reason: 'expected a 206 Partial Content Range response for $sourceUrl');
    } finally {
      httpClient.close(force: true);
    }
  }

  group('TikTokExtractor live', () {
    test(
      'extracts the hankgreen1 test video with an mp4 format and a working Range GET',
      () async {
        final sourceUrl = Uri.parse('https://www.tiktok.com/@hankgreen1/video/7047596209028074758');
        final info = await TikTokExtractor().extract(sourceUrl);
        await expectPlayableMp4(sourceUrl, info);
      },
      skip: skipReason,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('InstagramExtractor live', () {
    test(
      'extracts the Chunk8-jurw test reel with an mp4 format and a working Range GET',
      () async {
        final sourceUrl = Uri.parse('https://www.instagram.com/reel/Chunk8-jurw/');
        final info = await InstagramExtractor().extract(sourceUrl);
        await expectPlayableMp4(sourceUrl, info);
      },
      skip: skipReason,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
