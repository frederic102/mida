import 'browser_capture/browser_capture_extractor.dart';
import 'generic/generic_extractor.dart';
import 'instagram/instagram_extractor.dart';
import 'media_extractor.dart';
import 'tiktok/tiktok_extractor.dart';
import 'twitter/twitter_extractor.dart';
import 'youtube/youtube_extractor.dart';

/// Single place that decides extractor order for every URL MiDa is asked to
/// handle, per `docs/plan-phase2b-wiring.md`. Order: platform-native
/// extractors first (cheapest and most reliable for the sites they know),
/// `GenericExtractor` last among the primaries (it accepts every http(s)
/// URL, so anything registered after it would never be reached by
/// `ExtractorRegistry.find`), and `BrowserCaptureExtractor` (Phase 2d) as a
/// fallback - not part of the `canHandle` scan (see the field doc on
/// `ExtractorRegistry.fallbacks`). Both the Phase 2d NO_MEDIA_FOUND chain
/// and the platform-extractor-technique-failure chain (TikTok/Instagram/X
/// falling through to Generic then BrowserCapture) live in
/// `ExtractorRegistry.resolveInfo` (`media_extractor.dart`); this function
/// only builds the ordered list.
///
/// [useBrowserLoginSession] (Settings: "Use browser login session", off by
/// default) is threaded only into the two extractors that actually launch
/// a browser (`GenericExtractor`'s DOM-render fallback and
/// `BrowserCaptureExtractor`): per
/// `docs/plan-phase4-cookies-resilience.md` SCOPE 1, plain-HTTP extractors
/// (YouTube/Twitter/TikTok/Instagram) never get a cookie injected directly
/// and instead fall through to `BrowserCaptureExtractor` when they need the
/// login benefit.
ExtractorRegistry buildExtractorRegistry({bool useBrowserLoginSession = false}) {
  return ExtractorRegistry(
    [
      YoutubeExtractor(),
      TwitterExtractor(),
      TikTokExtractor(),
      InstagramExtractor(),
      GenericExtractor(useBrowserLoginSession: useBrowserLoginSession),
    ],
    fallbacks: [BrowserCaptureExtractor(useBrowserLoginSession: useBrowserLoginSession)],
  );
}
