import '../media_extractor.dart';
import '../media_models.dart';
import '../native_http/native_host_list.dart';
import '../native_http/native_http_client.dart';
import '../native_http/native_json.dart';
import 'streamable_url_matcher.dart';
import 'streamable_video_parser.dart';

/// Native Streamable extractor for `streamable.com/<code>` and
/// `streamable.com/e/<code>` (see [StreamableUrlMatcher]).
///
/// Technique, per `docs/supported-sites.md` Policy: the one plain HTTPS GET
/// the Streamable web player makes, `https://api.streamable.com/videos/<code>`,
/// then reading its `files` map ([StreamableVideoParser]): `mp4` and
/// `mp4-mobile` become two muxed-unknown formats with their width, height,
/// bitrate and size. No cookies, no login.
///
/// Outcomes:
/// - files found -> [MediaInfo].
/// - HTTP 404/410 -> `NOT_FOUND`.
/// - `status` other than 2 (queued, processing, failed) -> `PARSE_ERROR`
///   whose reason says the video is still processing.
/// - ready but no usable file -> `NO_MEDIA_FOUND`.
/// - HTTP 429 -> `RATE_LIMITED`; 401/403 -> `CHALLENGE_FAILED`; any other
///   non-200 -> `NETWORK`; unreadable or unrecognized JSON -> `PARSE_ERROR`.
class StreamableExtractor implements MediaExtractor {
  static const Map<String, String> _downloadHeaders = {'User-Agent': NativeHttpClient.userAgent};

  /// Streamable media lives on `streamable.com` and its subdomains
  /// (`cdn-cf-east.streamable.com`, ...). Files named anywhere else are dropped.
  static const NativeHostList _mediaHosts = NativeHostList(['streamable.com']);

  final NativeHttpClient _http;
  final StreamableVideoParser _parser;

  StreamableExtractor({NativeHttpClient? httpClient, StreamableVideoParser? parser})
      : _http = (httpClient ?? NativeHttpClient(service: 'Streamable')).withMediaHosts(_mediaHosts),
        _parser = parser ?? const StreamableVideoParser();

  @override
  bool canHandle(Uri url) => StreamableUrlMatcher.match(url) != null;

  @override
  Future<MediaInfo> extract(Uri url) async {
    final code = StreamableUrlMatcher.match(url);
    if (code == null) {
      throw const MediaExtractionException('UNSUPPORTED_URL', 'Not a recognizable Streamable video URL.');
    }

    final response = await _http.get(
      Uri.https('api.streamable.com', '/videos/$code'),
      kind: NativeBodyKind.api,
      headers: const {'Accept': 'application/json'},
      acceptHop: _isStreamableHost,
    );
    NativeHttpClient.throwForStatus(response.statusCode, 'Streamable');

    final video = _parser.parse(NativeJson.decodeObject(response.body, 'Streamable'));
    if (video.formats.isEmpty) {
      throw const MediaExtractionException('NO_MEDIA_FOUND', 'Streamable lists this video but gave no playable file.');
    }
    final formats = [for (final f in video.formats) if (_http.mediaUrlAllowed(f.url)) f];
    if (formats.isEmpty) {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'Streamable pointed at a video host MiDa does not trust; trying another method.',
      );
    }
    return MediaInfo(
      id: code,
      title: video.title ?? 'Streamable video $code',
      thumbnailUrl: video.thumbnailUrl != null && _http.mediaUrlAllowed(video.thumbnailUrl!) ? video.thumbnailUrl : null,
      duration: video.duration,
      formats: formats,
      sourceUrl: url,
      requestHeaders: _downloadHeaders,
    );
  }

  static bool _isStreamableHost(Uri hop) {
    final host = hop.host.toLowerCase();
    return host == 'api.streamable.com' || host == 'streamable.com' || host == 'www.streamable.com';
  }
}
