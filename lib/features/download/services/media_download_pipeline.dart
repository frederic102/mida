import 'dart:io';

import '../../../core/download/caption_downloader.dart';
import '../../../core/download/format_request_context.dart';
import '../../../core/download/hls_ffmpeg_downloader.dart';
import '../../../core/download/media_merger.dart';
import '../../../core/download/stream_downloader.dart';
import '../../../core/extractors/format_selector.dart';
import '../../../core/extractors/media_models.dart';
import '../../../core/utils/file_mover.dart';
import '../../../core/utils/file_utils.dart';
import 'all_format_candidates_failed_exception.dart';
import 'caption_download_step.dart';
import 'download_outcome_verifier.dart';
import 'download_service_io.dart';

/// Orchestrates a single download end to end for any [MediaInfo], no matter
/// which extractor produced it (YouTube/X/TikTok/Instagram/Generic/
/// browser-capture): rank format candidates -> download (retrying the next
/// candidate if one fails or produces a suspect file) -> merge/convert ->
/// captions.
///
/// Downloading branches on `MediaFormat.protocol`: `'https'` uses
/// `StreamDownloader` (ranged GETs), `'hls'`/`'dash'` use
/// `HlsFfmpegDownloader` (ffmpeg reads the manifest directly). Only the
/// muxed and audio-only paths need that branch: an adaptive video+audio
/// pair is YouTube-only in practice (`'https'` always), and no other
/// extractor ever produces separate video-only + audio-only HLS/DASH
/// formats (their m3u8/mpd formats are always a single muxed format).
class MediaDownloadPipeline {
  final FormatSelector _selector;
  final StreamDownloader Function() _downloaderFactory;
  final HlsFfmpegDownloader _hlsDownloader;
  final MediaMerger _merger;
  final FileMover _fileMover;
  final DownloadOutcomeVerifier _verifier;
  final CaptionDownloadStep _captionStep;

  /// Format candidates are tried in rank order up to this many times
  /// before giving up (fewer if `FormatSelector.rank` returned fewer): a
  /// broken/mislabeled top pick should not fail the whole download when
  /// other viable renditions exist.
  static const maxAttempts = 3;

  MediaDownloadPipeline({
    FormatSelector selector = const FormatSelector(),
    StreamDownloader Function()? downloaderFactory,
    HlsFfmpegDownloader? hlsDownloader,
    MediaMerger? merger,
    CaptionDownloader? captionDownloader,
    FileMover? fileMover,
    DownloadOutcomeVerifier? verifier,
    CaptionDownloadStep? captionStep,
  })  : _selector = selector,
        _downloaderFactory = downloaderFactory ?? StreamDownloader.new,
        _hlsDownloader = hlsDownloader ?? HlsFfmpegDownloader(),
        _merger = merger ?? MediaMerger(),
        _fileMover = fileMover ?? FileMover(),
        _verifier = verifier ?? DownloadOutcomeVerifier(),
        _captionStep = captionStep ??
            CaptionDownloadStep(
              captionDownloader: captionDownloader ?? CaptionDownloader(),
              merger: merger ?? MediaMerger(),
            );

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
    final candidates = _selector.rank(info, type, options);
    if (candidates.isEmpty) {
      throw const NoDownloadableFormatsException();
    }

    final rawBaseName = FileUtils.sanitizeFileName(info.title.isEmpty ? info.id : info.title);
    final baseName = FileUtils.fitBaseNameToPath(outputDir, rawBaseName);
    final requestContext = FormatRequestContext.fromInfo(info);
    final attempts = candidates.length < maxAttempts ? candidates.length : maxAttempts;

