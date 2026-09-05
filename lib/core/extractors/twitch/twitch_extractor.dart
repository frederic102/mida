import 'dart:convert';
import 'dart:io';

import '../media_extractor.dart';
import '../media_models.dart';
import 'twitch_clip_parser.dart';
import 'twitch_gql_client.dart';
import 'twitch_page_meta_parser.dart';
import 'twitch_playlist_parser.dart';

/// Native Twitch extractor for VODs (`twitch.tv/videos/<id>`) and clips
/// (`clips.twitch.tv/<slug>`, `twitch.tv/<channel>/clip/<slug>`).
///
/// VOD flow, verified live end to end 2026-09-05
/// (`docs/plan-phase5-coverage.md` Lane D): GET the watch page for
/// SEO `og:` meta tags ([TwitchPageMetaParser], title/thumbnail/duration -
/// the GQL `video(id:)` field is anonymous-null, see that parser's doc) +
/// GQL `videoPlaybackAccessToken` ([TwitchGqlClient], the public web
/// client id `kimne78kx3ncx6brgo4mv6wki5h1ko` plus an anonymous
/// `Client-Integrity` token) + GET the resulting signed
/// `usher.ttvnw.net/vod/<id>.m3u8` master playlist
/// ([TwitchPlaylistParser]).
///
/// Clip flow ([TwitchClipParser]) is implemented against the same
/// documented public contract but was not confirmed against a live still
/// existing clip within this pass's request budget - see that parser's
/// doc comment.
class TwitchExtractor implements MediaExtractor {
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  static final _vodPathPattern = RegExp(r'^/videos/(\d+)');
  static final _channelClipPathPattern = RegExp(r'^/[^/]+/clip/([A-Za-z0-9_-]+)');
  static final _clipsHostSlugPattern = RegExp(r'^/([A-Za-z0-9_-]+)');

  final HttpClient Function() _httpClientFactory;
  final TwitchGqlClient _gqlClient;
  final TwitchPlaylistParser _playlistParser;
  final TwitchPageMetaParser _pageMetaParser;
  final TwitchClipParser _clipParser;

  /// Rewrites the VOD watch-page URL each request is sent to. Identity by
  /// default; tests point it at a local `HttpServer`.
  final Uri Function(Uri url) _pageRequestUrlBuilder;

  /// Rewrites the usher master-playlist URL each request is sent to.
  /// Identity by default; tests point it at a local `HttpServer`.
  final Uri Function(Uri url) _usherRequestUrlBuilder;

