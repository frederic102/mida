import '../../media_models.dart';
import 'embed_resolver.dart';

/// Wistia, via the same public media JSON the Wistia player (E-v1.js)
/// loads: `https://fast.wistia.net/embed/medias/{hashedId}.json`, whose
/// `media.assets` lists every rendition (original, hd_mp4, md_mp4, ...,
/// and an HLS asset).
///
/// Detected from `fast.wistia.(net|com)/embed/(iframe|medias)/{id}`
/// iframes/scripts, the `wistia_async_{id}` class the async embed uses,
/// and `data-wistia-id`. Wistia hashed ids are exactly ten lowercase
/// alphanumerics; nothing else is accepted.
class WistiaEmbedResolver implements EmbedResolver {
  const WistiaEmbedResolver();

  @override
  String get platform => 'Wistia';

  static final RegExp _urlPattern = RegExp(
    r'fast\.wistia\.(?:net|com)/embed/(?:iframe|medias)/([a-z0-9]{10})\b',
    caseSensitive: false,
  );
  static final RegExp _asyncClassPattern = RegExp(r'\bwistia_async_([a-z0-9]{10})\b');
  static final RegExp _dataAttributePattern = RegExp(
    r'''data-wistia-id\s*=\s*["']?([a-z0-9]{10})\b''',
    caseSensitive: false,
  );

  /// Asset status 2 = ready; anything else has no file behind it yet.
  static const int _assetReady = 2;

  static const Set<String> _skippedTypes = {'preview', 'storyboard', 'still', 'still_image'};

  @override
  bool matches(String html) => findMediaId(html) != null;

  static String? findMediaId(String html) {
    final id = _urlPattern.firstMatch(html)?.group(1) ??
        _asyncClassPattern.firstMatch(html)?.group(1) ??
        _dataAttributePattern.firstMatch(html)?.group(1);
    return id?.toLowerCase();
  }

  @override
  Future<MediaInfo?> resolve(EmbedRequest request) async {
    final mediaId = findMediaId(request.html);
    if (mediaId == null) return null;
    final response = await request.http.get(
      Uri.https('fast.wistia.net', '/embed/medias/$mediaId.json'),
      headers: EmbedSupport.apiHeaders(request),
    );
    if (!response.isOk) return null;
    final json = EmbedSupport.tryDecodeJson(response.body);
    if (json is! Map) return null;
    return parseMediaJson(json, mediaId: mediaId, request: request);
  }

  /// Maps `{"media": {...}}` to a [MediaInfo]. A password-protected or
  /// unknown media comes back as `{"error": true, ...}`: null. Wistia has no
  /// DRM product; an asset carrying license-server keys anyway (the shared
  /// [EmbedSupport.hasDrmKeys] check) is treated exactly like the other
  /// platforms' protected renditions rather than trusted.
  MediaInfo? parseMediaJson(Map<dynamic, dynamic> json, {required String mediaId, required EmbedRequest request}) {
    if (json['error'] == true) return null;
    final media = json['media'];
    if (media is! Map) return null;
    final assets = media['assets'];
    if (assets is! List) return null;

    final formats = <MediaFormat>[];
    final seen = <String>{};
    String? thumbnail;
    var drmAssets = 0;
    for (final asset in assets) {
      if (asset is! Map) continue;
      final type = EmbedSupport.asString(asset['type']) ?? '';
      final status = EmbedSupport.asInt(asset['status']);
      if (status != null && status != _assetReady) continue;
      final url = EmbedSupport.httpUrl(asset['url']);
      if (url == null) continue;
      if (type == 'still_image' || type == 'still') {
        thumbnail ??= url;
        continue;
      }
      if (_skippedTypes.contains(type)) continue;
      if (EmbedSupport.hasDrmKeys(asset)) {
        drmAssets++;
        continue;
      }
      final format = _formatFor(asset, type, url, formats.length);
      if (format != null && seen.add(format.url)) formats.add(format);
    }

    if (formats.isEmpty) {
      if (drmAssets > 0) throw EmbedSupport.drmException(platform);
      return null;
    }

    final seconds = media['duration'];
    return MediaInfo(
      id: 'wistia-$mediaId',
      title: EmbedSupport.asString(media['name']) ?? 'Wistia video $mediaId',
      thumbnailUrl: thumbnail,
      duration: seconds is num && seconds > 0 ? Duration(milliseconds: (seconds * 1000).round()) : null,
      sourceUrl: request.pageUrl,
      formats: formats,
      requestHeaders: EmbedSupport.mediaHeaders(request),
    );
  }

  static MediaFormat? _formatFor(Map<dynamic, dynamic> asset, String type, String url, int index) {
    final container = (EmbedSupport.asString(asset['container']) ?? EmbedSupport.asString(asset['ext']) ?? '')
        .toLowerCase();
    final ext = (EmbedSupport.asString(asset['ext']) ?? '').toLowerCase();
    final displayName = EmbedSupport.asString(asset['display_name']);
    final formatId = 'wistia-${type.isEmpty ? 'asset' : type}-$index';

    if (container == 'm3u8' || ext == 'm3u8' || type.contains('hls')) {
      // Wistia serves its HLS master from the same `.bin` delivery path;
      // the player asks for it with an `.m3u8` suffix.
      final manifestUrl = url.endsWith('.bin') ? '${url.substring(0, url.length - 4)}.m3u8' : url;
      return MediaFormat(id: formatId, url: manifestUrl, container: 'm3u8', hasVideo: true, hasAudio: true);
    }

    final audioOnly = displayName == 'Audio' || type.contains('audio');
    final resolvedContainer = audioOnly ? 'm4a' : _videoContainer(container, ext, type);
    if (resolvedContainer == null) return null; // flash/unknown asset types: skip, don't guess

    return MediaFormat(
      id: formatId,
      url: url,
      container: resolvedContainer,
      videoCodec: audioOnly ? null : EmbedSupport.asString(asset['codec']),
      width: audioOnly ? null : EmbedSupport.asInt(asset['width']),
      height: audioOnly ? null : EmbedSupport.asInt(asset['height']),
      // Wistia reports bitrate in kbit/s.
      bitrate: (EmbedSupport.asInt(asset['bitrate']) ?? 0) * 1000,
      contentLength: EmbedSupport.asInt(asset['size']),
      hasVideo: !audioOnly,
      hasAudio: true,
    );
  }

  /// Container for a video asset from its own `container`/`ext`; a bare
  /// `*_video` transcode type is Wistia's MP4 ladder. Flash and anything
  /// unrecognized is skipped rather than guessed.
  static String? _videoContainer(String container, String ext, String type) {
    for (final candidate in [container, ext]) {
      if (candidate == 'flv') return null;
      if (candidate == 'mp4' || candidate == 'm4v') return 'mp4';
      if (candidate == 'mov' || candidate == 'webm' || candidate == 'mkv') return candidate;
    }
    if (type.endsWith('_video') && !type.startsWith('flash')) return 'mp4';
    return null;
  }
}
