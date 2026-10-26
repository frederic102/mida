import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mida/cli/cli_stream_probe.dart';
import 'package:mida/cli/mida_cli.dart';
import 'package:mida/core/extractors/media_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/services/ffmpeg_locator.dart';
import 'package:mida/features/download/models/download_models.dart';
import 'package:mida/features/download/services/media_download_pipeline.dart';

/// Secrets planted in fixtures. No CLI output line may ever contain one.
const secretSig = 'SECRETSIG123';
const secretHeader = 'SECRETHEADER456';
const secretCookie = 'SECRETCOOKIE789';

const testUrl = 'https://video.example.com/watch/42';

/// A resolved video with one muxed, one video-only and one audio-only
/// format, plus headers/cookies/signed URLs that must never be printed.
MediaInfo sampleInfo() => MediaInfo(
      id: '42',
      title: 'Sample clip',
      author: 'Someone',
      duration: const Duration(seconds: 90, milliseconds: 500),
      sourceUrl: Uri.parse(testUrl),
      requestHeaders: const {'Authorization': 'Bearer $secretHeader'},
      cookiesByDomain: const {
        'example.com': [
          CookieEntry(domain: 'example.com', path: '/', secure: true, name: 'sid', value: secretCookie),
        ],
      },
      captions: const [CaptionTrack(languageCode: 'en', url: 'https://cdn.example.com/en.vtt?sig=$secretSig')],
      formats: const [
        MediaFormat(
          id: 'muxed-720',
          url: 'https://cdn.example.com/720.mp4?sig=$secretSig',
          container: 'mp4',
          height: 720,
          fps: 30,
          contentLength: 1000,
          hasVideo: true,
          hasAudio: true,
        ),
        MediaFormat(
          id: 'v-1080',
          url: 'https://cdn.example.com/1080.mp4?sig=$secretSig',
          container: 'mp4',
          height: 1080,
          fps: 60,
          hasVideo: true,
          hasAudio: false,
        ),
        MediaFormat(
          id: 'a-128',
          url: 'https://cdn.example.com/a.m4a?sig=$secretSig',
          container: 'm4a',
          hasVideo: false,
          hasAudio: true,
          protocol: 'm3u8',
        ),
      ],
    );

/// Registry whose resolve step is fully scripted (no extractor, no retry
/// back-off, no network).
class FakeRegistry extends ExtractorRegistry {
  final Future<MediaInfo> Function(Uri url) onResolve;
  final List<Uri> resolved = [];

  FakeRegistry(this.onResolve) : super(const []);

  factory FakeRegistry.ok([MediaInfo? info]) => FakeRegistry((_) async => info ?? sampleInfo());

  factory FakeRegistry.throwing(Object error) => FakeRegistry((_) async => throw error);

  @override
  Future<MediaInfo> resolveInfo(Uri url) {
    resolved.add(url);
    return onResolve(url);
  }
}


/// One recorded [FakePipeline.download] call.
class PipelineCall {
  final MediaInfo info;
  final DownloadType type;
  final DownloadOptions options;
  final String outputDir;

  /// What ffmpeg resolves to for this pipeline's own environment, looked up
  /// mid-run (null when the pipeline was not built by the CLI's factory).
  final String? ffmpegSeenDuringRun;

  PipelineCall(this.info, this.type, this.options, this.outputDir, this.ffmpegSeenDuringRun);
}

/// Pipeline double: writes [bytes] to `<outputDir>/<fileName>` and returns
/// that path, or throws [error]. Records what it was asked for and, when
/// built through [FakePipeline.factory], which ffmpeg its environment picks.
class FakePipeline implements MediaDownloadPipeline {
  final Object? error;
  final String fileName;
  final List<int> bytes;
  final bool writeFile;
  final FutureOr<void> Function(void Function(double)? onProgress, void Function(String)? onStatus)? script;
  final List<PipelineCall> calls = [];

  /// The environment the CLI handed [FakePipeline.factory], if any.
  Map<String, String>? environment;

  FakePipeline({
    this.error,
    this.fileName = 'Sample clip.mp4',
    this.bytes = const [1, 2, 3, 4, 5],
    this.writeFile = true,
    this.script,
  });

  /// A [PipelineFactory] that records the environment on [pipeline].
  static PipelineFactory factory(FakePipeline pipeline) => (env) {
        pipeline.environment = env;
        return pipeline;
      };

