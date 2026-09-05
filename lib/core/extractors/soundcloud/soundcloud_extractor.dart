import 'dart:convert';
import 'dart:io';

import '../media_extractor.dart';
import '../media_models.dart';
import 'soundcloud_client_id_resolver.dart';
import 'soundcloud_track_parser.dart';

/// Native SoundCloud extractor for `soundcloud.com/<user>/<track-slug>`
/// URLs.
///
/// Sequence, verified live 2026-09-05 end to end
/// (`docs/plan-phase5-coverage.md` Lane D follow-up, real track
/// `rick-astley-official/never-gonna-give-you-up` - the task's original
/// example account, `officialrickastley`, has since been renamed):
/// 1. [SoundCloudClientIdResolver] - a cached (or freshly page-scanned)
///    `client_id`.
/// 2. `GET api-v2.soundcloud.com/resolve?url=<track url>&client_id=...`
///    for the track's JSON ([SoundCloudTrackParser]).
/// 3. For each `media.transcodings[]`, `GET <transcoding.url>
///    ?client_id=...`, which itself answers `{"url": "<signed CDN url>"}`
///    - the actual playable stream - rather than the stream itself.
///
/// Superseded flow (removed): an earlier version of this extractor read
/// the track's `__sc_hydration` blob directly out of the page HTML.
/// Live-confirmed 2026-09-05 that the current site's `__sc_hydration`
/// carries only app-shell entries (`anonymousId`, `apiClient`,
/// `features`, `geoip`, `privacySettings`,
/// `statsigClientInitializeResponse`, `trackingBrowserTabId`) - the track
/// itself is fetched client-side, not server-rendered, so that path is
/// gone; this `resolve`-API flow is the standard replacement every
/// current third-party SoundCloud client uses instead.
class SoundCloudExtractor implements MediaExtractor {
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  /// Matches `soundcloud.com/<user>/<track-slug>` - two non-empty path
  /// segments, neither a reserved top-level SoundCloud route.
  static final _trackPathPattern = RegExp(r'^/([^/]+)/([^/]+)/?$');
  static const _reservedFirstSegments = {
    'search', 'you', 'upload', 'discover', 'charts', 'stations', 'stream', 'people', 'pages', 'tags', //
  };

  final HttpClient Function() _httpClientFactory;
  final SoundCloudClientIdResolver _clientIdResolver;
  final SoundCloudTrackParser _trackParser;

  /// Rewrites the `resolve` API request URL. Identity by default; tests
  /// point it at a local `HttpServer`.
  final Uri Function(Uri url) _resolveRequestUrlBuilder;

  /// Rewrites each transcoding-resolution request URL. Identity by
  /// default; tests point it at a local `HttpServer`.
  final Uri Function(Uri url) _transcodingRequestUrlBuilder;

  SoundCloudExtractor({
    HttpClient Function()? httpClientFactory,
    SoundCloudClientIdResolver? clientIdResolver,
    SoundCloudTrackParser? trackParser,
    Uri Function(Uri url)? resolveRequestUrlBuilder,
    Uri Function(Uri url)? transcodingRequestUrlBuilder,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _clientIdResolver = clientIdResolver ?? SoundCloudClientIdResolver(httpClientFactory: httpClientFactory),
        _trackParser = trackParser ?? const SoundCloudTrackParser(),
        _resolveRequestUrlBuilder = resolveRequestUrlBuilder ?? _identity,
        _transcodingRequestUrlBuilder = transcodingRequestUrlBuilder ?? _identity;

  static Uri _identity(Uri url) => url;

  static bool _hostMatches(String host, String domain) => host == domain || host.endsWith('.$domain');

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

    final clientId = await _clientIdResolver.get(url);
    final track = await _resolveTrack(url, clientId);
    final trackInfo = _trackParser.parse(track);

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
      // PARSE_ERROR (fall-through eligible), not UNSUPPORTED_MEDIA: this
      // is reached only when trackInfo.transcodings was non-empty (a
      // genuinely empty list is already terminal - SoundCloudTrackParser
      // throws its own UNSUPPORTED_MEDIA before this point) but every
      // per-transcoding resolve call still failed. That is a technique
      // failure on this second step (rejected/expired client_id, a
      // transient network error, one bad response) - not "this track has
      // no media", which was already ruled out - so it deserves another
      // technique's (BrowserCaptureExtractor's) chance, not a terminal
      // verdict.
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'MiDa could not resolve a playable stream for any rendition of this track.',
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

  Future<Map<String, dynamic>> _resolveTrack(Uri trackUrl, String clientId) async {
    final endpoint = Uri.parse('https://api-v2.soundcloud.com/resolve').replace(queryParameters: {
      'url': trackUrl.toString(),
      'client_id': clientId,
    });
    final httpClient = _httpClientFactory();
    try {
      final request = await httpClient.getUrl(_resolveRequestUrlBuilder(endpoint));
      request.headers.set('User-Agent', _userAgent);
      final response = await request.close();
      final contentType = response.headers.contentType?.mimeType;
      final raw = await response.transform(utf8.decoder).join();

      if (response.statusCode == 404) {
        // Corroborate before trusting a bare 404 as terminal: verified
        // live 2026-09-05 (`docs/plan-phase5-coverage.md` Lane D follow-up)
        // that `resolve`'s real "not found" answer is
        // `Content-Type: application/json` with body `{}` - a
        // WAF/proxy synthesizing a 404 with its own HTML page must not
        // be mistaken for that.
        if (contentType?.contains('json') ?? false) {
          throw const MediaExtractionException(
            'NOT_FOUND',
            'This SoundCloud track no longer exists or the link is wrong.',
          );
        }
        throw const MediaExtractionException(
          'CHALLENGE_FAILED',
          'SoundCloud returned an unrecognized 404 response for this track.',
        );
      }
      if (response.statusCode == 401) {
        throw const MediaExtractionException(
          'PARSE_ERROR',
          'SoundCloud rejected this request\'s client_id (it may have rotated).',
        );
      }
      if (response.statusCode != 200) {
        throw MediaExtractionException(
          'NETWORK',
          'SoundCloud returned HTTP ${response.statusCode} for this track.',
        );
      }

      try {
        return jsonDecode(raw) as Map<String, dynamic>;
      } on FormatException {
        throw const MediaExtractionException(
          'PARSE_ERROR',
          'SoundCloud returned a response MiDa could not read as JSON.',
        );
      }
    } finally {
      httpClient.close(force: true);
    }
  }

  /// GETs a transcoding's own URL with `?client_id=` appended, which
  /// answers with `{"url": "<signed CDN url>"}` rather than the stream
  /// itself. Returns `null` (skip this rendition, do not fail the whole
  /// extraction) on a non-200 or unparsable body.
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
