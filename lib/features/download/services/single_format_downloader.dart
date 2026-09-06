import 'dart:io';

import '../../../core/download/format_request_context.dart';
import '../../../core/download/hls_ffmpeg_downloader.dart';
import '../../../core/download/media_merger.dart';
import '../../../core/download/stream_downloader.dart';
import '../../../core/extractors/format_selector.dart';
import '../../../core/extractors/media_models.dart';
import '../../../core/utils/file_mover.dart';
import '../../../core/utils/file_utils.dart';
import 'adaptive_pair_downloader.dart';
import 'download_service_io.dart';

/// The audio-only-request and muxed-candidate download paths, split out of
/// `MediaDownloadPipeline` purely to keep that file under the project's
/// 400-line cap (this is not a phase-6 contract file, just a same-phase
/// mechanical split once the retry/correction logic phase 6 added pushed
/// the pipeline over the line). Behavior is unchanged from what used to
/// live directly on `MediaDownloadPipeline` pre-phase-6.
class SingleFormatDownloader {
  final HlsFfmpegDownloader _hlsDownloader;
  final StreamDownloader Function() _downloaderFactory;
  final MediaMerger _merger;
  final FileMover _fileMover;

  SingleFormatDownloader({
    required HlsFfmpegDownloader hlsDownloader,
    required StreamDownloader Function() downloaderFactory,
    required MediaMerger merger,
    required FileMover fileMover,
  })  : _hlsDownloader = hlsDownloader,
        _downloaderFactory = downloaderFactory,
        _merger = merger,
        _fileMover = fileMover;

  /// Builds the in-progress temp path ffmpeg writes to before it is moved
  /// to [outputPath] on success - see `MediaDownloadPipeline._partPathFor`'s
  /// own doc for why this is inserted before the real extension rather than
  /// appended after it.
  String _partPathFor(String outputPath) {
    final dot = outputPath.lastIndexOf('.');
    if (dot == -1) return '$outputPath.part';
    return '${outputPath.substring(0, dot)}.part${outputPath.substring(dot)}';
  }

  Future<DownloadedOutput> downloadAudioOnly(
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

    if (AdaptivePairDownloader.needsFfmpeg(audio)) {
      final partPath = _partPathFor(outputPath);
      try {
        final declaredDuration = await _hlsDownloader.downloadVerified(
          url: audio.url,
          outputPath: partPath,
          headers: requestContext.headers,
          cookiesByDomain: requestContext.cookiesByDomain,
          audioOnly: true,
          audioCodecArgs: _merger.audioCodecArgs(options.audioFormat),
          totalDuration: duration,
          onProgress: (p) => onProgress?.call(p * 0.9),
          onStatus: onStatus,
          processTimeout: AdaptivePairDownloader.processTimeoutFor(duration),
        );
        onProgress?.call(0.9);
        await _fileMover.move(partPath, outputPath);
        return DownloadedOutput(outputPath, declaredDuration: declaredDuration);
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
      return DownloadedOutput(outputPath);
    } finally {
      await _tryDelete(tempPath);
    }
  }

  Future<DownloadedOutput> downloadMuxed(
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

    if (AdaptivePairDownloader.needsFfmpeg(muxed)) {
      final outputPath = await FileUtils.getUniqueFilePath('$outputDir/$baseName.${options.videoFormat.value}');
      final partPath = _partPathFor(outputPath);
      onStatus?.call('Downloading (stream)...');
      try {
        final declaredDuration = await _hlsDownloader.downloadVerified(
          url: muxed.url,
          outputPath: partPath,
          headers: requestContext.headers,
          cookiesByDomain: requestContext.cookiesByDomain,
          totalDuration: duration,
          onProgress: (p) => onProgress?.call(p * 0.9),
          onStatus: onStatus,
          processTimeout: AdaptivePairDownloader.processTimeoutFor(duration),
        );
        onProgress?.call(0.9);
        await _fileMover.move(partPath, outputPath);
        return DownloadedOutput(outputPath, declaredDuration: declaredDuration);
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
        return DownloadedOutput(outputPath);
      }

      final outputPath = await FileUtils.getUniqueFilePath(
        '$outputDir/$baseName.${options.videoFormat.value}',
      );
      try {
        await _merger.run(_merger.buildRemuxArgs(inputPath: tempPath, outputPath: outputPath));
        return DownloadedOutput(outputPath);
      } on MediaMergeException catch (e) {
        // Container change failed (e.g. codec unsupported by the container):
        // keep the original file rather than losing the download entirely.
        onStatus?.call('Kept original format (container conversion failed: ${e.message})');
        final fallbackPath = await FileUtils.getUniqueFilePath('$outputDir/$baseName.${muxed.container}');
        await _fileMover.move(tempPath, fallbackPath);
        return DownloadedOutput(fallbackPath);
      }
    } finally {
      // If either branch above moved tempPath away, this is a safe no-op
      // (the file no longer exists at tempPath); otherwise it deletes the
      // now-unneeded temp on both success and any other exception.
      await _tryDelete(tempPath);
    }
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

  Future<void> _tryDelete(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best effort cleanup only.
    }
  }
}
