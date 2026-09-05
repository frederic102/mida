import '../media_models.dart';

/// Pure JSON -> [MediaInfo] mapping for a Twitch `clip(slug: ...)` GQL
/// response (`TwitchGqlClient.query` with the query built in
/// `TwitchExtractor`). Kept free of any I/O so it can be exercised
/// entirely against `test/fixtures/twitch_clip_response.json`.
///
/// Live-confirmed 2026-09-05 against a real, still-existing clip
/// (`docs/plan-phase5-coverage.md` Lane D follow-up,
/// `clips.twitch.tv/AnimatedOptimisticWasabiVoteNay`) that the raw
/// (non-persisted) GQL query `TwitchExtractor` builds for this always
/// gets `clip: null` back - even a bare `{ clip(slug: "...") {
/// __typename } }` with no other fields. That is different from the VOD
/// path's `videoPlaybackAccessToken`, which works fine unauthenticated as
/// a raw query: Twitch's root `clip` field appears to be restricted to
/// registered *persisted* queries only (a known-shape anti-scraping
/// measure - silently null, not an error, for anything else). The
/// specific persisted query Twitch's own web client uses for this
/// (commonly named `VideoAccessToken_Clip` in public documentation) was
/// searched for across the clip page's own HTML and all 18 JS bundles it
/// loads on initial page load (`grep` for `VideoAccessToken_Clip` and
/// `sha256Hash`) and not found - consistent with it living in a
/// component chunk that only loads once the video player itself mounts
/// (the same lazy-loading pattern `SoundCloudClientIdResolver`'s doc
/// documents for `client_id`), which a plain page fetch does not
/// trigger. Until that hash is found (needs a browser-observed network
/// request, not a static bundle scan), `TwitchExtractor` correctly
/// surfaces `CHALLENGE_FAILED` for every clip and falls through to
/// `BrowserCaptureExtractor`. The `sourceURL` + `?sig=<signature>&
/// token=<value>` signing shape below is otherwise the long-stable,
/// widely-documented public contract every third-party Twitch clip
/// downloader uses, kept ready for once the query call itself is fixed.
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
