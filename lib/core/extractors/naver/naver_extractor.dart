import '../media_extractor.dart';
import '../media_models.dart';
import '../naver_shared/naver_vod_play_client.dart';
import 'naver_clip_info_client.dart';

/// Native Naver TV extractor (`tv.naver.com/v/<clipId>` and
/// `tv.naver.com/embed/<clipId>`). Two-step, same shape as
/// `TikTokExtractor`'s page-then-API pattern: resolve the clip number to a
/// `videoId`/`inKey` pair via [NaverClipInfoClient] (a signed call to
/// tv.naver.com's own web-client API, `docs/plan-phase5-coverage.md`
/// Lane C), then fetch renditions for that pair via the shared
/// [NaverVodPlayClient] (also used by CHZZK - both platforms hand off to
/// the same underlying Naver VOD playback backend). Verified live
/// 2026-09-05 against a fresh clip (the task's originally supplied clip id
/// had since been deleted server-side - `statusCode: CLIP_NOT_FOUND` -
/// which this extractor surfaces as `NOT_FOUND`, not a crash).
class NaverExtractor implements MediaExtractor {
  static final RegExp _clipPathPattern = RegExp(r'^/(v|embed)/(\d+)');

  final NaverClipInfoClient _clipInfoClient;
  final NaverVodPlayClient _vodPlayClient;

  NaverExtractor({
    NaverClipInfoClient? clipInfoClient,
    NaverVodPlayClient? vodPlayClient,
  })  : _clipInfoClient = clipInfoClient ?? NaverClipInfoClient(),
        _vodPlayClient = vodPlayClient ?? NaverVodPlayClient();

  static bool _isNaverTvHost(String host) {
    final normalized = host.toLowerCase();
    return normalized == 'tv.naver.com' || normalized.endsWith('.tv.naver.com');
  }

  static String? _extractClipId(Uri url) {
    if (!_isNaverTvHost(url.host)) return null;
    final match = _clipPathPattern.firstMatch(url.path);
    return match?.group(2);
  }

  @override
  bool canHandle(Uri url) => _extractClipId(url) != null;

  @override
  Future<MediaInfo> extract(Uri url) async {
    final clipId = _extractClipId(url);
    if (clipId == null) {
      throw MediaExtractionException(
        'UNSUPPORTED_URL',
        'Not a recognizable Naver TV clip URL: $url',
      );
    }

    final clip = await _clipInfoClient.fetch(clipId);
    final formats = await _vodPlayClient.fetchFormats(clip.videoId, clip.inKey);

    return MediaInfo(
      id: clipId,
      title: clip.title,
      author: clip.author,
      thumbnailUrl: clip.thumbnailUrl,
      duration: clip.duration,
      formats: formats,
      sourceUrl: url,
    );
  }
}
