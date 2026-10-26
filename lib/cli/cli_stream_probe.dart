import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/services/ffmpeg_locator.dart';

/// What ffprobe found in a finished file. A null block means ffprobe ran and
/// the file has no stream of that kind (an audio-only download has no video).
class OutputSummary {
  final ({String? codec, int? width, int? height, double? durationSeconds})? video;
  final ({String? codec})? audio;

  const OutputSummary({this.video, this.audio});
}

/// Starts a probe process. Production: [Process.start].
typedef ProbeStarter = Future<Process> Function(String executable, List<String> arguments);

/// ffprobe summary for the CLI `result` event (codec, size, duration). The
/// existing `OutputStreamProber` only reports which stream *types* exist,
/// which is not enough for the result block, so this asks ffprobe for the
/// handful of extra fields. Best effort: any failure returns null and the
/// caller reports null fields instead of failing a finished download.
///
/// Bounded: the whole probe (path lookup, start, output, exit) must finish
/// within [timeout]. On expiry the child is killed and null is returned,
/// so a hung ffprobe can never hold back a download that already saved
/// its file.
class CliStreamProbe {
  static const defaultTimeout = Duration(seconds: 20);

  final Future<String> Function() _ffprobePathResolver;
  final ProbeStarter _starter;
  final Duration timeout;

  CliStreamProbe({
    Future<String> Function()? ffprobePathResolver,
    ProbeStarter? starter,
    Map<String, String>? environment,
    this.timeout = defaultTimeout,
  })  : _ffprobePathResolver =
            ffprobePathResolver ?? (() => FfmpegLocator.ffprobePath(environment: environment)),
        _starter = starter ?? Process.start;

  Future<OutputSummary?> summarize(String path) async {
    Process? process;
    var expired = false;
    Future<OutputSummary?> run() async {
      final exe = await _ffprobePathResolver();
      if (expired) return null;
      final started = await _starter(exe, [
        '-v', 'error',
        '-show_entries', 'stream=codec_type,codec_name,width,height:format=duration',
        '-of', 'json',
        path,
      ]);
      process = started;
      if (expired) {
        started.kill(ProcessSignal.sigkill);
        return null;
      }
      unawaited(started.stderr.drain<void>().catchError((Object _) {}));
      // Output and exit are awaited together, with handlers attached right
      // away: a stdout or UTF-8 decoding error then fails this future (and
      // so yields null) instead of surfacing as an unhandled async error
      // while the exit code is still pending.
      final both = await Future.wait<Object>(
        [started.stdout.transform(utf8.decoder).join(), started.exitCode],
        eagerError: true,
      );
      if (both[1] != 0) return null;
      return parse(both[0] as String);
    }

    try {
      return await run().timeout(timeout, onTimeout: () {
        expired = true;
        process?.kill(ProcessSignal.sigkill);
        return null;
      });
    } catch (_) {
      // A stdout or decoding error ends the wait early; the child may still
      // be running, so stop it here too (killing an exited process is a no-op).
      expired = true;
      process?.kill(ProcessSignal.sigkill);
      return null;
    }
  }

  /// Parses ffprobe's `-of json` output. Null when it is not the expected shape.
  static OutputSummary? parse(String json) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    final streams = decoded['streams'];
    if (streams is! List) return null;
    final format = decoded['format'];
    final durationRaw = format is Map ? format['duration'] : null;
    final duration = durationRaw is String ? double.tryParse(durationRaw) : (durationRaw is num ? durationRaw.toDouble() : null);

    Map<String, Object?>? first(String type) {
      for (final s in streams) {
        if (s is Map<String, Object?> && s['codec_type'] == type) return s;
      }
      return null;
    }

    final v = first('video');
    final a = first('audio');
    return OutputSummary(
      video: v == null
          ? null
          : (
              codec: _str(v['codec_name']),
              width: _int(v['width']),
              height: _int(v['height']),
              durationSeconds: duration == null || !duration.isFinite ? null : duration,
            ),
      audio: a == null ? null : (codec: _str(a['codec_name'])),
    );
  }

  static String? _str(Object? v) => v is String ? v : null;

  static int? _int(Object? v) => v is int ? v : null;
}
