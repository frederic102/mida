import '../../features/download/services/download_service_io.dart';
import 'media_models.dart';

/// Result of running [FormatSelector.select] against a [MediaInfo]. Either
/// [video] + [audio] are both set (adaptive pair to be merged), or [muxed]
/// is set alone (single file, already has both streams), or everything is
/// null (nothing matched, caller should surface an error).
///
/// [videoNeedsTranscode]/[audioNeedsTranscode] are only ever true together
/// with an adaptive pair: they mean the selector could not find a pair
/// whose codecs natively fit the target container (and no muxed fallback
/// existed either), so it picked the best it could and the merger must
/// transcode that half instead of blindly `-c copy`-ing an incompatible
/// codec into the container.
class SelectedFormats {
  final MediaFormat? video;
  final MediaFormat? audio;
  final MediaFormat? muxed;
  final bool videoNeedsTranscode;
  final bool audioNeedsTranscode;

  /// True only for an audio download whose [audio] format is not actually
  /// audio-only: X, TikTok, Instagram and most generic sites never offer a
  /// dedicated audio-only stream, so [FormatSelector] falls back to the
  /// best muxed (or HLS/DASH) format instead. The pipeline downloads that
  /// format the same way it would for a video request, then runs ffmpeg
  /// `-vn` on it to pull just the audio track out - this flag exists so
  /// callers/tests can tell that fallback happened, not to change how the
  /// pipeline downloads (it already always runs `-vn` for an audio
  /// request, muxed source or not).
  final bool needsAudioExtraction;

  const SelectedFormats({
    this.video,
    this.audio,
    this.muxed,
    this.videoNeedsTranscode = false,
    this.audioNeedsTranscode = false,
    this.needsAudioExtraction = false,
  });

  bool get isEmpty => video == null && audio == null && muxed == null;
  bool get isAdaptivePair => video != null && audio != null;

  /// True when a successful download of this candidate is expected to
  /// contain both a video and an audio stream - used by
  /// `MediaDownloadPipeline`'s post-download sanity probe to decide
  /// whether a missing stream type means the source was mislabeled (e.g.
  /// a video-only DASH rendition that reported itself as muxed) versus
  /// "the source genuinely has no audio" (a muted/silent video, where
  /// [muxed] itself is a video-only [MediaFormat] - see
  /// [FormatSelector._rankVideo]'s silent-source fallback - and there was
  /// never an audio track to be missing). A pure audio candidate
  /// (`needsAudioExtraction` or a real audio-only stream) deliberately
  /// ends up audio-only after ffmpeg's `-vn`, so it is not held to this
  /// expectation either.
  bool get expectsVideoAndAudio {
    if (muxed != null) return muxed!.hasVideo && muxed!.hasAudio;
    return isAdaptivePair;
  }
}

/// Pure selection logic: given the formats a [MediaInfo] offers and the
/// user's [DownloadOptions], ranks every viable candidate best-first. No
/// I/O. [select] (kept for callers that only want the top pick) is just
/// `rank(...).firstOrElse(const SelectedFormats())`.
///
/// Ranking (not just picking one) exists so `MediaDownloadPipeline` can
/// retry with the next candidate when the top pick's actual bytes turn out
/// to be broken (a mislabeled/DRM playlist, a codec ffmpeg cannot merge,
/// ...) instead of failing the whole download outright even though other
/// viable renditions existed.
class FormatSelector {
  const FormatSelector();

  static const _mp4VideoCodecs = ['avc1', 'av01'];
  static const _webmVideoCodecs = ['vp9', 'vp09', 'av01'];

  SelectedFormats select(MediaInfo info, DownloadType type, DownloadOptions options) {
    final ranked = rank(info, type, options);
    return ranked.isEmpty ? const SelectedFormats() : ranked.first;
  }

