/// One `#EXT-X-STREAM-INF` variant from an HLS master playlist, resolved
/// to an absolute URL.
class HlsVariant {
  final String url;
  final int? bandwidth;
  final int? width;
  final int? height;

  const HlsVariant({required this.url, this.bandwidth, this.width, this.height});

  @override
  String toString() => 'HlsVariant($width x $height, ${bandwidth ?? '?'}bps, $url)';
}

/// Pure parser for HLS playlists (no network). Per
/// `docs/plan-generic-extractor.md`'s format model: a master playlist is
/// expanded into one [HlsVariant] per `#EXT-X-STREAM-INF`; a media
/// playlist (segments only, no stream-inf tags) yields no variants and
/// the caller keeps treating the original URL as a single format.
class HlsPlaylistParser {
  const HlsPlaylistParser._();

  static final RegExp _bandwidthPattern = RegExp(r'BANDWIDTH=(\d+)');
  static final RegExp _resolutionQuotedPattern = RegExp(r'''RESOLUTION="([^"]*)"''');
  static final RegExp _resolutionBarePattern = RegExp(r'RESOLUTION=(\d+x\d+)');

  /// Returns the resolved variant URLs from a master [playlistText], or an
  /// empty list if it is not a master playlist (no `#EXT-X-STREAM-INF`
  /// tag present).
  static List<HlsVariant> parseMasterVariants(String playlistText, Uri baseUrl) {
    if (!playlistText.contains('#EXT-X-STREAM-INF')) return const [];

    final lines = playlistText.split(RegExp(r'\r?\n'));
    final variants = <HlsVariant>[];

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF')) continue;

      final attrs = line.substring(line.indexOf(':') + 1);
      final bandwidth = _intAttr(_bandwidthPattern, attrs);
      final resolution = _resolutionAttr(attrs);
      int? width;
      int? height;
      if (resolution != null) {
        final parts = resolution.split('x');
        if (parts.length == 2) {
          width = int.tryParse(parts[0]);
          height = int.tryParse(parts[1]);
        }
      }

      String? uriLine;
      var nextIndex = i;
      for (var j = i + 1; j < lines.length; j++) {
        final candidate = lines[j].trim();
        if (candidate.isEmpty || candidate.startsWith('#')) continue;
        uriLine = candidate;
        nextIndex = j;
        break;
      }
      if (uriLine == null) continue;
      i = nextIndex;

      Uri resolved;
      try {
        resolved = baseUrl.resolve(uriLine);
      } catch (_) {
        continue;
      }
      variants.add(HlsVariant(url: resolved.toString(), bandwidth: bandwidth, width: width, height: height));
    }

    return variants;
  }

  static int? _intAttr(RegExp pattern, String attrs) {
    final match = pattern.firstMatch(attrs);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  static String? _resolutionAttr(String attrs) {
    final quoted = _resolutionQuotedPattern.firstMatch(attrs);
    if (quoted != null) return quoted.group(1);
    return _resolutionBarePattern.firstMatch(attrs)?.group(1);
  }
}