  @override
  Future<String> download({
    required MediaInfo info,
    required DownloadType type,
    required DownloadOptions options,
    required String outputDir,
    void Function(double progress)? onProgress,
    void Function(String message)? onStatus,
  }) async {
    await script?.call(onProgress, onStatus);
    final env = environment;
    final ffmpeg = env == null ? null : await FfmpegLocator.ffmpegPath(environment: env);
    calls.add(PipelineCall(info, type, options, outputDir, ffmpeg));
    final err = error;
    if (err != null) throw err;
    final path = '$outputDir${Platform.pathSeparator}$fileName';
    if (writeFile) await File(path).writeAsBytes(bytes);
    return path;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// ffprobe JSON for an h264 1920x1080 + aac file of 90.5 s.
const probeJson = '{"streams":[{"codec_type":"video","codec_name":"h264","width":1920,"height":1080},'
    '{"codec_type":"audio","codec_name":"aac"}],"format":{"duration":"90.500000"}}';

/// A [Process] double. [exitCode] null = never exits (and stdout never
/// closes), which is what a hung ffprobe looks like.
class FakeProcess implements Process {
  final int? code;
  final String output;
  final Completer<int> _exit = Completer<int>();
  final StreamController<List<int>> _stdout = StreamController<List<int>>();
  final List<ProcessSignal> killed = [];

  /// [bytes] are written to stdout as is (for malformed UTF-8); with
  /// [closeStdout] stdout ends even while the exit stays pending.
  FakeProcess({this.code = 0, this.output = '', List<int>? bytes, bool closeStdout = false}) {
    if (output.isNotEmpty) _stdout.add(utf8.encode(output));
    if (bytes != null) _stdout.add(bytes);
    if (code != null || closeStdout) _stdout.close();
    if (code != null) _exit.complete(code);
  }

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed.add(signal);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A [ProbeFactory] that never spawns a process. [stdoutJson] null =
/// ffprobe failed (exit 1).
ProbeFactory fakeProbe({String? stdoutJson = probeJson}) => (_) => CliStreamProbe(
      ffprobePathResolver: () async => 'ffprobe-fake',
      starter: (exe, args) async =>
          stdoutJson == null ? FakeProcess(code: 1) : FakeProcess(code: 0, output: stdoutJson),
    );

/// Captured result of one [runMidaCli] call.
class CliRun {
  final int exitCode;
  final String stdoutText;
  final String stderrText;

  CliRun(this.exitCode, this.stdoutText, this.stderrText);

  List<String> get lines => const LineSplitter().convert(stdoutText).where((l) => l.isNotEmpty).toList();

  /// Every stdout line decoded (throws if any line is not a JSON object).
  List<Map<String, Object?>> get events => [for (final l in lines) jsonDecode(l) as Map<String, Object?>];

  Map<String, Object?> get last => events.last;

  List<Map<String, Object?>> ofEvent(String name) => events.where((e) => e['event'] == name).toList();
}

ExtractorRegistry _offlineRegistry({bool useBrowserLoginSession = false, bool forceHeadless = false}) =>
    FakeRegistry.ok();

/// Runs the CLI hermetically through the guarded entry: captured sinks,
/// explicit environment (never the real process environment), injected
/// registry/pipeline, a fake ffprobe unless [probeFactory] is given.
Future<CliRun> runCli(
  List<String> args, {
  ExtractorRegistry? registry,
  MediaDownloadPipeline? pipeline,
  Map<String, String> environment = const {},
  RegistryBuilder? registryBuilder,
  PipelineFactory? pipelineFactory,
  ProbeFactory? probeFactory,
}) async {
  final out = StringBuffer();
  final err = StringBuffer();
  final code = await runMidaCliGuarded(
    args,
    registry: registry,
    pipeline: pipeline,
    out: out,
    err: err,
    environment: environment,
    // Never the real registry: an unscripted test must not touch the
    // network or launch a browser.
    registryBuilder: registryBuilder ?? _offlineRegistry,
    pipelineFactory: pipelineFactory ?? (_) => pipeline ?? FakePipeline(),
    probeFactory: probeFactory ?? fakeProbe(),
  );
  return CliRun(code, out.toString(), err.toString());
}
