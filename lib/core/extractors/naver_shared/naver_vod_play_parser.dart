import '../media_models.dart';

/// Pure JSON -> [MediaFormat] mapping for a response from Naver's shared
/// VOD playback backend (`apis.naver.com/rmcnmv/rmcnmv/vod/play/v2.0/{vid}`),
/// used by both `tv.naver.com` (Naver TV) and `chzzk.naver.com` (CHZZK VOD):
/// both platforms resolve their own front-end video id + `inKey` pair down
/// to the same underlying `videoId`/`inKey` this endpoint takes, and both
/// were observed live 2026-09-05 to return the identical `videos.list[]`
/// shape (`docs/plan-phase5-coverage.md` Lane C). Kept free of any I/O so
/// it can be exercised entirely against `test/fixtures/naver_vod_play_v2.json`
/// (captured from a live Naver TV clip; a separately captured CHZZK
/// response was byte-for-byte the same shape).
///
/// Only `videos.list[]` (progressive, already-muxed mp4 renditions) is
/// read, not the sibling `streams[]` (HLS master playlists also present in
/// the same response): every rendition in `videos.list[]` was verified
/// live to answer a ranged GET with `206 Partial Content`
/// (`docs/plan-phase5-coverage.md` Lane C DONE bar), which is exactly what
/// `MediaFormat`'s default `https` protocol assumes; adding the HLS
/// variants too would need `container: 'm3u8'` (a second download path
/// through ffmpeg) for renditions that already have a working simpler one.
class NaverVodPlayParser {
  const NaverVodPlayParser();

  /// Returns one [MediaFormat] per entry in `videos.list[]` with a
  /// non-empty `source`. Malformed or missing `videos`/`list` (any shape
  /// other than the expected object/array) yields an empty list rather
  /// than throwing - the caller (`NaverVodPlayClient`) is the one that
  /// decides an empty result means `NO_MEDIA_FOUND`, since "this response
  /// had no renditions" and "this response could not be read at all" are
  /// both represented the same way here on purpose (there is nothing
  /// downloadable either way).
  List<MediaFormat> parseFormats(Map<String, dynamic> json) {
    final videos = json['videos'];
    if (videos is! Map) return const [];
    final list = videos['list'];
    if (list is! List) return const [];

    final formats = <MediaFormat>[];
    for (final entry in list) {
      if (entry is! Map) continue;
      final source = entry['source'];
      if (source is! String || source.isEmpty) continue;

      final encodingOption = entry['encodingOption'];
      final width = encodingOption is Map ? _asInt(encodingOption['width']) : null;
      final height = encodingOption is Map ? _asInt(encodingOption['height']) : null;
      final encodingId = encodingOption is Map ? encodingOption['id'] as String? : null;

      final bitrateMap = entry['bitrate'];
      final videoKbps = bitrateMap is Map ? _asInt(bitrateMap['video']) ?? 0 : 0;
      final audioKbps = bitrateMap is Map ? _asInt(bitrateMap['audio']) ?? 0 : 0;

      formats.add(MediaFormat(
        id: encodingId ?? entry['id'] as String? ?? source,
        url: source,
        container: 'mp4',
        width: width,
        height: height,
        // The API reports bitrate in kbps; MediaFormat.bitrate is bits per
        // second (see media_models.dart), so the sum of the two streams
        // (this backend always serves progressive, pre-muxed mp4 - see
        // hasVideo/hasAudio below) is scaled by 1000.
        bitrate: (videoKbps + audioKbps) * 1000,
        contentLength: _asInt(entry['size']),
        // Every rendition `videos.list[]` returns from this backend is a
        // single progressive mp4 file with both tracks muxed in - verified
        // live for both Naver TV and CHZZK (`docs/plan-phase5-coverage.md`
        // Lane C); there is no video-only/audio-only split to represent.
        hasVideo: true,
        hasAudio: true,
      ));
    }
    return formats;
  }

  int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
