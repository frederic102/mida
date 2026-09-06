import '../extractors/media_models.dart';
import 'manifest_xml_utils.dart';

/// What a reference found inside a manifest *is*, which decides how
/// [ManifestReferenceScanner] treats it:
///  - [playlist]: another manifest (an HLS variant, an `#EXT-X-MEDIA`
///    audio/subtitle rendition, an I-frame playlist). The scanner fetches
///    it too, so its own references get host-checked as well - a nested
///    master that only *references* a private host would otherwise hand
///    ffmpeg a URL nothing ever looked at.
///  - [leaf]: something ffmpeg opens directly and this scanner never
///    fetches (a segment, an `#EXT-X-KEY`/`#EXT-X-MAP` URI, a DASH
///    `BaseURL`/`SegmentTemplate` target).
enum ManifestReferenceKind { playlist, leaf }

class ManifestReference {
  final Uri uri;
  final ManifestReferenceKind kind;
  const ManifestReference(this.uri, this.kind);

  @override
  String toString() => '${kind.name}:$uri';
}

/// How the media segments a manifest points at are framed, which is what
/// decides whether `-bsf:a aac_adtstoasc` may be applied (phase 6 B-R4).
/// [unknown] means the manifest carried no signal either way and the
/// caller must keep its own pre-existing default.
enum SegmentFraming { unknown, transportStream, fragmentedMp4 }

extension SegmentFramingMerge on SegmentFraming {
  /// Combines the framing signals of two playlists in one scan.
  /// [fragmentedMp4] wins over [transportStream] when a scan sees both
  /// (a master with mixed variants, or a `.ts`-named CMAF segment):
  /// applying `aac_adtstoasc` to fMP4-framed audio makes ffmpeg fail
  /// outright ("Error parsing ADTS frame header"), whereas omitting it on
  /// a genuine ADTS source is the far milder direction to be wrong in.
  SegmentFraming merge(SegmentFraming other) {
    if (this == other) return this;
    if (this == SegmentFraming.fragmentedMp4 || other == SegmentFraming.fragmentedMp4) {
      return SegmentFraming.fragmentedMp4;
    }
    if (this == SegmentFraming.unknown) return other;
    if (other == SegmentFraming.unknown) return this;
    return SegmentFraming.unknown;
  }

  /// The tri-state `segmentsAreTransportStream` value
  /// `HlsFfmpegDownloader.buildArgs` already understands.
  bool? get asTransportStreamFlag => switch (this) {
        SegmentFraming.transportStream => true,
        SegmentFraming.fragmentedMp4 => false,
        SegmentFraming.unknown => null,
      };
}

class ParsedManifest {
  final List<ManifestReference> references;
  final SegmentFraming framing;

  /// Phase 6 B-R3-7: how long this one manifest says its content is -
  /// the sum of an HLS media playlist's `#EXTINF` durations, or a DASH
  /// MPD's `mediaPresentationDuration`. Null for a master playlist (it
  /// declares no timeline of its own) and for any manifest whose
  /// declaration is missing or unparseable. Purely *declared*, never
  /// measured: the caller uses it as the expected duration to verify a
  /// downloaded file against, so it must be what the source claims.
  final Duration? declaredDuration;

  const ParsedManifest(this.references, this.framing, {this.declaredDuration});
}

/// Pure text-to-references parsing for HLS playlists and DASH MPDs, split
/// out of `manifest_reference_scanner.dart` so both stay under this
/// project's 400-line cap. Does no I/O and no host checking at all: it
/// only says *what* a manifest points at, never whether any of it is
/// allowed. [ManifestReferenceScanner] owns that decision.
class ManifestReferenceWalker {
  const ManifestReferenceWalker._();

  /// Tags whose `URI="..."` is itself another playlist to walk into.
  /// `#EXT-X-MEDIA` is how an HLS master points at its alternate audio /
  /// subtitle renditions - exactly the playlists phase 6's A/V pairing
  /// makes ffmpeg open, so they must be walked, not just host-checked.
  static const _playlistUriTags = ['#EXT-X-MEDIA', '#EXT-X-I-FRAME-STREAM-INF'];

