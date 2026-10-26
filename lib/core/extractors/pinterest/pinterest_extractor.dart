import 'dart:convert';

import '../generic/format_expander.dart';
import '../media_extractor.dart';
import '../media_models.dart';
import '../native_http/native_host_list.dart';
import '../native_http/native_http_client.dart';
import 'pinterest_pin_parser.dart';
import 'pinterest_url_matcher.dart';

/// Native Pinterest extractor for public video pins
/// (`pinterest.<tld>/pin/<id>/`, `pin.it/<code>`; see [PinterestUrlMatcher]).
///
/// Technique, per `docs/supported-sites.md` Policy: the one anonymous JSON
/// call Pinterest's own web client makes for a pin,
/// `GET https://www.pinterest.com/resource/PinResource/get/?data={"options":
/// {"field_set_key":"unauth_react_main_pin","id":"<id>"}}` plus the
/// web client's own `source_url=/pin/<id>/` and `X-Pinterest-PWS-Handler:
/// www/pin/[id].js` header, sent with a
/// normal desktop User-Agent and no cookies. A `pin.it` short link is
/// resolved through its `Location` header (every hop through `HostPolicy`,
/// HTTPS only); the target must be a Pinterest pin URL, else the link is
/// refused and the generic tier gets the URL.
///
/// Formats ([PinterestPinParser] lists `video_list`):
/// - `V_HLSV4` (else `V_HLSV3_WEB`, else `V_HLSV3_MOBILE`): an HLS master,
///   expanded by `FormatExpander` (DRM-scanned, one format per variant).
///   Only the first of those that yields formats is used, so the same
///   stream is not offered three times.
/// - `V_720P`, `V_EXP*`, ... `.mp4` URLs: progressive mp4, muxed but flagged
///   `capabilitiesUnknown` (nothing in the answer states the file has
///   sound; `FormatCapabilityResolver` sniffs the real tracks), with the
///   width/height the API gave.
///
/// Outcomes: a pin without video -> `NO_MEDIA_FOUND`; a removed pin ->
/// `NOT_FOUND`; a private pin -> `LOGIN_REQUIRED`; HTTP 429 ->
/// `RATE_LIMITED`; 401/403 -> `CHALLENGE_FAILED`; an unrecognized answer ->
/// `PARSE_ERROR`; network trouble -> `NETWORK`.
class PinterestExtractor implements MediaExtractor {
  static const String _apiHost = 'www.pinterest.com';
  static const String _referer = 'https://www.pinterest.com/';

  static const Map<String, String> _downloadHeaders = {
    'User-Agent': NativeHttpClient.userAgent,
    'Referer': _referer,
  };

  /// Preference order among HLS keys; the first that yields formats wins.
  static const List<String> _hlsKeyOrder = ['V_HLSV4', 'V_HLSV3_WEB', 'V_HLSV3_MOBILE'];

  final NativeHttpClient _http;
  final PinterestPinParser _parser;
  final FormatExpander _expander;

  /// Hosts Pinterest media (HLS playlists, mp4 files) may live on. A
  /// `video_list` URL, or an HLS redirect, outside it is never requested or
  /// offered.
  static const NativeHostList mediaHosts = NativeHostList(['pinimg.com']);

  PinterestExtractor({NativeHttpClient? httpClient, PinterestPinParser? parser})
      : this._(
          (httpClient ?? NativeHttpClient(service: 'Pinterest')).withMediaHosts(mediaHosts),
          parser ?? const PinterestPinParser(),
        );

  PinterestExtractor._(this._http, this._parser) : _expander = FormatExpander(fetchText: _http.fetchText);

  @override
  bool canHandle(Uri url) => PinterestUrlMatcher.match(url) != null;

