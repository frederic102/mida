import 'dart:io';

import '../../../core/download/caption_downloader.dart';
import '../../../core/download/format_capability_resolver.dart';
import '../../../core/download/format_request_context.dart';
import '../../../core/download/hls_ffmpeg_downloader.dart';
import '../../../core/download/media_merger.dart';
import '../../../core/download/stream_downloader.dart';
import '../../../core/extractors/format_selector.dart';
import '../../../core/extractors/media_models.dart';
import '../../../core/utils/file_mover.dart';
import '../../../core/utils/file_utils.dart';
import 'adaptive_pair_downloader.dart';
import 'all_format_candidates_failed_exception.dart';
import 'caption_download_step.dart';
import 'download_outcome_verifier.dart';
import 'download_service_io.dart';
import 'single_format_downloader.dart';

/// Orchestrates a single download end to end for any [MediaInfo], no matter
/// which extractor produced it (YouTube/X/TikTok/Instagram/Generic/
/// browser-capture): resolve unknown capabilities -> rank format candidates
/// -> download (retrying the next candidate if one fails or produces a
/// suspect file, and re-ranking with corrected metadata when the post
/// download probe finds a mislabeled candidate) -> merge/convert ->
/// captions.
///
/// Downloading branches on `MediaFormat.protocol`: `'https'` uses
/// `StreamDownloader` (ranged GETs), `'hls'`/`'dash'` use
/// `HlsFfmpegDownloader` (ffmpeg reads the manifest directly). An adaptive
/// video+audio pair (`AdaptivePairDownloader`) routes each half
/// independently, since phase 6 (`docs/plan-phase6-av-pairing.md`) made a
/// pair's audio half a real HLS/DASH manifest possible (an alternate-audio
/// rendition group split out of an HLS master) - pre-phase-6 an adaptive
/// pair was YouTube-only in practice and always `'https'`.
class MediaDownloadPipeline {
  final FormatSelector _selector;
  final StreamDownloader Function() _downloaderFactory;
  final HlsFfmpegDownloader _hlsDownloader;
  final MediaMerger _merger;
  final FileMover _fileMover;
  final DownloadOutcomeVerifier _verifier;
  final CaptionDownloadStep _captionStep;
  final FormatCapabilityResolver _capabilityResolver;
  late final AdaptivePairDownloader _adaptivePairDownloader;
  late final SingleFormatDownloader _singleFormatDownloader;

  /// Format candidates are tried in rank order up to this many times
  /// before giving up (fewer if `FormatSelector.rank` returned fewer): a
  /// broken/mislabeled top pick should not fail the whole download when
  /// other viable renditions exist.
  /// Coupled to `FormatSelector._pairsBeforeMuxed` (2) and
  /// `FormatSelector._maxPairsPerTier` (6): the selector places the first
  /// muxed candidate at index 2 precisely so it is reachable inside these
  /// three attempts, and its pair cap plus [correctiveRetryBudget] bound
  /// the total. Change one of the three only with the others in view
  /// (Plumbline, phase 6 round 3).
  static const maxAttempts = 3;

  /// Extra attempts a genuine metadata correction (see [_correctedInfo])
  /// is allowed to buy beyond [maxAttempts] - each successful correction
  /// grants exactly one more attempt, up to this many total, so the worst
  /// case total attempts across a whole download is `maxAttempts +
  /// correctiveRetryBudget` (phase 6 digest P4c). A plain failure (no
  /// correction - including every pre-phase-6 failure mode) never grants
  /// extra budget, so a download with no corrections behaves exactly as
  /// before: capped at [maxAttempts].
  static const correctiveRetryBudget = 3;