  /// Tags whose `URI="..."` is a leaf ffmpeg fetches directly. B-R4-5 adds
  /// the two LL-HLS tags: `#EXT-X-PART` (a low-latency partial segment,
  /// already fetchable on its own) and `#EXT-X-PRELOAD-HINT` (the next
  /// partial segment, advertised before it exists in full) - both carry a
  /// `URI=` a client is meant to fetch, same as a regular segment line.
  static const _leafUriTags = [
    '#EXT-X-KEY',
    '#EXT-X-MAP',
    '#EXT-X-SESSION-KEY',
    '#EXT-X-PART',
    '#EXT-X-PRELOAD-HINT',
  ];

  /// HLS attribute values are double-quoted by the spec and their
  /// contents are NOT XML-entity-encoded (an `&amp;` inside an HLS URI is
  /// a literal `&amp;`), so this stays deliberately stricter than the
  /// DASH attribute reader further down.
  static final _uriAttributePattern = RegExp(r'URI="([^"]*)"');

  static final _extinfPattern = RegExp(r'^#EXTINF:\s*(\d+(?:\.\d+)?)');

  /// Segment path suffixes that mean ISO-BMFF / CMAF framing (no ADTS, so
  /// no `aac_adtstoasc`).
  static const _fragmentedMp4Suffixes = ['.m4s', '.mp4', '.cmfa', '.cmfv', '.m4a', '.m4v'];

  /// Segment path suffixes that mean an MPEG-TS (or raw ADTS) segment -
  /// the shape `aac_adtstoasc` exists for.
  static const _transportStreamSuffixes = ['.ts', '.aac'];

  static String _stripBom(String text) => text.startsWith('\uFEFF') ? text.substring(1) : text;

  /// B-R4-4 (Codex #8): a lookalike body - an HTML error page that merely
  /// *mentions* `<MPD` somewhere in its markup, or after a login-wall
  /// banner - must not pass this check. The old `RegExp('<MPD\\b').hasMatch`
  /// scanned the WHOLE body for that substring anywhere; this instead
  /// skips only what XML actually permits before a document's root
  /// element (an `<?xml ...?>` declaration, comments, a doctype) and
  /// requires the very next real element to start with `<MPD`.
  static bool looksLikeDash(String text) {
    var s = _stripBom(text).trimLeft();
    while (true) {
      s = s.trimLeft();
      if (s.startsWith('<?')) {
        final end = s.indexOf('?>');
        if (end == -1) return false;
        s = s.substring(end + 2);
        continue;
      }
      if (s.startsWith('<!--')) {
        final end = s.indexOf('-->');
        if (end == -1) return false;
        s = s.substring(end + 3);
        continue;
      }
      if (s.startsWith('<!')) {
        // DOCTYPE or similar markup declaration.
        final end = s.indexOf('>');
        if (end == -1) return false;
        s = s.substring(end + 1);
        continue;
      }
      break;
    }
    return RegExp(r'^<MPD\b', caseSensitive: false).hasMatch(s);
  }

  /// Phase 6 B-R3-1, tightened by B-R4-4: the shape check every fetched
  /// playlist must pass before the scanner treats it as a manifest at
  /// all. A body that is neither an `#EXTM3U` playlist (its exact first
  /// line - not merely a line that starts with that prefix, which a
  /// lookalike tag like `#EXTM3UEXTRA` would also match) nor DASH XML
  /// whose first real element is `<MPD` is a captive portal, an error
  /// page, or an HTML interstitial; handing one to the parser yields "no
  /// references found", which is indistinguishable from a clean manifest
  /// and is precisely the silent pass this refuses.
  static bool looksLikeManifest(String text) {
    final head = _stripBom(text).trimLeft();
    final newline = head.indexOf('\n');
    final firstLine = (newline == -1 ? head : head.substring(0, newline)).trimRight();
    return firstLine == '#EXTM3U' || looksLikeDash(head);
  }