  TwitchExtractor({
    HttpClient Function()? httpClientFactory,
    TwitchGqlClient? gqlClient,
    TwitchPlaylistParser? playlistParser,
    TwitchPageMetaParser? pageMetaParser,
    TwitchClipParser? clipParser,
    Uri Function(Uri url)? pageRequestUrlBuilder,
    Uri Function(Uri url)? usherRequestUrlBuilder,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _gqlClient = gqlClient ?? TwitchGqlClient(),
        _playlistParser = playlistParser ?? const TwitchPlaylistParser(),
        _pageMetaParser = pageMetaParser ?? const TwitchPageMetaParser(),
        _clipParser = clipParser ?? const TwitchClipParser(),
        _pageRequestUrlBuilder = pageRequestUrlBuilder ?? _identity,
        _usherRequestUrlBuilder = usherRequestUrlBuilder ?? _identity;

  static Uri _identity(Uri url) => url;

  static bool _hostMatches(String host, String domain) => host == domain || host.endsWith('.$domain');

  @override
  bool canHandle(Uri url) {
    final host = url.host.toLowerCase();
    // `clips.twitch.tv` is itself a subdomain of `twitch.tv`, so it is
    // checked first: the general `twitch.tv` branch below only knows the
    // VOD/channel-clip path shapes, not the clips host's own `/<slug>`
    // shape, and would otherwise shadow it.
    if (_hostMatches(host, 'clips.twitch.tv')) {
      return _clipsHostSlugPattern.hasMatch(url.path);
    }
    if (_hostMatches(host, 'twitch.tv')) {
      return _vodPathPattern.hasMatch(url.path) || _channelClipPathPattern.hasMatch(url.path);
    }
    return false;
  }

  @override
  Future<MediaInfo> extract(Uri url) async {
    final host = url.host.toLowerCase();

    if (_hostMatches(host, 'clips.twitch.tv')) {
      final slugMatch = _clipsHostSlugPattern.firstMatch(url.path);
      if (slugMatch != null) return _extractClip(slugMatch.group(1)!, url);
    } else if (_hostMatches(host, 'twitch.tv')) {
      final vodMatch = _vodPathPattern.firstMatch(url.path);
      if (vodMatch != null) return _extractVod(vodMatch.group(1)!, url);

      final clipMatch = _channelClipPathPattern.firstMatch(url.path);
      if (clipMatch != null) return _extractClip(clipMatch.group(1)!, url);
    }

    throw MediaExtractionException('UNSUPPORTED_URL', 'Not a recognizable Twitch URL: $url');
  }

  Future<MediaInfo> _extractVod(String vodId, Uri sourceUrl) async {
    final meta = await _fetchPageMeta(sourceUrl);

    final data = await _gqlClient.query(
      'query(\$id: ID!){ videoPlaybackAccessToken(id: \$id, params: {platform: "web", '
          'playerBackend: "mediaplayer", playerType: "site"}) { value signature } }',
      {'id': vodId},
    );
    // CHALLENGE_FAILED (fall-through eligible), not the terminal
    // NOT_FOUND an earlier version of this extractor used: a null
    // videoPlaybackAccessToken is not live-confirmed to mean "this VOD
    // does not exist" specifically - it is the same anonymous-GQL field
    // that can also come back null for reasons this extractor cannot
    // distinguish from here (a stale/rejected Client-Integrity token,
    // subscriber-only content, geo-gating), several of which a real
    // browser session (BrowserCaptureExtractor) has a genuine chance at
    // that this technique does not.
    final token = data['videoPlaybackAccessToken'];
    if (token is! Map) {
      throw const MediaExtractionException(
        'CHALLENGE_FAILED',
        'Twitch did not return a playback token for this VOD (it may not '
            'exist, be subscriber-only, or this request was blocked).',
      );
    }
    final value = token['value'] as String?;
    final signature = token['signature'] as String?;
    if (value == null || signature == null) {
      throw const MediaExtractionException(
        'CHALLENGE_FAILED',
        'Twitch returned an incomplete playback token for this VOD.',
      );
    }

    final usherUrl = Uri.parse('https://usher.ttvnw.net/vod/$vodId.m3u8').replace(queryParameters: {
      'nauth': value,
      'nauthsig': signature,
      'allow_source': 'true',
      'player': 'twitchweb',
      'playlist_include_framerates': 'true',
      'supported_codecs': 'avc1',
    });
    final playlistText = await _fetchUsherPlaylist(usherUrl);
    final formats = _playlistParser.parse(playlistText);

    return MediaInfo(
      id: vodId,
      title: meta.title ?? 'Untitled',
      author: meta.author,
      thumbnailUrl: meta.thumbnailUrl,
      duration: meta.duration,
      formats: formats,
      sourceUrl: sourceUrl,
      requestHeaders: const {'User-Agent': _userAgent},
    );
  }

  Future<MediaInfo> _extractClip(String slug, Uri sourceUrl) async {
    final data = await _gqlClient.query(
      'query(\$slug: ID!){ clip(slug: \$slug) { title durationSeconds thumbnailURL '
          'broadcaster { displayName } videoQualities { quality frameRate sourceURL } '
          'playbackAccessToken(params: {platform: "web", playerType: "clipshare-client"}) '
          '{ value signature } } }',
      {'slug': slug},
    );
    return _clipParser.parse(data, sourceUrl: sourceUrl, requestHeaders: const {'User-Agent': _userAgent});
  }

  Future<TwitchPageMeta> _fetchPageMeta(Uri sourceUrl) async {
    final httpClient = _httpClientFactory();
    try {
      final request = await httpClient.getUrl(_pageRequestUrlBuilder(sourceUrl));
      request.headers.set('User-Agent', _userAgent);
      final response = await request.close();
      final html = await response.transform(utf8.decoder).join();
      if (response.statusCode == 404) {
        throw const MediaExtractionException(
          'NOT_FOUND',
          'This Twitch VOD no longer exists or the link is wrong.',
        );
      }
      if (response.statusCode != 200) {
        throw MediaExtractionException(
          'NETWORK',
          'Twitch returned HTTP ${response.statusCode} for this page.',
        );
      }
      return _pageMetaParser.parse(html);
    } finally {
      httpClient.close(force: true);
    }
  }

  Future<String> _fetchUsherPlaylist(Uri usherUrl) async {
    final httpClient = _httpClientFactory();
    try {
      final request = await httpClient.getUrl(_usherRequestUrlBuilder(usherUrl));
      request.headers.set('User-Agent', _userAgent);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw MediaExtractionException(
          'NETWORK',
          'Twitch returned HTTP ${response.statusCode} for this video\'s playlist.',
        );
      }
      return body;
    } finally {
      httpClient.close(force: true);
    }
  }
}

typedef TwitchPageMeta = ({String? title, String? author, String? thumbnailUrl, Duration? duration});