  MediaDownloadPipeline({
    FormatSelector selector = const FormatSelector(),
    StreamDownloader Function()? downloaderFactory,
    HlsFfmpegDownloader? hlsDownloader,
    MediaMerger? merger,
    CaptionDownloader? captionDownloader,
    FileMover? fileMover,
    DownloadOutcomeVerifier? verifier,
    CaptionDownloadStep? captionStep,
    FormatCapabilityResolver? capabilityResolver,
  })  : _selector = selector,
        _downloaderFactory = downloaderFactory ?? StreamDownloader.new,
        _hlsDownloader = hlsDownloader ?? HlsFfmpegDownloader(),
        _merger = merger ?? MediaMerger(),
        _fileMover = fileMover ?? FileMover(),
        _verifier = verifier ?? DownloadOutcomeVerifier(),
        _capabilityResolver = capabilityResolver ?? const FormatCapabilityResolver(),
        _captionStep = captionStep ??
            CaptionDownloadStep(
              captionDownloader: captionDownloader ?? CaptionDownloader(),
              merger: merger ?? MediaMerger(),
            ) {
    _adaptivePairDownloader = AdaptivePairDownloader(
      hlsDownloader: _hlsDownloader,
      downloaderFactory: _downloaderFactory,
      merger: _merger,
    );
    _singleFormatDownloader = SingleFormatDownloader(
      hlsDownloader: _hlsDownloader,
      downloaderFactory: _downloaderFactory,
      merger: _merger,
      fileMover: _fileMover,
    );
  }

