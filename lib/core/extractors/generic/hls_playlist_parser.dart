/// One `#EXT-X-STREAM-INF` variant from an HLS master playlist, resolved
/// to an absolute URL.
class HlsVariant {
  final String url;
  final int? bandwidth;
  final int? width;
  final int? height;

  /// This variant's own `CODECS="..."` attribute value (e.g.
  /// `avc1.4d401f,mp4a.40.2`), verbatim, or null when the attribute is
  /// absent (optional in the HLS spec). See `FormatCapabilities
  /// .videoCodecFrom`/`.audioCodecFrom` for pulling a single codec string
  /// back out of this.
  final String? codecs;

  /// This variant's `AUDIO="..."` attribute (the `#EXT-X-MEDIA` rendition
  /// group its audio comes from), or null when absent - which per the HLS
  /// spec means this variant's own media playlist already carries muxed
  /// audio, not that it has none. Only meaningful together with
  /// `HlsPlaylistParser.parseAudioRenditions`: a group id present here that
  /// has no *URI-carrying* rendition in that list still means "muxed",
  /// same as if this were null - see that method's own doc.
  final String? audioGroupId;

  const HlsVariant({
    required this.url,
    this.bandwidth,
    this.width,
    this.height,
    this.codecs,
    this.audioGroupId,
  });

  @override
  String toString() => 'HlsVariant($width x $height, ${bandwidth ?? '?'}bps, $url)';
}

/// One `#EXT-X-MEDIA:TYPE=AUDIO` alternate-audio rendition from an HLS
/// master playlist, resolved to an absolute URL. Only renditions that
/// carry their own `URI="..."` are ever turned into one of these (see
/// [HlsPlaylistParser.parseAudioRenditions]) - a rendition with no URI
/// means its audio is muxed directly into whichever variant(s) reference
/// its group, not a separately fetchable stream.
class HlsAudioRendition {
  final String groupId;
  final String uri;
  final String? name;
  final String? language;
  final bool isDefault;

  /// This rendition's own `AUTOSELECT=YES` attribute - per the HLS spec, a
  /// hint that a client with no explicit preference (no matching system
  /// language, say) should still consider selecting it automatically.
  /// [HlsMasterFormatMapper] uses it, behind [isDefault], as the second
  /// tiebreaker for which rendition in a group to emit first (`Phase 6 P6,
  /// docs/plan-phase6-av-pairing.md`): `DEFAULT=YES` outranks it, and a
  /// rendition with neither keeps whatever order it appeared in the
  /// playlist.
  final bool isAutoSelect;
  final int? channels;

  /// This rendition's `CHARACTERISTICS="..."` attribute value, verbatim
  /// (comma-separated Uniform Type Identifiers, e.g.
  /// `public.accessibility.describes-video`), or null when absent. Round 3
  /// P-R3-3 (Gadfly C4): a rendition tagged with any
  /// `public.accessibility.*` characteristic is an audio-description or
  /// hard-of-hearing track, not the track a viewer who asked for "the
  /// audio" wants - [HlsMasterFormatMapper] maps it to
  /// [MediaFormat.audioPreference] 3 so it ranks below every ordinary
  /// rendition instead of being silently picked because it happened to
  /// carry the highest bitrate or appear first.
  final String? characteristics;

  /// This rendition's `FORCED=YES` attribute. Per the HLS spec a forced
  /// rendition carries only the passages a viewer must hear (foreign
  /// dialogue in an otherwise native-language program), so it is a partial
  /// track by construction - deprioritized the same way [characteristics]
  /// accessibility tracks are (round 3 P-R3-3).
  final bool isForced;

  const HlsAudioRendition({
    required this.groupId,
    required this.uri,
    this.name,
    this.language,
    this.isDefault = false,
    this.isAutoSelect = false,
    this.channels,
    this.characteristics,
    this.isForced = false,
  });

  /// True when this rendition names at least one `public.accessibility.*`
  /// characteristic. Substring-free parsing (split on `,`, trim, compare
  /// the prefix) so a characteristic that merely *contains* that text
  /// inside a longer, unrelated identifier does not match.
  bool get isAccessibility {
    final raw = characteristics;
    if (raw == null) return false;
    return raw.split(',').map((c) => c.trim().toLowerCase()).any((c) => c.startsWith('public.accessibility.'));
  }

  @override
  String toString() => 'HlsAudioRendition($groupId, $language ?? $name, $uri)';
}

/// Pure parser for HLS playlists (no network). Per
/// `docs/plan-generic-extractor.md`'s format model: a master playlist is
/// expanded into one [HlsVariant] per `#EXT-X-STREAM-INF`; a media
/// playlist (segments only, no stream-inf tags) yields no variants and
/// the caller keeps treating the original URL as a single format.
///
/// Phase 6 adds [parseAudioRenditions] (a master's alternate-audio
/// `#EXT-X-MEDIA` renditions) and, on [HlsVariant] itself, `codecs`/
/// `audioGroupId` - both needed by `HlsMasterFormatMapper` to tell a
/// variant that only *looks* muxed (no separate audio-only sibling
/// anywhere) apart from one whose audio actually lives in a referenced
/// rendition group, which the pre-phase-6 mapping ignored entirely (see
/// `docs/plan-phase6-av-pairing.md` C1). [parseMasterVariants]'s own
/// signature is unchanged - only the class it returns gained fields.
class HlsPlaylistParser {
  const HlsPlaylistParser._();

