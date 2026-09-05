import '../media_models.dart';

/// Pure text -> [MediaFormat] mapping for a Twitch "usher" HLS master
/// playlist (`https://usher.ttvnw.net/vod/<id>.m3u8?...`). Kept free of any
/// I/O so it can be exercised entirely against
/// `test/fixtures/twitch_usher_master.m3u8` (captured live 2026-09-05,
/// `docs/plan-phase5-coverage.md` Lane D, from a real public VOD).
///
/// Twitch's usher response is a master playlist listing one
/// `#EXT-X-STREAM-INF` + media-playlist-URL pair per available rendition
/// (`chunked`/source, `720p60`, `480p30`, ...), each of which is itself a
/// playable HLS media playlist (already muxed video+audio, single
/// `CODECS` string covering both `avc1...` and `mp4a...`). This parser
/// turns each pair into its own `MediaFormat` (container `m3u8`) rather
/// than returning the master playlist as one opaque format, so the app's
/// quality picker has real resolutions to choose from - the same reasoning
/// `NaverVodPlayParser`'s doc comment gives for why it does per-rendition
/// parsing instead of handing back one manifest.
class TwitchPlaylistParser {
  const TwitchPlaylistParser();

  static final _streamInfPattern = RegExp(
    r'#EXT-X-STREAM-INF:([^\n]*)\n(\S+)',
  );
  static final _resolutionPattern = RegExp(r'RESOLUTION=(\d+)x(\d+)');
  static final _bandwidthPattern = RegExp(r'BANDWIDTH=(\d+)');
  static final _codecsPattern = RegExp(r'CODECS="([^"]*)"');
  static final _nameAttrPattern = RegExp(r'NAME="([^"]*)"');
  static final _frameRatePattern = RegExp(r'FRAME-RATE=([\d.]+)');

  /// Throws [MediaExtractionException] (`UNSUPPORTED_MEDIA`) when the
  /// playlist has no `#EXT-X-STREAM-INF` entries at all - a DRM-only or
  /// subscriber-only VOD usher sometimes returns an otherwise-empty
  /// playlist for rather than an HTTP error.
  List<MediaFormat> parse(String playlistText) {
    final formats = <MediaFormat>[];
    for (final match in _streamInfPattern.allMatches(playlistText)) {
      final attrs = match.group(1)!;
      final url = match.group(2)!;

      final resolution = _resolutionPattern.firstMatch(attrs);
      final width = resolution != null ? int.tryParse(resolution.group(1)!) : null;
      final height = resolution != null ? int.tryParse(resolution.group(2)!) : null;
      final bandwidth = _bandwidthPattern.firstMatch(attrs);
      final codecs = _codecsPattern.firstMatch(attrs)?.group(1);
      final name = _nameAttrPattern.firstMatch(attrs)?.group(1);
      final fps = _frameRatePattern.firstMatch(attrs);

      final codecParts = codecs?.split(',').map((s) => s.trim()).toList() ?? const <String>[];
      final videoCodec = codecParts.where((c) => c.startsWith('avc1') || c.startsWith('av01')).firstOrNull;
      final audioCodec = codecParts.where((c) => c.startsWith('mp4a')).firstOrNull;

      formats.add(MediaFormat(
        id: name ?? '${width ?? 0}x${height ?? 0}',
        url: url,
        container: 'm3u8',
        videoCodec: videoCodec,
        audioCodec: audioCodec,
        width: width,
        height: height,
        fps: fps != null ? double.tryParse(fps.group(1)!) : null,
        bitrate: bandwidth != null ? int.tryParse(bandwidth.group(1)!) ?? 0 : 0,
        hasVideo: true,
        hasAudio: true,
      ));
    }

    if (formats.isEmpty) {
      throw const MediaExtractionException(
        'UNSUPPORTED_MEDIA',
        'Twitch returned no playable renditions for this video (it may be '
            'subscriber-only or DRM-protected).',
      );
    }
    return formats;
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
