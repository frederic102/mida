import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/extractors/media_extractor.dart';
import '../core/extractors/media_models.dart';
import '../core/services/download_settings.dart';
import '../core/services/ffmpeg_locator.dart';
import '../core/utils/url_parser.dart';
import '../features/download/services/media_download_pipeline.dart';
import 'cli_args.dart';
import 'cli_events.dart';
import 'cli_exit.dart';
import 'cli_format_ids.dart';
import 'cli_stream_probe.dart';

/// Everything one CLI run needs, built once per [runMidaCli] call. Nothing
/// in here is process-global, so two runs in the same isolate never see
/// each other's environment, registry or ffmpeg choice.
class CliContext {
  final CliRequest request;
  final CliEmitter emitter;
  final StringSink err;

  /// The run's environment as given (or the process environment).
  final Map<String, String> env;

  /// [env] plus `--ffmpeg` as `MIDA_FFMPEG_PATH`: the only map the ffmpeg
  /// and ffprobe lookups of this run read.
  final Map<String, String> ffmpegEnv;
  final ExtractorRegistry Function() buildRegistry;
  final MediaDownloadPipeline Function() buildPipeline;
  final CliStreamProbe Function() buildProbe;

  CliContext({
    required this.request,
    required this.emitter,
    required this.err,
    required this.env,
    required this.ffmpegEnv,
    required this.buildRegistry,
    required this.buildPipeline,
    required this.buildProbe,
  });

  /// Emits [failure] as the `error` event and returns its exit code.
  int fail(CliFailure failure) {
    emitter.error(failure.code, failure.message);
    return failure.exitCode;
  }

  /// Classifies [error], logs it when debugging, and emits it.
  int failWith(Object error, StackTrace stack, CliStage stage) {
    final failure = classifyError(error, stage: stage);
    debugLog(error, failure, stack);
    return fail(failure);
  }

  /// Debug-only detail on stderr (never stdout), gated on `MIDA_DEBUG=1` in
  /// the run's environment. Prints the *classified* message, never the raw
  /// exception: the raw text of a header or DevTools error is exactly what
  /// [classifyError] replaces with a fixed sentence. The stack trace holds
  /// only code locations.
  void debugLog(Object error, CliFailure failure, StackTrace stack) {
    if (env['MIDA_DEBUG'] != '1') return;
    err.writeln(UrlParser.redactUrlsInText('debug: ${error.runtimeType} -> ${failure.code}: ${failure.message}\n$stack'));
  }

  /// Echoes at most the scheme and host of [raw]: never userinfo
  /// (`user:pw@`), path, query or fragment (`#token=`), which the URL
  /// redaction would not recognise in something that is not an http(s) URL.
  int invalidUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    final scheme = uri?.scheme ?? '';
    final host = uri == null || !uri.hasAuthority ? '' : uri.host;
    final safe = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]{0,15}$');
    final safeHost = RegExp(r'^[A-Za-z0-9.-]{1,253}$');
    final detail = safe.hasMatch(scheme) && safeHost.hasMatch(host) ? ' (got a "$scheme" URL for host $host)' : '';
    return fail(CliFailure('INVALID_URL', 'The argument is not a valid http(s) URL$detail.', CliExit.usage));
  }
}

Uri? validatedUrl(String raw) => UrlParser.isValidUrl(raw) ? Uri.tryParse(raw) : null;

