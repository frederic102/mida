import '../media_models.dart';

/// Pure JSON -> [MediaInfo] mapping for a response from Vimeo's own player
/// config endpoint (`https://player.vimeo.com/video/<id>/config`, the same
/// unauthenticated JSON contract vimeo.com's own embedded player and
/// `player.vimeo.com/video/<id>` fetch to bootstrap playback). Kept free of
/// any I/O so it can be exercised entirely against
/// `test/fixtures/vimeo_config.json`.
///
/// Shape (documented public contract, reproduced honestly - no embed-token
/// or challenge handling):
/// - `request.files.progressive[]`: muxed `video/mp4` renditions, each with
///   `url`/`width`/`height`/`quality`. Always has audio and video together.
/// - `request.files.hls.cdns.<cdn name>.url`: an HLS master (m3u8) that
///   itself carries every adaptive rendition (video and audio, muxed by
///   ffmpeg reading the manifest) - `request.files.hls.default_cdn` picks
///   which CDN entry to prefer when more than one is offered.
/// - `video.title`/`video.duration`/`video.owner.name`/`video.thumbs`:
///   metadata. `thumbs` is a map keyed by pixel width; the largest wins.
/// - `errors`: a top-level array present instead of (or alongside) empty
///   `request.files` when the video is private/unlisted and this
///   unauthenticated config call cannot see it.
class VimeoConfigParser {
  const VimeoConfigParser();

  /// Substrings Vimeo's own privacy answers carry (`errors[].message`
  /// or a top-level `message`): "This video is private", "password",
  /// "not available"/"unlisted" wording. Anything else - an HTML page, a
  /// WAF notice, an address ban - is NOT a privacy refusal.
  static const List<String> _privacyMarkers = [
    'private',
    'password',
    'unlisted',
    'not available in your',
    'does not exist',
  ];

  /// True when [raw] (a response body, JSON or not) is Vimeo's own
  /// "you are not allowed to see this video" answer, as opposed to an
  /// unrelated refusal that another tier might still get past.
  static bool isPrivacyRefusal(String raw) {
    final trimmed = raw.trimLeft();
    if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return false;
    final lower = raw.toLowerCase();
    if (!lower.contains('"errors"') && !lower.contains('"message"')) return false;
    return _privacyMarkers.any(lower.contains);
  }

  /// Throws [MediaExtractionException] (`LOGIN_REQUIRED`) when [json]
  /// carries a top-level `errors` array (Vimeo's own way of saying this
  /// video needs a password or is private to this unauthenticated caller),
  /// and (`UNSUPPORTED_MEDIA`) when neither a progressive rendition nor an
  /// HLS master is present at all (e.g. an audio-only or otherwise
  /// non-video config shape this extractor does not recognize).
  MediaInfo parse(
    Map<String, dynamic> json, {
    required Uri sourceUrl,
    required Map<String, String> requestHeaders,
  }) {
    final errors = json['errors'];
    if (errors is List && errors.isNotEmpty) {
      final first = errors.first;
      final rawMessage = first is Map ? first['message'] : null;
      final message = rawMessage is String ? rawMessage : null;
      final lower = (message ?? '').toLowerCase();
      if (_privacyMarkers.any(lower.contains)) {
        throw MediaExtractionException(
          'LOGIN_REQUIRED',
          message ?? 'This Vimeo video is private, unlisted, or password protected.',
        );
      }
      // An errors array whose text is not a privacy signal is an API-shape
      // or transient condition this extractor does not understand: let
      // the registry try the generic and browser tiers.
      throw MediaExtractionException('PARSE_ERROR', 'Vimeo reported an error MiDa does not recognize: ${message ?? errors.first}');
    }

    final request = json['request'];
    final files = request is Map ? request['files'] : null;

    final formats = <MediaFormat>[
      ..._progressiveFormats(files is Map ? files['progressive'] : null),
      ..._hlsFormat(files is Map ? files['hls'] : null),
    ];

    if (formats.isEmpty) {
      throw const MediaExtractionException(
        'UNSUPPORTED_MEDIA',
        'Vimeo returned no playable video renditions for this link.',
      );
    }

    final video = json['video'];
    final owner = video is Map ? video['owner'] : null;

    return MediaInfo(
      id: video is Map ? '${video['id'] ?? ''}' : '',
      title: video is Map ? _asString(video['title']) ?? 'Untitled' : 'Untitled',
      author: owner is Map ? _asString(owner['name']) : null,
      thumbnailUrl: _bestThumbnail(video is Map ? video['thumbs'] : null),
      duration: _durationFromSeconds(video is Map ? video['duration'] : null),
      formats: formats,
      sourceUrl: sourceUrl,
      requestHeaders: requestHeaders,
    );
  }

  List<MediaFormat> _progressiveFormats(dynamic rawProgressive) {
    if (rawProgressive is! List) return const [];
    final result = <MediaFormat>[];
    for (final entry in rawProgressive) {
      if (entry is! Map) continue;
      final url = _httpsUrl(entry['url']);
      if (url == null) continue;
      result.add(MediaFormat(
        id: 'progressive-${result.length}',
        url: url,
        container: 'mp4',
        width: _asInt(entry['width']),
        height: _asInt(entry['height']),
        fps: _asDouble(entry['fps']),
        hasVideo: true,
        hasAudio: true,
      ));
    }
    return result;
  }

  /// Picks `hls.cdns[hls.default_cdn].url` when present, otherwise the
  /// first CDN entry offered - `default_cdn` is Vimeo's own preference,
  /// but a config that omits it (or names a CDN not actually present in
  /// `cdns`) should still yield a usable master rather than nothing.
  List<MediaFormat> _hlsFormat(dynamic rawHls) {
    if (rawHls is! Map) return const [];
    final cdns = rawHls['cdns'];
    if (cdns is! Map || cdns.isEmpty) return const [];

    final defaultCdn = _asString(rawHls['default_cdn']);
    final preferred = defaultCdn != null ? cdns[defaultCdn] : null;
    final chosen = preferred is Map ? preferred : cdns.values.first;
    final url = chosen is Map ? _httpsUrl(chosen['url']) : null;
    if (url == null) return const [];

    return [
      MediaFormat(
        id: 'hls-master',
        url: url,
        container: 'm3u8',
        hasVideo: true,
        hasAudio: true,
      ),
    ];
  }

  String? _bestThumbnail(dynamic rawThumbs) {
    if (rawThumbs is! Map || rawThumbs.isEmpty) return null;
    var bestKey = -1;
    String? bestUrl;
    for (final entry in rawThumbs.entries) {
      final size = int.tryParse('${entry.key}') ?? -1;
      if (size >= bestKey && entry.value is String) {
        bestKey = size;
        bestUrl = entry.value as String;
      }
    }
    return bestUrl;
  }

  Duration? _durationFromSeconds(dynamic raw) {
    if (raw is int) return Duration(seconds: raw);
    if (raw is num) return Duration(seconds: raw.toInt());
    return null;
  }

  String? _asString(dynamic value) => value is String ? value : null;

  /// Only absolute `https` URLs are accepted from the config. A plain-http
  /// or relative value would be printed verbatim by ffmpeg-side diagnostics
  /// and is not something Vimeo's real config ever carries.
  String? _httpsUrl(dynamic value) {
    if (value is! String) return null;
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme || uri.scheme.toLowerCase() != 'https' || uri.host.isEmpty) return null;
    return value;
  }

  int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }

  double? _asDouble(dynamic value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return null;
  }
}
