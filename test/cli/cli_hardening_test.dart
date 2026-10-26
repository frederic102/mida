import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/cli/cli_exit.dart';
import 'package:mida/cli/cli_stream_probe.dart';
import 'package:mida/cli/mida_cli.dart';
import 'package:mida/core/download/hls_ffmpeg_args.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/services/cdp_client.dart';
import 'package:mida/core/services/ffmpeg_locator.dart';

import 'cli_test_support.dart';

String _exe(String base) => Platform.isWindows ? '$base.exe' : base;

/// Signed-URL sentinels, one per output path under test.
String _signed(String tag) => 'https://leak.example/$tag?sig=SIGNED_$tag&token=T_$tag';

class _ThrowingSink implements StringSink {
  int attempts = 0;

  @override
  void write(Object? object) => _boom();
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) => _boom();
  @override
  void writeCharCode(int charCode) => _boom();
  @override
  void writeln([Object? object = '']) => _boom();

  void _boom() {
    attempts++;
    throw const FileSystemException('Broken pipe', '', OSError('The pipe is being closed.', 232));
  }
}

void main() {
  late Directory tmp;

  setUp(() async => tmp = await Directory.systemTemp.createTemp('mida_cli_hard_'));
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('MIDA_DEBUG uses the classified (sanitized) message', () {
    final errors = <String, Object>{
      'header error': const HeaderInjectionException('Refusing header "Authorization: Bearer $secretHeader"'),
      'DevTools payload': const CdpCommandException('Network.getCookies', {'cookies': 'sid=$secretCookie'}),
    };
    errors.forEach((name, error) {
      test(name, () async {
        final run = await runCli(['resolve', testUrl],
            registry: FakeRegistry.throwing(error), environment: const {'MIDA_DEBUG': '1'});
        expect(run.stderrText, contains('debug: '));
        for (final secret in [secretHeader, secretCookie]) {
          expect(run.stderrText, isNot(contains(secret)), reason: 'stderr leaked $secret');
          expect(run.stdoutText, isNot(contains(secret)), reason: 'stdout leaked $secret');
        }
      });
    });
  });

  group('every stdout string is redacted', () {
    test('resolve: title, author, format id, caption code', () async {
      final info = MediaInfo(
        id: '1',
        title: 'Watch ${_signed('TITLE')}',
        author: 'By ${_signed('AUTHOR')}',
        sourceUrl: Uri.parse(testUrl),
        formats: const [
          MediaFormat(
            id: 'https://leak.example/f?sig=SIGNED_FMT',
            url: 'https://cdn.example/x',
            container: 'mp4',
            hasVideo: true,
            hasAudio: true,
          ),
        ],
        captions: const [CaptionTrack(languageCode: 'https://leak.example/c?sig=SIGNED_CAP', url: 'https://cdn.example/c.vtt')],
      );
      final run = await runCli(['resolve', testUrl], registry: FakeRegistry.ok(info));
      expect(run.exitCode, 0, reason: run.stdoutText);
      expect(run.stdoutText, isNot(contains('SIGNED_')));
      expect(run.last['title'], startsWith('Watch https://leak.example'));
    });

    test('download: ffmpeg override diagnostic, unknown format id, usage echo, thrown error', () async {
      final runs = [
        await runCli(['download', testUrl, '--out', tmp.path, '--ffmpeg', _signed('FFMPEG')], pipeline: FakePipeline()),
        await runCli(['download', testUrl, '--out', tmp.path, '--format-id', _signed('FORMATID')],
            registry: FakeRegistry.ok(), pipeline: FakePipeline()),
        await runCli(['download', testUrl, '--quality', _signed('USAGE')]),
        await runCli(['download', testUrl, '--out', tmp.path],
            registry: FakeRegistry.ok(), pipeline: FakePipeline(error: StateError('failed at ${_signed('ERR')}'))),
        await runCli(['download', testUrl, '--out', tmp.path],
            registry: FakeRegistry.ok(), pipeline: FakePipeline(script: (_, s) => s!('Fetching ${_signed('STATUS')}'))),
      ];
      for (final run in runs) {
        expect(run.stdoutText, isNot(contains('SIGNED_')), reason: run.stdoutText);
        expect(run.stdoutText, isNot(contains('token=')), reason: run.stdoutText);
      }
      expect(runs[0].last['code'], 'FFMPEG_MISSING');
      expect(runs[1].last['code'], 'FORMAT_NOT_FOUND');
      expect(runs[2].last['code'], 'INVALID_VALUE');
    });
  });

  test('two interleaved runs keep their own ffmpeg, registry flags and pipeline', () async {
    Future<Directory> binWith(String name) async {
      final d = await Directory('${tmp.path}${Platform.pathSeparator}$name').create();
      File('${d.path}${Platform.pathSeparator}${_exe('ffmpeg')}').writeAsStringSync('');
      return d;
    }

    final binA = await binWith('a');
    final binB = await binWith('b');
    final gateA = Completer<void>();
    final gateB = Completer<void>();
    final started = <String>[];
    final flags = <String, bool>{};
    RegistryBuilder builder(String tag, Completer<void> gate) => ({bool useBrowserLoginSession = false, bool forceHeadless = false}) {
          flags[tag] = forceHeadless;
          return FakeRegistry((_) async {
            started.add(tag);
            await gate.future;
            return sampleInfo();
          });
        };
    final pipeA = FakePipeline();
    final pipeB = FakePipeline();
    final outA = await Directory('${tmp.path}${Platform.pathSeparator}outA').create();
    final outB = await Directory('${tmp.path}${Platform.pathSeparator}outB').create();

    final runA = runCli(['download', testUrl, '--out', outA.path, '--headless'],
        environment: {FfmpegLocator.envVar: binA.path},
        registryBuilder: builder('A', gateA),
        pipelineFactory: FakePipeline.factory(pipeA));
    final runB = runCli(['download', testUrl, '--out', outB.path, '--ffmpeg', binB.path],
        environment: {FfmpegLocator.envVar: binA.path},
        registryBuilder: builder('B', gateB),
        pipelineFactory: FakePipeline.factory(pipeB));
    while (started.length < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    gateA.complete(); // A finishes first ...
    final a = await runA;
    gateB.complete(); // ... then B.
    final b = await runB;

    expect(a.exitCode, 0, reason: a.stdoutText);
    expect(b.exitCode, 0, reason: b.stdoutText);
    expect(pipeA.calls.single.ffmpegSeenDuringRun, '${binA.path}${Platform.pathSeparator}${_exe('ffmpeg')}');
    expect(pipeB.calls.single.ffmpegSeenDuringRun, '${binB.path}${Platform.pathSeparator}${_exe('ffmpeg')}');
    expect(pipeA.calls.single.outputDir, outA.path);
    expect(pipeB.calls.single.outputDir, outB.path);
    expect(flags, {'A': true, 'B': false});
  });

  group('ffprobe summary is bounded', () {
    test('a never-ending ffprobe is killed and yields null', () async {
      final hung = FakeProcess(code: null);
      final probe = CliStreamProbe(
        ffprobePathResolver: () async => 'ffprobe',
        starter: (_, __) async => hung,
        timeout: const Duration(milliseconds: 50),
      );
      final watch = Stopwatch()..start();
      expect(await probe.summarize('x.mp4'), isNull);
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(hung.killed, isNotEmpty);
    });

    test('the download still succeeds (exit 0) with null stream fields', () async {
      final hung = FakeProcess(code: null);
      final run = await runCli(['download', testUrl, '--out', tmp.path],
          registry: FakeRegistry.ok(),
          pipeline: FakePipeline(),
          probeFactory: (_) => CliStreamProbe(
                ffprobePathResolver: () async => 'ffprobe',
                starter: (_, __) async => hung,
                timeout: const Duration(milliseconds: 50),
              ));
      expect(run.exitCode, 0, reason: run.stdoutText);
      expect(run.last['video'], {'codec': null, 'width': null, 'height': null, 'duration_seconds': null});
      expect(hung.killed, isNotEmpty);
    });
  });

  group('nothing escapes as a raw crash', () {
    test('an unawaited error inside the download chain becomes one JSON error', () async {
      final run = await runCli(['download', testUrl, '--out', tmp.path],
          registry: FakeRegistry.ok(),
          pipeline: FakePipeline(script: (_, __) async {
            unawaited(Future<void>(() => throw StateError('background failure')));
            await Completer<void>().future; // the awaited path never finishes
          })).timeout(const Duration(seconds: 10));
      expect(run.exitCode, CliExit.download);
      expect(run.last['event'], 'error');
      expect(run.last['code'], 'DOWNLOAD_FAILED');
    });

    test('a throw from the pipeline factory and from the registry builder are classified', () async {
      final p = await runCli(['download', testUrl, '--out', tmp.path],
          registry: FakeRegistry.ok(), pipelineFactory: (_) => throw ArgumentError('bad wiring'));
      expect(p.exitCode, CliExit.download);
      expect(p.last['code'], 'DOWNLOAD_FAILED');
      final r = await runCli(['download', testUrl, '--out', tmp.path],
          registryBuilder: ({bool useBrowserLoginSession = false, bool forceHeadless = false}) => throw StateError('no'));
      expect(r.exitCode, CliExit.extraction);
      expect(r.last['code'], 'EXTRACTION_FAILED');
    });

    test('a NUL in --out is refused up front (Windows would truncate the path there)', () async {
      final pipeline = FakePipeline();
      final run = await runCli(['download', testUrl, '--out', '${tmp.path}${Platform.pathSeparator}a\u0000b'],
          registry: FakeRegistry.ok(), pipeline: pipeline);
      expect(run.exitCode, CliExit.usage);
      expect(run.events, hasLength(1));
      expect(run.last['code'], 'INVALID_OUT');
      expect(pipeline.calls, isEmpty);
    });

    test('a reader that closed stdout: no exception, exit 8, writes stop', () async {
      final sink = _ThrowingSink();
      final code = await runMidaCliGuarded(['sites'], out: sink, err: StringBuffer(), environment: const {});
      expect(code, CliExit.outputClosed);
      expect(sink.attempts, 1);
      final download = _ThrowingSink();
      final code2 = await runMidaCliGuarded(['download', testUrl, '--out', tmp.path],
          out: download,
          err: StringBuffer(),
          environment: const {},
          registry: FakeRegistry.ok(),
          pipeline: FakePipeline(script: (p, s) => p!(0.5)),
          probeFactory: fakeProbe());
      // The file was saved: that is the result, so exit 0 even though the
      // reader never saw the `result` line.
      expect(code2, CliExit.ok);
      expect(File('${tmp.path}${Platform.pathSeparator}Sample clip.mp4').existsSync(), isTrue);
      expect(download.attempts, 1, reason: 'after the first failed write nothing more is attempted');

      // Closed output and a failed download: exit 8, not the failure code.
      final failed = _ThrowingSink();
      final code3 = await runMidaCliGuarded(['download', testUrl, '--out', tmp.path],
          out: failed,
          err: StringBuffer(),
          environment: const {},
          registry: FakeRegistry.ok(),
          pipeline: FakePipeline(error: StateError('x')),
          probeFactory: fakeProbe());
      expect(code3, CliExit.outputClosed);
    });

    test('file saved, then a detached failure while ffprobe is pending, stdout closed: code is not 8', () async {
      final code = await runMidaCliGuarded(['download', testUrl, '--out', tmp.path],
          out: _ThrowingSink(),
          err: StringBuffer(),
          environment: const {},
          registry: FakeRegistry.ok(),
          pipeline: FakePipeline(),
          probeFactory: (_) => CliStreamProbe(ffprobePathResolver: () async {
                unawaited(Future<void>(() => throw StateError('detached after save')));
                return Completer<String>().future; // the probe never finishes
              })).timeout(const Duration(seconds: 10));
      expect(File('${tmp.path}${Platform.pathSeparator}Sample clip.mp4').existsSync(), isTrue);
      expect(code, isNot(CliExit.outputClosed));
      expect(code, CliExit.download, reason: 'the real failure code is kept');
    });
  });

  test('a policy status keeps its own exit code through the guarded entry', () async {
    final run = await runCli(['resolve', testUrl],
        registry: FakeRegistry.throwing(const MediaExtractionException('LOGIN_REQUIRED', 'sign in')));
    expect(run.exitCode, CliExit.policy);
  });
}
