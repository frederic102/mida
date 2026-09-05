import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../utils/url_parser.dart';
import '../media_extractor.dart';
import '../media_models.dart';
import 'innertube_clients.dart';
import 'player_response_parser.dart';
import 'youtube_session.dart';

/// Native YouTube extractor. Follows the request sequence
/// validated in `docs/spikes/youtube_visionos_spike.dart` (2026-09-05):
/// watch page for cookies/visitorData, then `/youtubei/v1/player` with the
/// visionOS client. Falls back to a fresh session retry, then the android
/// client, per `docs/plan-native-extractor.md`.
class YoutubeExtractor implements MediaExtractor {
  final HttpClient Function() _httpClientFactory;
  final PlayerResponseParser _parser;

  YoutubeExtractor({
    HttpClient Function()? httpClientFactory,
    PlayerResponseParser? parser,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _parser = parser ?? const PlayerResponseParser();

  @override
  bool canHandle(Uri url) => UrlParser.extractYouTubeVideoId(url.toString()) != null;

  @override
  Future<MediaInfo> extract(Uri url) async {
    final videoId = UrlParser.extractYouTubeVideoId(url.toString());
    if (videoId == null) {
      throw ArgumentError('Not a recognizable YouTube URL: $url');
    }
    return extractById(videoId, sourceUrl: url);
  }

  Future<MediaInfo> extractById(String videoId, {Uri? sourceUrl}) async {
    final effectiveSourceUrl = sourceUrl ?? Uri.parse('https://www.youtube.com/watch?v=$videoId');
    // visionOS twice (fresh session retry covers most bot-check flukes),
    // then android as a last resort for videos visionOS cannot play at all.
    return attemptWithFallback([
      () => _tryClient(videoId, visionosClient, effectiveSourceUrl),
      () => _tryClient(videoId, visionosClient, effectiveSourceUrl),
      () => _tryClient(videoId, androidClient, effectiveSourceUrl),
    ]);
  }

  /// Runs [attempts] in order, moving on to the next one for any failure
  /// that plausibly means "this attempt didn't work" rather than "the
  /// program is broken": a bad playability status, a parse error, or a
  /// transient network hiccup (DNS/connection failure, timeout, or a
  /// malformed/unexpected response body). A visionOS network blip must
  /// still fall through to the retry and the android attempt, not abort
  /// the whole extraction.
  ///
  /// Exposed (not private) so this fallback behavior is unit-testable
  /// without needing to fake `dart:io`'s `HttpClient`. Not part of the
  /// class's intended public API otherwise; callers should use
  /// [extractById]/[extract].
  Future<MediaInfo> attemptWithFallback(List<Future<MediaInfo> Function()> attempts) async {
    MediaExtractionException? lastFailure;
    for (final attempt in attempts) {
      try {
        return await attempt();
      } on MediaExtractionException catch (e) {
        lastFailure = e;
      } on SocketException catch (e) {
        // 'NETWORK' (not 'NETWORK_ERROR'): aligned with
        // `ExtractorRegistry._platformFallThroughStatuses`, so a network
        // blip here falls through to Generic/BrowserCapture the same way
        // every other platform extractor's network failures do.
        lastFailure = MediaExtractionException('NETWORK', e.message);
      } on TimeoutException catch (e) {
        lastFailure = MediaExtractionException('NETWORK', e.toString());
      } on FormatException catch (e) {
        lastFailure = MediaExtractionException('PARSE_ERROR', e.message);
      } on TypeError catch (e) {
        lastFailure = MediaExtractionException('PARSE_ERROR', e.toString());
      }
    }
    throw lastFailure ??
        const MediaExtractionException('UNKNOWN', 'All InnerTube clients failed with no reported reason');
  }

  Future<MediaInfo> _tryClient(String videoId, InnertubeClient client, Uri sourceUrl) async {
    final httpClient = _httpClientFactory();
    try {
      final session = YoutubeSession(httpClient: httpClient);
      final sessionData = await session.create(videoId, userAgent: client.userAgent);

      final body = jsonEncode({
        'context': {'client': client.buildClientContext(visitorData: sessionData.visitorData)},
        'videoId': videoId,
        'contentCheckOk': true,
        'racyCheckOk': true,
        'playbackContext': {
          'contentPlaybackContext': {'html5Preference': 'HTML5_PREF_WANTS'},
        },
      });

      final request = await httpClient.postUrl(
        Uri.parse('https://www.youtube.com/youtubei/v1/player?prettyPrint=false'),
      );
      request.headers.set('Content-Type', 'application/json');
      request.headers.set('User-Agent', client.userAgent);
      request.headers.set('X-YouTube-Client-Name', client.xYoutubeClientName);
      request.headers.set('X-YouTube-Client-Version', client.clientVersion);
      request.headers.set('Origin', 'https://www.youtube.com');
      request.headers.set('Accept-Language', 'en-us,en;q=0.5');
      request.headers.set('Cookie', sessionData.cookieHeader);
      if (sessionData.visitorData != null) {
        request.headers.set('X-Goog-Visitor-Id', sessionData.visitorData!);
      }
      request.write(body);

      final response = await request.close();
      final raw = await response.transform(utf8.decoder).join();
      final json = jsonDecode(raw) as Map<String, dynamic>;

      return _parser.parse(
        json,
        sourceUrl: sourceUrl,
        requestHeaders: {'User-Agent': client.userAgent},
      );
    } finally {
      httpClient.close(force: true);
    }
  }
}
