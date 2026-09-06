import 'dart:io';

import '../../../core/download/format_request_context.dart';
import '../../../core/download/hls_ffmpeg_downloader.dart';
import '../../../core/download/media_merger.dart';
import '../../../core/download/stream_downloader.dart';
import '../../../core/extractors/format_selector.dart';
import '../../../core/extractors/media_models.dart';
import '../../../core/utils/file_utils.dart';
import 'download_service_io.dart';

/// Downloads and merges an adaptive video+audio pair, split out of
/// `MediaDownloadPipeline` to keep that file under the project's 400-line
/// cap (`docs/plan-phase6-av-pairing.md`, Lane P, contract file).
///
/// Phase 6 fix: a pair's video and/or audio half can each independently be
/// an HLS/DASH manifest (`MediaFormat.protocol == 'hls'/'dash'`, or a
/// `.m3u8`/`.mpd` URL mislabeled `'https'` - see [needsFfmpeg]) now that
/// `HlsMasterFormatMapper` actually splits a master's alternate-audio
/// rendition group into its own format instead of exposing the whole
/// variant as muxed. Pre-phase-6, this class did not exist at all: every
/// half went through `StreamDownloader` unconditionally, which - handed a
/// manifest URL - just downloads the manifest *text* as if it were the
/// media file itself. Each half is routed independently (the two halves
/// of one pair are not always the same shape - e.g. Facebook's `efg`-tagged
/// flat mp4 video-only + audio-only pair is plain `https`, needing no
/// ffmpeg at all).
/// What a download step produced: the file it wrote, plus the duration the
/// source manifest DECLARED for it, when it declared one (phase 6 round 3
/// P-R3-5, from Lane B's `HlsFfmpegDownloader.downloadVerified` contract).
///
/// The declared duration exists so `DownloadOutcomeVerifier` can still
/// catch a truncated download when the extractor itself reported no
/// duration - an HLS master's `#EXTINF` sum is a second, independent
/// statement of how long the media is, and a plain `StreamDownloader`
/// half simply has none (null), which the verifier already treats as
/// "no check possible".
class DownloadedOutput {
  final String path;
  final Duration? declaredDuration;

  const DownloadedOutput(this.path, {this.declaredDuration});
}

class AdaptivePairDownloader {
  final HlsFfmpegDownloader _hlsDownloader;
  final StreamDownloader Function() _downloaderFactory;
  final MediaMerger _merger;

  AdaptivePairDownloader({
    required HlsFfmpegDownloader hlsDownloader,
    required StreamDownloader Function() downloaderFactory,
    required MediaMerger merger,
  })  : _hlsDownloader = hlsDownloader,
        _downloaderFactory = downloaderFactory,
        _merger = merger;

  /// True when [format] must go through `HlsFfmpegDownloader` rather than
  /// `StreamDownloader` - shared with `MediaDownloadPipeline._needsFfmpeg`
  /// (one definition, not duplicated per this project's DRY convention):
  /// either it is already labeled `hls`/`dash`, or its own URL path plainly
  /// ends in `.m3u8`/`.mpd` despite being labeled `https` (a mislabeled
  /// manifest - live-caught, coordinator repro).
  static bool needsFfmpeg(MediaFormat format) {
    if (format.protocol != 'https') return true;
    final path = Uri.tryParse(format.url)?.path.toLowerCase() ?? '';
    return path.endsWith('.m3u8') || path.endsWith('.mpd');
  }

  /// `HlsFfmpegDownloader.downloadVerified`'s `processTimeout` (round 2
  /// P-R5, Codex#7), shared with [SingleFormatDownloader] since both call
  /// through ffmpeg the same way: a known [duration] gets 4x headroom plus
  /// a flat 5 minutes (ffmpeg reading a live/slow manifest can run well
  /// past real-time, but not indefinitely); an unknown one (a source that
  /// never reported it) gets a generous flat hour rather than no cap at
  /// all - a hung ffmpeg process must eventually fail this candidate and
  /// let the retry loop move on, not block the whole download forever.
  static Duration processTimeoutFor(Duration? duration) {
    if (duration == null) return const Duration(minutes: 60);
    return duration * 4 + const Duration(minutes: 5);
  }