  /// Best-first candidate list. Tiers are flattened into one list (rather
  /// than gating on "did the previous tier find nothing") so a lower tier
  /// is still available as a retry fallback even when a higher tier's top
  /// pick exists but turns out to be unusable: `.first` always equals what
  /// the old tier-gated `select()` returned, so this is a strict
  /// generalization, not a behavior change for the success path.
  List<SelectedFormats> rank(MediaInfo info, DownloadType type, DownloadOptions options) {
    if (type == DownloadType.audio) {
      return _rankAudio(info.formats, options);
    }
    return _rankVideo(info.formats, options);
  }

  /// Tier 1: every dedicated audio-only stream (round 2 P-R8, Gadfly#6b:
  /// not just the single best one - a broken/unreachable top pick should
  /// still leave the next-best audio-only rendition available as a retry
  /// candidate), ranked by [MediaFormat.audioPreference] ascending then
  /// bitrate descending. Tier 2: every muxed `https` format, smallest first
  /// (video is discarded, so there is no reason to download more of it than
  /// necessary). Tier 3: every muxed HLS/DASH format, smallest first (also
  /// muxed by construction: `GenericExtractor`/`BrowserCaptureExtractor`
  /// never split an HLS/DASH stream into separate video-only/audio-only
  /// formats). Tiers 2 and 3 both flag [SelectedFormats.needsAudioExtraction].
  List<SelectedFormats> _rankAudio(List<MediaFormat> formats, DownloadOptions options) {
    final candidates = <SelectedFormats>[];

    for (final audio in _rankAudioCandidates(formats.where((f) => f.isAudioOnly).toList())) {
      candidates.add(SelectedFormats(audio: audio));
    }

    for (final muxed in _rankSmallestMuxed(formats.where((f) => f.protocol == 'https'))) {
      candidates.add(SelectedFormats(audio: muxed, needsAudioExtraction: true));
    }
    for (final muxed in _rankSmallestMuxed(formats.where((f) => f.protocol != 'https'))) {
      candidates.add(SelectedFormats(audio: muxed, needsAudioExtraction: true));
    }

    return candidates;
  }

  /// Ascending ranking (smallest first) among muxed [formats] - the
  /// opposite ordering from [_rankByHeightThenBitrate], which prefers the
  /// tallest/highest-bitrate for video requests, where quality is the
  /// point; here every extra pixel is bytes wasted on a stream that gets
  /// thrown away.
  List<MediaFormat> _rankSmallestMuxed(Iterable<MediaFormat> formats) {
    final candidates = formats.where((f) => f.isMuxed).toList();
    if (candidates.isEmpty) return const [];

    final withHeight = candidates.where((f) => f.height != null).toList()
      ..sort((a, b) {
        final byHeight = a.height!.compareTo(b.height!);
        return byHeight != 0 ? byHeight : a.bitrate.compareTo(b.bitrate);
      });
    final withoutHeight = candidates.where((f) => f.height == null).toList()
      ..sort((a, b) => a.bitrate.compareTo(b.bitrate));

    return [...withHeight, ...withoutHeight];
  }

  /// Ranked candidates a retry loop may try, in order, before giving up on
  /// pairing this [groupId] entirely (round 2 P-R3, Codex#1: siblings from
  /// the same HLS master used to monopolize every attempt because only the
  /// single best pair was ever offered - now several are, so a mislabeled
  /// or unreachable top pick still leaves other real pairs to fall back to).
  static const int _maxPairsPerTier = 6;

  /// How many pairs are offered before the muxed tier is interleaved
  /// (round 3 P-R3-2, tightened per Codex round-3 #4). The pipeline's
  /// `maxAttempts` is 3, so the first muxed candidate must sit at index 2
  /// at the latest to be reachable by a download that gets no
  /// corrections: two pairs, then the best muxed rendition, then the rest.
  /// Coupled to `MediaDownloadPipeline.maxAttempts` (3): see the comment
  /// there before changing either.
  static const int _pairsBeforeMuxed = 2;