    Object? lastError;
    for (var i = 0; i < attempts; i++) {
      final selected = candidates[i];
      final tempPrefix = '$outputDir/.mida_tmp_${info.id}_${DateTime.now().millisecondsSinceEpoch}_$i';

      onProgress?.call(0.0);
      if (i == 0) {
        onStatus?.call('Downloading...');
        if (type == DownloadType.video) _verifier.announceQualityMismatch(selected, options, onStatus);
      } else {
        onStatus?.call('Retrying with another format (${i + 1}/$attempts)...');
      }

      String? finalPath;
      try {
        if (type == DownloadType.audio) {
          finalPath = await _downloadAudioOnly(
            selected, options, baseName, outputDir, tempPrefix, requestContext, info.duration, onProgress, onStatus,
          );
        } else if (selected.isAdaptivePair) {
          finalPath = await _downloadAdaptivePair(
            selected, options, baseName, outputDir, tempPrefix, requestContext, onProgress, onStatus,
          );
        } else {
          finalPath = await _downloadMuxed(
            selected, options, baseName, outputDir, tempPrefix, requestContext, info.duration, onProgress, onStatus,
          );
        }

        // Always runs for a video download (never skipped based on the
        // selected format's own hasAudio/hasVideo flags): the probe result
        // itself, not what the extractor claimed, is what "no audio track"
        // status/failure decisions are based on.
        await _verifier.verifyOutput(finalPath, selected, type, onStatus);

        await _captionStep.run(
          info: info,
          options: options,
          baseName: baseName,
          outputDir: outputDir,
          tempPrefix: tempPrefix,
          headers: requestContext.headers,
          onStatus: onStatus,
        );
        onProgress?.call(1.0);
        return finalPath;
      } on Exception catch (e) {
        // One clause deliberately covers every failure shape a
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

    throw AllFormatCandidatesFailedException(attempts, lastError!);
  }

  /// Builds the in-progress temp path ffmpeg writes to before it is moved
  /// to [outputPath] on success. Inserted *before* the real extension
  /// (`name.mp4` -> `name.part.mp4`), not appended after it
  /// (`name.mp4.part`): ffmpeg's muxer auto-detection keys off the output
  /// filename's extension, so a trailing `.part` makes it fail with
  /// "Error initializing the muxer" instead of actually writing an mp4
  /// (caught live: `test/live/pipeline_live_test.dart`'s HLS case).
  String _partPathFor(String outputPath) {
    final dot = outputPath.lastIndexOf('.');
    if (dot == -1) return '$outputPath.part';
    return '${outputPath.substring(0, dot)}.part${outputPath.substring(dot)}';
  }

  Future<String> _downloadAudioOnly(
    SelectedFormats selected,
    DownloadOptions options,
    String baseName,
    String outputDir,
    String tempPrefix,
    FormatRequestContext requestContext,
    Duration? duration,
    void Function(double progress)? onProgress,
    void Function(String message)? onStatus,
  ) async {
    final audio = selected.audio!;
    if (selected.needsAudioExtraction) {
      onStatus?.call('No separate audio track offered; extracting audio from the video stream...');
    }

    final outputPath = await FileUtils.getUniqueFilePath('$outputDir/$baseName.${options.audioFormat.value}');

    if (_needsFfmpeg(audio)) {
      final partPath = _partPathFor(outputPath);
      try {
        await _hlsDownloader.downloadVerified(
          url: audio.url,
          outputPath: partPath,
          headers: requestContext.headers,
          cookiesByDomain: requestContext.cookiesByDomain,
          audioOnly: true,
          audioCodecArgs: _merger.audioCodecArgs(options.audioFormat),
          totalDuration: duration,
          onProgress: (p) => onProgress?.call(p * 0.9),
        );
        onProgress?.call(0.9);
        await _fileMover.move(partPath, outputPath);
        return outputPath;
      } catch (_) {
        await _tryDelete(partPath);
        rethrow;
      }
    }

    final tempPath = '$tempPrefix.${audio.container}';
    try {
      final totalLen = audio.contentLength ?? 0;
      await _downloadFormat(audio, tempPath, requestContext, (received) {
        if (totalLen > 0) onProgress?.call((received / totalLen) * 0.9);
      });

      onProgress?.call(0.9);
      final args = _merger.buildAudioConvertArgs(
        inputPath: tempPath,
        outputPath: outputPath,
        format: options.audioFormat,
        quality: options.audioQuality,
      );
      await _merger.run(args);
      return outputPath;
    } finally {
      await _tryDelete(tempPath);
    }
  }

  Future<String> _downloadAdaptivePair(
    SelectedFormats selected,
    DownloadOptions options,
    String baseName,
    String outputDir,
    String tempPrefix,
    FormatRequestContext requestContext,
    void Function(double progress)? onProgress,
    void Function(String message)? onStatus,
  ) async {
    final video = selected.video!;
    final audio = selected.audio!;
    final videoTemp = '$tempPrefix.video.${video.container}';
    final audioTemp = '$tempPrefix.audio.${audio.container}';

    try {
      final videoLen = video.contentLength ?? 0;
      final audioLen = audio.contentLength ?? 0;
      final totalLen = videoLen + audioLen;

      await _downloadFormat(video, videoTemp, requestContext, (received) {
        if (totalLen > 0) onProgress?.call((received / totalLen) * 0.9);
      });
      await _downloadFormat(audio, audioTemp, requestContext, (received) {
        if (totalLen > 0) onProgress?.call(((videoLen + received) / totalLen) * 0.9);
      });

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
      final outputPath = await FileUtils.getUniqueFilePath(
        '$outputDir/$baseName.${options.videoFormat.value}',
      );
      await _merger.run(_merger.buildMergeArgs(
        videoPath: videoTemp,
        audioPath: audioTemp,
        outputPath: outputPath,
        container: options.videoFormat,
        transcodeVideo: transcodeVideo,
        transcodeAudio: transcodeAudio,
      ));
      return outputPath;
    } finally {
      await _tryDelete(videoTemp);
      await _tryDelete(audioTemp);
    }
  }

  Future<String> _downloadMuxed(
    SelectedFormats selected,
    DownloadOptions options,
    String baseName,
    String outputDir,
    String tempPrefix,
    FormatRequestContext requestContext,
    Duration? duration,
    void Function(double progress)? onProgress,
    void Function(String message)? onStatus,
  ) async {
    final muxed = selected.muxed!;

    if (_needsFfmpeg(muxed)) {
      final outputPath = await FileUtils.getUniqueFilePath('$outputDir/$baseName.${options.videoFormat.value}');
      final partPath = _partPathFor(outputPath);
      onStatus?.call('Downloading (stream)...');
      try {
        await _hlsDownloader.downloadVerified(
          url: muxed.url,
          outputPath: partPath,
          headers: requestContext.headers,
          cookiesByDomain: requestContext.cookiesByDomain,
          totalDuration: duration,
          onProgress: (p) => onProgress?.call(p * 0.9),
        );
        onProgress?.call(0.9);
        await _fileMover.move(partPath, outputPath);
        return outputPath;
      } catch (_) {
        await _tryDelete(partPath);
        rethrow;
      }
    }

    final tempPath = '$tempPrefix.${muxed.container}';
    try {
      final totalLen = muxed.contentLength ?? 0;
      await _downloadFormat(muxed, tempPath, requestContext, (received) {
        if (totalLen > 0) onProgress?.call((received / totalLen) * 0.9);
      });
      onProgress?.call(0.9);

      if (muxed.container == options.videoFormat.value) {
        final outputPath = await FileUtils.getUniqueFilePath('$outputDir/$baseName.${muxed.container}');
        await _fileMover.move(tempPath, outputPath);
        return outputPath;
      }

      final outputPath = await FileUtils.getUniqueFilePath(
        '$outputDir/$baseName.${options.videoFormat.value}',
      );
      try {
        await _merger.run(_merger.buildRemuxArgs(inputPath: tempPath, outputPath: outputPath));
        return outputPath;
      } on MediaMergeException catch (e) {
        // Container change failed (e.g. codec unsupported by the container):
        // keep the original file rather than losing the download entirely.
        onStatus?.call('Kept original format (container conversion failed: ${e.message})');
        final fallbackPath = await FileUtils.getUniqueFilePath('$outputDir/$baseName.${muxed.container}');
        await _fileMover.move(tempPath, fallbackPath);
        return fallbackPath;
      }
    } finally {
      // If either branch above moved tempPath away, this is a safe no-op
      // (the file no longer exists at tempPath); otherwise it deletes the
      // now-unneeded temp on both success and any other exception.
      await _tryDelete(tempPath);
    }
  }

  /// True when [format] must go through `HlsFfmpegDownloader` rather than
  /// `StreamDownloader`: either it is already labeled `hls`/`dash`, or -
  /// live-caught (coordinator repro) - its own URL path plainly ends in
  /// `.m3u8`/`.mpd` despite being labeled `https`. A manifest handed to
  /// `StreamDownloader` is not itself the media (`StreamDownloader` would
  /// just download the manifest TEXT as if it were a video file), so a
  /// mislabeled one must be routed to ffmpeg, which can actually read it.
  /// The query string is stripped first so a signed URL like
  /// `manifest.m3u8?token=...` still matches.
  static bool _needsFfmpeg(MediaFormat format) {
    if (format.protocol != 'https') return true;
    final path = Uri.tryParse(format.url)?.path.toLowerCase() ?? '';
    return path.endsWith('.m3u8') || path.endsWith('.mpd');
  }

  Future<void> _downloadFormat(
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
