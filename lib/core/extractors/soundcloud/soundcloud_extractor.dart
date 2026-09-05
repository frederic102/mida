import 'dart:convert';
import 'dart:io';

import '../media_extractor.dart';
import '../media_models.dart';
import 'soundcloud_client_id_resolver.dart';
import 'soundcloud_hydration_parser.dart';

/// Native SoundCloud extractor. Fetches a track page, reads its
/// server-rendered `window.__sc_hydration` payload
/// ([SoundCloudHydrationParser]) for metadata + the list of
/// `media.transcodings[]` the track offers, resolves the web app's
/// `client_id` from the page's own JS bundles
/// ([SoundCloudClientIdResolver]), then GETs each transcoding URL with
/// `?client_id=` appended - which itself returns `{"url": "<signed CDN
/// url>"}`, the actual playable stream.
///
/// Live status (`docs/plan-phase5-coverage.md` Lane D report): track-page
/// hydration parsing was confirmed against a real fetched page's
/// `__sc_hydration` shape; the client_id step was not confirmed live
/// within this pass's budget (see [SoundCloudClientIdResolver]'s doc). A
/// track this can't resolve a client_id for surfaces `PARSE_ERROR`, which
/// `ExtractorRegistry` falls through on to `BrowserCaptureExtractor`.
class SoundCloudExtractor implements MediaExtractor {
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  static final _hydrationPattern = RegExp(
    r'window\.__sc_hydration\s*=\s*(\[.*?\]);',
    dotAll: true,
  );

  final HttpClient Function() _httpClientFactory;
  final SoundCloudHydrationParser _hydrationParser;
  final SoundCloudClientIdResolver _clientIdResolver;

  /// Rewrites the track page URL each request is sent to. Identity by
  /// default; tests point it at a local `HttpServer`.
  final Uri Function(Uri url) _pageRequestUrlBuilder;

  /// Rewrites each transcoding-resolution URL (`<transcoding.url>
  /// ?client_id=...`) request. Identity by default; tests point it at a
  /// local `HttpServer`.
  final Uri Function(Uri url) _transcodingRequestUrlBuilder;

  SoundCloudExtractor({
    HttpClient Function()? httpClientFactory,
    SoundCloudHydrationParser? hydrationParser,
    SoundCloudClientIdResolver? clientIdResolver,
    Uri Function(Uri url)? pageRequestUrlBuilder,
    Uri Function(Uri url)? transcodingRequestUrlBuilder,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _hydrationParser = hydrationParser ?? const SoundCloudHydrationParser(),
        _clientIdResolver =
            clientIdResolver ?? SoundCloudClientIdResolver(httpClientFactory: httpClientFactory),
        _pageRequestUrlBuilder = pageRequestUrlBuilder ?? _identity,
        _transcodingRequestUrlBuilder = transcodingRequestUrlBuilder ?? _identity;

  static Uri _identity(Uri url) => url;

  static bool _hostMatches(String host, String domain) => host == domain || host.endsWith('.$domain');

  /// Matches `soundcloud.com/<user>/<track-slug>` - two non-empty path
  /// segments, neither a reserved top-level SoundCloud route (`/search`,
  /// `/you`, `/upload`, `/discover`, `/charts` all have exactly two
  /// segments in some sub-paths too, but this is a cheap best-effort
  /// filter; SoundCloud has no numeric-id URL shape to key off instead).
  static final _trackPathPattern = RegExp(r'^/([^/]+)/([^/]+)/?$');
  static const _reservedFirstSegments = {
    'search', 'you', 'upload', 'discover', 'charts', 'stations', 'stream', 'people', 'pages', 'tags', //
  };

  @override
  bool canHandle(Uri url) {
    final host = url.host.toLowerCase();
    if (!_hostMatches(host, 'soundcloud.com')) return false;
    final match = _trackPathPattern.firstMatch(url.path);
    if (match == null) return false;
    return !_reservedFirstSegments.contains(match.group(1)!.toLowerCase());
  }

  @override
  Future<MediaInfo> extract(Uri url) async {
    if (!canHandle(url)) {
      throw MediaExtractionException('UNSUPPORTED_URL', 'Not a recognizable SoundCloud track URL: $url');
    }

    final html = await _fetchPageHtml(url);
    final hydrationMatch = _hydrationPattern.firstMatch(html);
    if (hydrationMatch == null) {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'MiDa could not find track data on this SoundCloud page.',
      );
    }

    final List<dynamic> hydration;
    try {
      hydration = jsonDecode(hydrationMatch.group(1)!) as List<dynamic>;
    } on FormatException {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'MiDa could not read this SoundCloud page\'s track data.',
      );
    }
    final trackInfo = _hydrationParser.parse(hydration);

    final clientId = await _clientIdResolver.resolve(html);

    final formats = <MediaFormat>[];
    for (var i = 0; i < trackInfo.transcodings.length; i++) {
      final transcoding = trackInfo.transcodings[i];
      final resolvedUrl = await _resolveTranscoding(transcoding.url, clientId);
      if (resolvedUrl == null) continue;
      formats.add(MediaFormat(
        id: '$i',
        url: resolvedUrl,
        container: transcoding.isHls ? 'm3u8' : (transcoding.mimeType?.contains('mp4') ?? false ? 'm4a' : 'mp3'),
        hasVideo: false,
        hasAudio: true,
      ));
    }

    if (formats.isEmpty) {
      throw const MediaExtractionException(
        'UNSUPPORTED_MEDIA',
        'SoundCloud did not return a playable stream for any rendition of this track.',
      );
    }

    return MediaInfo(
      id: trackInfo.id,
      title: trackInfo.title,
      author: trackInfo.author,
      thumbnailUrl: trackInfo.artworkUrl,
      duration: trackInfo.duration,
      formats: formats,
      sourceUrl: url,
      requestHeaders: const {'User-Agent': _userAgent},
    );
  }

  Future<String> _fetchPageHtml(Uri url) async {
    final httpClient = _httpClientFactory();
    try {
      final request = await httpClient.getUrl(_pageRequestUrlBuilder(url));
      request.headers.set('User-Agent', _userAgent);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode == 404) {
        throw const MediaExtractionException(
          'NOT_FOUND',
          'This SoundCloud track no longer exists or the link is wrong.',
        );
      }
      if (response.statusCode != 200) {
        throw MediaExtractionException(
          'NETWORK',
          'SoundCloud returned HTTP ${response.statusCode} for this page.',
        );
      }
      return body;
    } finally {
      httpClient.close(force: true);
    }
  }

  /// GETs a transcoding's own URL with `?client_id=` appended, which
  /// answers with `{"url": "<signed CDN url>"}` rather than the stream
  /// itself - a second indirection SoundCloud's API uses for every
  /// rendition. Returns `null` (skip this rendition, do not fail the
  /// whole extraction) on a non-200 or unparsable body, since one bad
  /// transcoding should not sink every other rendition the track has.
  Future<String?> _resolveTranscoding(String transcodingUrl, String clientId) async {
    final requestUrl = Uri.parse(transcodingUrl).replace(queryParameters: {
      ...Uri.parse(transcodingUrl).queryParameters,
      'client_id': clientId,
    });
    final httpClient = _httpClientFactory();
    try {
      final request = await httpClient.getUrl(_transcodingRequestUrlBuilder(requestUrl));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) return null;
      final json = jsonDecode(body);
      return json is Map ? json['url'] as String? : null;
    } on FormatException {
      return null;
    } finally {
      httpClient.close(force: true);
    }
  }
}