  /// Runs the full pipeline. [onProgress] receives 0.0-1.0 per attempt
  /// (0-0.9 for the raw download, 0.9-1.0 for merge/convert) and resets to
  /// 0.0 at the start of each retry. [onStatus] receives short
  /// human-readable status lines for [DownloadTask.statusMessage],
  /// including `Retrying with another format (i/n)...` between attempts.
  Future<String> download({
    required MediaInfo info,
    required DownloadType type,
    required DownloadOptions options,
    required String outputDir,
    void Function(double progress)? onProgress,
    void Function(String message)? onStatus,
  }) async {
    var currentInfo = await _capabilityResolver.resolve(info);
    var rankedQueue = _selector.rank(currentInfo, type, options);
    if (rankedQueue.isEmpty) throw _nothingToTry(currentInfo, 0);

    final rawBaseName = FileUtils.sanitizeFileName(currentInfo.title.isEmpty ? currentInfo.id : currentInfo.title);
    final baseName = FileUtils.fitBaseNameToPath(outputDir, rawBaseName);
    var requestContext = FormatRequestContext.fromInfo(currentInfo);
    // The denominator shown to the user in "Retrying with another format
    // (i/n)..." is fixed at the plan visible after attempt 1, never
    // inflated by a later corrective re-rank extending how many attempts
    // actually run past it.
    final plannedAttempts = rankedQueue.length < maxAttempts ? rankedQueue.length : maxAttempts;

    final triedTupleKeys = <String>{};
    Object? lastError;
    var totalAttempted = 0;
    var displayIndex = 0;
    var correctionsGranted = 0;

    while (totalAttempted < maxAttempts + correctionsGranted) {
      // Re-ranked from [currentInfo] on every iteration (not a stale
      // snapshot kept across attempts): a plain failure leaves [currentInfo]
      // unchanged, so this is a cheap no-op recompute of the identical
      // order; a genuine correction below changes [currentInfo], and this
      // is what makes the very next attempt actually see it.
      rankedQueue = _selector.rank(currentInfo, type, options);
      final selected = _firstUntried(rankedQueue, triedTupleKeys);
      if (selected == null) break; // nothing left this re-rank offered that has not already failed

      triedTupleKeys.add(_tupleKey(selected));
      totalAttempted++;
      displayIndex++;
      final tempPrefix = '$outputDir/.mida_tmp_${currentInfo.id}_${DateTime.now().millisecondsSinceEpoch}_$totalAttempted';

      onProgress?.call(0.0);
      if (displayIndex == 1) {
        onStatus?.call('Downloading...');
        if (type == DownloadType.video) _verifier.announceQualityMismatch(selected, options, onStatus);
      } else {
        onStatus?.call('Retrying with another format ($displayIndex/$plannedAttempts)...');
      }

      String? finalPath;
      try {
        DownloadedOutput downloaded;
        if (type == DownloadType.audio) {
          downloaded = await _singleFormatDownloader.downloadAudioOnly(
            selected, options, baseName, outputDir, tempPrefix, requestContext, currentInfo.duration, onProgress, onStatus,
          );
        } else if (selected.isAdaptivePair) {
          downloaded = await _adaptivePairDownloader.download(
            selected: selected,
            options: options,
            baseName: baseName,
            outputDir: outputDir,
            tempPrefix: tempPrefix,
            requestContext: requestContext,
            duration: currentInfo.duration,
            onProgress: onProgress,
            onStatus: onStatus,
          );
        } else {
          downloaded = await _singleFormatDownloader.downloadMuxed(
            selected, options, baseName, outputDir, tempPrefix, requestContext, currentInfo.duration, onProgress, onStatus,
          );
        }
        finalPath = downloaded.path;

        // Always runs for a video download (never skipped based on the
        // selected format's own hasAudio/hasVideo flags): the probe result
        // itself, not what the extractor claimed, is what "no audio track"
        // status/failure decisions are based on. `expectedDuration` (round
        // 2 P-R9) lets the verifier reject a truncated merge (real duration
        // far short of the source's own reported one), not just a missing
        // stream type.
        await _verifier.verifyOutput(
          finalPath,
          selected,
          type,
          onStatus,
          // Round 3 P-R3-5: the source's own reported duration when it has
          // one, otherwise what the manifest chain declared
          // (`#EXTINF` sum / `mediaPresentationDuration`, read during the
          // pre-download safety scan). A truncated download of a source
          // whose extractor reported no duration used to pass unchecked;
          // the manifest's own statement is a second, independent number
          // to hold the output against.
          expectedDuration: currentInfo.duration ?? downloaded.declaredDuration,
        );

        await _captionStep.run(
          info: currentInfo,
          options: options,
          baseName: baseName,
          outputDir: outputDir,
          tempPrefix: tempPrefix,
          headers: requestContext.headers,
          onStatus: onStatus,
        );
        onProgress?.call(1.0);
        return finalPath;
      } on OutputTrackMismatchException catch (e) {
        // Per digest P4c: a mismatch on a *single muxed* format is a real,
        // actionable correction (that one format's own flags were wrong -
        // copy what ffprobe actually found onto it and re-rank). A mismatch
        // on an *adaptive pair* only tells us the merged output as a whole
        // was missing a track, not which half was actually at fault - so a
        // pair never gets its flags rewritten here, only its tuple recorded
        // as failed (via [triedTupleKeys] below), letting the next re-rank
        // offer a genuinely different candidate instead of guessing.
        lastError = e;
        await _tryDelete(finalPath);
        if (selected.muxed != null && correctionsGranted < correctiveRetryBudget) {
          final corrected = _correctedInfo(currentInfo, selected.muxed!, e);
          if (corrected != null) {
            correctionsGranted++;
            currentInfo = corrected;
            requestContext = FormatRequestContext.fromInfo(currentInfo);
          }
        }
      } on Exception catch (e) {
        // One clause deliberately covers every other failure shape a
        // downloader/builder can throw for a single candidate -
        // `StreamDownloadException`, `MediaMergeException`,
        // `HeaderInjectionException`, `MediaExtractionException` (the HLS
        // manifest/segment host check), a `FormatException` from a
        // malformed URL, ... - all `implements Exception`, and all mean
        // the same thing here: this candidate did not work, move on to
        // the next one rather than letting it escape as a raw crash.
        lastError = e;
        await _tryDelete(finalPath);
      }
    }

    if (lastError == null) throw _nothingToTry(currentInfo, totalAttempted);
    throw AllFormatCandidatesFailedException(totalAttempted, lastError);
  }

  /// The failure to throw when ranking offered nothing (left) to try.
  /// Normally that is [NoDownloadableFormatsException] - the source had no
  /// usable format at all. When some format is
  /// [MediaFormat.audioWasStripped], though, the truthful reason is
  /// narrower and worth saying out loud (round 3 P-R3-1): there IS a video
  /// here, and MiDa is refusing to hand back a silent copy of it rather
  /// than pretending the source was muted. The stripped case is always
  /// wrapped in [AllFormatCandidatesFailedException] (even at [attempted]
  /// 0, when the refusal happened before any download started), so a
  /// caller's existing "every candidate failed" handling covers it without
  /// a new branch.
  Exception _nothingToTry(MediaInfo info, int attempted) {
    final audioWasStripped = info.formats.any((f) => f.audioWasStripped);
    if (!audioWasStripped) {
      return attempted == 0
          ? const NoDownloadableFormatsException()
          : AllFormatCandidatesFailedException(attempted, const NoDownloadableFormatsException());
    }
    return AllFormatCandidatesFailedException(
      attempted,
      const NoDownloadableFormatsException(
        'This video has audio, but none of its audio tracks could be downloaded, so MiDa will not save it as a '
        'silent video. Try again later, or download it from a page where its audio is not restricted.',
      ),
    );
  }

