import '../core/extractors/extractor_site_ids.dart';

/// Platform-native extractors, in registry order
/// (`lib/core/extractors/extractor_registry_builder.dart`), from the shared
/// class-to-id table. `test/cli/cli_sites_drift_test.dart` fails when the
/// builder gains or loses an extractor without a row there.
final List<String> nativeSiteIds = List.unmodifiable(nativeExtractorIds.values);

/// The catch-all tiers behind the natives, in the order they are tried.
final List<String> siteTiers = List.unmodifiable(tierExtractorIds.values);

/// The ids from [nativeSiteIds] and [siteTiers] that have downloaded a
/// real file in a recorded live run (`docs/coverage-corpus.md`: the
/// 2026-09-06 v2.2.0 32-site run's "Downloaded:" line plus the v2.3.0
/// five-site rerun, plus the 2026-11-03 "Downloaded natively" line for
/// v2.4.0). A native counts only when its corpus row lists that native
/// extractor as the tier; a site that downloaded through generic analysis or
/// browser capture counts for that tier, not for a native added later.
/// Rumble (HEADLESS_BLOCKED), LinkedIn and Xiaohongshu are still unmeasured.
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
  'facebook',
  'pinterest',
  'soop',
  'telegram',
  'streamable',
  'bluesky',
  'generic',
  'browser-capture',
];