  static final RegExp _bandwidthPattern = RegExp(r'BANDWIDTH=(\d+)');
  static final RegExp _resolutionQuotedPattern = RegExp(r'''RESOLUTION="([^"]*)"''');
  static final RegExp _resolutionBarePattern = RegExp(r'RESOLUTION=(\d+x\d+)');
  static final RegExp _codecsAttrPattern = RegExp(r'''CODECS="([^"]*)"''');
  static final RegExp _audioGroupAttrPattern = RegExp(r'''AUDIO="([^"]*)"''');

  static final RegExp _mediaTagPattern = RegExp(r'^#EXT-X-MEDIA:(.*)$', caseSensitive: false);
  static final RegExp _typeAttrPattern = RegExp(r'''TYPE=([A-Z-]+)''', caseSensitive: false);
  static final RegExp _groupIdAttrPattern = RegExp(r'''GROUP-ID="([^"]*)"''');
  static final RegExp _uriAttrPattern = RegExp(r'''URI="([^"]*)"''');
  static final RegExp _nameAttrPattern = RegExp(r'''NAME="([^"]*)"''');
  static final RegExp _languageAttrPattern = RegExp(r'''LANGUAGE="([^"]*)"''');
  static final RegExp _defaultAttrPattern = RegExp(r'''DEFAULT=(YES|NO)''', caseSensitive: false);
  static final RegExp _autoSelectAttrPattern = RegExp(r'''AUTOSELECT=(YES|NO)''', caseSensitive: false);
  // CHANNELS is quoted but its value may carry a trailing `/...` (e.g.
  // `"2/JOC"` for Dolby Atmos) - only the leading digit run is parsed, no
  // closing quote required in the pattern itself.
  static final RegExp _channelsAttrPattern = RegExp(r'''CHANNELS="(\d+)''');
  static final RegExp _characteristicsAttrPattern = RegExp(r'''CHARACTERISTICS="([^"]*)"''');
  static final RegExp _forcedAttrPattern = RegExp(r'''FORCED=(YES|NO)''', caseSensitive: false);

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
      final codecs = _codecsAttrPattern.firstMatch(attrs)?.group(1);
      final audioGroupId = _audioGroupAttrPattern.firstMatch(attrs)?.group(1);

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
      variants.add(HlsVariant(
        url: resolved.toString(),
        bandwidth: bandwidth,
        width: width,
        height: height,
        codecs: codecs,
        audioGroupId: audioGroupId,
      ));
    }

    return variants;
  }

  /// Every `#EXT-X-MEDIA:TYPE=AUDIO` rendition in [playlistText] that
  /// carries its own `URI="..."` attribute, resolved against [baseUrl]. A
  /// rendition with no `URI` is deliberately excluded - per the HLS spec
  /// that means this rendition's audio is muxed directly into the
  /// variant(s) referencing its `GROUP-ID`, not a separately downloadable
  /// stream, so there is nothing here for a caller to fetch on its own.
  static List<HlsAudioRendition> parseAudioRenditions(String playlistText, Uri baseUrl) {
    final renditions = <HlsAudioRendition>[];
    for (final rawLine in playlistText.split(RegExp(r'\r?\n'))) {
      final match = _mediaTagPattern.firstMatch(rawLine.trim());
      if (match == null) continue;
      final attrs = match.group(1)!;
      final type = _typeAttrPattern.firstMatch(attrs)?.group(1)?.toUpperCase();
      if (type != 'AUDIO') continue;

      final groupId = _groupIdAttrPattern.firstMatch(attrs)?.group(1);
      final uriRaw = _uriAttrPattern.firstMatch(attrs)?.group(1);
      if (groupId == null || uriRaw == null) continue;

      Uri resolved;
      try {
        resolved = baseUrl.resolve(uriRaw);
      } catch (_) {
        continue;
      }

      final channelsRaw = _channelsAttrPattern.firstMatch(attrs)?.group(1);
      renditions.add(HlsAudioRendition(
        groupId: groupId,
        uri: resolved.toString(),
        name: _nameAttrPattern.firstMatch(attrs)?.group(1),
        language: _languageAttrPattern.firstMatch(attrs)?.group(1),
        isDefault: _defaultAttrPattern.firstMatch(attrs)?.group(1)?.toUpperCase() == 'YES',
        isAutoSelect: _autoSelectAttrPattern.firstMatch(attrs)?.group(1)?.toUpperCase() == 'YES',
        channels: channelsRaw == null ? null : int.tryParse(channelsRaw),
        characteristics: _characteristicsAttrPattern.firstMatch(attrs)?.group(1),
        isForced: _forcedAttrPattern.firstMatch(attrs)?.group(1)?.toUpperCase() == 'YES',
      ));
    }
    return renditions;
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