  /// Tier 1: strict adaptive pairs (codecs natively fit the target
  /// container), every video-only x its own group's audio-only candidate,
  /// ranked video-first then audio-first, capped at [_maxPairsPerTier].
  /// Tier 2: every muxed format, tallest/best-bitrate first (a pre-muxed
  /// file, which the source itself packaged, is a safer retry than a
  /// codec-mismatched merge). Tier 3: loose adaptive pairs (flagged for
  /// transcode), same enumeration as tier 1 but without the codec filter,
  /// only offered when tiers 1-2 found nothing at all. Tier 4 (silent
  /// source, [_rankSilentSource]): when nothing above matched *and* the
  /// source has no audio anywhere (a muted video, e.g. a silent Instagram
  /// reel - extractors report `hasAudio: false` honestly rather than lying
  /// about it), the best video-only rendition that is not
  /// [MediaFormat.audioWasStripped] is offered directly as
  /// [SelectedFormats.muxed]: there is no audio to pair it with, but that
  /// does not make the video undownloadable.
  List<SelectedFormats> _rankVideo(List<MediaFormat> formats, DownloadOptions options) {
    final maxHeight = _heightCap(options.videoQuality);
    final container = options.videoFormat;
    final candidates = <SelectedFormats>[];

    // Round 3 P-R3-2 (Codex#10): muxed candidates are interleaved after the
    // first [_pairsBeforeMuxed] pairs rather than queued behind all of
    // them. A master that offers six viable pairs used to spend every
    // retry the pipeline has on pairs alone, so a source-side problem
    // affecting the whole alternate-audio group (a dead rendition host,
    // say) never reached the pre-muxed rendition that would have worked.
    // The top pick is unchanged: pairs still lead the list.
    final pairs = _rankPairs(formats, maxHeight: maxHeight, container: container, strict: true);
    final leadingPairs = pairs.length <= _pairsBeforeMuxed ? pairs : pairs.sublist(0, _pairsBeforeMuxed);
    candidates.addAll(leadingPairs);

    for (final muxed in _rankMuxed(formats, maxHeight: maxHeight)) {
      candidates.add(SelectedFormats(muxed: muxed));
    }

    if (pairs.length > leadingPairs.length) {
      candidates.addAll(pairs.sublist(leadingPairs.length));
    }

    if (candidates.isEmpty) {
      candidates.addAll(_rankPairs(formats, maxHeight: maxHeight, container: container, strict: false));
    }

    if (candidates.isEmpty) {
      candidates.addAll(_rankSilentSource(formats, maxHeight: maxHeight, container: container));
    }

    return candidates;
  }

  /// Tier 4, the silent-source fallback: only when the source claims no
  /// audio anywhere (an honestly muted video) *and* the video-only format
  /// offered is not one whose audio is known to have been stripped
  /// (round 3 P-R3-1c). [MediaFormat.audioWasStripped] marks exactly the
  /// two cases this tier must refuse - an HLS variant whose entire audio
  /// rendition group was excluded, and a format the pipeline itself
  /// corrected to video-only after ffprobe found the audio it claimed
  /// missing. Serving either from here is how a video the user expects to
  /// have sound gets saved as a silent file and reported as success; with
  /// both refused, every candidate is exhausted and the download fails
  /// loudly instead.
  List<SelectedFormats> _rankSilentSource(
    List<MediaFormat> formats, {
    required int? maxHeight,
    required VideoFormat container,
  }) {
    if (formats.any((f) => f.hasAudio)) return const [];
    final pool = _videoOnlyPool(formats, container: container, strict: false)
        .where((f) => !f.audioWasStripped)
        .toList();
    final ranked = _rankByHeightThenBitrate(pool, maxHeight);
    if (ranked.isEmpty) return const [];
    return [SelectedFormats(muxed: ranked.first)];
  }