  /// Parses [text] (HLS or DASH, auto-detected) relative to [base].
  /// Throws `MediaExtractionException('PARSE_ERROR', ...)` for content
  /// that looks like DASH XML but has no `<MPD>` root - refusing beats
  /// reporting "nothing to check" for a manifest this could not read.
  static ParsedManifest parse(String text, Uri base) {
    final body = _stripBom(text);
    return looksLikeDash(body) ? _parseDash(body, base) : _parseHls(body, base);
  }

  static ParsedManifest _parseHls(String text, Uri base) {
    final isMaster = text.contains('#EXT-X-STREAM-INF');
    final references = <ManifestReference>[];
    var framing = SegmentFraming.unknown;
    var extinfSeconds = 0.0;
    var sawExtinf = false;

    for (final rawLine in text.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#')) {
        final extinf = _extinfPattern.firstMatch(line);
        if (extinf != null) {
          final seconds = double.tryParse(extinf.group(1)!);
          if (seconds != null) {
            sawExtinf = true;
            extinfSeconds += seconds;
          }
        }
        final isPlaylistTag = _playlistUriTags.any(line.startsWith);
        final isLeafTag = _leafUriTags.any(line.startsWith);
        if (!isPlaylistTag && !isLeafTag) continue;
        // An #EXT-X-MAP at all means fMP4/CMAF init-segment framing,
        // whatever the segment file names happen to look like.
        if (line.startsWith('#EXT-X-MAP')) framing = framing.merge(SegmentFraming.fragmentedMp4);
        final value = _uriAttributePattern.firstMatch(line)?.group(1);
        if (value == null || value.isEmpty) continue;
        _tryResolveAdd(
          references,
          base,
          value,
          isPlaylistTag ? ManifestReferenceKind.playlist : ManifestReferenceKind.leaf,
        );
        continue;
      }

      if (isMaster) {
        // A plain line under #EXT-X-STREAM-INF is a variant playlist.
        _tryResolveAdd(references, base, line, ManifestReferenceKind.playlist);
      } else {
        final before = references.length;
        _tryResolveAdd(references, base, line, ManifestReferenceKind.leaf);
        if (references.length > before) {
          framing = framing.merge(_framingOf(references.last.uri));
        }
      }
    }
    return ParsedManifest(
      references,
      framing,
      // A master carries no #EXTINF of its own; only a media playlist
      // declares a real timeline.
      declaredDuration: !isMaster && sawExtinf && extinfSeconds > 0
          ? Duration(microseconds: (extinfSeconds * Duration.microsecondsPerSecond).round())
          : null,
    );
  }

  static SegmentFraming _framingOf(Uri uri) {
    final path = uri.path.toLowerCase();
    if (_fragmentedMp4Suffixes.any(path.endsWith)) return SegmentFraming.fragmentedMp4;
    if (_transportStreamSuffixes.any(path.endsWith)) return SegmentFraming.transportStream;
    return SegmentFraming.unknown;
  }

  /// DASH references are extracted with regex rather than a real XML
  /// parser (no new dependency). Everything found is a [leaf]: an MPD
  /// does not chain into further manifests the way an HLS master does
  /// (`<Location>` is a relocation of this same MPD, not a child of it,
  /// and is treated as a leaf reference to host-check rather than walked,
  /// so a `<Location>` loop cannot drive this scanner in circles).
  static ParsedManifest _parseDash(String xml, Uri base) {
    final mpdTag = RegExp(r'<MPD\b[^>]*>', caseSensitive: false).firstMatch(xml);
    if (mpdTag == null) {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'Could not parse this DASH manifest (no <MPD> root element found); refusing rather than passing it to '
            'ffmpeg unchecked.',
      );
    }

    final references = <ManifestReference>[];
    var framing = SegmentFraming.unknown;

    void add(String? value) {
      if (value == null || value.isEmpty) return;
      _tryResolveAdd(references, base, value, ManifestReferenceKind.leaf);
    }

    for (final m in RegExp(r'<BaseURL\b[^>]*>([^<]*)</BaseURL>', caseSensitive: false).allMatches(xml)) {
      add(ManifestXmlUtils.decodeEntities(m.group(1)!.trim()));
    }
    for (final m in RegExp(r'<Location\b[^>]*>([^<]*)</Location>', caseSensitive: false).allMatches(xml)) {
      add(ManifestXmlUtils.decodeEntities(m.group(1)!.trim()));
    }
    for (final m in RegExp(r'<SegmentURL\b[^>]*>', caseSensitive: false).allMatches(xml)) {
      add(ManifestXmlUtils.attributeOf(m.group(0)!, 'media'));
      add(ManifestXmlUtils.attributeOf(m.group(0)!, 'index'));
    }
    for (final m in RegExp(r'<SegmentTemplate\b[^>]*>', caseSensitive: false).allMatches(xml)) {
      final tag = m.group(0)!;
      add(ManifestXmlUtils.attributeOf(tag, 'media'));
      final init = ManifestXmlUtils.attributeOf(tag, 'initialization');
      if (init != null) {
        // An initialization segment is the DASH equivalent of
        // #EXT-X-MAP: ISO-BMFF framing, never ADTS.
        framing = framing.merge(SegmentFraming.fragmentedMp4);
        add(init);
      }
    }
    // B-R4-5 (Codex #9): a `<SegmentBase>`-style representation declares
    // its init segment as a standalone `<Initialization sourceURL="...">`
    // element instead of `<SegmentTemplate initialization="...">` - same
    // fMP4-framing signal, different spelling.
    for (final m in RegExp(r'<Initialization\b[^>]*>', caseSensitive: false).allMatches(xml)) {
      final source = ManifestXmlUtils.attributeOf(m.group(0)!, 'sourceURL');
      if (source != null) {
        framing = framing.merge(SegmentFraming.fragmentedMp4);
        add(source);
      }
    }
    final contentProtectionPattern = RegExp(
      r'<ContentProtection\b.*?(?:/>|</ContentProtection>)',
      caseSensitive: false,
      dotAll: true,
    );
    final urlInTextPattern = RegExp(r'''https?://[^\s"'<>]+''');
    for (final m in contentProtectionPattern.allMatches(xml)) {
      for (final urlMatch in urlInTextPattern.allMatches(ManifestXmlUtils.decodeEntities(m.group(0)!))) {
        add(urlMatch.group(0)!);
      }
    }

    for (final reference in references) {
      framing = framing.merge(_framingOf(reference.uri));
    }
    return ParsedManifest(
      references,
      framing,
      declaredDuration: _dashDeclaredDuration(xml, mpdTag.group(0)!),
    );
  }

  /// B-R4-7 (Gadfly round 3 extension): scoped to the `<Period>`s this MPD
  /// actually declares rather than always trusting the MPD-wide
  /// `mediaPresentationDuration` - a multi-period MPD's overall figure can
  /// disagree with what a single-period download of it actually produces.
  /// When every `<Period>` states its own `duration`, their sum is exactly
  /// what will be downloaded; only when that signal is incomplete (a
  /// period missing a duration, or none at all) does this fall back to the
  /// MPD-level value.
  static Duration? _dashDeclaredDuration(String xml, String mpdTag) {
    final periodDurations = <Duration>[];
    var everyPeriodDeclaresDuration = true;
    for (final m in RegExp(r'<Period\b[^>]*>', caseSensitive: false).allMatches(xml)) {
      final duration = ManifestXmlUtils.parseIso8601Duration(ManifestXmlUtils.attributeOf(m.group(0)!, 'duration'));
      if (duration == null) {
        everyPeriodDeclaresDuration = false;
      } else {
        periodDurations.add(duration);
      }
    }
    if (periodDurations.isNotEmpty && everyPeriodDeclaresDuration) {
      return periodDurations.reduce((a, b) => a + b);
    }
    return ManifestXmlUtils.parseIso8601Duration(ManifestXmlUtils.attributeOf(mpdTag, 'mediaPresentationDuration'));
  }

  static void _tryResolveAdd(
    List<ManifestReference> list,
    Uri base,
    String value,
    ManifestReferenceKind kind,
  ) {
    try {
      list.add(ManifestReference(base.resolve(value), kind));
    } catch (_) {
      // Not a valid URI reference; ignore rather than fail the whole scan.
    }
  }
}
