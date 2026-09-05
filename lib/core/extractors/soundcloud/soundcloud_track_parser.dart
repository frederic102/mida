import '../media_models.dart';

typedef SoundCloudTranscoding = ({String url, String protocol, String? mimeType, bool isHls});

typedef SoundCloudTrackInfo = ({
  String id,
  String title,
  String? author,
  String? artworkUrl,
  Duration? duration,
  List<SoundCloudTranscoding> transcodings,
});

/// Pure JSON -> [SoundCloudTrackInfo] mapping for a track object returned
/// by `api-v2.soundcloud.com/resolve` (the direct track JSON - not
/// wrapped in the page's `__sc_hydration` array, which SoundCloud's
/// current web client no longer server-renders track data into; see
/// `SoundCloudExtractor`'s doc). Kept free of any I/O so it can be
/// exercised entirely against `test/fixtures/soundcloud_resolve_track.json`
/// (captured live 2026-09-05 via a real `resolve` call,
/// `docs/plan-phase5-coverage.md` Lane D follow-up).
class SoundCloudTrackParser {
  const SoundCloudTrackParser();

  /// Throws [MediaExtractionException] (`UNSUPPORTED_MEDIA`) when
  /// `media.transcodings` is empty - a track still processing server-side,
  /// or one this account has no listening rights for at all (distinct
  /// from a "snipped"/preview-only transcoding, which is still playable
  /// and not an error here - SoundCloud gates the *content* to a 30s
  /// preview for unlicensed tracks, not the API response).
  SoundCloudTrackInfo parse(Map<String, dynamic> track) {
    final transcodings = _parseTranscodings(track['media']);
    if (transcodings.isEmpty) {
      throw const MediaExtractionException(
        'UNSUPPORTED_MEDIA',
        'SoundCloud returned no playable renditions for this track.',
      );
    }

    final user = track['user'];
    return (
      id: '${track['id'] ?? ''}',
      title: track['title'] as String? ?? 'Untitled',
      author: user is Map ? user['username'] as String? : null,
      artworkUrl: track['artwork_url'] as String?,
      duration: _durationFromMillis(track['full_duration'] ?? track['duration']),
      transcodings: transcodings,
    );
  }

  List<SoundCloudTranscoding> _parseTranscodings(dynamic media) {
    if (media is! Map) return const [];
    final list = media['transcodings'];
    if (list is! List) return const [];

    final result = <SoundCloudTranscoding>[];
    for (final entry in list) {
      if (entry is! Map) continue;
      final url = entry['url'] as String?;
      if (url == null) continue;
      final format = entry['format'];
      final protocol = format is Map ? format['protocol'] as String? ?? 'progressive' : 'progressive';
      final mimeType = format is Map ? format['mime_type'] as String? : null;
      result.add((url: url, protocol: protocol, mimeType: mimeType, isHls: protocol == 'hls'));
    }

    // Progressive (plain mp3, a single ranged-GET-able file) first, HLS
    // last: a progressive rendition is simpler to download and this app
    // prefers it when both are offered for the same track.
    result.sort((a, b) => (a.isHls ? 1 : 0) - (b.isHls ? 1 : 0));
    return result;
  }

  Duration? _durationFromMillis(dynamic raw) {
    if (raw is int) return Duration(milliseconds: raw);
    if (raw is num) return Duration(milliseconds: raw.toInt());
    return null;
  }
}