  /// Every video-only x same-group audio-only combination worth offering,
  /// video-rank-major then audio-rank-minor, capped at [_maxPairsPerTier]
  /// total (round 2 P-R2/P-R3). "Same group" (round 2 P-R2, Codex#17/
  /// Gadfly#5) means [MediaFormat.audioGroupId] equal - including both
  /// null, so a plain (non-HLS-split) video-only/audio-only pair with
  /// neither side carrying a group id still pairs exactly as before this
  /// field existed - but a master with two distinct alternate-audio groups
  /// never lets group B's audio pair with group A's video. [strict] applies
  /// the same container-codec filter to both halves that the pre-round-2
  /// single-pick tiers did; when false (the loose/transcode-flagged tier)
  /// every video-only/audio-only candidate is eligible regardless of codec.
  List<SelectedFormats> _rankPairs(
    List<MediaFormat> formats, {
    required int? maxHeight,
    required VideoFormat container,
    required bool strict,
  }) {
    final videoPool = _videoOnlyPool(formats, container: container, strict: strict);
    if (videoPool.isEmpty) return const [];
    final rankedVideo = _rankByHeightThenBitrate(videoPool, maxHeight);

    // Round 3 P-R3-2 (Codex#10): enumerated audio-rank-major, not
    // video-rank-major - every video paired with the best audio first
    // (video1+audio1, video2+audio1, ...), and only then the second-best
    // audio with each video. The previous order exhausted one video's
    // whole audio list before trying a different video at all, so a
    // broken *video* rendition burned every retry on itself while the
    // audio half - the half that was already fine - kept being swapped.
    // `.first` is still video1+audio1.
    final audioByVideo = [
      for (final video in rankedVideo)
        _rankAudioCandidates(
          _audioOnlyPool(formats, container: container, strict: strict, groupId: video.audioGroupId),
        ),
    ];
    final deepestAudioList = audioByVideo.fold<int>(0, (deepest, list) => list.length > deepest ? list.length : deepest);

    final pairs = <SelectedFormats>[];
    for (var audioRank = 0; audioRank < deepestAudioList; audioRank++) {
      for (var videoRank = 0; videoRank < rankedVideo.length; videoRank++) {
        final audioList = audioByVideo[videoRank];
        if (audioRank >= audioList.length) continue;
        final video = rankedVideo[videoRank];
        final audio = audioList[audioRank];
        pairs.add(SelectedFormats(
          video: video,
          audio: audio,
          videoNeedsTranscode: !strict && !_isVideoCompatible(video.videoCodec, container),
          audioNeedsTranscode: !strict && !_isAudioCompatible(audio.audioCodec, container),
        ));
        if (pairs.length >= _maxPairsPerTier) return pairs;
      }
    }
    return pairs;
  }

  int? _heightCap(VideoQuality quality) {
    if (quality == VideoQuality.best) return null;
    return int.tryParse(quality.value);
  }

  bool _isVideoCompatible(String? codec, VideoFormat container) {
    if (container == VideoFormat.mkv) return true;
    if (codec == null) return false;
    final list = container == VideoFormat.webm ? _webmVideoCodecs : _mp4VideoCodecs;
    return list.any((c) => codec.startsWith(c));
  }

  bool _isAudioCompatible(String? codec, VideoFormat container) {
    if (container == VideoFormat.mkv) return true;
    if (codec == null) return false;
    return container == VideoFormat.webm ? codec.startsWith('opus') : codec.startsWith('mp4a');
  }

  /// Every video-only format, optionally filtered ([strict], non-mkv) to
  /// ones whose codec natively fits [container] - unranked (callers rank
  /// with [_rankByHeightThenBitrate] once they know the [maxHeight] cap and,
  /// for pairing, only after also narrowing by audio group).
  List<MediaFormat> _videoOnlyPool(List<MediaFormat> formats, {required VideoFormat container, required bool strict}) {
    final candidates = formats.where((f) => f.isVideoOnly).toList();
    if (!strict || container == VideoFormat.mkv) return candidates;
    return candidates.where((f) => _isVideoCompatible(f.videoCodec, container)).toList();
  }