  /// Extension for the temp file a ffmpeg-routed half is written to.
  /// Normally the mp4-family container matching `HlsFfmpegDownloader`'s own
  /// `-c copy` remux target (`.mp4` video, `.m4a` audio). A half the
  /// selector flagged for transcoding (round 3 P-R3-4, Codex#13) gets
  /// `.mkv` instead: [needsTranscode] means precisely that this half's
  /// codec does NOT fit the requested container, and mp4/m4a would refuse
  /// to hold it - ffmpeg fails the muxer at the download step, before the
  /// merge that was going to transcode it ever runs. Matroska accepts
  /// essentially any codec, so the stream copy lands intact and the merge
  /// does the one transcode that was planned. The temp is deleted either
  /// way, so this never reaches the user's output.
  static String _ffmpegTempExtension({required bool isAudioHalf, required bool needsTranscode}) {
    if (needsTranscode) return 'mkv';
    return isAudioHalf ? 'm4a' : 'mp4';
  }

  Future<DownloadedOutput> download({
    required SelectedFormats selected,
    required DownloadOptions options,
    required String baseName,
    required String outputDir,
    required String tempPrefix,
    required FormatRequestContext requestContext,
    required Duration? duration,
    void Function(double progress)? onProgress,
    void Function(String message)? onStatus,
  }) async {
    final video = selected.video!;
    final audio = selected.audio!;
    final videoNeedsFfmpeg = needsFfmpeg(video);
    final audioNeedsFfmpeg = needsFfmpeg(audio);
    Duration? declaredDuration;
    // A half routed through ffmpeg lands in a temp container chosen by
    // [_ffmpegTempExtension]; a plain `StreamDownloader` half keeps its
    // real container, same as before this class existed.
    final videoTemp = '$tempPrefix.video.${videoNeedsFfmpeg ? _ffmpegTempExtension(isAudioHalf: false, needsTranscode: selected.videoNeedsTranscode) : video.container}';
    final audioTemp = '$tempPrefix.audio.${audioNeedsFfmpeg ? _ffmpegTempExtension(isAudioHalf: true, needsTranscode: selected.audioNeedsTranscode) : audio.container}';

    try {
      if (!videoNeedsFfmpeg && !audioNeedsFfmpeg) {
        // Common case (YouTube, and Facebook's flat efg-tagged mp4 pair):
        // byte-weighted joint progress across both halves, exactly as
        // before this class existed.
        final videoLen = video.contentLength ?? 0;
        final audioLen = audio.contentLength ?? 0;
        final totalLen = videoLen + audioLen;
        await _downloadPlain(video, videoTemp, requestContext, (received) {
          if (totalLen > 0) onProgress?.call((received / totalLen) * 0.9);
        });
        await _downloadPlain(audio, audioTemp, requestContext, (received) {
          if (totalLen > 0) onProgress?.call(((videoLen + received) / totalLen) * 0.9);
        });
      } else {
        // At least one half needs ffmpeg: bytes and ffmpeg's own
        // out_time_ms-based fraction are not directly comparable, so each
        // half instead gets an equal half of the 0.0-0.9 budget, driven by
        // whatever progress signal that half's own downloader provides.
        declaredDuration = await _downloadHalf(
          format: video,
          outputPath: videoTemp,
          isAudioHalf: false,
          needsFfmpeg: videoNeedsFfmpeg,
          requestContext: requestContext,
          duration: duration,
          onFraction: onProgress == null ? null : (f) => onProgress(f * 0.45),
          onStatus: onStatus,
        );
        // The audio half is ALWAYS downloaded (round 3 Codex#1: an earlier
        // `declaredDuration ??= await _downloadHalf(audio)` short-circuited
        // the whole await whenever the video half already reported a
        // duration, so the audio temp was never written and the merge ran
        // on a missing file). Only the *duration* is conditional: the
        // video half's own declared duration is preferred and the audio
        // half's fills in for a missing one, since the two halves of one
        // presentation should agree and it is the video the output is
        // checked against.
        final audioDeclaredDuration = await _downloadHalf(
          format: audio,
          outputPath: audioTemp,
          isAudioHalf: true,
          needsFfmpeg: audioNeedsFfmpeg,
          requestContext: requestContext,
          duration: duration,
          onFraction: onProgress == null ? null : (f) => onProgress(0.45 + f * 0.45),
          onStatus: onStatus,
        );
        declaredDuration ??= audioDeclaredDuration;
      }

      final transcodeVideo = selected.videoNeedsTranscode;
      final transcodeAudio = selected.audioNeedsTranscode;
      onStatus?.call(
        transcodeVideo || transcodeAudio
            ? 'Merging (transcoding ${transcodeVideo ? 'video' : ''}'
                '${transcodeVideo && transcodeAudio ? ' and ' : ''}'
                '${transcodeAudio ? 'audio' : ''} to fit ${options.videoFormat.label})...'
            : 'Merging...',
      );
      onProgress?.call(0.9);
      final outputPath = await FileUtils.getUniqueFilePath('$outputDir/$baseName.${options.videoFormat.value}');
      await _merger.run(_merger.buildMergeArgs(
        videoPath: videoTemp,
        audioPath: audioTemp,
        outputPath: outputPath,
        container: options.videoFormat,
        transcodeVideo: transcodeVideo,
        transcodeAudio: transcodeAudio,
      ));
      return DownloadedOutput(outputPath, declaredDuration: declaredDuration);
    } finally {
      await _tryDelete(videoTemp);
      await _tryDelete(audioTemp);
    }
  }

