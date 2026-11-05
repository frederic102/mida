/// Extractor class name -> the site id `mida-cli sites` prints for it, in
/// registry order (`extractor_registry_builder.dart`). The one table behind
/// `MediaInfo.extractor`, the CLI `extractor` result field and
/// `nativeSiteIds`; `test/cli/cli_sites_drift_test.dart` fails when the
/// builder gains or loses a native without a row here.
const Map<String, String> nativeExtractorIds = {
  'YoutubeExtractor': 'youtube',
  'TwitterExtractor': 'x',
  'TikTokExtractor': 'tiktok',
  'InstagramExtractor': 'instagram',
  'NaverExtractor': 'naver-tv',
  'ChzzkExtractor': 'chzzk',
  'KakaoExtractor': 'kakao',
  'DailymotionExtractor': 'dailymotion',
  'TwitchExtractor': 'twitch',
  'RedditExtractor': 'reddit',
  'SoundCloudExtractor': 'soundcloud',
  'BilibiliExtractor': 'bilibili',
  'DouyinExtractor': 'douyin',
  'NiconicoExtractor': 'niconico',
  'OdyseeExtractor': 'odysee',
  'VimeoExtractor': 'vimeo',
  'FacebookExtractor': 'facebook',
  'PinterestExtractor': 'pinterest',
  'SoopExtractor': 'soop',
  'LinkedInExtractor': 'linkedin',
  'XiaohongshuExtractor': 'xiaohongshu',
  'TelegramExtractor': 'telegram',
  'RumbleExtractor': 'rumble',
  'StreamableExtractor': 'streamable',
  'BlueskyExtractor': 'bluesky',
};

/// The catch-all tiers behind the natives, in the order they are tried.
const Map<String, String> tierExtractorIds = {
  'GenericExtractor': 'generic',
  'BrowserCaptureExtractor': 'browser-capture',
};

/// The site id for [extractor], or null for a class outside both tables
/// (a test double). Keyed by class name; the release build is not obfuscated.
String? extractorSiteId(Object extractor) {
  final name = extractor.runtimeType.toString();
  return nativeExtractorIds[name] ?? tierExtractorIds[name];
}
