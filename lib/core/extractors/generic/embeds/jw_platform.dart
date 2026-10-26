import '../../media_models.dart';
import 'embed_resolver.dart';

/// JW Player hosted media (JW Platform), via the same public Delivery API
/// the cloud-hosted JW player loads: `https://cdn.jwplayer.com/v2/media/{id}`,
/// whose `playlist[0].sources` lists the HLS manifest and the MP4/M4A
/// ladder.
///
/// Detected from `content.jwplatform.com/players/{id}-{player}.js|html`,
/// `cdn.jwplayer.com/players/{id}[-{player}]`, other
/// `content.jwplatform.com|cdn.jwplayer.com` media paths
/// (`videos/`, `manifests/`, `previews/`, `v2/media/`), and
/// `data-video-jw-id`. JW media ids are exactly eight alphanumerics.
class JwPlatformEmbedResolver implements EmbedResolver {
  const JwPlatformEmbedResolver();

  @override
  String get platform => 'JW Player';

  static final RegExp _urlPattern = RegExp(
    r'(?:content\.jwplatform\.com|cdn\.jwplayer\.com)/(?:players|previews|manifests|videos|v2/media)/([a-zA-Z0-9]{8})(?![a-zA-Z0-9])',
    caseSensitive: false,
  );
  static final RegExp _dataAttributePattern = RegExp(
    r'''data-video-jw-id\s*=\s*["']?([a-zA-Z0-9]{8})(?![a-zA-Z0-9])''',
    caseSensitive: false,
  );

  @override
  bool matches(String html) => findMediaId(html) != null;

  static String? findMediaId(String html) =>
      _urlPattern.firstMatch(html)?.group(1) ?? _dataAttributePattern.firstMatch(html)?.group(1);

  @override
  Future<MediaInfo?> resolve(EmbedRequest request) async {
    final mediaId = findMediaId(request.html);
    if (mediaId == null) return null;
    final response = await request.http.get(
      Uri.https('cdn.jwplayer.com', '/v2/media/$mediaId'),
      headers: EmbedSupport.apiHeaders(request),
    );
    if (!response.isOk) return null;
    final json = EmbedSupport.tryDecodeJson(response.body);
    if (json is! Map) return null;
    return parseMediaJson(json, mediaId: mediaId, request: request);
  }

  /// Maps a Delivery API response to a [MediaInfo]. A source carrying a
  /// `drm` block (JW's Studio DRM: Widevine/PlayReady/FairPlay license
  /// URLs) is never offered; when that leaves nothing, the media is
  /// reported as `DRM_PROTECTED`.
  MediaInfo? parseMediaJson(Map<dynamic, dynamic> json, {required String mediaId, required EmbedRequest request}) {
    final playlist = json['playlist'];
    if (playlist is! List || playlist.isEmpty) return null;
    final item = playlist.first;
    if (item is! Map) return null;
    final sources = item['sources'];
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
      final url = EmbedSupport.httpUrl(source['file']);
      if (url == null || !seen.add(url)) continue;
      final format = _formatFor(source, url, formats.length);
      if (format != null) formats.add(format);
    }

    if (formats.isEmpty) {
      if (drmSources > 0) throw EmbedSupport.drmException(platform);
      return null;
    }

    final seconds = item['duration'];
    return MediaInfo(
      id: 'jwplayer-$mediaId',
      title: EmbedSupport.asString(item['title']) ?? EmbedSupport.asString(json['title']) ?? 'JW Player video $mediaId',
      thumbnailUrl: EmbedSupport.httpUrl(item['image']),
      duration: seconds is num && seconds > 0 ? Duration(milliseconds: (seconds * 1000).round()) : null,
      sourceUrl: request.pageUrl,
      formats: formats,
      requestHeaders: EmbedSupport.mediaHeaders(request),
    );
  }

  static MediaFormat? _formatFor(Map<dynamic, dynamic> source, String url, int index) {
    final type = (EmbedSupport.asString(source['type']) ?? '').toLowerCase();
    final label = EmbedSupport.asString(source['label']);

    if (type == 'application/vnd.apple.mpegurl' || type == 'application/x-mpegurl' || type == 'hls') {
      return MediaFormat(id: 'jwplayer-hls-$index', url: url, container: 'm3u8', hasVideo: true, hasAudio: true);
    }
    if (type == 'application/dash+xml' || type == 'dash') {
      return MediaFormat(id: 'jwplayer-dash-$index', url: url, container: 'mpd', hasVideo: true, hasAudio: true);
    }
    if (type == 'audio/mp4' || type == 'audio/mpeg') {
      return MediaFormat(
        id: 'jwplayer-audio-$index',
        url: url,
        container: type == 'audio/mpeg' ? 'mp3' : 'm4a',
        bitrate: EmbedSupport.asInt(source['bitrate']) ?? 0,
        contentLength: EmbedSupport.asInt(source['filesize']),
        hasVideo: false,
        hasAudio: true,
      );
    }
    if (type == 'video/mp4' || type == 'video/webm') {
      final height = EmbedSupport.asInt(source['height']);
      return MediaFormat(
        id: 'jwplayer-${label ?? height ?? 'mp4'}-$index',
        url: url,
        container: type == 'video/webm' ? 'webm' : 'mp4',
        width: EmbedSupport.asInt(source['width']),
        height: height,
        fps: source['framerate'] is num ? (source['framerate'] as num).toDouble() : null,
        bitrate: EmbedSupport.asInt(source['bitrate']) ?? 0,
        contentLength: EmbedSupport.asInt(source['filesize']),
        hasVideo: true,
        hasAudio: true,
      );
    }
    return null; // Unknown delivery type: skip rather than guess.
  }
}
