import 'dart:convert';
import 'dart:io';

import '../media_extractor.dart';
import '../media_models.dart';
import 'reddit_dash_manifest_parser.dart';
import 'reddit_post_parser.dart';

/// Native Reddit extractor for `v.redd.it` video posts
/// (`reddit.com/r/<sub>/comments/<id>/...`). Calls Reddit's public,
/// unauthenticated `.json` listing endpoint every third-party Reddit
/// client reads, then resolves the post's DASH manifest
/// (`v.redd.it/<id>/DASHPlaylist.mpd`) into separate video-only/audio-only
/// [MediaFormat]s.
///
/// Not live-verified end to end (`docs/plan-phase5-coverage.md` Lane D
/// report): this sandbox's outbound network hit Reddit's Akamai-style
/// anti-bot challenge on every technique tried (`.json` API with a
/// browser User-Agent, with a Reddit-compliant custom User-Agent, and the
/// HTML page itself), consistently returning the same JS-challenge shell
/// regardless of headers - a pattern consistent with a TLS-fingerprint
/// based block that would reproduce with `dart:io`'s `HttpClient` too,
/// not just curl. The request/parse contract implemented here matches the
/// long-stable, widely-documented public API every Reddit downloader
/// tool uses; needs live re-verification from a non-flagged network.
class RedditExtractor implements MediaExtractor {
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  /// Matches `/r/<sub>/comments/<id>/...` on a recognized Reddit host.
  /// Group 1 is the post id.
  static final _commentsPathPattern = RegExp(r'^/r/[^/]+/comments/([a-z0-9]+)');

  final HttpClient Function() _httpClientFactory;
  final RedditPostParser _postParser;
  final RedditDashManifestParser _dashParser;

  /// Rewrites the `.json` listing URL each request is sent to. Identity
  /// by default; tests point it at a local `HttpServer`.
  final Uri Function(Uri url) _listingRequestUrlBuilder;

  /// Rewrites the DASH manifest URL each request is sent to. Identity by
  /// default; tests point it at a local `HttpServer`.
  final Uri Function(Uri url) _dashRequestUrlBuilder;

  RedditExtractor({
    HttpClient Function()? httpClientFactory,
    RedditPostParser? postParser,
    RedditDashManifestParser? dashParser,
    Uri Function(Uri url)? listingRequestUrlBuilder,
    Uri Function(Uri url)? dashRequestUrlBuilder,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _postParser = postParser ?? const RedditPostParser(),
        _dashParser = dashParser ?? const RedditDashManifestParser(),
        _listingRequestUrlBuilder = listingRequestUrlBuilder ?? _identity,
        _dashRequestUrlBuilder = dashRequestUrlBuilder ?? _identity;

  static Uri _identity(Uri url) => url;

  static bool _hostMatches(String host, String domain) => host == domain || host.endsWith('.$domain');

  @override
  bool canHandle(Uri url) {
    final host = url.host.toLowerCase();
    if (!_hostMatches(host, 'reddit.com')) return false;
    return _commentsPathPattern.hasMatch(url.path);
  }

  @override
  Future<MediaInfo> extract(Uri url) async {
    final match = _commentsPathPattern.firstMatch(url.path);
    if (match == null) {
      throw MediaExtractionException('UNSUPPORTED_URL', 'Not a recognizable Reddit post URL: $url');
    }

    final listingUrl = url.replace(
      path: '${url.path.endsWith('/') ? url.path : '${url.path}/'}.json',
      queryParameters: {'raw_json': '1'},
    );
    final json = await _fetchJson(listingUrl);
    final videoInfo = _postParser.parse(json);

    final dashUrl = videoInfo.dashUrl;
    if (dashUrl == null) {
      throw const MediaExtractionException(
        'UNSUPPORTED_MEDIA',
        'This Reddit video has no DASH manifest to read renditions from.',
      );
    }

    final manifestUri = Uri.parse(dashUrl);
    final baseUrl = dashUrl.substring(0, dashUrl.lastIndexOf('/') + 1);
    final manifestXml = await _fetchText(_dashRequestUrlBuilder(manifestUri), allowNotFound: false);
    final formats = _dashParser.parse(manifestXml, baseUrl: baseUrl);

    return MediaInfo(
      id: videoInfo.id,
      title: videoInfo.title,
      author: videoInfo.author,
      thumbnailUrl: videoInfo.thumbnailUrl,
      duration: videoInfo.duration,
      formats: formats,
      sourceUrl: url,
      requestHeaders: const {'User-Agent': _userAgent},
    );
  }

  Future<dynamic> _fetchJson(Uri listingUrl) async {
    final raw = await _fetchText(_listingRequestUrlBuilder(listingUrl), allowNotFound: true);
    try {
      return jsonDecode(raw);
    } on FormatException {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'Reddit returned a response MiDa could not read as JSON.',
      );
    }
  }

  /// [allowNotFound] gates whether a bare HTTP 404 on [requestUrl] can
  /// ever become the terminal `NOT_FOUND` at all - only the `.json`
  /// listing fetch passes `true`, and even then only after a body-shape
  /// corroboration below. The DASH manifest fetch passes `false`: an
  /// unreachable manifest for a post whose listing already resolved is
  /// not an expected "this does not exist" case, so any 404 there falls
  /// into the same uncorroborated-404 branch as a listing 404 with no
  /// JSON body - `CHALLENGE_FAILED` (fall-through eligible), never
  /// terminal.
  Future<String> _fetchText(Uri requestUrl, {required bool allowNotFound}) async {
    final httpClient = _httpClientFactory();
    try {
      final request = await httpClient.getUrl(requestUrl);
      request.headers.set('User-Agent', _userAgent);
      final response = await request.close();
      final contentType = response.headers.contentType?.mimeType;
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode == 404) {
        // Corroborate before trusting a bare 404 as terminal: Reddit's
        // own `.json` API answers a genuinely-gone post with a JSON body
        // (this pass could not capture the exact live shape - every
        // request from this network hit the anti-bot challenge first,
        // see the class doc - but the challenge shell itself is
        // consistently `text/html`, confirmed across 3 hosts). Requiring
        // a JSON content-type at minimum means a WAF/proxy synthesizing
        // a 404 with its own HTML page is never mistaken for Reddit's
        // own "not found" answer.
        if (allowNotFound && (contentType?.contains('json') ?? false)) {
          throw const MediaExtractionException(
            'NOT_FOUND',
            'This Reddit post or video no longer exists.',
          );
        }
        throw const MediaExtractionException(
          'CHALLENGE_FAILED',
          'Reddit returned an unrecognized 404 response for this request.',
        );
      }
      if (response.statusCode == 403) {
        throw const MediaExtractionException(
          'CHALLENGE_FAILED',
          'Reddit blocked this request with an anti-bot challenge.',
        );
      }
      if (response.statusCode == 429) {
        throw const MediaExtractionException(
          'RATE_LIMITED',
          'Reddit is throttling this request. Wait a moment and try again.',
        );
      }
      if (response.statusCode != 200) {
        throw MediaExtractionException(
          'NETWORK',
          'Reddit returned HTTP ${response.statusCode} for this request.',
        );
      }
      return body;
    } finally {
      httpClient.close(force: true);
    }
  }
}
