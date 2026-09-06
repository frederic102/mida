import '../browser_capture/format_capabilities.dart';
import '../media_models.dart';
import 'hls_playlist_parser.dart';

/// Shared HLS master-playlist -> [MediaFormat] mapping, used by both
/// `FormatExpander` (generic extractor) and `CapturedFormatBuilder`
/// (browser-capture) so this one piece of logic - and its one bug fix -
/// is not duplicated between those two callers (`docs/plan-phase6-av-pairing.md`,
/// C1). This is not a claim that every HLS master anywhere in the codebase
/// goes through this class: `twitch_playlist_parser.dart` parses Twitch's
/// own master shape independently and is out of this phase's scope
/// (round 2, Plumbline F8) - "shared" here means shared by the two callers
/// that opted into it, not "the sole HLS parser in this project".
///
/// Root cause this exists to fix: a master playlist whose variants split
/// audio into a separate `#EXT-X-MEDIA:TYPE=AUDIO` rendition group (video
/// muxed only with itself, real audio delivered via a *different* URL) used
/// to be exposed as one "muxed" format per variant - the pre-phase-6 code
/// parsed `#EXT-X-STREAM-INF` variants only and never looked at
/// `#EXT-X-MEDIA`/a variant's own `AUDIO="..."` attribute at all. Piping
/// that "muxed" URL straight to ffmpeg produced a video-only file every
/// time, which the post-download probe then rejected as "missing its audio
/// track" - live-caught on pinterest and ted, both HLS masters shaped
/// exactly this way.
class HlsMasterFormatMapper {
  const HlsMasterFormatMapper._();

  /// Parses [playlistText] (already confirmed by the caller to actually be
  /// an HLS playlist) and maps it the same way [formatsForVariants] does.
  /// Returns an empty list when it has no `#EXT-X-STREAM-INF` variants at
  /// all (not a master playlist) - callers keep their own existing
  /// single-format fallback for that case; this class is a pure mapper, no
  /// network/DRM/caller-specific default-format construction.
  static List<MediaFormat> formatsFor(
    String masterUrl,
    String playlistText, {
    FormatCapabilities? defaultCaps,
  }) {
    final baseUri = Uri.parse(masterUrl);
    final variants = HlsPlaylistParser.parseMasterVariants(playlistText, baseUri);
    if (variants.isEmpty) return const [];
    final audioRenditions = HlsPlaylistParser.parseAudioRenditions(playlistText, baseUri);
    return formatsForVariants(masterUrl, variants, audioRenditions, defaultCaps: defaultCaps);
  }

