import 'dart:async';
import 'dart:io';

import '../core/extractors/extractor_registry_builder.dart';
import '../core/extractors/media_extractor.dart';
import '../core/extractors/media_models.dart';
import '../core/services/ffmpeg_locator.dart';
import '../core/utils/url_parser.dart';
import '../features/download/services/media_download_pipeline.dart';
import 'cli_args.dart';
import 'cli_download.dart';
import 'cli_events.dart';
import 'cli_exit.dart';
import 'cli_format_ids.dart';
import 'cli_output_sink.dart';
import 'cli_sites.dart';
import 'cli_stream_probe.dart';
import 'cli_version.dart';

export 'cli_version.dart';

typedef RegistryBuilder = ExtractorRegistry Function({bool useBrowserLoginSession, bool forceHeadless});

/// Builds the run's pipeline. [ffmpegEnvironment] is the run's effective
/// environment (`--ffmpeg` folded in as `MIDA_FFMPEG_PATH`).
typedef PipelineFactory = MediaDownloadPipeline Function(Map<String, String> ffmpegEnvironment);

/// Builds the ffprobe summary step, with the same environment.
typedef ProbeFactory = CliStreamProbe Function(Map<String, String> ffmpegEnvironment);

MediaDownloadPipeline _defaultPipeline(Map<String, String> env) => MediaDownloadPipeline(ffmpegEnvironment: env);

CliStreamProbe _defaultProbe(Map<String, String> env) => CliStreamProbe(environment: env);

bool _truthy(String? value) {
  final v = value?.trim().toLowerCase();
  return v == '1' || v == 'true' || v == 'yes';
}

/// `bin/mida_cli.dart` entry: run guarded, flush both streams (ignoring a
/// reader that went away), then exit with the command's code (a plain
/// `exit` can drop buffered stdout on a pipe).
Future<void> runMidaCliProcess(List<String> args) async {
  final out = CliOutputSink(stdout);
  final err = CliOutputSink(stderr);
  // A closed pipe surfaces as an error on `done`; handle it so it is never
  // an unhandled exception (exit 255 plus a Dart trace on stderr).
  unawaited(stdout.done.then<void>((_) {}, onError: (Object _) => out.markClosed()));
  unawaited(stderr.done.then<void>((_) {}, onError: (Object _) => err.markClosed()));
  final state = CliRunState();
  final code = await runMidaCliGuarded(args, out: out, err: err, runState: state);
  await _flushQuietly(stdout, out);
  await _flushQuietly(stderr, err);
  exit(_withClosedOutput(code, out, state));
}

/// [CliExit.outputClosed] when stdout went away, unless the command already
/// saved its file: then the file is the result and the real code (0, or the
/// failure that came after saving) is kept, never 8.
int _withClosedOutput(int code, CliOutputSink out, CliRunState state) =>
    out.closed && !state.savedFile ? CliExit.outputClosed : code;

Future<void> _flushQuietly(IOSink sink, CliOutputSink guard) async {
  if (guard.closed) return;
  try {
    await sink.flush();
  } catch (_) {
    guard.markClosed();
  }
}

/// [runMidaCli] inside [runZonedGuarded]: an error that escapes it (an
/// unawaited future failing in the download chain, say) still ends as one
/// JSON `error` line and a contract exit code, never a raw Dart crash.
/// When [out] stops accepting writes the result is [CliExit.outputClosed],
/// except after a download that saved its file (then 0).
/// [runState] lets the caller inspect the run afterwards.
Future<int> runMidaCliGuarded(
  List<String> args, {
  ExtractorRegistry? registry,
  MediaDownloadPipeline? pipeline,
  StringSink? out,
  StringSink? err,
  Map<String, String>? environment,
  RegistryBuilder? registryBuilder,
  PipelineFactory? pipelineFactory,
  ProbeFactory? probeFactory,
  CliRunState? runState,
}) {
  final sink = out is CliOutputSink ? out : CliOutputSink(out ?? stdout);
  final errSink = err is CliOutputSink ? err : CliOutputSink(err ?? stderr);
  final state = runState ?? CliRunState();
  final done = Completer<int>();
  void finish(int code) {
    if (!done.isCompleted) done.complete(_withClosedOutput(code, sink, state));
  }

  runZonedGuarded(() async {
    finish(await runMidaCli(
      args,
      registry: registry,
      pipeline: pipeline,
      out: sink,
      err: errSink,
      environment: environment,
      registryBuilder: registryBuilder,
      pipelineFactory: pipelineFactory,
      probeFactory: probeFactory,
      runState: state,
    ));
  }, (error, stack) {
    // A detached failure after the run already ended (result or error
    // written) changes nothing. Before that, it ends the run: the shared
    // [state] stops the command's own emitter and makes the download step
    // abort instead of saving a file behind this error.
    if (done.isCompleted || state.terminated) return;
    final stage = args.contains('download') ? CliStage.download : CliStage.resolve;
    final failure = classifyError(error, stage: stage);
    CliEmitter(sink, state: state).error(failure.code, failure.message);
    finish(failure.exitCode);
  });
  return done.future;
}

