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
  /// (typically a subset of `{video, audio}`), an empty set when ffprobe
  /// ran but could not make sense of the file at all, or null only when
  /// ffprobe itself could not even be started.
  ///
  /// These are two genuinely different failure shapes, previously
  /// conflated into one (both returned null, "inconclusive, do not fail
  /// the download over it") - live-caught (coordinator repro): a CMAF/
  /// fragmented-mp4 media segment with no init segment (`moof`/`traf`/
  /// `trun` boxes but no `ftyp`/`moov` at all - vimeo and facebook both
  /// exposed exactly this shape as if it were a complete progressive
  /// file) makes ffprobe exit non-zero with "trun track id unknown, no
  /// tfhd was found" - that is not an environment problem, it is
  /// definitive evidence the downloaded content is not a real,
  /// standalone-playable file, and letting it through as "could not
  /// verify" was exactly why these turned up as a "successful" download
  /// with zero real streams. A `Process.run` call that never gets to
  /// exit at all (missing/unspawnable ffprobe binary, an `OSError`, ...)
  /// is the actual environment-problem case, and stays null.
  Future<Set<String>?> streamTypes(String path) async {
    ProcessResult result;
    try {
      final ffprobePath = await _ffprobePathResolver();
      result = await Process.run(ffprobePath, [
        '-v', 'error',
        '-show_entries', 'stream=codec_type',
        '-of', 'csv=p=0',
        path,
      ]);
    } catch (_) {
      return null;
    }
    final stdout = result.stdout;
    final types = stdout is String
        ? stdout.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toSet()
        : <String>{};
    // A non-zero exit with nothing parsed means ffprobe actively refused
    // this file (corrupt/fragmented-without-init/not really media at
    // all) - a confirmed empty set, not an inconclusive null. A non-zero
    // exit that still yielded some partial stream info is left as-is
    // rather than discarded.
    if (result.exitCode != 0 && types.isEmpty) return const <String>{};
    return types;
  }

  /// Phase 6 round 2 (S-R7): the container-level `format=duration` (in
  /// whole seconds plus fraction) ffprobe reports for [path], or null when
  /// ffprobe could not even be run, its exit was non-zero, or the value it
  /// printed could not be parsed as a positive number. Unlike
  /// [streamTypes], there is no "confirmed empty" distinction worth making
  /// here - a duration we could not read is simply unknown, never
  /// evidence of anything on its own, so [DownloadOutcomeVerifier] treats
  /// null the same as "nothing to compare against" rather than a failure.
  Future<Duration?> duration(String path) async {
    ProcessResult result;
    try {
      final ffprobePath = await _ffprobePathResolver();
      result = await Process.run(ffprobePath, [
        '-v', 'error',
        '-show_entries', 'format=duration',
        '-of', 'csv=p=0',
        path,
      ]);
    } catch (_) {
      return null;
    }
    if (result.exitCode != 0) return null;
    final stdout = result.stdout;
    if (stdout is! String) return null;
    final seconds = double.tryParse(stdout.trim());
    if (seconds == null || !seconds.isFinite || seconds <= 0) return null;
    return Duration(milliseconds: (seconds * 1000).round());
  }
}
