import 'dart:io';

import '../../../core/download/media_merger.dart';
import '../../../core/download/output_stream_prober.dart';
import '../../../core/extractors/format_selector.dart';
import 'download_service_io.dart';

/// Post-download checks `MediaDownloadPipeline` runs once per attempt,
/// split out of that class purely to keep it under the 400-line rule.
class DownloadOutcomeVerifier {
  final OutputStreamProber _prober;

  DownloadOutcomeVerifier({OutputStreamProber? prober}) : _prober = prober ?? OutputStreamProber();

  /// Cheap post-download sanity check, run right after a download/merge
  /// step reports success: the output must exist and be non-empty. For a
  /// video download, ffprobe is then **always** run (never skipped based
  /// on [selected]'s own `hasAudio`/`hasVideo` flags - those are only
  /// consulted afterward, to decide what a missing stream *means*):
  ///   - missing video: always a failure (a video download must have one).
  ///   - missing audio, and [selected] claimed to have audio: a failure
  ///     (retry the next candidate - the source was likely mislabeled,
  ///     e.g. a video-only DASH rendition reported as muxed).
  ///   - missing audio, and [selected] never claimed audio (a genuinely
  ///     silent source, e.g. a muted reel): accepted, but only *after* the
  ///     probe confirms it - [onStatus] then reports
  ///     `"ffprobe confirms the source has no audio track"`.
  /// Both mislabel cases throw [OutputTrackMismatchException] (phase 6),
  /// carrying what ffprobe actually found, so `MediaDownloadPipeline` can
  /// correct the candidate's flags and re-rank instead of just moving on.
  /// The empty-output case above still throws [MediaMergeException] - that
  /// one is not a mislabeling, just a download that produced nothing.
  Future<void> verifyOutput(
    String path,
    SelectedFormats selected,
    DownloadType type,
    void Function(String message)? onStatus, {
    Duration? expectedDuration,
  }) async {
    final file = File(path);
    if (!await file.exists() || await file.length() <= 0) {
      throw const MediaMergeException('Output file is missing or empty after download.');
    }
    // Phase 6 round 3 (S-R3-3, Codex #11): only the *stream-kind* checks
    // below are video-only (an audio download legitimately has no video
    // track, so running them would fail every audio download). The
    // truncation check at the end is not: an audio download cut off
    // partway through is the same defect with the same evidence (a real
    // source duration we can compare ffprobe's against), and round 2's
    // single early return here silently exempted every audio download
    // from it.
    if (type != DownloadType.video) {
      await _checkNotTruncated(path, expectedDuration);
      return;
    }

    final streamTypes = await _prober.streamTypes(path);
    if (streamTypes == null) {
      // ffprobe could not be started at all: no stream-kind opinion. Phase
      // 6 round 4 (S-R4-4, Gadfly#1 / Codex#3): a candidate that itself
      // claims to carry both video and audio cannot be waved through just
      // because ffprobe has no opinion here - "could not verify" and
      // "confirmed fine" must not read identically to the caller, or a
      // video-only rendition mislabeled as muxed sails straight through
      // unverified. A candidate that never claimed audio is unaffected:
      // there is nothing ffprobe would have needed to confirm about a
      // track the candidate itself never promised, so the truncation
      // check's own independent "could not read it" fallback still gets
      // its chance for that case (S-R3-3).
      if (selected.expectsVideoAndAudio) {
        throw const MediaMergeException(
          'Could not verify the output streams (ffprobe unavailable) for a format that claims audio and video',
        );
      }
      await _checkNotTruncated(path, expectedDuration);
      return;
    }

    if (!streamTypes.contains('video')) {
      throw OutputTrackMismatchException(
        hasVideo: false,
        hasAudio: streamTypes.contains('audio'),
        message: 'Output is missing its video track; the selected format may have been mislabeled.',
      );
    }
    if (!streamTypes.contains('audio')) {
      if (_candidateClaimedAudio(selected)) {
        throw const OutputTrackMismatchException(
          hasVideo: true,
          hasAudio: false,
          message: 'Output is missing its audio track; the selected format may have been mislabeled '
              '(e.g. a video-only rendition reported as muxed).',
        );
      }
      onStatus?.call('ffprobe confirms the source has no audio track.');
    }

    await _checkNotTruncated(path, expectedDuration);
  }

  /// Phase 6 round 2 (S-R7, Gadfly#3), widened to audio downloads in
  /// round 3 (S-R3-3, Codex #11): a source whose true duration is
  /// known (the extractor reported one) but whose downloaded output falls
  /// well short of it is evidence of a truncated/aborted transfer that
  /// still happened to leave both a video and an audio stream behind (so
  /// neither check above ever catches it) - a partial CDN response cut
  /// off mid-segment is the live-observed shape of this (vimeo range
  /// fragments). Below 90% of [expectedDuration] is treated as a failure;
  /// missing duration on either side (no [expectedDuration] at all, or
  /// ffprobe could not read the output's) means no check is made - never
  /// a failure by default over something we could not actually measure.
  Future<void> _checkNotTruncated(String path, Duration? expectedDuration) async {
    if (expectedDuration == null || expectedDuration <= Duration.zero) return;
    final actual = await _prober.duration(path);
    if (actual == null) return;

    if (actual.inMilliseconds < expectedDuration.inMilliseconds * 0.9) {
      throw MediaMergeException(
        'Output is shorter than the source (got ${_formatSeconds(actual)}, expected '
        '${_formatSeconds(expectedDuration)}); the download was likely cut off partway through.',
      );
    }
  }

  String _formatSeconds(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';

  /// Whether [selected] itself claimed to include an audio stream -
  /// checked only after ffprobe already reports audio missing, to decide
  /// whether that is a mislabeling (failure) or a genuinely silent source
  /// (accepted).
  bool _candidateClaimedAudio(SelectedFormats selected) {
    if (selected.muxed != null) return selected.muxed!.hasAudio;
    return selected.isAdaptivePair; // a real, separately-selected audio format
  }

  /// Reports a status line when the ranked candidate actually picked is a
  /// lower (or higher) resolution than the user requested, e.g. the
  /// source did not offer 2160p and the best available was 1080p.
  void announceQualityMismatch(
    SelectedFormats selected,
    DownloadOptions options,
    void Function(String message)? onStatus,
  ) {
    if (options.videoQuality == VideoQuality.best) return;
    final requestedHeight = int.tryParse(options.videoQuality.value);
    if (requestedHeight == null) return;
    final actualHeight = selected.muxed?.height ?? selected.video?.height;
    if (actualHeight == null || actualHeight == requestedHeight) return;
    onStatus?.call('Requested ${requestedHeight}p, best available ${actualHeight}p.');
  }
}

/// Contract type (phase 6, lead-owned signature; Lane S makes
/// [DownloadOutcomeVerifier.verifyOutput] throw it in place of the two
/// "mislabeled" `MediaMergeException`s). Carries what ffprobe actually
/// found so `MediaDownloadPipeline` can correct the selected format's
/// flags and re-rank instead of blindly moving to the next candidate.
class OutputTrackMismatchException implements Exception {
  /// What the produced file really contained.
  final bool hasVideo;
  final bool hasAudio;
  final String message;

  const OutputTrackMismatchException({required this.hasVideo, required this.hasAudio, required this.message});

  @override
  String toString() => message;
}