/// `download`: pre-checks, resolve, pipeline, ffprobe summary. Every
/// exception, including one from a pre-check, ends as one JSON `error`.
Future<int> runDownloadCommand(CliContext ctx) async {
  final request = ctx.request;
  // Which step a failure came from: an exception the table does not name
  // explicitly defaults to 3 (resolve) or 4 (download) by this.
  var stage = CliStage.resolve;
  try {
    final uri = validatedUrl(request.url!);
    if (uri == null) return ctx.invalidUrl(request.url!);

    final home = ctx.env['USERPROFILE'] ?? ctx.env['HOME'] ?? '';
    if (request.outDir == null && home.trim().isEmpty) {
      // The default folder hangs off the home folder; without one it would
      // silently become `\Videos\MiDa` at the drive root.
      return ctx.fail(
        const CliFailure('OUTPUT_DIR_UNAVAILABLE', 'No USERPROFILE/HOME in the environment; pass --out DIR.', CliExit.environment),
      );
    }
    final rawDir = request.outDir ?? DownloadSettings.defaultDesktopDownloadPath(environment: ctx.env);
    if (rawDir.runes.any((c) => c < 0x20 || c == 0x7f)) {
      // Windows truncates a path at NUL; never write somewhere else.
      return ctx.fail(const CliFailure('INVALID_OUT', '--out contains a control character.', CliExit.usage));
    }
    final settings = DownloadSettings(
      downloadPath: p.normalize(p.absolute(rawDir)),
      useBrowserLoginSession: request.loginSession,
    );
    if (File(settings.downloadPath).existsSync()) {
      return ctx.fail(CliFailure('INVALID_OUT', '--out points at a file, not a folder: ${settings.downloadPath}', CliExit.usage));
    }
    final ffmpegProblem = await FfmpegLocator.overrideProblem(environment: ctx.ffmpegEnv);
    if (ffmpegProblem != null) {
      return ctx.fail(CliFailure('FFMPEG_MISSING', ffmpegProblem, CliExit.environment));
    }
    try {
      await Directory(settings.downloadPath).create(recursive: true);
    } on FileSystemException catch (e) {
      final code = e.osError?.errorCode;
      return ctx.fail(CliFailure(
        'OUTPUT_DIR_UNAVAILABLE',
        'Cannot create ${settings.downloadPath}${code == null ? '' : ' (OS error $code)'}.',
        CliExit.environment,
      ));
    }

    for (final note in request.noOpWarnings) {
      ctx.emitter.status('Note: $note');
    }
    var attempts = 1;
    ctx.emitter.status('Resolving...');
    var info = await ctx.buildRegistry().resolveInfo(uri);
    // A detached failure may have ended the run while this was resolving.
    if (ctx.emitter.terminated) return CliExit.download;
    stage = CliStage.download;
    final pinned = request.formatId;
    if (pinned != null) {
      final narrowed = _pinFormat(info, pinned);
      if (narrowed == null) {
        return ctx.fail(CliFailure('FORMAT_NOT_FOUND', 'No format with id "$pinned". Run "resolve" to list ids.', CliExit.usage));
      }
      info = narrowed;
    }

    final outputPath = await ctx.buildPipeline().download(
      info: info,
      type: request.type,
      options: request.downloadOptions,
      outputDir: settings.downloadPath,
      onProgress: (fraction) {
        if (ctx.emitter.terminated) throw const CliAborted();
        ctx.emitter.progress(fraction);
      },
      onStatus: (message) {
        if (ctx.emitter.terminated) throw const CliAborted();
        final retry = RegExp(r'^Retrying with another format \((\d+)/').firstMatch(message);
        final n = retry == null ? null : int.tryParse(retry.group(1)!);
        if (n != null && n > attempts) attempts = n;
        ctx.emitter.status(message);
      },
    );

    final file = File(p.normalize(p.absolute(outputPath)));
    if (ctx.emitter.terminated) {
      // Finished behind an already reported error: do not leave the file.
      if (await file.exists()) await file.delete();
      return CliExit.download;
    }
    if (!await file.exists()) {
      return ctx.fail(const CliFailure('DOWNLOAD_FAILED', 'The download finished but no output file exists.', CliExit.download));
    }
    ctx.emitter.state.savedFile = true;
    final summary = await ctx.buildProbe().summarize(file.path);
    ctx.emitter.result('download', {
      'output_path': file.path,
      'bytes': await file.length(),
      ..._streamBlocks(summary),
      'attempts': attempts,
    });
    return CliExit.ok;
  } catch (e, st) {
    if (ctx.emitter.terminated) return CliExit.download;
    return ctx.failWith(e, st, stage);
  }
}

/// `video`/`audio` result blocks. ffprobe unavailable ([summary] null):
/// both blocks present with null fields. ffprobe ran: a block is null when
/// the file has no stream of that kind (an audio download has no video).
Map<String, Object?> _streamBlocks(OutputSummary? summary) {
  if (summary == null) {
    return {
      'video': {'codec': null, 'width': null, 'height': null, 'duration_seconds': null},
      'audio': {'codec': null},
    };
  }
  final v = summary.video;
  final a = summary.audio;
  return {
    'video': v == null
        ? null
        : {'codec': v.codec, 'width': v.width, 'height': v.height, 'duration_seconds': v.durationSeconds},
    'audio': a == null ? null : {'codec': a.codec},
  };
}

/// Narrows [info] to the one format whose selection id (as printed by
/// `resolve`, see [formatSelectionIds]) is [id], plus every audio-only
/// format when that one is video-only, so the pipeline can still pair it.
/// Null if absent.
MediaInfo? _pinFormat(MediaInfo info, String id) {
  final index = formatSelectionIds(info.formats).indexOf(id);
  if (index == -1) return null;
  final chosen = info.formats[index];
  final keep = <MediaFormat>[
    chosen,
    if (chosen.isVideoOnly) ...info.formats.where((f) => f.isAudioOnly),
  ];
  return info.copyWith(formats: keep);
}
