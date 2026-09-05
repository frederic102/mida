import 'dart:io';

import '../../features/download/services/download_service_io.dart';
import '../services/ffmpeg_locator.dart';

class MediaMergeException implements Exception {
  final String message;
  const MediaMergeException(this.message);

  /// Builds from a process's raw stderr: keeps only the last few non-blank
  /// lines, since a failed ffmpeg run typically buries the actual reason
  /// under pages of encoder banner/build-config output. Shared by
  /// [MediaMerger.run] and `HlsFfmpegDownloader.run` (both wrap ffmpeg)
  /// instead of each re-implementing the same tail-extraction.
  factory MediaMergeException.fromStderr(String stderr) {
    final lines = stderr.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return const MediaMergeException('ffmpeg failed with no output');
    final tail = lines.length > 3 ? lines.sublist(lines.length - 3) : lines;
    return MediaMergeException(tail.join(' | '));
  }

  @override
  String toString() => 'MediaMergeException: $message';
}

/// Builds and runs the ffmpeg invocations needed to turn downloaded
/// video/audio pieces into the file the user asked for. Argument building
/// is pure (unit tested); [run] does the actual `Process.start` and is
/// exercised by the lead's live verification instead (real ffmpeg output
/// is only meaningful against real media).
class MediaMerger {
  final Future<String> Function() _ffmpegPathResolver;

  MediaMerger({Future<String> Function()? ffmpegPathResolver})
      : _ffmpegPathResolver = ffmpegPathResolver ?? FfmpegLocator.ffmpegPath;

  /// Case (a): separate video + audio adaptive streams, muxed into
  /// [container]. Normally both streams are already in a codec the target
  /// container supports (copied, no re-encode); [transcodeVideo]/
  /// [transcodeAudio] are set by [FormatSelector] only in the rare case
  /// where it had to fall back to an incompatible codec (no muxed
  /// alternative existed either), in which case that half is transcoded to
  /// a codec [container] can actually hold instead of blindly copying it.
  List<String> buildMergeArgs({
    required String videoPath,
    required String audioPath,
    required String outputPath,
    required VideoFormat container,
    bool transcodeVideo = false,
    bool transcodeAudio = false,
  }) {
    final videoCodec = transcodeVideo ? _videoTranscodeCodec(container) : 'copy';
    final audioCodec = transcodeAudio ? _audioTranscodeCodec(container) : 'copy';
    return [
      '-y', '-i', videoPath, '-i', audioPath,
      '-c:v', videoCodec,
      '-c:a', audioCodec,
      outputPath,
    ];
  }

  /// Encoder to fall back to when a video stream's codec cannot be copied
  /// as-is into [container]. `mkv` never needs this (it accepts any codec).
  String _videoTranscodeCodec(VideoFormat container) {
    return container == VideoFormat.webm ? 'libvpx-vp9' : 'libx264';
  }

  /// Encoder to fall back to when an audio stream's codec cannot be copied
  /// as-is into [container].
  String _audioTranscodeCodec(VideoFormat container) {
    return container == VideoFormat.webm ? 'libopus' : 'aac';
  }

  /// Case (b): audio-only download, transcoded to the requested format.
  /// `best` quality keeps the codec's own default rate; anything else maps
  /// to an explicit `-b:a Nk` per the existing [AudioQuality] kbps values.
  List<String> buildAudioConvertArgs({
    required String inputPath,
    required String outputPath,
    required AudioFormat format,
    required AudioQuality quality,
  }) {
    final args = <String>['-y', '-i', inputPath, '-vn', ...audioCodecArgs(format)];
    if (quality != AudioQuality.best) {
      args.addAll(['-b:a', '${quality.value}k']);
    }
    args.add(outputPath);
    return args;
  }

  /// The `-c:a ...` args for a given output [format]. Public (not just used
  /// internally by [buildAudioConvertArgs]) so `HlsFfmpegDownloader` can
  /// reuse the same mapping instead of duplicating it for the audio-only
  /// HLS/DASH direct-ffmpeg path.
  List<String> audioCodecArgs(AudioFormat format) {
    switch (format) {
      case AudioFormat.mp3:
        return ['-c:a', 'libmp3lame'];
      case AudioFormat.m4a:
        return ['-c:a', 'aac'];
      case AudioFormat.opus:
        return ['-c:a', 'libopus'];
      case AudioFormat.flac:
        return ['-c:a', 'flac'];
      case AudioFormat.wav:
        return ['-c:a', 'pcm_s16le'];
    }
  }

  /// Case (c): source only offered a muxed format. Remux (no re-encode)
  /// into the requested container.
  List<String> buildRemuxArgs({required String inputPath, required String outputPath}) {
    return ['-y', '-i', inputPath, '-c', 'copy', outputPath];
  }

  Future<void> run(List<String> args) async {
    final ffmpegPath = await _ffmpegPathResolver();
    final result = await Process.run(ffmpegPath, args);
    if (result.exitCode != 0) {
      throw MediaMergeException.fromStderr(result.stderr.toString());
    }
  }
}
