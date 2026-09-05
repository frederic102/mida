import '../media_extractor.dart';
import '../media_models.dart';
import 'kakao_play_info_client.dart';

/// Native KakaoTV extractor (`tv.kakao.com/channel/<channelId>/cliplink/<clipId>`
/// and `tv.kakao.com/v/<clipId>`).
///
/// **KakaoTV's public video service was verified live 2026-09-05 to be
/// discontinued** (`docs/plan-phase5-coverage.md` Lane C; see
/// [KakaoPlayInfoClient]'s class doc for the two independent live checks).
/// This extractor still resolves the URL shape and calls the real
/// historical playback endpoint so it fails with a specific, honest
/// `NOT_FOUND` (via [KakaoPlayInfoClient]) rather than falling through to
/// Generic/BrowserCapture and burning a browser launch on a link nothing
/// can ever play - not because the implementation could not be completed,
/// but because there is no live service left to complete it against.
class KakaoExtractor implements MediaExtractor {
  static final RegExp _cliplinkPathPattern = RegExp(r'^/channel/\d+/cliplink/(\d+)');
  static final RegExp _shortPathPattern = RegExp(r'^/v/(\d+)');

  final KakaoPlayInfoClient _playInfoClient;

  KakaoExtractor({KakaoPlayInfoClient? playInfoClient})
      : _playInfoClient = playInfoClient ?? KakaoPlayInfoClient();

  static bool _isKakaoTvHost(String host) {
    final normalized = host.toLowerCase();
    return normalized == 'tv.kakao.com' || normalized.endsWith('.tv.kakao.com');
  }

  static String? _extractClipId(Uri url) {
    if (!_isKakaoTvHost(url.host)) return null;
    final cliplinkMatch = _cliplinkPathPattern.firstMatch(url.path);
    if (cliplinkMatch != null) return cliplinkMatch.group(1);
    final shortMatch = _shortPathPattern.firstMatch(url.path);
    return shortMatch?.group(1);
  }

  @override
  bool canHandle(Uri url) => _extractClipId(url) != null;

  @override
  Future<MediaInfo> extract(Uri url) async {
    final clipId = _extractClipId(url);
    if (clipId == null) {
      throw MediaExtractionException(
        'UNSUPPORTED_URL',
        'Not a recognizable KakaoTV clip URL: $url',
      );
    }

    final formats = await _playInfoClient.fetchFormats(clipId);

    return MediaInfo(
      id: clipId,
      title: 'KakaoTV clip $clipId',
      formats: formats,
      sourceUrl: url,
    );
  }
}
