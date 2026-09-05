import 'dart:io';

import '../services/ffmpeg_locator.dart';

/// Cheap post-download sanity check: does the produced file actually
/// contain the stream types (`video`/`audio`) the selected format was
/// supposed to have? Exists because a mislabeled source (e.g. a
/// video-only DASH rendition marked as if it were muxed, or a broken/DRM
/// playlist ffmpeg "succeeded" against but produced garbage from) can
/// otherwise look like a successful download that is actually unplayable
/// or missing sound.
class OutputStreamProber {
  final Future<String> Function() _ffprobePathResolver;

  OutputStreamProber({Future<String> Function()? ffprobePathResolver})
      : _ffprobePathResolver = ffprobePathResolver ?? FfmpegLocator.ffprobePath;

  /// Returns the distinct `codec_type` values ffprobe reports for [path]
  /// (typically a subset of `{video, audio}`), or null if ffprobe itself
  /// could not be run or its output could not be read - a probe failure
  /// must not be treated the same as "probed successfully and found no
  /// streams" (see caller): a broken/missing ffprobe is an environment
  /// problem, not evidence the downloaded format was bad.
  Future<Set<String>?> streamTypes(String path) async {
    try {
      final ffprobePath = await _ffprobePathResolver();
      final result = await Process.run(ffprobePath, [
        '-v', 'error',
        '-show_entries', 'stream=codec_type',
        '-of', 'csv=p=0',
        path,
      ]);
      if (result.exitCode != 0) return null;
      final stdout = result.stdout;
      if (stdout is! String) return null;
      return stdout.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toSet();
    } catch (_) {
      return null;
    }
  }
}
