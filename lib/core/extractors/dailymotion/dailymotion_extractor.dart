import 'dart:convert';
import 'dart:io';

import '../media_extractor.dart';
import '../media_models.dart';
import 'dailymotion_metadata_parser.dart';

/// Native Dailymotion extractor. Calls the same public player-metadata
/// endpoint Dailymotion's own embed player calls
/// (`https://www.dailymotion.com/player/metadata/video/<xid>`): a single
/// unauthenticated GET, no page fetch, no cookie bootstrap needed. Verified
/// live 2026-09-05 (`docs/plan-phase5-coverage.md` Lane D): the manifest
/// URLs the endpoint returns work with a desktop User-Agent and no
/// `Referer` (adding one produced an HTTP 403 in testing, so this
/// extractor deliberately does not send one).
class DailymotionExtractor implements MediaExtractor {
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  /// Matches `dailymotion.com/video/<xid>` (with or without a trailing
  /// title slug, e.g. `/video/x9i2xqd_some-title`) and the `dai.ly/<xid>`
  /// short host. Group 1 is the id.
  static final _pathIdPattern = RegExp(r'^/video/([a-zA-Z0-9]+)');
  static final _shortIdPattern = RegExp(r'^/([a-zA-Z0-9]+)$');

  final HttpClient Function() _httpClientFactory;
  final DailymotionMetadataParser _parser;

  /// Rewrites the metadata endpoint URL each request is sent to.
  /// Identity by default; tests point it at a local `HttpServer` instead
  /// of the real `www.dailymotion.com` (same seam as `TwitterExtractor`'s
  /// `endpointBuilder`).
  final Uri Function(String xid) _endpointBuilder;

  DailymotionExtractor({
    HttpClient Function()? httpClientFactory,
    DailymotionMetadataParser? parser,
    Uri Function(String xid)? endpointBuilder,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _parser = parser ?? const DailymotionMetadataParser(),
        _endpointBuilder = endpointBuilder ?? _defaultEndpoint;

  static Uri _defaultEndpoint(String xid) =>
      Uri.parse('https://www.dailymotion.com/player/metadata/video/$xid');

  static bool _hostMatches(String host, String domain) => host == domain || host.endsWith('.$domain');

  String? _extractId(Uri url) {
    final host = url.host.toLowerCase();
    if (_hostMatches(host, 'dailymotion.com')) {
      final match = _pathIdPattern.firstMatch(url.path);
      return match?.group(1);
    }
    if (_hostMatches(host, 'dai.ly')) {
      final match = _shortIdPattern.firstMatch(url.path);
      return match?.group(1);
    }
    return null;
  }

  @override
  bool canHandle(Uri url) => _extractId(url) != null;

  @override
  Future<MediaInfo> extract(Uri url) async {
    final xid = _extractId(url);
    if (xid == null) {
      throw MediaExtractionException('UNSUPPORTED_URL', 'Not a recognizable Dailymotion URL: $url');
    }
    return extractById(xid, sourceUrl: url);
  }

  Future<MediaInfo> extractById(String xid, {Uri? sourceUrl}) async {
    final effectiveSourceUrl = sourceUrl ?? Uri.parse('https://www.dailymotion.com/video/$xid');
    final httpClient = _httpClientFactory();
    try {
      final request = await httpClient.getUrl(_endpointBuilder(xid));
      request.headers.set('User-Agent', _userAgent);
      final response = await request.close();
      final raw = await response.transform(utf8.decoder).join();

      if (response.statusCode == 429) {
        throw const MediaExtractionException(
          'RATE_LIMITED',
          'Dailymotion is throttling this request. Wait a moment and try again.',
        );
      }
      if (response.statusCode != 200) {
        throw MediaExtractionException(
          'NETWORK',
          'Dailymotion returned HTTP ${response.statusCode} for this video.',
        );
      }

      final Map<String, dynamic> json;
      try {
        json = jsonDecode(raw) as Map<String, dynamic>;
      } on FormatException {
        throw const MediaExtractionException(
          'PARSE_ERROR',
          'Dailymotion returned a response MiDa could not read as JSON.',
        );
      }

      return _parser.parse(
        json,
        sourceUrl: effectiveSourceUrl,
        requestHeaders: const {'User-Agent': _userAgent},
      );
    } finally {
      httpClient.close(force: true);
    }
  }
}