/// Runs one CLI command and returns its exit code (see [CliExit]). Never
/// throws for an operational failure: every failure becomes one JSON
/// `error` line on [out] plus a non-zero code. Hermetic when [registry]
/// (or [registryBuilder]), [pipeline] (or [pipelineFactory]), [out], [err]
/// and [environment] are all supplied. No process-global state is read
/// or written, so concurrent calls are independent.
Future<int> runMidaCli(
  List<String> args, {
  ExtractorRegistry? registry,
  MediaDownloadPipeline? pipeline,
  StringSink? out,
  StringSink? err,
  Map<String, String>? environment,
  RegistryBuilder? registryBuilder,
  PipelineFactory? pipelineFactory,
  ProbeFactory? probeFactory,
  CliRunState? runState,
}) async {
  final state = runState ?? CliRunState();
  final env = environment ?? Platform.environment;
  final outSink = out ?? stdout;
  final errSink = err ?? stderr;

  final CliRequest request;
  try {
    request = parseCliArgs(args);
  } on CliUsageError catch (e) {
    CliEmitter(outSink, state: state).error(e.code, e.message);
    return CliExit.usage;
  }

  final emitter = CliEmitter(outSink, quiet: request.quiet, state: state);
  switch (request.command) {
    case 'help':
      emitter.result('help', {'usage': cliUsage});
      return CliExit.ok;
    case 'version':
      emitter.result('version', {'version': midaCliVersion});
      return CliExit.ok;
    case 'sites':
      emitter.result('sites', {'native': nativeSiteIds, 'tiers': siteTiers, 'measured_live': measuredLiveSiteIds});
      return CliExit.ok;
  }

  final headless = request.headless || _truthy(env['MIDA_HEADLESS']);
  // `--ffmpeg` beats MIDA_FFMPEG_PATH. This map is handed to this run's
  // pipeline and probe only; nothing is installed process-wide.
  final ffmpegEnv = Map<String, String>.unmodifiable({
    ...env,
    if (request.ffmpeg != null) FfmpegLocator.envVar: request.ffmpeg!,
  });
  final ctx = CliContext(
    request: request,
    emitter: emitter,
    err: errSink,
    env: env,
    ffmpegEnv: ffmpegEnv,
    buildRegistry: () =>
        registry ??
        (registryBuilder ?? buildExtractorRegistry)(useBrowserLoginSession: request.loginSession, forceHeadless: headless),
    buildPipeline: () => pipeline ?? (pipelineFactory ?? _defaultPipeline)(ffmpegEnv),
    buildProbe: () => (probeFactory ?? _defaultProbe)(ffmpegEnv),
  );
  if (request.command == 'resolve') return _runResolve(ctx);
  return runDownloadCommand(ctx);
}

/// The enum name for the four hand-detected platforms, else the bare host.
String _platformOf(Uri uri) {
  final platform = UrlParser.detectPlatform(uri.toString());
  if (platform != PlatformType.unknown) return platform.name;
  final host = uri.host.toLowerCase();
  return host.startsWith('www.') ? host.substring(4) : host;
}

double? _seconds(Duration? d) => d == null ? null : d.inMilliseconds / 1000;

Future<int> _runResolve(CliContext ctx) async {
  try {
    final uri = validatedUrl(ctx.request.url!);
    if (uri == null) return ctx.invalidUrl(ctx.request.url!);
    final info = await ctx.buildRegistry().resolveInfo(uri);
    ctx.emitter.result('resolve', {
      'title': info.title,
      'author': info.author,
      'duration_seconds': _seconds(info.duration),
      'platform': _platformOf(uri),
      'formats': [
        for (final (i, id) in formatSelectionIds(info.formats).indexed) _formatJson(id, info.formats[i]),
      ],
      'captions': [for (final c in info.captions) c.languageCode],
    });
    return CliExit.ok;
  } catch (e, st) {
    return ctx.failWith(e, st, CliStage.resolve);
  }
}

/// Only the public, non-sensitive format fields: never `url`, headers or
/// cookies. [id] is the selection id (see [formatSelectionIds]), not the
/// extractor's raw id, which may be a signed URL.
Map<String, Object?> _formatJson(String id, MediaFormat f) => {
      'id': id,
      'ext': f.container,
      'height': f.height,
      'fps': f.fps,
      'has_video': f.hasVideo,
      'has_audio': f.hasAudio,
      'protocol': f.protocol,
      'content_length': f.contentLength,
    };
