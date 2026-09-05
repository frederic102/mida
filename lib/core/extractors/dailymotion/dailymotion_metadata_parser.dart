import '../media_models.dart';

/// Pure JSON -> [MediaInfo] mapping for a response from Dailymotion's
/// public player metadata endpoint
/// (`https://www.dailymotion.com/player/metadata/video/<xid>`). Kept free
/// of any I/O so it can be exercised entirely against
/// `test/fixtures/dailymotion_metadata.json`.
///
/// Field mapping verified live 2026-09-05 (`docs/plan-phase5-coverage.md`
/// Lane D): `qualities` is a map keyed by either `"auto"` (adaptive HLS,
/// `type: application/x-mpegURL`) or a pixel-height string (`"480"`,
/// `"380"`, ...; progressive `video/mp4`), each value a list of
/// `{type, url}`. `title`/`duration`/`owner.username`/`thumbnails` are
/// top-level. An `error` object (instead of the fields above) means the
/// video id does not exist or was removed.
///
/// `NOT_FOUND` for `error.code == '404'` re-confirmed live 2026-09-05
/// (`docs/plan-phase5-coverage.md` Lane D follow-up, in response to a
/// "is this a misread or really gone" check): this endpoint is a clean
/// JSON API with no HTML/WAF layer observed in any test this pass ran
/// against it (unlike Bilibili/Douyin/Reddit) - the `error` object always
/// arrives with a well-formed `error_data.reason` (`"object_not_found"`
/// for a bad id), never as a side effect of anti-bot blocking, so this
/// status is intentionally still terminal, not fall-through eligible.
class DailymotionMetadataParser {
  const DailymotionMetadataParser();

  static const _hlsMimeType = 'application/x-mpegURL';
  static const _mp4MimeType = 'video/mp4';

  /// Throws [MediaExtractionException] for the endpoint's own `error`
  /// object (`NOT_FOUND` for a missing/removed video, `LOGIN_REQUIRED` for
  /// a password-protected one it reports as `is_password_protected`,
  /// `UNSUPPORTED_MEDIA` for anything else it explicitly errors on), and
  /// `UNSUPPORTED_MEDIA` when `qualities` has no usable entries (live
  /// streams currently offline, or a type this parser does not recognize).
  MediaInfo parse(
    Map<String, dynamic> json, {
    required Uri sourceUrl,
    required Map<String, String> requestHeaders,
  }) {
    final error = json['error'];
    if (error is Map) {
      final code = '${error['code'] ?? ''}';
      if (code == '404') {
        throw const MediaExtractionException(
          'NOT_FOUND',
          'This Dailymotion video no longer exists or the link is wrong.',
        );
      }
      throw MediaExtractionException(
        'UNSUPPORTED_MEDIA',
        error['message'] as String? ?? 'Dailymotion refused to return this video.',
      );
    }

    if (json['is_password_protected'] == true) {
      throw const MediaExtractionException(
        'LOGIN_REQUIRED',
        'This Dailymotion video is password protected.',
      );
    }

    final formats = _parseQualities(json['qualities']);
    if (formats.isEmpty) {
      throw const MediaExtractionException(
        'UNSUPPORTED_MEDIA',
        'Dailymotion returned no playable renditions for this video (it may '
            'be a live stream that has ended, or geo-restricted).',
      );
    }

    final owner = json['owner'];
    return MediaInfo(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? 'Untitled',
      author: owner is Map ? owner['username'] as String? : null,
      thumbnailUrl: _bestThumbnail(json['thumbnails']),
      duration: _durationFromSeconds(json['duration']),
      formats: formats,
      sourceUrl: sourceUrl,
      requestHeaders: requestHeaders,
    );
  }

  List<MediaFormat> _parseQualities(dynamic rawQualities) {
    if (rawQualities is! Map) return const [];
    final result = <MediaFormat>[];

    rawQualities.forEach((key, value) {
      if (value is! List) return;
      final height = key == 'auto' ? null : int.tryParse('$key');
      for (final entry in value) {
        if (entry is! Map) continue;
        final url = entry['url'] as String?;
        final type = entry['type'] as String?;
        if (url == null || type == null) continue;

        final container = type == _hlsMimeType
            ? 'm3u8'
            : type == _mp4MimeType
                ? 'mp4'
                : null;
        if (container == null) continue; // unrecognized delivery type: skip, don't guess

        result.add(MediaFormat(
          id: '$key-${result.length}',
          url: url,
          container: container,
          width: null,
          height: height,
          // The auto (HLS) entry is a master playlist offering every
          // rendition itself, so it is never muxed-only-video; the
          // per-height progressive entries are always muxed mp4.
          hasVideo: true,
          hasAudio: true,
        ));
      }
    });
    return result;
  }

  String? _bestThumbnail(dynamic rawThumbnails) {
    if (rawThumbnails is! Map || rawThumbnails.isEmpty) return null;
    var bestKey = -1;
    String? bestUrl;
    for (final entry in rawThumbnails.entries) {
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
}
