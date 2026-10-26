/// Platform-native extractors, in registry order
/// (`lib/core/extractors/extractor_registry_builder.dart`). Hand-kept: the
/// registry exposes no listing API. `test/cli/cli_sites_drift_test.dart`
/// fails when the builder gains or loses an extractor without this list.
const List<String> nativeSiteIds = [
  'youtube',
  'x',
  'tiktok',
  'instagram',
  'naver-tv',
  'chzzk',
  'kakao',
  'dailymotion',
  'twitch',
  'reddit',
  'soundcloud',
  'bilibili',
  'douyin',
  'niconico',
  'odysee',
  'vimeo',
  'facebook',
  'pinterest',
  'soop',
  'linkedin',
  'xiaohongshu',
  'telegram',
  'rumble',
  'streamable',
  'bluesky',
];

/// The catch-all tiers behind the natives, in the order they are tried.
const List<String> siteTiers = ['generic', 'browser-capture'];

/// The ids from [nativeSiteIds] and [siteTiers] that have downloaded a
/// real file in a recorded live run (`docs/coverage-corpus.md`: the
/// 2026-09-06 v2.2.0 32-site run's "Downloaded:" line plus the v2.3.0
/// five-site rerun). A native counts only when its corpus row lists that
/// native extractor as the tier; a site that downloaded through generic
/// analysis or browser capture counts for that tier, not for a native
/// added later (Rumble, Streamable, Pinterest and Facebook natives are
/// v2.4.0 and unmeasured). Every v2.4.0 addition is absent here.
/// `test/cli/cli_sites_drift_test.dart` recomputes this from the corpus
/// document and fails when the two disagree.
const List<String> measuredLiveSiteIds = [
  'youtube',
  'x',
  'tiktok',
  'instagram',
  'naver-tv',
  'chzzk',
  'soundcloud',
  'douyin',
  'odysee',
  'generic',
  'browser-capture',
];