  /// First entry in [rankedQueue] whose tuple key is not already in
  /// [tried] - a full re-rank after a correction can (and usually does)
  /// re-offer an already-failed candidate at a different position, so this
  /// always scans from the top rather than resuming from some prior index.
  SelectedFormats? _firstUntried(List<SelectedFormats> rankedQueue, Set<String> tried) {
    for (final candidate in rankedQueue) {
      if (!tried.contains(_tupleKey(candidate))) return candidate;
    }
    return null;
  }

  /// Identifies a ranked candidate by the exact [MediaFormat] *instance*(s)
  /// it uses (round 2 P-R4, Codex#2), not by [MediaFormat.id]: a provider's
  /// own id string is attacker/source-controlled input and is not
  /// guaranteed unique across every format `FormatSelector` could ever
  /// offer in one [MediaInfo] (two direct-candidate formats built from the
  /// same URL, say, both end up with that URL as their id - see
  /// `FormatExpander.formatFor`/`CapturedFormatBuilder._formatFor`). Keying
  /// on `identityHashCode` instead means two formats that merely share an
  /// id string are still tracked as different candidates, and - together
  /// with [_correctedInfo] matching by `identical()` - a correction can
  /// never silently overwrite a *different* format that just happens to
  /// carry the same id.
  String _tupleKey(SelectedFormats selected) {
    if (selected.muxed != null) return 'm:${identityHashCode(selected.muxed)}';
    return 'p:${identityHashCode(selected.video)}:${identityHashCode(selected.audio)}';
  }

  /// Builds a corrected [MediaInfo] with [original] (the single muxed
  /// format that just failed its post-download probe) replaced by a
  /// `copyWith` of what [mismatch] actually found - `null` only if
  /// [original] is somehow no longer present in [current.formats] (should
  /// not happen in practice: it came from ranking [current] in the first
  /// place). Matches by object identity (`identical`), not
  /// [MediaFormat.id] (round 2 P-R4): replacing by id could rewrite a
  /// *different* format that happens to carry the same (source-controlled)
  /// id string as [original] - only the exact instance the pipeline just
  /// selected and tried is ever touched. Rebuilt via [MediaInfo.copyWith]
  /// (round 2 P-R9) rather than a hand-spelled field list, so a field added
  /// to [MediaInfo] later cannot be silently dropped here the way
  /// `cookiesByDomain` once was.
  MediaInfo? _correctedInfo(MediaInfo current, MediaFormat original, OutputTrackMismatchException mismatch) {
    if (!current.formats.any((f) => identical(f, original))) return null;
    final corrected = original.copyWith(
      hasVideo: mismatch.hasVideo,
      hasAudio: mismatch.hasAudio,
      capabilitiesUnknown: false,
      // Round 3 P-R3-1b (Gadfly C1/C2): a correction that lands on
      // "no audio" is not the same fact as a source that never claimed
      // any. [original] did claim audio and the delivered file had none,
      // so the corrected format is marked stripped and `FormatSelector`'s
      // silent-source tier refuses it - which is what turns this into a
      // loud `AllFormatCandidatesFailedException` instead of a retry that
      // re-downloads the same URL and accepts the same silent file as
      // success. A correction in the other direction (the probe found the
      // audio a video-only format did not claim) clears the flag, since
      // nothing was stripped after all.
      audioWasStripped: !mismatch.hasAudio,
    );
    return current.copyWith(
      formats: [for (final f in current.formats) identical(f, original) ? corrected : f],
    );
  }

  Future<void> _tryDelete(String? path) async {
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best effort cleanup only.
    }
  }
}
