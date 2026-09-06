/// Whether a format carries video, audio, or both.
class FormatCapabilities {
  final bool hasVideo;
  final bool hasAudio;

  const FormatCapabilities({required this.hasVideo, required this.hasAudio});

  /// The safe assumption when nothing more specific is known: a plain
  /// `video/*` response, or a manifest with no per-variant codec info at
  /// all. The pipeline verifies the real answer with ffprobe once a
  /// format is actually selected, so this only needs to be a reasonable
  /// prior, not a guarantee.
  static const muxed = FormatCapabilities(hasVideo: true, hasAudio: true);

  static const audioOnly = FormatCapabilities(hasVideo: false, hasAudio: true);

  /// From a `Network.responseReceived` mimeType: `audio/*` is audio-only,
  /// everything else (including `video/*`, HLS/DASH manifest mimes, and
  /// unknown/absent mimeType) assumes [muxed].
  factory FormatCapabilities.fromMimeType(String? mimeType) {
    if (mimeType != null && mimeType.toLowerCase().startsWith('audio/')) return audioOnly;
    return muxed;
  }

  static const List<String> _videoCodecPrefixes = ['avc1', 'avc3', 'hvc1', 'hev1', 'av01', 'vp09', 'vp08', 'vp8'];
  static const List<String> _audioCodecPrefixes = ['mp4a', 'ac-3', 'ec-3', 'opus', 'vorbis', 'flac', 'alac'];

  /// From an HLS master playlist variant's `CODECS="..."` attribute value
  /// (e.g. `avc1.4d401f,mp4a.40.2`). Null/empty (attribute absent, or this
  /// variant's index has no match) falls back to [muxed] - the attribute
  /// is optional in the HLS spec and plenty of real playlists omit it.
  factory FormatCapabilities.fromHlsCodecs(String? codecsAttribute) {
    if (codecsAttribute == null || codecsAttribute.trim().isEmpty) return muxed;
    final parts = codecsAttribute.split(',').map((c) => c.trim().toLowerCase()).toList();
    final hasVideo = parts.any((c) => _videoCodecPrefixes.any(c.startsWith));
    final hasAudio = parts.any((c) => _audioCodecPrefixes.any(c.startsWith));
    // A CODECS value listing only e.g. a subtitle/unknown codec fourcc
    // (neither list matches) is not enough to positively assert "no
    // audio" - fall back to the safe default rather than produce a
    // format flagged as having neither.
    if (!hasVideo && !hasAudio) return muxed;
    return FormatCapabilities(hasVideo: hasVideo, hasAudio: hasAudio);
  }

  /// The first `CODECS="..."` entry naming a recognized video fourcc
  /// (verbatim, e.g. `avc1.4d401f`, not just the matched prefix), or null
  /// when [codecsAttribute] is absent or names no video codec. Used to
  /// populate [MediaFormat.videoCodec] for an HLS variant so
  /// `FormatSelector`'s strict adaptive-pair tier (which requires a
  /// non-null codec starting with `avc1`/`hvc1`/`av01`/... to consider a
  /// pairing "natively compatible") can actually match one - phase 6
  /// (`docs/plan-phase6-av-pairing.md`) trap 1.
  static String? videoCodecFrom(String? codecsAttribute) => _firstMatching(codecsAttribute, _videoCodecPrefixes);

  /// Same as [videoCodecFrom] but for an audio fourcc
  /// (`mp4a`/`ac-3`/`ec-3`/`opus`/`vorbis`/`flac`/`alac`).
  static String? audioCodecFrom(String? codecsAttribute) => _firstMatching(codecsAttribute, _audioCodecPrefixes);

  static String? _firstMatching(String? codecsAttribute, List<String> prefixes) {
    if (codecsAttribute == null || codecsAttribute.trim().isEmpty) return null;
    for (final part in codecsAttribute.split(',').map((c) => c.trim())) {
      if (part.isEmpty) continue;
      if (prefixes.any((p) => part.toLowerCase().startsWith(p))) return part;
    }
    return null;
  }
}