  /// Same mapping as [formatsFor], for a caller (`FormatExpander`) that
  /// already parsed the master text itself (and may have dropped some
  /// variants after its own per-variant DRM check) and just needs the
  /// video/audio-rendition-pairing logic run over whatever [variants] it
  /// decided to keep. Each surviving variant's id still reflects its
  /// position in [variants] (`<masterUrl>#<i>`), not a renumbered one, so a
  /// caller that filtered its own list does not need to track a separate
  /// original-index mapping.
  ///
  /// For each variant:
  /// - If its `AUDIO="..."` group references at least one rendition that
  ///   itself carries a `URI` (a real, separately-fetchable alternate audio
  ///   track - see [HlsPlaylistParser.parseAudioRenditions]), the variant is
  ///   emitted video-only (`hasAudio: false`, `videoCodec` from its own
  ///   `CODECS`), and - once per distinct group, not once per variant that
  ///   references it - one audio-only format per distinct rendition URI in
  ///   that group (`audioCodec` taken from the *referencing variant's own*
  ///   `CODECS`, since `#EXT-X-MEDIA` itself never carries a `CODECS`
  ///   attribute; id `<masterUrl>#audio:<groupId>:<n>`).
  /// - Otherwise (no audio group, or the group's renditions are all
  ///   muxed-into-the-variant with no URI of their own) behavior is exactly
  ///   what both callers already did pre-phase-6: capabilities come from
  ///   the variant's own `CODECS` when present, [defaultCaps] (each
  ///   caller's own fallback signal - browser-capture has none,
  ///   `FormatExpander` passes through the sibling-JSON `capabilities` it
  ///   was given) when `CODECS` is absent, or the safe muxed guess when
  ///   neither says anything - flagged [MediaFormat.capabilitiesUnknown] in
  ///   that last case, since nothing here actually confirmed it.
  /// [excludedAudioUris]: rendition URIs that must never get their own
  /// audio-only format emitted (a caller-side DRM check on that specific
  /// rendition playlist found it protected - `FormatExpander`'s use case).
  /// A group that had URI-carrying renditions but is left with zero
  /// *usable* ones after this filter (round 3 P-R3-1a, Gadfly C1/C2) is
  /// NOT re-read as muxed: the referencing variant is emitted
  /// `hasAudio: false, audioWasStripped: true`, regardless of what its own
  /// `CODECS` claims. Round 2 mislabeled it muxed on purpose (so
  /// `DownloadOutcomeVerifier` would expect both tracks and fail loudly),
  /// but that only held until the pipeline's own mismatch correction
  /// rewrote the flags to video-only and the selector's silent-source tier
  /// accepted the result - a silent file shipped as success, the exact
  /// regression the mislabel was meant to prevent. Marking the variant
  /// stripped instead states the truth (no audio, and not because the
  /// source is silent) and `FormatSelector` refuses to serve it from the
  /// silent tier, so the download fails loudly with no round trip through a
  /// correction that can quietly launder it. Defaults to empty: every other
  /// caller passes exactly the renditions it wants both counted and
  /// emitted.
  static List<MediaFormat> formatsForVariants(
    String masterUrl,
    List<HlsVariant> variants,
    List<HlsAudioRendition> audioRenditions, {
    FormatCapabilities? defaultCaps,
    Set<String> excludedAudioUris = const {},
  }) {
    final renditionsByGroup = <String, List<HlsAudioRendition>>{};
    for (final rendition in audioRenditions) {
      renditionsByGroup.putIfAbsent(rendition.groupId, () => []).add(rendition);
    }

    final formats = <MediaFormat>[];
    final emittedAudioGroups = <String>{};

    for (var i = 0; i < variants.length; i++) {
      final variant = variants[i];
      final groupId = variant.audioGroupId;
      final rawGroup = groupId == null ? null : renditionsByGroup[groupId];
      final videoCodec = FormatCapabilities.videoCodecFrom(variant.codecs);
      final audioCodecFromVariant = _soleAudioCodec(variant.codecs);

      // [rawGroup] alone is not enough to classify this variant video-only
      // - every one of its renditions may have just been excluded (DRM,
      // `FormatExpander`'s own per-rendition scan). [effectiveAudio] is
      // what actually gates the video-only classification below, and an
      // empty one where [rawGroup] itself was not empty is the stripped
      // case (round 3 P-R3-1a) handled right after it.
      final effectiveAudio =
          groupId == null || rawGroup == null ? const <HlsAudioRendition>[] : _effectiveRenditions(rawGroup, excludedAudioUris);

      if (groupId != null && effectiveAudio.isNotEmpty) {
        formats.add(MediaFormat(
          id: '$masterUrl#$i',
          url: variant.url,
          container: 'm3u8',
          videoCodec: videoCodec,
          width: variant.width,
          height: variant.height,
          bitrate: variant.bandwidth ?? 0,
          hasVideo: true,
          hasAudio: false,
          audioGroupId: groupId,
        ));

        if (emittedAudioGroups.add(groupId)) {
          var n = 0;
          for (final rendition in effectiveAudio) {
            formats.add(MediaFormat(
              id: '$masterUrl#audio:$groupId:$n',
              url: rendition.uri,
              container: 'm3u8',
              audioCodec: audioCodecFromVariant,
              hasVideo: false,
              hasAudio: true,
              audioGroupId: groupId,
              audioPreference: _preferenceFor(rendition),
            ));
            n++;
          }
        }
        continue;
      }

      // Round 3 P-R3-1a: the group was referenced and did carry
      // separately-fetchable renditions, but every one of them was
      // excluded. There is no audio to pair this variant with and no
      // honest way to call it muxed, so it is emitted as what it is -
      // video whose audio was stripped for a reason that is not "the
      // source is silent". `FormatSelector` will not offer it at all,
      // which is the point: the download fails loudly instead of quietly
      // producing a silent file.
      if (groupId != null && rawGroup != null && rawGroup.isNotEmpty) {
        formats.add(MediaFormat(
          id: '$masterUrl#$i',
          url: variant.url,
          container: 'm3u8',
          videoCodec: videoCodec,
          width: variant.width,
          height: variant.height,
          bitrate: variant.bandwidth ?? 0,
          hasVideo: true,
          hasAudio: false,
          audioGroupId: groupId,
          audioWasStripped: true,
        ));
        continue;
      }

      // Falls through here when there was never a real audio group to
      // begin with: either no `AUDIO=` attribute at all, or one whose
      // renditions are all muxed-into-the-variant (no `URI` of their own,
      // so `HlsPlaylistParser.parseAudioRenditions` never returned them).
      // Per the HLS spec both genuinely mean "this variant's own media
      // playlist carries the audio", so the pre-phase-6 CODECS-based
      // classification is correct here, unchanged.
      final caps = _capsFor(variant.codecs, defaultCaps);
      formats.add(MediaFormat(
        id: '$masterUrl#$i',
        url: variant.url,
        container: 'm3u8',
        videoCodec: videoCodec,
        audioCodec: audioCodecFromVariant,
        width: variant.width,
        height: variant.height,
        bitrate: variant.bandwidth ?? 0,
        hasVideo: caps.hasVideo,
        hasAudio: caps.hasAudio,
        capabilitiesUnknown: variant.codecs == null || variant.codecs!.trim().isEmpty,
      ));
    }

    return formats;
  }

