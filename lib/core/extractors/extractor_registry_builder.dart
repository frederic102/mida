import 'bilibili/bilibili_extractor.dart';
import 'browser_capture/browser_capture_extractor.dart';
import 'chzzk/chzzk_extractor.dart';
import 'dailymotion/dailymotion_extractor.dart';
import 'douyin/douyin_extractor.dart';
import 'facebook/facebook_extractor.dart';
import 'generic/generic_extractor.dart';
import 'instagram/instagram_extractor.dart';
import 'kakao/kakao_extractor.dart';
import 'media_extractor.dart';
import 'naver/naver_extractor.dart';
import 'niconico/niconico_extractor.dart';
import 'odysee/odysee_extractor.dart';
import 'vimeo/vimeo_extractor.dart';
import 'reddit/reddit_extractor.dart';
import 'soundcloud/soundcloud_extractor.dart';
import 'tiktok/tiktok_extractor.dart';
import 'twitch/twitch_extractor.dart';
import 'twitter/twitter_extractor.dart';
import 'youtube/youtube_extractor.dart';
import 'pinterest/pinterest_extractor.dart';
import 'soop/soop_extractor.dart';
import 'linkedin/linkedin_extractor.dart';
import 'xiaohongshu/xiaohongshu_extractor.dart';
import 'telegram/telegram_extractor.dart';
import 'rumble/rumble_extractor.dart';
import 'streamable/streamable_extractor.dart';
import 'bluesky/bluesky_extractor.dart';

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
/// As of Phase 7 (`docs/plan-phase7-coverage-agent.md`) this list has 25
/// platform-native extractors ahead of Generic. See
/// `docs/supported-sites.md` for the current, human-readable list of what
/// each one covers and what still falls through to Generic/BrowserCapture
/// or is out of scope entirely - that file, not this one, is the place to
/// keep in sync when a new extractor is added below.
///
/// [useBrowserLoginSession] (Settings: "Use browser login session", off by
/// default) is threaded only into the two extractors that actually launch
/// a browser (`GenericExtractor`'s DOM-render fallback and
/// `BrowserCaptureExtractor`): per
/// `docs/plan-phase4-cookies-resilience.md` SCOPE 1, plain-HTTP extractors
/// (YouTube/Twitter/TikTok/Instagram) never get a cookie injected directly
/// and instead fall through to `BrowserCaptureExtractor` when they need the
/// login benefit.
/// `forceHeadless` is the Phase 7 agent/CLI contract (docs/plan-phase7-coverage-agent.md
/// Lane H): when true the browser-capture tier never opens a headed window
/// (one headless attempt, `HEADLESS_BLOCKED` on a challenge page). It is
/// passed straight through to `BrowserCaptureExtractor` and `GenericExtractor`.
ExtractorRegistry buildExtractorRegistry({
  bool useBrowserLoginSession = false,
  bool forceHeadless = false,
}) {
  return ExtractorRegistry(
    [
      YoutubeExtractor(),
      TwitterExtractor(),
      TikTokExtractor(),
      InstagramExtractor(),
      NaverExtractor(),
      ChzzkExtractor(),
      KakaoExtractor(),
      DailymotionExtractor(),
      TwitchExtractor(),
      RedditExtractor(),
      SoundCloudExtractor(),
      BilibiliExtractor(),
      DouyinExtractor(),
      NiconicoExtractor(),
      OdyseeExtractor(),
      VimeoExtractor(),
      FacebookExtractor(),
      PinterestExtractor(),
      SoopExtractor(),
      LinkedInExtractor(),
      XiaohongshuExtractor(),
      TelegramExtractor(),
      RumbleExtractor(),
      StreamableExtractor(),
      BlueskyExtractor(),
      GenericExtractor(useBrowserLoginSession: useBrowserLoginSession, forceHeadless: forceHeadless),
    ],
    fallbacks: [
      BrowserCaptureExtractor(useBrowserLoginSession: useBrowserLoginSession, forceHeadless: forceHeadless),
    ],
    // A platform LOGIN_REQUIRED only reaches the browser fallback when that
    // browser can carry the user's session (Gadfly G2).
    loginSessionAvailable: useBrowserLoginSession,
  );
}
