import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/browser_capture/browser_capture_extractor.dart';
import 'package:mida/core/extractors/extractor_registry_builder.dart';
import 'package:mida/core/extractors/generic/generic_extractor.dart';
import 'package:mida/core/extractors/instagram/instagram_extractor.dart';
import 'package:mida/core/extractors/tiktok/tiktok_extractor.dart';
import 'package:mida/core/extractors/twitter/twitter_extractor.dart';
import 'package:mida/core/extractors/youtube/youtube_extractor.dart';

/// No network is involved anywhere here: `find`/the fallback list only
/// call `canHandle`, which every extractor documents as cheap/pure.
void main() {
  group('buildExtractorRegistry order', () {
    test('a YouTube URL resolves to YoutubeExtractor even though GenericExtractor also matches it', () {
      final registry = buildExtractorRegistry();
      final found = registry.find(Uri.parse('https://www.youtube.com/watch?v=dQw4w9WgXcQ'));
      expect(found, isA<YoutubeExtractor>());
    });

    test('an X/Twitter URL resolves to TwitterExtractor even though GenericExtractor also matches it', () {
      final registry = buildExtractorRegistry();
      final found = registry.find(Uri.parse('https://x.com/someone/status/1234567890'));
      expect(found, isA<TwitterExtractor>());
    });

    test('a TikTok URL resolves to TikTokExtractor even though GenericExtractor also matches it', () {
      final registry = buildExtractorRegistry();
      final found = registry.find(Uri.parse('https://www.tiktok.com/@hankgreen1/video/7047596209028074758'));
      expect(found, isA<TikTokExtractor>());
    });

    test('an Instagram post URL resolves to InstagramExtractor even though GenericExtractor also matches it', () {
      final registry = buildExtractorRegistry();
      final found = registry.find(Uri.parse('https://www.instagram.com/reel/Chunk8-jurw/'));
      expect(found, isA<InstagramExtractor>());
    });

    test('an unrelated http(s) URL falls through to GenericExtractor', () {
      final registry = buildExtractorRegistry();
      final found = registry.find(Uri.parse('https://example.com/some/video/page'));
      expect(found, isA<GenericExtractor>());
    });

    test('BrowserCaptureExtractor is registered as a fallback, not part of the canHandle scan', () {
      final registry = buildExtractorRegistry();
      expect(registry.fallbacks, hasLength(1));
      expect(registry.fallbacks.single, isA<BrowserCaptureExtractor>());
    });
  });
}
