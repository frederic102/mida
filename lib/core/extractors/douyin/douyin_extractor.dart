import 'dart:convert';
import 'dart:io';

import '../media_extractor.dart';
import '../media_models.dart';
import 'douyin_render_data_parser.dart';

/// Native Douyin extractor for `douyin.com/video/<id>` URLs. Fetches the
/// video page (with a cookie bootstrap request first, since Douyin's edge
/// otherwise serves its anti-bot interstitial on a cold connection more
/// often) and reads the page's `RENDER_DATA` script tag
/// ([DouyinRenderDataParser]).
///
/// Not live-verified (`docs/plan-phase5-coverage.md` Lane D report):
/// Douyin's anti-bot is a custom JS-VM bytecode challenge
/// (`_$jsvmprt`-prefixed obfuscated interpreter observed live
/// 2026-09-05), which by design cannot be solved without executing real
/// JS - this extractor detects that shell (no `RENDER_DATA` tag, but the
/// `_$jsvmprt` marker present) and throws `CHALLENGE_FAILED` so
/// `ExtractorRegistry` falls through to `BrowserCaptureExtractor`, a real
/// Chromium instance that can actually run the challenge - which is the
/// architecturally correct outcome for this specific anti-bot design, not
/// a gap in this extractor.
class DouyinExtractor implements MediaExtractor {
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  static final _renderDataPattern = RegExp(
    r'<script id="RENDER_DATA" type="application/json">([^<]*)</script>',
  );
  static final _videoIdPathPattern = RegExp(r'^/video/(\d+)');
  static const _jsVmChallengeMarker = r'_$jsvmprt';

  final HttpClient Function() _httpClientFactory;
  final DouyinRenderDataParser _parser;

  /// Rewrites the cookie-bootstrap (site root) request URL. Identity by
  /// default; tests point it at a local `HttpServer`.
  final Uri Function(Uri url) _bootstrapRequestUrlBuilder;

  /// Rewrites the video-page request URL. Identity by default; tests
  /// point it at a local `HttpServer`.
  final Uri Function(Uri url) _pageRequestUrlBuilder;

  DouyinExtractor({
    HttpClient Function()? httpClientFactory,
    DouyinRenderDataParser? parser,
    Uri Function(Uri url)? bootstrapRequestUrlBuilder,
    Uri Function(Uri url)? pageRequestUrlBuilder,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _parser = parser ?? const DouyinRenderDataParser(),
        _bootstrapRequestUrlBuilder = bootstrapRequestUrlBuilder ?? _identity,
        _pageRequestUrlBuilder = pageRequestUrlBuilder ?? _identity;

  static Uri _identity(Uri url) => url;

  static bool _hostMatches(String host, String domain) => host == domain || host.endsWith('.$domain');

  String? _videoIdFor(Uri url) {
    if (!_hostMatches(url.host.toLowerCase(), 'douyin.com')) return null;
    return _videoIdPathPattern.firstMatch(url.path)?.group(1);
  }

  @override
  bool canHandle(Uri url) => _videoIdFor(url) != null;

  @override
  Future<MediaInfo> extract(Uri url) async {
    final videoId = _videoIdFor(url);
    if (videoId == null) {
      throw MediaExtractionException('UNSUPPORTED_URL', 'Not a recognizable Douyin video URL: $url');
    }

    final httpClient = _httpClientFactory();
    try {
      final cookieJar = await _bootstrapCookies(httpClient, url);
      final html = await _fetchPage(httpClient, url, cookieJar);

      final match = _renderDataPattern.firstMatch(html);
      if (match == null) {
        if (html.contains(_jsVmChallengeMarker)) {
          throw const MediaExtractionException(
            'CHALLENGE_FAILED',
            'Douyin served its anti-bot JS challenge instead of the video page.',
          );
        }
        throw const MediaExtractionException(
          'PARSE_ERROR',
          'MiDa could not find video data on this Douyin page.',
        );
      }

      final Map<String, dynamic> renderData;
      try {
        final decoded = Uri.decodeComponent(match.group(1)!);
        renderData = jsonDecode(decoded) as Map<String, dynamic>;
      } on FormatException {
        throw const MediaExtractionException(
          'PARSE_ERROR',
          'MiDa could not read this Douyin page\'s video data.',
        );
      }

      final requestHeaders = <String, String>{
        'User-Agent': _userAgent,
        'Referer': 'https://www.douyin.com/',
        if (cookieJar.isNotEmpty) 'Cookie': _cookieHeader(cookieJar),
      };
      return _parser.parse(renderData, sourceUrl: url, requestHeaders: requestHeaders);
    } finally {
      httpClient.close(force: true);
    }
  }

  /// A single GET to the site root, purely to collect the anonymous
  /// tracking cookies (`ttwid`, etc) Douyin's edge sets on a fresh
  /// connection - sending them back on the actual page request was
  /// observed (per third-party Douyin client behavior this technique is
  /// based on) to reduce how often the anti-bot interstitial appears
  /// compared to a cookie-less request.
  Future<Map<String, String>> _bootstrapCookies(HttpClient client, Uri sourceUrl) async {
    final cookies = <String, String>{};
    final request = await client.getUrl(_bootstrapRequestUrlBuilder(Uri.parse('https://www.douyin.com/')));
    request.headers.set('User-Agent', _userAgent);
    final response = await request.close();
    await response.drain<void>();
    for (final cookie in response.cookies) {
      cookies[cookie.name] = cookie.value;
    }
    return cookies;
  }

  Future<String> _fetchPage(HttpClient client, Uri sourceUrl, Map<String, String> cookies) async {
    final request = await client.getUrl(_pageRequestUrlBuilder(sourceUrl));
    request.headers.set('User-Agent', _userAgent);
    request.headers.set('Accept-Language', 'zh-CN,zh;q=0.9');
    if (cookies.isNotEmpty) request.headers.set('Cookie', _cookieHeader(cookies));
    final response = await request.close();
    final html = await response.transform(utf8.decoder).join();

    // No dedicated 404 -> NOT_FOUND branch: live-checked 2026-09-06
    // (`docs/plan-phase5-coverage.md` Lane D review round 2) that
    // Douyin's watch page answers HTTP 200 even for a nonexistent video
    // id (it serves the same anti-bot shell either way from this
    // network). A 404 here would only come from an intermediary
    // synthesizing one, not Douyin itself, so it is folded into the
    // generic non-200 handling below; the real "not found vs anti-bot"
    // signal is the `_$jsvmprt`/RENDER_DATA check above and
    // `DouyinRenderDataParser`'s own body-shape check, both already
    // fall-through eligible (`CHALLENGE_FAILED`/`PARSE_ERROR`).
    if (response.statusCode != 200) {
      throw MediaExtractionException(
        'NETWORK',
        'Douyin returned HTTP ${response.statusCode} for this page.',
      );
    }
    return html;
  }

  String _cookieHeader(Map<String, String> cookies) =>
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
}
