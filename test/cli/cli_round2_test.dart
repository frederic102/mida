import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/cli/cli_exit.dart';
import 'package:mida/cli/cli_stream_probe.dart';
import 'package:mida/cli/mida_cli.dart';
import 'package:mida/core/extractors/media_models.dart';

import 'cli_test_support.dart';

const _signedId = 'https://cdn.example.com/v.m3u8?sig=$secretSig';

MediaInfo _infoWithSignedIds() => MediaInfo(
      id: '9',
      title: 'Signed',
      sourceUrl: Uri.parse(testUrl),
      formats: const [
        MediaFormat(id: _signedId, url: _signedId, container: 'mp4', height: 1080, hasVideo: true, hasAudio: true),
        MediaFormat(id: 'muxed-720', url: 'https://cdn.example.com/720.mp4', container: 'mp4', hasVideo: true, hasAudio: true),
        MediaFormat(id: 'dup', url: 'https://cdn.example.com/a', container: 'mp4', hasVideo: true, hasAudio: true),
        MediaFormat(id: 'dup', url: 'https://cdn.example.com/b', container: 'webm', hasVideo: true, hasAudio: true),
      ],
    );

List<Map<String, Object?>> _events(String text) => [
      for (final l in const LineSplitter().convert(text))
        if (l.trim().isNotEmpty) jsonDecode(l) as Map<String, Object?>,
    ];

void main() {
  late Directory tmp;

  setUp(() async => tmp = await Directory.systemTemp.createTemp('mida_cli_r2_'));
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('format selection ids', () {
    test('resolve prints unique, non-secret ids; download accepts exactly those ids', () async {
      final resolved = await runCli(['resolve', testUrl], registry: FakeRegistry.ok(_infoWithSignedIds()));
      expect(resolved.exitCode, 0, reason: resolved.stdoutText);
      expect(resolved.stdoutText, isNot(contains(secretSig)));
      final ids = [for (final f in resolved.last['formats']! as List) (f as Map)['id'] as String];
      expect(ids, ['fmt-0', 'muxed-720', 'fmt-2', 'fmt-3']);
      expect(ids.toSet(), hasLength(ids.length));

      // Pick each printed id and download it: the pipeline gets that format.
      final urls = <String>[];
      for (final id in ids) {
        final pipeline = FakePipeline();
        final run = await runCli(['download', testUrl, '--out', tmp.path, '--format-id', id],
            registry: FakeRegistry.ok(_infoWithSignedIds()), pipeline: pipeline);
        expect(run.exitCode, 0, reason: '$id: ${run.stdoutText}');
        urls.add(pipeline.calls.single.info.formats.single.url);
      }
      expect(urls, [_signedId, 'https://cdn.example.com/720.mp4', 'https://cdn.example.com/a', 'https://cdn.example.com/b']);
    });

    test('the raw signed id is not accepted (only the printed id is)', () async {
      final run = await runCli(['download', testUrl, '--out', tmp.path, '--format-id', _signedId],
          registry: FakeRegistry.ok(_infoWithSignedIds()), pipeline: FakePipeline());
      expect(run.last['code'], 'FORMAT_NOT_FOUND');
      expect(run.stdoutText, isNot(contains(secretSig)));
    });
  });

  test('a detached error while extraction is pending ends the run: one error, no success, no file', () async {
    final gate = Completer<void>();
    final pipeline = FakePipeline();
    final out = StringBuffer();
    final registry = FakeRegistry((_) async {
      unawaited(Future<void>(() => throw StateError('detached failure')));
      await gate.future;
      return sampleInfo();
    });
    final code = await runMidaCliGuarded(['download', testUrl, '--out', tmp.path],
        out: out, err: StringBuffer(), environment: const {}, registry: registry, pipeline: pipeline, probeFactory: fakeProbe());
    expect(code, CliExit.download);
    gate.complete(); // extraction now "succeeds" behind the reported error
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final terminal = _events(out.toString()).where((e) => e['event'] == 'result' || e['event'] == 'error').toList();
    expect(terminal, hasLength(1), reason: out.toString());
    expect(terminal.single['event'], 'error');
    expect(pipeline.calls, isEmpty);
    expect(tmp.listSync(), isEmpty);
  });

  test('ffprobe: malformed stdout with a pending exit gives null and no uncaught error', () async {
    final uncaught = <Object>[];
    final watch = Stopwatch()..start();
    OutputSummary? summary = const OutputSummary();
    final child = FakeProcess(code: null, bytes: const [0xff, 0xfe, 0xfd], closeStdout: true);
    await runZonedGuarded(() async {
      final probe = CliStreamProbe(
        ffprobePathResolver: () async => 'ffprobe',
        starter: (_, __) async => child,
        timeout: const Duration(seconds: 5),
      );
      summary = await probe.summarize('x.mp4');
    }, (e, _) => uncaught.add(e));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(summary, isNull);
    expect(uncaught, isEmpty);
    expect(child.killed, isNotEmpty, reason: 'the still-running child must be stopped on the early error');
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)), reason: 'the decode error ends it, not the deadline');
  });

  group('duplicate flags are refused in either position (exit 2)', () {
    for (final args in [
      ['--quiet', '--quiet', 'version'],
      ['--quiet', 'version', '--quiet'],
      ['--json', 'sites', '--json'],
      ['download', testUrl, '--headless', '--out', 'x', '--headless'],
      ['resolve', testUrl, '--login-session', '--login-session'],
    ]) {
      test(args.join(' '), () async {
        final run = await runCli(args, registry: FakeRegistry.ok(), pipeline: FakePipeline());
        expect(run.exitCode, CliExit.usage, reason: run.stdoutText);
        expect(run.last['code'], 'INVALID_VALUE');
      });
    }
  });

  group('help is recognised by position, not by text', () {
    test('--out help is a folder called help', () async {
      final previous = Directory.current;
      Directory.current = tmp;
      addTearDown(() => Directory.current = previous);
      final pipeline = FakePipeline();
      final run = await runCli(['download', testUrl, '--out', 'help'], registry: FakeRegistry.ok(), pipeline: pipeline);
      expect(run.exitCode, 0, reason: run.stdoutText);
      expect(pipeline.calls.single.outputDir, '${tmp.path}${Platform.pathSeparator}help');
    });

    test('--format-id help and --format-id -h are format ids', () async {
      for (final id in ['help', '-h']) {
        final run = await runCli(['download', testUrl, '--out', tmp.path, '--format-id', id],
            registry: FakeRegistry.ok(), pipeline: FakePipeline());
        expect(run.last['code'], 'FORMAT_NOT_FOUND', reason: id);
      }
    });

    test('after the end-of-options marker, -h is the url, not help', () async {
      final run = await runCli(['resolve', '--', '-h']);
      expect(run.last['code'], 'INVALID_URL');
    });

    for (final args in [
      ['--help'],
      ['-h'],
      ['help'],
      ['--quiet', '--help'],
      ['download', testUrl, '--help'],
      ['download', '-h'],
    ]) {
      test('genuine: ${args.join(' ')}', () async {
        final run = await runCli(args);
        expect(run.exitCode, 0);
        expect(run.last['kind'], 'help');
      });
    }
  });
}
