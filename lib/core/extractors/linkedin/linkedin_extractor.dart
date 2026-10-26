import '../generic/format_expander.dart';
import '../media_extractor.dart';
import '../media_models.dart';
import '../native_http/native_host_list.dart';
import '../native_http/native_http_client.dart';
import 'linkedin_post_parser.dart';
import 'linkedin_url_matcher.dart';

/// Native LinkedIn extractor for public video posts
/// (`linkedin.com/posts/<slug>`, `/feed/update/urn:li:activity:<id>`,
/// `/embed/feed/update/...`; see [LinkedInUrlMatcher]). Learning courses
/// and anything behind sign-in are out of scope.
///
/// Technique, per `docs/supported-sites.md` Policy: one plain HTTPS GET of
/// the public post page with a normal desktop User-Agent and no cookies,
/// then reading the `<video data-sources>` JSON the page itself hands its
/// player ([LinkedInPostParser]). Redirects stay on LinkedIn hosts; a
/// redirect to `/authwall` or `/checkpoint` is the anonymous-visitor wall
/// (`CHALLENGE_FAILED`: it is shown for public posts too); only a redirect
/// to the explicit `/login` form is `LOGIN_REQUIRED`.
///
/// Formats: `application/x-mpegURL` sources are HLS, expanded by
/// `FormatExpander` (DRM-scanned, one format per variant); `video/mp4`
/// sources are progressive mp4, muxed but flagged `capabilitiesUnknown`
/// with the bitrate the page gave. Every listed source is offered.
///
/// Outcomes: authwall/checkpoint (redirect or page) -> `CHALLENGE_FAILED`
/// (the registry then tries the generic and browser tiers); `/login` ->
/// `LOGIN_REQUIRED` (the browser tier may carry the user's session); a post
/// page without a video -> `NO_MEDIA_FOUND`; 429 -> `RATE_LIMITED`;
/// 401/403, LinkedIn's 999 and a bare 404/410 (never
/// terminal: the body is not read, and LinkedIn also 404s unwanted clients) ->
/// `CHALLENGE_FAILED`;
/// any other non-200 -> `NETWORK`; a video listing MiDa cannot read ->
/// `PARSE_ERROR`; DRM -> `DRM_PROTECTED`.
class LinkedInExtractor implements MediaExtractor {
  static const Map<String, String> _downloadHeaders = {
    'User-Agent': NativeHttpClient.userAgent,
    'Referer': 'https://www.linkedin.com/',
  };

  /// LinkedIn's `/authwall` is shown to anonymous clients for public posts
  /// too, so it is a technique failure (falls through to the generic and
  /// browser tiers), not proof the post needs an account.
  static const MediaExtractionException _authwall = MediaExtractionException(
    'CHALLENGE_FAILED',
    'LinkedIn put its sign-in wall in front of this post for an anonymous visitor; trying another method.',
  );

  static const MediaExtractionException _loginRequired = MediaExtractionException(
    'LOGIN_REQUIRED',
    'LinkedIn sent this request to its sign-in page. Turn on "Use browser login session" in Settings '
        'if your own browser is signed in to LinkedIn.',
  );

  final NativeHttpClient _http;
  final LinkedInPostParser _parser;
  final FormatExpander _expander;

  /// Hosts LinkedIn media may live on (`dms.licdn.com`, `media.licdn.com`).
  /// A source URL, or an HLS redirect, outside it is never requested or
  /// offered.
  static const NativeHostList mediaHosts = NativeHostList(['licdn.com', 'linkedin.com']);

  LinkedInExtractor({NativeHttpClient? httpClient, LinkedInPostParser? parser})
      : this._(
          (httpClient ?? NativeHttpClient(service: 'LinkedIn')).withMediaHosts(mediaHosts),
          parser ?? const LinkedInPostParser(),
        );

  LinkedInExtractor._(this._http, this._parser) : _expander = FormatExpander(fetchText: _http.fetchText);

  @override
  bool canHandle(Uri url) => LinkedInUrlMatcher.match(url) != null;

  @override
  Future<MediaInfo> extract(Uri url) async {
    final ref = LinkedInUrlMatcher.match(url);
    if (ref == null) {
      throw const MediaExtractionException('UNSUPPORTED_URL', 'Not a recognizable public LinkedIn post URL.');
    }

    final page = await _http.get(
      ref.fetchUrl,
      headers: const {'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'},
      kind: NativeBodyKind.page,
      acceptHop: (hop) => LinkedInUrlMatcher.isLinkedInHost(hop.host),
    );
    if (LinkedInUrlMatcher.isAuthwall(page.effectiveUrl)) throw _authwall;
    if (LinkedInUrlMatcher.isLoginPage(page.effectiveUrl)) throw _loginRequired;
    if (page.statusCode == 999) {
      throw const MediaExtractionException('CHALLENGE_FAILED', 'LinkedIn refused the page request (HTTP 999); trying another method.');
    }
    if (page.statusCode == 404 || page.statusCode == 410) {
      // The 404 body is not read, so there is no explicit "removed" text to
      // trust; LinkedIn also 404s clients it dislikes. Not terminal.
      throw const MediaExtractionException(
        'CHALLENGE_FAILED',
        'LinkedIn answered "not found" for this post; it may be removed or hidden from anonymous visitors; trying another method.',
      );
    }
    NativeHttpClient.throwForStatus(page.statusCode, 'LinkedIn');

    final post = _parser.parse(page.body, postId: ref.postId, requestedPath: ref.fetchUrl.path);
    if (post == null) {
      if (page.body.toLowerCase().contains('authwall')) throw _authwall;
      throw const MediaExtractionException('NO_MEDIA_FOUND', 'This LinkedIn post has no video.');
    }

    final built = await _formats(post);
    if (built.formats.isEmpty) {
      throw built.drmDetected
          ? const MediaExtractionException('DRM_PROTECTED', 'This LinkedIn video is DRM protected. MiDa does not bypass DRM.')
          : const MediaExtractionException('NO_MEDIA_FOUND', 'LinkedIn listed no playable video for this post.');
    }

    return MediaInfo(
      id: ref.postId ?? _slugId(ref.fetchUrl),
      title: post.title,
      author: post.author,
      thumbnailUrl: post.thumbnailUrl,
      formats: built.formats,
      sourceUrl: url,
      requestHeaders: _downloadHeaders,
    );
  }

  Future<({List<MediaFormat> formats, bool drmDetected})> _formats(LinkedInPost post) async {
    final formats = <MediaFormat>[];
    var drmDetected = false;

    final sources = post.sources.where((s) => _http.mediaUrlAllowed(s.url)).toList();
    for (final source in sources.where((s) => s.container == 'mp4')) {
      formats.add(MediaFormat(
        id: 'mp4-${formats.length + 1}',
        url: source.url,
        container: 'mp4',
        bitrate: source.bitrate ?? 0,
        hasVideo: true,
        hasAudio: true,
        capabilitiesUnknown: true,
      ));
    }
    for (final source in sources.where((s) => s.container == 'm3u8')) {
      final expanded = await _expander.expandFormats(
        source.url,
        'm3u8',
        extraHeaders: _downloadHeaders,
        bitrate: source.bitrate,
      );
      drmDetected = drmDetected || expanded.drmDetected;
      formats.addAll(_http.filterAllowedFormats(expanded.formats));
    }
    return (formats: formats, drmDetected: drmDetected);
  }

  static String _slugId(Uri fetchUrl) {
    // The raw path (still percent-encoded): `pathSegments` throws on `%FF`.
    final last = fetchUrl.path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? 'post';
    return last.length > 80 ? last.substring(0, 80) : last;
  }
}
