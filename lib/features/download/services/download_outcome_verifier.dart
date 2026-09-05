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
  /// Reusing [MediaMergeException] for the failure case (rather than a new
  /// exception type) means the pipeline's retry loop already catches it
  /// with no extra branch.
  Future<void> verifyOutput(
    String path,
    SelectedFormats selected,
    DownloadType type,
    void Function(String message)? onStatus,
  ) async {
    final file = File(path);
    if (!await file.exists() || await file.length() <= 0) {
      throw const MediaMergeException('Output file is missing or empty after download.');
    }
    if (type != DownloadType.video) return;

    final streamTypes = await _prober.streamTypes(path);
    if (streamTypes == null) return; // could not verify; do not fail the download over it

    if (!streamTypes.contains('video')) {
      throw const MediaMergeException(
        'Output is missing its video track; the selected format may have been mislabeled.',
      );
    }
    if (!streamTypes.contains('audio')) {
      if (_candidateClaimedAudio(selected)) {
        throw const MediaMergeException(
          'Output is missing its audio track; the selected format may have been mislabeled '
          '(e.g. a video-only rendition reported as muxed).',
        );
      }
      onStatus?.call('ffprobe confirms the source has no audio track.');
    }
  }

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