  /// Every audio-only format sharing [groupId] with the video half being
  /// paired (round 2 P-R2: both null counts as a match, so a source with no
  /// concept of audio groups pairs exactly as it always did), optionally
  /// codec-filtered the same way [_videoOnlyPool] is.
  List<MediaFormat> _audioOnlyPool(
    List<MediaFormat> formats, {
    required VideoFormat container,
    required bool strict,
    required String? groupId,
  }) {
    final candidates = formats.where((f) => f.isAudioOnly && f.audioGroupId == groupId).toList();
    if (!strict || container == VideoFormat.mkv) return candidates;
    return candidates.where((f) => _isAudioCompatible(f.audioCodec, container)).toList();
  }

  /// [candidates] ranked best-first by [MediaFormat.audioPreference]
  /// ascending (0 = `DEFAULT=YES` outranks everything, 3 = a
  /// forced/accessibility rendition, ranked last), then bitrate
  /// descending, then the order they arrived in. A format with no
  /// preference signal defaults to 2, so this is a strict generalization
  /// of the old bitrate-only ordering, not a behavior change for any
  /// source that never sets it.
  ///
  /// The trailing index comparison (round 3 P-R3-3) is what makes the
  /// result deterministic: `List.sort` is not stable in Dart, so two
  /// renditions with the same preference and the same bitrate - the normal
  /// case for an HLS group whose renditions carry no `BANDWIDTH` of their
  /// own, all defaulting to 0 - could otherwise come back in either order
  /// on different inputs, silently changing which language a user gets.
  List<MediaFormat> _rankAudioCandidates(List<MediaFormat> candidates) {
    final indexed = [for (var i = 0; i < candidates.length; i++) MapEntry(i, candidates[i])];
    indexed.sort((a, b) {
      final byPreference = a.value.audioPreference.compareTo(b.value.audioPreference);
      if (byPreference != 0) return byPreference;
      final byBitrate = b.value.bitrate.compareTo(a.value.bitrate);
      if (byBitrate != 0) return byBitrate;
      return a.key.compareTo(b.key);
    });
    return [for (final entry in indexed) entry.value];
  }

  List<MediaFormat> _rankMuxed(List<MediaFormat> formats, {required int? maxHeight}) {
    final candidates = formats.where((f) => f.isMuxed).toList();
    if (candidates.isEmpty) return const [];
    return _rankByHeightThenBitrate(candidates, maxHeight);
  }

  /// Ranks [candidates] best-first: (1) known height, at/under [maxHeight]
  /// (or no cap), tallest-then-highest-bitrate first; (2) known height,
  /// over the cap (only relevant when 1 has entries too - offered as lower
  /// -priority retry candidates, closest fit first); (3) unknown height,
  /// by bitrate - so a format missing `height` never outranks one that
  /// reports it, but is still selectable. `.first` always matches the old
  /// single-pick `_pickByHeightThenBitrate` in every case.
  List<MediaFormat> _rankByHeightThenBitrate(List<MediaFormat> candidates, int? maxHeight) {
    final withHeight = candidates.where((f) => f.height != null).toList();
    final withoutHeight = candidates.where((f) => f.height == null).toList();

    final underCap = maxHeight == null ? withHeight : withHeight.where((f) => f.height! <= maxHeight).toList();
    final overCap = maxHeight == null ? const <MediaFormat>[] : withHeight.where((f) => f.height! > maxHeight).toList();

    underCap.sort((a, b) {
      final byHeight = b.height!.compareTo(a.height!);
      return byHeight != 0 ? byHeight : b.bitrate.compareTo(a.bitrate);
    });
    final sortedOverCap = List<MediaFormat>.from(overCap)
      ..sort((a, b) {
        final byHeight = a.height!.compareTo(b.height!);
        return byHeight != 0 ? byHeight : b.bitrate.compareTo(a.bitrate);
      });
    final sortedWithoutHeight = List<MediaFormat>.from(withoutHeight)
      ..sort((a, b) => b.bitrate.compareTo(a.bitrate));

    return [...underCap, ...sortedOverCap, ...sortedWithoutHeight];
  }
}