  @override
  Future<MediaInfo> extract(Uri url) async {
    final ref = PinterestUrlMatcher.match(url);
    if (ref == null) {
      throw const MediaExtractionException('UNSUPPORTED_URL', 'Not a recognizable Pinterest pin URL.');
    }

    final pinId = ref.pinId ?? await _resolveShortLink(ref.shortLink!);
    final response = await _http.get(
      _apiUrl(pinId),
      headers: {
        'Accept': 'application/json, text/javascript, */*; q=0.01',
        'X-Requested-With': 'XMLHttpRequest',
        'X-Pinterest-PWS-Handler': 'www/pin/[id].js',
        'Referer': 'https://www.pinterest.com/pin/$pinId/',
      },
      kind: NativeBodyKind.api,
      acceptHop: (hop) => PinterestUrlMatcher.isPinterestHost(hop.host),
    );
    NativeHttpClient.throwForStatus(response.statusCode, 'Pinterest');
    if (response.truncated) {
      throw const MediaExtractionException('PARSE_ERROR', 'Pinterest answered with more data than expected; trying another method.');
    }

    final pin = _parser.parse(response.body, pinId: pinId);
    final built = await _formats(pin);
    if (built.formats.isEmpty) {
      throw built.drmDetected
          ? const MediaExtractionException('DRM_PROTECTED', 'This Pinterest video is DRM protected. MiDa does not bypass DRM.')
          : const MediaExtractionException('NO_MEDIA_FOUND', 'Pinterest listed no playable video for this pin.');
    }

    return MediaInfo(
      id: pin.id,
      title: pin.title,
      author: pin.author,
      thumbnailUrl: pin.thumbnailUrl,
      duration: _duration(pin),
      formats: built.formats,
      sourceUrl: url,
      requestHeaders: _downloadHeaders,
    );
  }

  Future<String> _resolveShortLink(Uri shortLink) async {
    final target = await _http.resolveShortLink(
      shortLink,
      accept: (hop) => PinterestUrlMatcher.pinIdFromLanding(hop) != null,
      // pin.it -> api.pinterest.com/url_shortener/<code>/redirect/ -> the pin:
      // up to 3 hops inside Pinterest-owned hosts, each checked before it is
      // requested.
      followHop: (hop) => PinterestUrlMatcher.isPinterestOwnedHost(hop.host),
      maxFollowHops: 2,
    );
    return PinterestUrlMatcher.pinIdFromLanding(target)!;
  }

  /// [pinId] is already validated (`\d{1,25}`) by [PinterestUrlMatcher].
  static Uri _apiUrl(String pinId) {
    final data = jsonEncode({
      'options': {'field_set_key': 'unauth_react_main_pin', 'id': pinId},
    });
    return Uri.https(_apiHost, '/resource/PinResource/get/', {'source_url': '/pin/$pinId/', 'data': data});
  }

  Future<({List<MediaFormat> formats, bool drmDetected})> _formats(PinterestPin pin) async {
    final formats = <MediaFormat>[];
    var drmDetected = false;

    final videos = pin.videos.where((v) => _http.mediaUrlAllowed(v.url)).toList();
    final hlsEntries = <PinterestVideoEntry>[
      for (final key in _hlsKeyOrder) ...videos.where((v) => v.key == key),
      // A non-standard key that still points at a playlist.
      ...videos.where((v) => !_hlsKeyOrder.contains(v.key) && _isPlaylist(v.url)),
    ];
    for (final entry in hlsEntries) {
      final expanded = await _expander.expandFormats(
        entry.url,
        'm3u8',
        extraHeaders: _downloadHeaders,
        width: entry.width,
        height: entry.height,
      );
      drmDetected = drmDetected || expanded.drmDetected;
      final allowed = _http.filterAllowedFormats(expanded.formats);
      if (allowed.isNotEmpty) {
        formats.addAll(allowed);
        break;
      }
    }

    for (final entry in videos) {
      if (!_isMp4(entry.url) || _hlsKeyOrder.contains(entry.key)) continue;
      formats.add(MediaFormat(
        id: entry.key.toLowerCase(),
        url: entry.url,
        container: 'mp4',
        width: entry.width,
        height: entry.height,
        hasVideo: true,
        hasAudio: true,
        capabilitiesUnknown: true,
      ));
    }

    final seen = <String>{};
    return (formats: [for (final f in formats) if (seen.add(f.url)) f], drmDetected: drmDetected);
  }

  static Duration? _duration(PinterestPin pin) {
    for (final entry in pin.videos) {
      final ms = entry.durationMs;
      if (ms != null) return Duration(milliseconds: ms);
    }
    return null;
  }

  static String _path(String url) => Uri.parse(url).path.toLowerCase();
  static bool _isMp4(String url) => _path(url).endsWith('.mp4');
  static bool _isPlaylist(String url) => _path(url).endsWith('.m3u8');
}
