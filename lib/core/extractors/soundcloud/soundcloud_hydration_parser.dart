import '../media_models.dart';

/// The pieces of a SoundCloud track's `__sc_hydration` payload
/// [SoundCloudHydrationParser] reads out, before each transcoding URL is
/// resolved (a second HTTP GET with `?client_id=`,
/// `SoundCloudExtractor._resolveTranscoding`) into an actual playable CDN
/// URL.
typedef SoundCloudTranscoding = ({String url, String protocol, String? mimeType, bool isHls});

typedef SoundCloudTrackInfo = ({
  String id,
  String title,
  String? author,
  String? artworkUrl,
  Duration? duration,
  List<SoundCloudTranscoding> transcodings,
});

/// Pure JSON -> [SoundCloudTrackInfo] mapping for the `__sc_hydration`
/// array embedded in a SoundCloud track page
/// (`window.__sc_hydration = [...]`, one entry per widget on the page;
/// the track itself is the entry with `hydratable: "sound"`). Kept free
/// of any I/O so it can be exercised entirely against
/// `test/fixtures/soundcloud_hydration.json`.
class SoundCloudHydrationParser {
  const SoundCloudHydrationParser();

  /// Throws [MediaExtractionException] (`PARSE_ERROR`) when no `"sound"`
  /// entry is present at all. Verified live 2026-09-05
  /// (`docs/plan-phase5-coverage.md` Lane D report): a real track page's
  /// `__sc_hydration` only carried app-shell entries (`anonymousId`,
  /// `apiClient`, `features`, `geoip`, `privacySettings`,
  /// `statsigClientInitializeResponse`, `trackingBrowserTabId`) with no
  /// `"sound"` entry at all - the track itself is fetched client-side
  /// after the page loads, not server-rendered, for this SoundCloud
  /// version. That is a technique failure (this extractor's core
  /// assumption - that the track is in the initial HTML - no longer
  /// holds), not "this URL has no track", so it is deliberately
  /// `PARSE_ERROR` (fall-through eligible in `ExtractorRegistry`) rather
  /// than the terminal `NOT_FOUND` an earlier version of this parser used
  /// (which would have wrongly blocked `BrowserCaptureExtractor`, a real
  /// browser that can run the page's JS and fetch the real track data,
  /// from ever getting a chance at this URL).
  ///
  /// (`UNSUPPORTED_MEDIA`) when the track exists but `media.transcodings`
  /// is empty (rare, but happens for a track still processing/
  /// transcoding server-side).
  SoundCloudTrackInfo parse(List<dynamic> hydration) {
    Map<String, dynamic>? sound;
    for (final entry in hydration) {
      if (entry is Map && entry['hydratable'] == 'sound') {
        final data = entry['data'];
        if (data is Map<String, dynamic>) sound = data;
      }
    }

    if (sound == null) {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'MiDa could not find track data on this SoundCloud page.',
      );
    }

    final transcodings = _parseTranscodings(sound['media']);
    if (transcodings.isEmpty) {
      throw const MediaExtractionException(
        'UNSUPPORTED_MEDIA',
        'SoundCloud returned no playable renditions for this track.',
      );
    }

    final user = sound['user'];
    return (
      id: '${sound['id'] ?? ''}',
      title: sound['title'] as String? ?? 'Untitled',
      author: user is Map ? user['username'] as String? : null,
      artworkUrl: sound['artwork_url'] as String?,
      duration: _durationFromMillis(sound['duration']),
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
      result.add((
        url: url,
        protocol: protocol,
        mimeType: mimeType,
        isHls: protocol == 'hls',
      ));
    }
    return result;
  }

  Duration? _durationFromMillis(dynamic raw) {
    if (raw is int) return Duration(milliseconds: raw);
    if (raw is num) return Duration(milliseconds: raw.toInt());
    return null;
  }
}