  /// [group] ordered by preference ([_orderedByPreference]), then filtered
  /// down to renditions that are both not in [excludedAudioUris] and not a
  /// duplicate URI already kept earlier in that order - i.e. exactly the
  /// renditions this mapper will actually turn into a downloadable
  /// audio-only format for this group. An empty result means the group,
  /// for this caller's purposes, has no real audio left at all.
  static List<HlsAudioRendition> _effectiveRenditions(
    List<HlsAudioRendition> group,
    Set<String> excludedAudioUris,
  ) {
    final seenUris = <String>{};
    final effective = <HlsAudioRendition>[];
    for (final rendition in _orderedByPreference(group)) {
      if (excludedAudioUris.contains(rendition.uri)) continue;
      if (!seenUris.add(rendition.uri)) continue;
      effective.add(rendition);
    }
    return effective;
  }

  /// [MediaFormat.audioPreference] for one rendition: an accessibility
  /// (`public.accessibility.*` characteristic) or `FORCED=YES` rendition
  /// is 3 (round 3 P-R3-3, Gadfly C4 - a descriptive or partial track must
  /// never outrank an ordinary one, even when it is the group's
  /// `DEFAULT`), else `DEFAULT=YES` -> 0, else `AUTOSELECT=YES` -> 1, else
  /// 2. [_orderedByPreference] sorts on exactly this number, so the emit
  /// order and the value `FormatSelector` re-sorts on cannot disagree.
  static int _preferenceFor(HlsAudioRendition rendition) {
    if (rendition.isForced || rendition.isAccessibility) return 3;
    if (rendition.isDefault) return 0;
    if (rendition.isAutoSelect) return 1;
    return 2;
  }

  /// [variantCodecs]' single audio fourcc, or null when it names zero or
  /// more than one (round 3 P-R3-3). `#EXT-X-MEDIA` carries no `CODECS` of
  /// its own, so an audio-only format's codec can only be inferred from the
  /// referencing variant - and that inference is only sound when the
  /// variant names exactly one audio codec. A master whose variant lists
  /// two (`mp4a.40.2,ec-3`, one per audio group) would otherwise stamp the
  /// first one onto every rendition of every group, telling
  /// `HlsFfmpegDownloader` the wrong codec for at least one of them. Null
  /// means "unknown", which every consumer already handles.
  static String? _soleAudioCodec(String? variantCodecs) {
    if (variantCodecs == null || variantCodecs.trim().isEmpty) return null;
    final audioParts = <String>[];
    for (final part in variantCodecs.split(',')) {
      final codec = FormatCapabilities.audioCodecFrom(part);
      if (codec != null) audioParts.add(codec);
    }
    return audioParts.length == 1 ? audioParts.first : null;
  }

  /// Reorders one audio group's renditions so the one worth downloading by
  /// default is emitted first (`n=0` in its format id, and - since nothing
  /// else about these audio-only formats differentiates them for
  /// `FormatSelector` - the one a bitrate tie between them lets survive):
  /// Ascending [_preferenceFor] (0 default, 1 autoselect, 2 ordinary, 3
  /// forced/accessibility), ties keeping the playlist's own order (phase 6
  /// P6, `docs/plan-phase6-av-pairing.md`; round 3 P-R3-3 added the fourth
  /// bucket). Bucketed with `List.where` rather than `List.sort`, which
  /// Dart does not guarantee is stable, so two renditions with the same
  /// preference keep their relative playlist order.
  static List<HlsAudioRendition> _orderedByPreference(List<HlsAudioRendition> group) {
    final ordered = <HlsAudioRendition>[];
    for (var preference = 0; preference <= 3; preference++) {
      ordered.addAll(group.where((r) => _preferenceFor(r) == preference));
    }
    return ordered;
  }

  static FormatCapabilities _capsFor(String? codecs, FormatCapabilities? defaultCaps) {
    if (codecs == null || codecs.trim().isEmpty) return defaultCaps ?? FormatCapabilities.muxed;
    return FormatCapabilities.fromHlsCodecs(codecs);
  }
}
