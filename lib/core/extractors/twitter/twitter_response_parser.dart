import '../media_models.dart';

/// Pure JSON -> [MediaInfo] mapping for a response from X's public
/// syndication endpoint (`cdn.syndication.twimg.com/tweet-result`). Kept
/// free of any I/O so it can be exercised entirely against
/// `test/fixtures/twitter_syndication.json`.
///
/// Field mapping verified live 2026-09-05 (`docs/extractor-research.md`
/// section 1, `docs/plan-phase2-extractors.md`):
/// `mediaDetails[].video_info.variants[]` (mp4 renditions, `content_type`
/// video/mp4 only, `.m3u8` playlist entries skipped),
/// `mediaDetails[].media_url_https` (thumbnail),
/// `video_info.duration_millis` (duration), `text` (title),
/// `user.screen_name` (author).
class TwitterResponseParser {
  const TwitterResponseParser();

  static const _videoMimeType = 'video/mp4';
  static final _resolutionPattern = RegExp(r'/(\d+)x(\d+)/');

  /// Throws [MediaExtractionException] (`UNSUPPORTED_MEDIA`) when the
  /// tweet has no `mediaDetails` with at least one mp4 variant: a card
  /// tweet or an externally hosted player, neither of which the
  /// syndication endpoint exposes video for.
  MediaInfo parse(
    Map<String, dynamic> json, {
    required Uri sourceUrl,
    required Map<String, String> requestHeaders,
  }) {
    final mediaDetails = json['mediaDetails'];
    final formats = <MediaFormat>[];
    String? thumbnailUrl;
    Duration? duration;

    if (mediaDetails is List) {
      for (final entry in mediaDetails) {
        if (entry is! Map) continue;
        thumbnailUrl ??= entry['media_url_https'] as String?;
        final videoInfo = entry['video_info'];
        if (videoInfo is! Map) continue;
        duration ??= _durationFromMillis(videoInfo['duration_millis']);
        formats.addAll(_parseVariants(videoInfo['variants']));
      }
    }

    if (formats.isEmpty) {
      throw const MediaExtractionException(
        'UNSUPPORTED_MEDIA',
        'This post has no attached video. It looks like a card or an '
            'externally hosted player, which the syndication API does not '
            'expose video for. Open the post in a browser to view it there.',
      );
    }

    final user = json['user'];
    return MediaInfo(
      id: json['id_str'] as String? ?? '',
      title: json['text'] as String? ?? 'Untitled',
      author: user is Map ? user['screen_name'] as String? : null,
      thumbnailUrl: thumbnailUrl,
      duration: duration,
      formats: formats,
      sourceUrl: sourceUrl,
      requestHeaders: requestHeaders,
    );
  }

  List<MediaFormat> _parseVariants(dynamic rawVariants) {
    if (rawVariants is! List) return const [];
    final result = <MediaFormat>[];
    for (final variant in rawVariants) {
      if (variant is! Map) continue;
      if (variant['content_type'] != _videoMimeType) continue; // skip m3u8
      final url = variant['url'] as String?;
      if (url == null) continue;

      final resolution = _resolutionPattern.firstMatch(url);
      final width = resolution != null ? int.tryParse(resolution.group(1)!) : null;
      final height = resolution != null ? int.tryParse(resolution.group(2)!) : null;
      final bitrate = _asInt(variant['bitrate']) ?? 0;

      result.add(MediaFormat(
        id: '$bitrate',
        url: url,
        container: 'mp4',
        width: width,
        height: height,
        bitrate: bitrate,
        // The syndication endpoint only ever returns progressive (already
        // muxed) mp4 renditions for attached video, never video-only or
        // audio-only streams.
        hasVideo: true,
        hasAudio: true,
      ));
    }
    return result;
  }

  Duration? _durationFromMillis(dynamic raw) {
    final millis = _asInt(raw);
    return millis == null ? null : Duration(milliseconds: millis);
  }

  int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
