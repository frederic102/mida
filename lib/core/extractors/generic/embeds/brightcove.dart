import '../../media_models.dart';
import 'embed_resolver.dart';

/// One Brightcove player embed found on a host page.
class BrightcoveEmbed {
  final String accountId;
  final String playerId;
  final String embedId;
  final String videoId;

  const BrightcoveEmbed({
    required this.accountId,
    required this.playerId,
    required this.embedId,
    required this.videoId,
  });
}

/// Brightcove Video Cloud, via the same two public calls the Brightcove
/// Player makes: the player's own `config.json` (for
/// `video_cloud.policy_key`), then the Playback API with
/// `Accept: application/json;pk=<policy key>`.
///
/// Detected from an `<iframe src="https://players.brightcove.net/{account}/
/// {player}_{embed}/index.html?videoId={id}">` or an in-page
/// `<video|video-js data-account data-player data-embed data-video-id>`.
/// Every id is checked against a strict pattern before it is put into a
/// URL, so page text can never steer a request off these two hosts.
class BrightcoveEmbedResolver implements EmbedResolver {
  const BrightcoveEmbedResolver();

  @override
  String get platform => 'Brightcove';

  static final RegExp _iframePattern = RegExp(
    r'''players\.brightcove\.net/(\d+)/([A-Za-z0-9-]+)_([A-Za-z0-9-]+)/index\.html\?[^"'\s<>]*?\bvideoId=([^"&'\s<>]+)''',
    caseSensitive: false,
  );
  static final RegExp _accountPattern = RegExp(r'^\d{1,20}$');
  static final RegExp _playerPattern = RegExp(r'^[A-Za-z0-9-]{1,64}$');
  static final RegExp _videoIdPattern = RegExp(r'^(?:\d{1,20}|ref:[A-Za-z0-9_.\-]{1,150})$');
  static final RegExp _policyKeyPattern = RegExp(r'^[A-Za-z0-9_\-.=]{1,512}$');

  @override
  bool matches(String html) => findEmbed(html) != null;

  /// First well-formed Brightcove embed in [html], iframe form first.
  static BrightcoveEmbed? findEmbed(String html) {
    final decoded = EmbedSupport.unescapeHtml(html);
    for (final match in _iframePattern.allMatches(decoded)) {
      String videoId;
      try {
        videoId = Uri.decodeComponent(match.group(4)!);
      } on ArgumentError {
        continue;
      }
      final embed = _validated(match.group(1), match.group(2), match.group(3), videoId);
      if (embed != null) return embed;
    }
    for (final tag in EmbedSupport.openingTags(html, const ['video', 'video-js'])) {
      final attributes = EmbedSupport.attributesOf(tag);
      final embed = _validated(
        attributes['data-account'],
        attributes['data-player'] ?? 'default',
        attributes['data-embed'] ?? 'default',
        attributes['data-video-id'],
      );
      if (embed != null) return embed;
    }
    return null;
  }

  static BrightcoveEmbed? _validated(String? account, String? player, String? embed, String? videoId) {
    if (account == null || player == null || embed == null || videoId == null) return null;
    if (!_accountPattern.hasMatch(account)) return null;
    if (!_playerPattern.hasMatch(player) || !_playerPattern.hasMatch(embed)) return null;
    if (!_videoIdPattern.hasMatch(videoId)) return null;
    return BrightcoveEmbed(accountId: account, playerId: player, embedId: embed, videoId: videoId);
  }

  @override
  Future<MediaInfo?> resolve(EmbedRequest request) async {
    final embed = findEmbed(request.html);
    if (embed == null) return null;

    final policyKey = await _fetchPolicyKey(request, embed);
    if (policyKey == null) return null;

    final playbackUrl = Uri.https(
      'edge.api.brightcove.com',
      '/playback/v1/accounts/${embed.accountId}/videos/${embed.videoId}',
    );
    final response = await request.http.get(
      playbackUrl,
      headers: EmbedSupport.apiHeaders(request, accept: 'application/json;pk=$policyKey'),
    );
    if (!response.isOk) return null;
    final json = EmbedSupport.tryDecodeJson(response.body);
    if (json is! Map) return null;
    return parsePlayback(json, embed: embed, request: request);
  }

