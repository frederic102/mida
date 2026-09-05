import '../media_extractor.dart';
import '../media_models.dart';
import '../naver_shared/naver_vod_play_client.dart';
import 'chzzk_video_info_client.dart';

/// Native CHZZK VOD extractor (`chzzk.naver.com/video/<videoNo>`). Live
/// streams (`chzzk.naver.com/live/<channelId>`) are out of scope per
/// `docs/plan-phase5-coverage.md` Lane C and deliberately do not match
/// [canHandle].
///
/// Two-step, same shape as `NaverExtractor`: resolve the video number to a
/// `videoId`/`inKey` pair via [ChzzkVideoInfoClient] (CHZZK's own public,
/// unsigned video-info API), then fetch renditions for that pair via the
/// shared [NaverVodPlayClient] - CHZZK hands off to the same underlying
/// Naver VOD playback backend Naver TV uses, verified live 2026-09-05
/// (`docs/plan-phase5-coverage.md` Lane C).
class ChzzkExtractor implements MediaExtractor {
  static final RegExp _videoPathPattern = RegExp(r'^/video/(\d+)');

  final ChzzkVideoInfoClient _videoInfoClient;
  final NaverVodPlayClient _vodPlayClient;

  ChzzkExtractor({
    ChzzkVideoInfoClient? videoInfoClient,
    NaverVodPlayClient? vodPlayClient,
  })  : _videoInfoClient = videoInfoClient ?? ChzzkVideoInfoClient(),
        _vodPlayClient = vodPlayClient ?? NaverVodPlayClient();

  static bool _isChzzkHost(String host) {
    final normalized = host.toLowerCase();
    return normalized == 'chzzk.naver.com' || normalized.endsWith('.chzzk.naver.com');
  }

  static String? _extractVideoNo(Uri url) {
    if (!_isChzzkHost(url.host)) return null;
    final match = _videoPathPattern.firstMatch(url.path);
    return match?.group(1);
  }

  @override
  bool canHandle(Uri url) => _extractVideoNo(url) != null;

  @override
  Future<MediaInfo> extract(Uri url) async {
    final videoNo = _extractVideoNo(url);
    if (videoNo == null) {
      throw MediaExtractionException(
        'UNSUPPORTED_URL',
        'Not a recognizable CHZZK VOD URL: $url',
      );
    }

    final video = await _videoInfoClient.fetch(videoNo);
    final formats = await _vodPlayClient.fetchFormats(video.videoId, video.inKey);

    return MediaInfo(
      id: videoNo,
      title: video.title,
      author: video.author,
      thumbnailUrl: video.thumbnailUrl,
      duration: video.duration,
      formats: formats,
      sourceUrl: url,
    );
  }
}
