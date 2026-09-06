import 'dart:convert';
import 'dart:io';

import '../media_extractor.dart';
import '../media_models.dart';
import 'niconico_dmc_session_client.dart';
import 'niconico_watch_data_parser.dart';

/// Native Niconico extractor for `nicovideo.jp/watch/<id>` URLs.
///
/// Live status (`docs/plan-phase5-coverage.md` Lane D report): the
/// current site (verified 2026-09-05) no longer server-renders the
/// legacy `js-initial-watch-data` this parses - see
/// `NiconicoWatchDataParser`'s doc. That page shape produces
/// `PARSE_ERROR`, which `ExtractorRegistry` treats as fall-through
/// eligible (`BrowserCaptureExtractor`, which can execute the SPA's own
/// JS and observe whatever request it actually makes). This extractor
/// still implements the full legacy contract end to end (page parse ->
/// DMC session start -> stream URL) so it works the moment either an
/// older cached page shape is hit, or a future patch updates
/// [NiconicoWatchDataParser] for the new site's actual data source.
class NiconicoExtractor implements MediaExtractor {
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  static final _videoIdPathPattern = RegExp(r'^/watch/([a-z]{2}\d+)');

  /// Matches Niconico's own real 404 page's embedded (HTML-entity-encoded)
  /// loader state - see [_fetchPage]'s corroboration doc.
  static final _niconicoNotFoundMarkerPattern = RegExp(r'code&quot;:&quot;NOT_FOUND&quot;');

  final HttpClient Function() _httpClientFactory;
  final NiconicoWatchDataParser _pageParser;
  final NiconicoDmcSessionClient _sessionClient;

  /// Rewrites the watch-page request URL. Identity by default; tests
  /// point it at a local `HttpServer`.
  final Uri Function(Uri url) _pageRequestUrlBuilder;

  NiconicoExtractor({
    HttpClient Function()? httpClientFactory,
    NiconicoWatchDataParser? pageParser,
    NiconicoDmcSessionClient? sessionClient,
    Uri Function(Uri url)? pageRequestUrlBuilder,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _pageParser = pageParser ?? const NiconicoWatchDataParser(),
        _sessionClient = sessionClient ?? NiconicoDmcSessionClient(httpClientFactory: httpClientFactory),
        _pageRequestUrlBuilder = pageRequestUrlBuilder ?? _identity;

  static Uri _identity(Uri url) => url;

  static bool _hostMatches(String host, String domain) => host == domain || host.endsWith('.$domain');

  String? _videoIdFor(Uri url) {
    if (!_hostMatches(url.host.toLowerCase(), 'nicovideo.jp')) return null;
    return _videoIdPathPattern.firstMatch(url.path)?.group(1);
  }

  @override
  bool canHandle(Uri url) => _videoIdFor(url) != null;

  @override
  Future<MediaInfo> extract(Uri url) async {
    if (_videoIdFor(url) == null) {
      throw MediaExtractionException('UNSUPPORTED_URL', 'Not a recognizable Niconico video URL: $url');
    }

    final html = await _fetchPage(url);
    final watchData = _pageParser.tryParse(html);
    if (watchData == null) {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'MiDa could not find video data on this Niconico page (the site '
            'may have changed how it serves this).',
      );
    }

    final session = await _sessionClient.startSession(watchData.sessionApi);
    final contentUri = session.contentUri;

    return MediaInfo(
      id: watchData.id,
      title: watchData.title,
      author: watchData.author,
      thumbnailUrl: watchData.thumbnailUrl,
      duration: watchData.duration,
      formats: [
        MediaFormat(
          id: 'dmc',
          url: contentUri,
          container: contentUri.contains('.m3u8') ? 'm3u8' : 'mp4',
          hasVideo: true,
          hasAudio: true,
        ),
      ],
      sourceUrl: url,
      // Referer matches the page the video actually plays on - the same
      // header the delivery CDN sees from a real browser session, per
      // docs/plan-phase6-av-pairing.md Lane N (N2/N3): only what a real
      // client sends, never a spoofed fingerprint or a solved challenge.
      requestHeaders: const {'User-Agent': _userAgent, 'Referer': 'https://www.nicovideo.jp/'},
      cookiesByDomain: session.cookiesByDomain,
    );
  }

  Future<String> _fetchPage(Uri url) async {
    final httpClient = _httpClientFactory();
    try {
      final request = await httpClient.getUrl(_pageRequestUrlBuilder(url));
      request.headers.set('User-Agent', _userAgent);
      final response = await request.close();
      final html = await response.transform(utf8.decoder).join();

      if (response.statusCode == 404) {
        // Corroborate before trusting a bare 404 as terminal: verified
        // live 2026-09-06 (`docs/plan-phase5-coverage.md` Lane D review
        // round 2, a real nonexistent `sm` id) that Niconico's own 404
        // page embeds its React-Router loader's response state inline as
        // HTML-entity-encoded JSON containing literally
        // `&quot;code&quot;:&quot;NOT_FOUND&quot;` alongside
        // `&quot;statusCode&quot;:404`. A WAF/proxy synthesizing a bare
        // 404 would not reproduce that exact embedded marker, so its
        // absence here means "some 404, not confirmed to be Niconico's
        // own" and is treated as fall-through eligible instead.
        if (_niconicoNotFoundMarkerPattern.hasMatch(html)) {
          throw const MediaExtractionException(
            'NOT_FOUND',
            'This Niconico video no longer exists or the link is wrong.',
          );
        }
        throw const MediaExtractionException(
          'CHALLENGE_FAILED',
          'Niconico returned an unrecognized 404 page for this video.',
        );
      }
      if (response.statusCode != 200) {
        throw MediaExtractionException(
          'NETWORK',
          'Niconico returned HTTP ${response.statusCode} for this page.',
        );
      }
      return html;
    } finally {
      httpClient.close(force: true);
    }
  }
}