  Future<void> _downloadPlain(
    MediaFormat format,
    String outputPath,
    FormatRequestContext requestContext,
    void Function(int received)? onProgress,
  ) async {
    final downloader = _downloaderFactory();
    try {
      await downloader.download(
        url: format.url,
        outputPath: outputPath,
        headers: requestContext.headers,
        cookiesByDomain: requestContext.cookiesByDomain,
        contentLength: format.contentLength,
        onProgress: onProgress == null ? null : (received, total) => onProgress(received),
      );
    } finally {
      downloader.close();
    }
  }

  /// Returns the duration this half's manifest declared, or null (a plain
  /// `StreamDownloader` half never has one).
  Future<Duration?> _downloadHalf({
    required MediaFormat format,
    required String outputPath,
    required bool isAudioHalf,
    required bool needsFfmpeg,
    required FormatRequestContext requestContext,
    required Duration? duration,
    void Function(double fraction)? onFraction,
    void Function(String message)? onStatus,
  }) async {
    if (!needsFfmpeg) {
      final totalLen = format.contentLength ?? 0;
      await _downloadPlain(
        format,
        outputPath,
        requestContext,
        totalLen <= 0 || onFraction == null ? null : (received) => onFraction((received / totalLen).clamp(0.0, 1.0)),
      );
      return null;
    }

    return _hlsDownloader.downloadVerified(
      url: format.url,
      outputPath: outputPath,
      headers: requestContext.headers,
      cookiesByDomain: requestContext.cookiesByDomain,
      // Both halves are a stream *copy* (`-c copy`, never `audioOnly`'s
      // `-vn` + re-encode path) - there is nothing to transcode here, only
      // to remux into an mp4-family container. The audio half's own
      // `audioCodec` (from `HlsMasterFormatMapper`'s CODECS reading, when
      // available) is passed through so `buildArgs` can skip
      // `-bsf:a aac_adtstoasc` for a definitely-non-AAC codec (trap 2) -
      // `segmentsAreTransportStream` is left unset (real per-manifest
      // segment-shape sniffing is a follow-up this phase does not attempt),
      // so an unknown/AAC codec still gets the legacy default treatment.
      sourceAudioCodec: isAudioHalf ? format.audioCodec : null,
      totalDuration: duration,
      onProgress: onFraction,
      // Round 4 B-R4-8: the credential-strip notice must reach the user's
      // status line, not only the debug console.
      onStatus: onStatus,
      processTimeout: processTimeoutFor(duration),
    );
  }

  Future<void> _tryDelete(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best effort cleanup only.
    }
  }
}