  Future<String?> _fetchPolicyKey(EmbedRequest request, BrightcoveEmbed embed) async {
    final configUrl = Uri.https(
      'players.brightcove.net',
      '/${embed.accountId}/${embed.playerId}_${embed.embedId}/config.json',
    );
    final response = await request.http.get(configUrl, headers: EmbedSupport.apiHeaders(request));
    if (!response.isOk) return null;
    final json = EmbedSupport.tryDecodeJson(response.body);
    if (json is! Map) return null;
    final videoCloud = json['video_cloud'];
    if (videoCloud is! Map) return null;
    final key = EmbedSupport.asString(videoCloud['policy_key']);
    // Policy keys are base64url-ish tokens; anything else (whitespace,
    // `;`, `,`) could smuggle extra parameters into the Accept header.
    if (key == null || !_policyKeyPattern.hasMatch(key)) return null;
    return key;
  }

  /// Maps a Playback API video object to a [MediaInfo]. A source carrying
  /// `key_systems` is DRM-packaged and is never offered; when that leaves
  /// nothing, the whole video is reported as `DRM_PROTECTED`.
  MediaInfo? parsePlayback(Map<dynamic, dynamic> json, {required BrightcoveEmbed embed, required EmbedRequest request}) {
    final sources = json['sources'];
    if (sources is! List) return null;

    final formats = <MediaFormat>[];
    final seen = <String>{};
    var drmSources = 0;
    for (final source in sources) {
      if (source is! Map) continue;
      if (EmbedSupport.hasDrmKeys(source)) {
        drmSources++;
        continue;
      }
      final url = EmbedSupport.httpUrl(source['src']);
      if (url == null || !seen.add(url)) continue;
      final format = _formatFor(source, url, formats.length);
      if (format != null) formats.add(format);
    }

    if (formats.isEmpty) {
      if (drmSources > 0) throw EmbedSupport.drmException(platform);
      return null;
    }

    final durationMs = EmbedSupport.asInt(json['duration']);
    return MediaInfo(
      id: 'brightcove-${embed.accountId}-${EmbedSupport.asString(json['id']) ?? embed.videoId}',
      title: EmbedSupport.asString(json['name']) ?? 'Brightcove video ${embed.videoId}',
      thumbnailUrl: EmbedSupport.httpUrl(json['poster']) ?? EmbedSupport.httpUrl(json['thumbnail']),
      duration: durationMs != null && durationMs > 0 ? Duration(milliseconds: durationMs) : null,
      sourceUrl: request.pageUrl,
      formats: formats,
      requestHeaders: EmbedSupport.mediaHeaders(request),
    );
  }

  static MediaFormat? _formatFor(Map<dynamic, dynamic> source, String url, int index) {
    final type = (EmbedSupport.asString(source['type']) ?? '').toLowerCase();
    final container = (EmbedSupport.asString(source['container']) ?? '').toLowerCase();

    if (type == 'application/x-mpegurl' || type == 'application/vnd.apple.mpegurl' || container == 'm2ts') {
      return MediaFormat(id: 'brightcove-hls-$index', url: url, container: 'm3u8', hasVideo: true, hasAudio: true);
    }
    if (type == 'application/dash+xml') {
      return MediaFormat(id: 'brightcove-dash-$index', url: url, container: 'mpd', hasVideo: true, hasAudio: true);
    }
    if (container == 'mp4' || type == 'video/mp4') {
      final width = EmbedSupport.asInt(source['width']);
      final height = EmbedSupport.asInt(source['height']);
      final codec = EmbedSupport.asString(source['codec']);
      // Brightcove lists an audio-only MP4 rendition with no frame size and
      // an AAC codec; every sized MP4 rendition is muxed.
      final audioOnly = width == null && height == null && (codec ?? '').toUpperCase() == 'AAC';
      return MediaFormat(
        id: 'brightcove-mp4-${height ?? 'audio'}-$index',
        url: url,
        container: audioOnly ? 'm4a' : 'mp4',
        videoCodec: audioOnly ? null : codec,
        width: width,
        height: height,
        bitrate: EmbedSupport.asInt(source['avg_bitrate']) ?? 0,
        contentLength: EmbedSupport.asInt(source['size']),
        hasVideo: !audioOnly,
        hasAudio: true,
      );
    }
    return null; // RTMP, unknown delivery types: skip rather than guess.
  }
}
