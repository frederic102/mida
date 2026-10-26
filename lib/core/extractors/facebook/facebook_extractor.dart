import '../generic/format_expander.dart';
import '../media_extractor.dart';
import '../media_models.dart';
import 'facebook_format_builder.dart';
import 'facebook_page_fetcher.dart';
import 'facebook_page_state.dart';
import 'facebook_url_matcher.dart';
import 'facebook_video_json_parser.dart';

/// Native Facebook extractor for public videos (`/<page>/videos/<id>`,
/// `/watch/?v=<id>`, `/reel/<id>`, `/share/v/<slug>`, `fb.watch/<slug>`;
/// see [FacebookUrlMatcher]).
///
/// Technique, per `docs/supported-sites.md` Policy: one plain HTTPS GET of
/// the video page with a normal desktop browser User-Agent
/// ([FacebookPageFetcher]), then reading the server-rendered JSON the
/// site's own web player bootstraps from ([FacebookVideoJsonParser]). Short
/// links are followed through their `Location` header by the same guarded
/// GET. No cookies (none sent, none synthesized), no mobile-app UA, no
/// GraphQL `doc_id` calls, no challenge solving.
///
/// Outcomes:
/// - Playback data found -> [MediaInfo] ([FacebookFormatBuilder]).
/// - Redirect to `/login.php`/`/checkpoint`, or (with no playback data) a
///   `login_form`/"Log in" page -> `LOGIN_REQUIRED`. Signed-in access is the
///   browser-capture tier's job, with the user's "Use browser login
///   session" toggle; this extractor never reads cookies itself.
/// - HTTP 404/410, or Facebook's "content isn't available" page ->
///   `NOT_FOUND`.
/// - Only DRM-flagged DASH -> `DRM_PROTECTED`.
/// - HTTP 429 -> `RATE_LIMITED`; 401/403 -> `CHALLENGE_FAILED`; any other
///   non-200 -> `NETWORK`; a short link landing off Facebook or an
///   unrecognized page shape -> `PARSE_ERROR`. Those four are fall-through
///   statuses: the registry then tries the generic
///   and browser tiers, which is how Facebook worked before this class.
class FacebookExtractor implements MediaExtractor {
  static const Map<String, String> _downloadHeaders = {
    'User-Agent': FacebookPageFetcher.userAgent,
    'Referer': 'https://www.facebook.com/',
  };

  final FacebookPageFetcher _fetcher;
  final FacebookVideoJsonParser _parser;
  final FacebookFormatBuilder _formatBuilder;

  FacebookExtractor({FacebookPageFetcher? fetcher, FacebookVideoJsonParser? parser})
      : this._(fetcher ?? FacebookPageFetcher(), parser ?? const FacebookVideoJsonParser());

  FacebookExtractor._(this._fetcher, this._parser)
      : _formatBuilder = FacebookFormatBuilder(expander: FormatExpander(fetchText: _fetcher.fetchText));

  @override
  bool canHandle(Uri url) => FacebookUrlMatcher.match(url) != null;

  @override
  Future<MediaInfo> extract(Uri url) async {
    final ref = FacebookUrlMatcher.match(url);
    if (ref == null) {
      throw const MediaExtractionException('UNSUPPORTED_URL', 'Not a recognizable Facebook video URL.');
    }

    final page = await _fetcher.fetchPage(ref.fetchUrl);
    final landed = page.effectiveUrl;
    if (FacebookPageStateDetector.isLoginRedirect(landed)) throw _loginRequired;
    _throwForStatus(page.statusCode);
    if (!FacebookUrlMatcher.isFacebookHost(landed.host)) {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'This Facebook short link did not lead to a Facebook page; trying another method.',
      );
    }

    final videoId = ref.videoId ?? FacebookUrlMatcher.videoIdFromFacebookPath(landed);
    final data = _parser.parse(page.body, videoId: videoId);
    final node = data.video;
    if (node != null) {
      final built = await _formatBuilder.build(node, requestHeaders: _downloadHeaders);
      if (built.formats.isNotEmpty) return _info(built.formats, data.meta, node, videoId, url);
      if (built.drmDetected) {
        throw const MediaExtractionException(
          'DRM_PROTECTED',
          'This Facebook video is DRM protected. MiDa does not bypass DRM.',
        );
      }
    }

    switch (FacebookPageStateDetector.classify(page.body)) {
      case FacebookPageState.loginWall:
        throw _loginRequired;
      case FacebookPageState.notFound:
        throw _notFound;
      case FacebookPageState.unknown:
        throw MediaExtractionException(
          'PARSE_ERROR',
          'MiDa could not find video data in this Facebook page'
              '${page.truncated ? ' (page larger than the read limit)' : ''}; trying another method.',
        );
    }
  }

  static const MediaExtractionException _loginRequired = MediaExtractionException(
    'LOGIN_REQUIRED',
    'Facebook asks to sign in to watch this video. Turn on "Use browser login session" in Settings '
        'if your own browser is signed in to Facebook.',
  );

  static const MediaExtractionException _notFound = MediaExtractionException(
    'NOT_FOUND',
    'This Facebook video is not available. It may have been removed or shared only with certain people.',
  );

  static void _throwForStatus(int status) {
    if (status == 404 || status == 410) throw _notFound;
    if (status == 429) {
      throw const MediaExtractionException(
        'RATE_LIMITED',
        'Facebook is throttling this request. Wait a moment and try again.',
      );
    }
    if (status == 401 || status == 403) {
      throw MediaExtractionException(
        'CHALLENGE_FAILED',
        'Facebook refused the page request (HTTP $status); trying another method.',
      );
    }
    if (status != 200) {
      throw MediaExtractionException('NETWORK', 'Facebook returned HTTP $status for this page.');
    }
  }

  static MediaInfo _info(
    List<MediaFormat> formats,
    FacebookVideoMeta meta,
    FacebookVideoNode node,
    String? videoId,
    Uri sourceUrl,
  ) {
    final id = videoId ?? (node.id.isNotEmpty ? node.id : sourceUrl.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? 'facebook');
    return MediaInfo(
      id: id,
      title: meta.title ?? 'Facebook video $id',
      author: meta.author,
      thumbnailUrl: meta.thumbnailUrl,
      duration: meta.duration,
      formats: formats,
      sourceUrl: sourceUrl,
      requestHeaders: _downloadHeaders,
    );
  }
}
