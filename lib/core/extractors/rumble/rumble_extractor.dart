import '../generic/format_expander.dart';
import '../media_extractor.dart';
import '../media_models.dart';
import '../native_http/native_host_list.dart';
import '../native_http/native_http_client.dart';
import '../native_http/native_json.dart';
import 'rumble_page_parser.dart';
import 'rumble_url_matcher.dart';
import 'rumble_video_parser.dart';

/// Native Rumble extractor for `rumble.com/<slug>.html` and
/// `rumble.com/embed/<id>` (see [RumbleUrlMatcher]).
///
/// Technique, per `docs/supported-sites.md` Policy: the two plain HTTPS GETs
/// Rumble's own pages make. For a page URL, one GET of the page to read its
/// embed id ([RumblePageParser]); then, for both URL shapes, the embed
/// player's own data call
/// `https://rumble.com/embedJS/u3/?request=video&ver=2&v=<id>`
/// ([RumbleVideoParser]). Progressive mp4/webm renditions become one format
/// per height; the HLS master is expanded through `FormatExpander` (which
/// also DRM-scans it). No cookies, no login, no signature or token forging.
///
/// Outcomes:
/// - formats found -> [MediaInfo].
/// - HTTP 404/410, or an embedJS `false`/not-found answer -> `NOT_FOUND`.
/// - an embedJS error naming a login/subscription/age gate -> `LOGIN_REQUIRED`.
/// - only DRM-flagged HLS -> `DRM_PROTECTED`; a live stream with no VOD
///   rendition, or an answer without any playable URL -> `NO_MEDIA_FOUND`.
/// - HTTP 429 -> `RATE_LIMITED`; 401/403 -> `CHALLENGE_FAILED`; a page
///   without an embed id, or an unrecognized answer -> `PARSE_ERROR`.
class RumbleExtractor implements MediaExtractor {
  static const Map<String, String> _downloadHeaders = {
    'User-Agent': NativeHttpClient.userAgent,
    'Referer': 'https://rumble.com/',
  };

  /// Where Rumble media may live: the site, its `rmbl.ws` playlist host and
  /// the `1a-1791.com` / `rumble.cloud` CDNs. An embedJS answer naming any
  /// other host gets no request and no format.
  static const NativeHostList _mediaHosts = NativeHostList(['rumble.com', 'rmbl.ws', '1a-1791.com', 'rumble.cloud']);

  final NativeHttpClient _http;
  final RumblePageParser _pageParser;
  final RumbleVideoParser _videoParser;
  final FormatExpander _expander;

  RumbleExtractor({NativeHttpClient? httpClient, RumblePageParser? pageParser, RumbleVideoParser? videoParser})
      : this._((httpClient ?? NativeHttpClient(service: 'Rumble')).withMediaHosts(_mediaHosts), pageParser, videoParser);

  RumbleExtractor._(this._http, RumblePageParser? pageParser, RumbleVideoParser? videoParser)
      : _pageParser = pageParser ?? const RumblePageParser(),
        _videoParser = videoParser ?? const RumbleVideoParser(),
        _expander = FormatExpander(fetchText: _http.fetchText);

  @override
  bool canHandle(Uri url) => RumbleUrlMatcher.match(url) != null;

  @override
  Future<MediaInfo> extract(Uri url) async {
    final ref = RumbleUrlMatcher.match(url);
    if (ref == null) {
      throw const MediaExtractionException('UNSUPPORTED_URL', 'Not a recognizable Rumble video URL.');
    }

    final embedId = ref.embedId ?? await _embedIdFromPage(ref);
    final video = await _fetchVideo(embedId);

    var drmDetected = false;
    final formats = <MediaFormat>[
      for (final file in video.files)
        if (_http.mediaUrlAllowed(file.url))
          MediaFormat(
          id: file.id,
          url: file.url,
          container: file.container,
          width: file.width,
          height: file.height,
          fps: file.fps,
          bitrate: file.bitrate,
          contentLength: file.size,
          hasVideo: true,
          hasAudio: true,
          capabilitiesUnknown: true,
        ),
    ];
    for (final hls in video.hlsUrls) {
      final expanded = await _expander.expandFormats(hls, 'm3u8', extraHeaders: _downloadHeaders);
      drmDetected = drmDetected || expanded.drmDetected;
      formats.addAll(_http.filterAllowedFormats(expanded.formats));
    }

    if (formats.isEmpty) {
      if (drmDetected) {
        throw const MediaExtractionException(
          'DRM_PROTECTED',
          'This Rumble video is DRM protected. MiDa does not bypass DRM.',
        );
      }
      throw MediaExtractionException(
        'NO_MEDIA_FOUND',
        video.isLive
            ? 'This Rumble video is a live stream with no recording to download yet.'
            : 'Rumble listed this video but gave no playable file.',
      );
    }

    return MediaInfo(
      id: embedId,
      title: video.title ?? 'Rumble video $embedId',
      author: video.author,
      thumbnailUrl: video.thumbnailUrl != null && _http.mediaUrlAllowed(video.thumbnailUrl!) ? video.thumbnailUrl : null,
      duration: video.duration,
      formats: formats,
      sourceUrl: url,
      requestHeaders: _downloadHeaders,
    );
  }

  Future<String> _embedIdFromPage(RumbleRef ref) async {
    final page = await _http.get(ref.pageUrl, acceptHop: _isRumbleHost);
    NativeHttpClient.throwForStatus(page.statusCode, 'Rumble');
    final id = _pageParser.embedId(page.body, slug: ref.pageSlug!);
    if (id == null) {
      throw MediaExtractionException(
        'PARSE_ERROR',
        'MiDa could not find the player id in this Rumble page'
        '${page.truncated ? ' (page larger than the read limit)' : ''}; trying another method.',
      );
    }
    return id;
  }

  Future<RumbleVideo> _fetchVideo(String embedId) async {
    if (!RumbleUrlMatcher.embedId.hasMatch(embedId)) {
      throw const MediaExtractionException('PARSE_ERROR', 'Rumble gave a player id MiDa does not accept.');
    }
    final endpoint = Uri.https('rumble.com', '/embedJS/u3/', {'request': 'video', 'ver': '2', 'v': embedId});
    final response = await _http.get(
      endpoint,
      kind: NativeBodyKind.api,
      headers: const {'Accept': 'application/json', 'Referer': 'https://rumble.com/'},
      acceptHop: _isRumbleHost,
    );
    NativeHttpClient.throwForStatus(response.statusCode, 'Rumble');

    final decoded = NativeJson.decode(response.body, 'Rumble');
    if (decoded == false || decoded == null) {
      throw const MediaExtractionException('NOT_FOUND', 'This Rumble video is not available. It may have been removed.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const MediaExtractionException('PARSE_ERROR', 'Rumble returned JSON in a shape MiDa does not recognize.');
    }
    return _videoParser.parse(decoded);
  }

  static bool _isRumbleHost(Uri hop) {
    final host = hop.host.toLowerCase();
    return host == 'rumble.com' || host == 'www.rumble.com';
  }
}
