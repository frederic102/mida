import '../media_models.dart';

/// Pure JSON -> [MediaInfo] mapping for a Twitch `clip(slug: ...)` GQL
/// response (`TwitchGqlClient.query` with the query built in
/// `TwitchExtractor`). Kept free of any I/O so it can be exercised
/// entirely against `test/fixtures/twitch_clip_response.json`.
///
/// Not live-verified (`docs/plan-phase5-coverage.md` Lane D report):
/// finding a still-existing clip slug and confirming the
/// `playbackAccessToken`-signed `sourceURL` query-param shape end to end
/// was not completed within this pass's request budget. The shape here
/// (`clip.videoQualities[].sourceURL` + `clip.playbackAccessToken.{value,
/// signature}` appended as `?sig=<signature>&token=<value>`) matches the
/// long-stable, widely-documented public contract every third-party
/// Twitch clip downloader uses; treat as needing a field re-check before
/// relying on it.
class TwitchClipParser {
  const TwitchClipParser();

  /// Throws [MediaExtractionException] (`CHALLENGE_FAILED`, fall-through
  /// eligible - not the terminal `NOT_FOUND` an earlier version of this
  /// parser used, per the same reasoning `TwitchExtractor._extractVod`
  /// documents for its analogous `videoPlaybackAccessToken` check) when
  /// `data['clip']` is `null`, and (`UNSUPPORTED_MEDIA`) when it exists
  /// but has no `videoQualities`.
  MediaInfo parse(Map<String, dynamic> data, {required Uri sourceUrl, required Map<String, String> requestHeaders}) {
    final clip = data['clip'];
    if (clip is! Map) {
      throw const MediaExtractionException(
        'CHALLENGE_FAILED',
        'Twitch did not return data for this clip (it may not exist, or '
            'this request was blocked).',
      );
    }

    final token = clip['playbackAccessToken'];
    final value = token is Map ? token['value'] as String? : null;
    final signature = token is Map ? token['signature'] as String? : null;

    final qualities = clip['videoQualities'];
    if (qualities is! List || qualities.isEmpty) {
      throw const MediaExtractionException(
        'UNSUPPORTED_MEDIA',
        'Twitch returned no playable renditions for this clip.',
      );
    }

    final formats = <MediaFormat>[];
    for (final entry in qualities) {
      if (entry is! Map) continue;
      final source = entry['sourceURL'] as String?;
      if (source == null) continue;

      final signedUrl = (value != null && signature != null)
          ? '$source?sig=$signature&token=${Uri.encodeQueryComponent(value)}'
          : source;

      final quality = entry['quality'];
      final height = quality is String ? int.tryParse(quality) : null;
      final frameRate = entry['frameRate'];

      formats.add(MediaFormat(
        id: '${quality ?? formats.length}',
        url: signedUrl,
        container: 'mp4',
        height: height,
        fps: frameRate is num ? frameRate.toDouble() : null,
        hasVideo: true,
        hasAudio: true,
      ));
    }

    final broadcaster = clip['broadcaster'];
    final durationSeconds = clip['durationSeconds'];
    return MediaInfo(
      id: sourceUrl.pathSegments.isNotEmpty ? sourceUrl.pathSegments.last : '',
      title: clip['title'] as String? ?? 'Untitled',
      author: broadcaster is Map ? broadcaster['displayName'] as String? : null,
      thumbnailUrl: clip['thumbnailURL'] as String?,
      duration: durationSeconds is num ? Duration(seconds: durationSeconds.toInt()) : null,
      formats: formats,
      sourceUrl: sourceUrl,
      requestHeaders: requestHeaders,
    );
  }
}
