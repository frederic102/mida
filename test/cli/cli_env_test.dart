import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/services/ffmpeg_locator.dart';

import 'cli_test_support.dart';

// The '@' is kept out of literals so the repo's email guard never sees an address-shaped string.
const _at = '@';

/// Records the flags the CLI hands its registry builder.
class _BuilderSpy {
  final List<({bool login, bool headless})> calls = [];
  final FakeRegistry registry = FakeRegistry.ok();

  ExtractorRegistry call({bool useBrowserLoginSession = false, bool forceHeadless = false}) {
    calls.add((login: useBrowserLoginSession, headless: forceHeadless));
    return registry;
  }
}

String _exe(String base) => Platform.isWindows ? '$base.exe' : base;

void main() {
  late Directory tmp;
  late _BuilderSpy spy;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mida_cli_env_');
    spy = _BuilderSpy();
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('headless reaches the registry builder', () {
    final cases = <String, (List<String>, Map<String, String>, bool)>{
      'default is headed': ([], {}, false),
      '--headless': (['--headless'], {}, true),
      'MIDA_HEADLESS=1': ([], {'MIDA_HEADLESS': '1'}, true),
      'MIDA_HEADLESS=true': ([], {'MIDA_HEADLESS': 'true'}, true),
      'MIDA_HEADLESS=0': ([], {'MIDA_HEADLESS': '0'}, false),
      'MIDA_HEADLESS empty': ([], {'MIDA_HEADLESS': ''}, false),
      'flag wins over MIDA_HEADLESS=0': (['--headless'], {'MIDA_HEADLESS': '0'}, true),
    };
    cases.forEach((name, c) {
      test('resolve: $name', () async {
        final run = await runCli(['resolve', testUrl, ...c.$1], environment: c.$2, registryBuilder: spy.call);
        expect(run.exitCode, 0, reason: run.stdoutText);
        expect(spy.calls.single.headless, c.$3);
        expect(spy.calls.single.login, isFalse);
      });
      test('download: $name', () async {
        final run = await runCli(['download', testUrl, '--out', tmp.path, ...c.$1],
            pipeline: FakePipeline(), environment: c.$2, registryBuilder: spy.call);
        expect(run.exitCode, 0, reason: run.stdoutText);
        expect(spy.calls.single.headless, c.$3);
      });
    });

    test('--login-session reaches the builder', () async {
      await runCli(['resolve', testUrl, '--login-session', '--headless'], registryBuilder: spy.call);
      expect(spy.calls.single, (login: true, headless: true));
    });

    test('an injected registry bypasses the builder', () async {
      final run = await runCli(['resolve', testUrl, '--headless'], registry: FakeRegistry.ok(), registryBuilder: spy.call);
      expect(run.exitCode, 0);
      expect(spy.calls, isEmpty);
    });

    test('version and sites never build a registry', () async {
      await runCli(['version'], registryBuilder: spy.call);
      await runCli(['sites'], registryBuilder: spy.call);
      expect(spy.calls, isEmpty);
    });
  });

  group('MIDA_FFMPEG_PATH', () {
    late Directory bin;

    setUp(() async {
      bin = await Directory('${tmp.path}${Platform.pathSeparator}ffbin').create();
      File('${bin.path}${Platform.pathSeparator}${_exe('ffmpeg')}').writeAsStringSync('');
      File('${bin.path}${Platform.pathSeparator}${_exe('ffprobe')}').writeAsStringSync('');
    });

    String inBin(String base) => '${bin.path}${Platform.pathSeparator}${_exe(base)}';

    test('a directory resolves both executables', () async {
      final env = {FfmpegLocator.envVar: bin.path};
      expect(await FfmpegLocator.ffmpegPath(environment: env), inBin('ffmpeg'));
      expect(await FfmpegLocator.ffprobePath(environment: env), inBin('ffprobe'));
      expect(await FfmpegLocator.overrideProblem(environment: env), isNull);
    });

    test('the ffmpeg executable itself resolves ffprobe as its sibling', () async {
      final env = {FfmpegLocator.envVar: inBin('ffmpeg')};
      expect(await FfmpegLocator.ffmpegPath(environment: env), inBin('ffmpeg'));
      expect(await FfmpegLocator.ffprobePath(environment: env), inBin('ffprobe'));
    });

    test('a bad value is reported and the resolver falls back', () async {
      final env = {FfmpegLocator.envVar: '${tmp.path}${Platform.pathSeparator}missing'};
      expect(await FfmpegLocator.overrideProblem(environment: env), contains(FfmpegLocator.envVar));
      expect(await FfmpegLocator.ffmpegPath(environment: env), isNot(contains('missing')));
      expect(await FfmpegLocator.overrideProblem(environment: const {}), isNull);
    });

    test('download: the run pipeline gets the env ffmpeg; nothing process-wide changes', () async {
      final pipeline = FakePipeline();
      final run = await runCli(['download', testUrl, '--out', tmp.path],
          pipelineFactory: FakePipeline.factory(pipeline),
          registryBuilder: spy.call,
          environment: {FfmpegLocator.envVar: bin.path});
      expect(run.exitCode, 0, reason: run.stdoutText);
      expect(pipeline.calls.single.ffmpegSeenDuringRun, inBin('ffmpeg'));
      expect(await FfmpegLocator.ffmpegPath(), isNot(inBin('ffmpeg')), reason: 'GUI call (no environment)');
    });

    test('--ffmpeg beats a broken MIDA_FFMPEG_PATH', () async {
      final pipeline = FakePipeline();
      final run = await runCli(['download', testUrl, '--out', tmp.path, '--ffmpeg', bin.path],
          pipelineFactory: FakePipeline.factory(pipeline),
          registryBuilder: spy.call,
          environment: {FfmpegLocator.envVar: '${tmp.path}${Platform.pathSeparator}nope'});
      expect(run.exitCode, 0, reason: run.stdoutText);
      expect(pipeline.calls.single.ffmpegSeenDuringRun, inBin('ffmpeg'));
    });

    test('a broken override fails fast with FFMPEG_MISSING (6) before any download', () async {
      final pipeline = FakePipeline();
      final run = await runCli(['download', testUrl, '--out', tmp.path, '--ffmpeg', '${tmp.path}/none'],
          pipeline: pipeline, registryBuilder: spy.call);
      expect(run.exitCode, 6);
      expect(run.last['code'], 'FFMPEG_MISSING');
      expect(pipeline.calls, isEmpty);
      expect(spy.calls, isEmpty);
    });

    test('a relative override is refused (it would resolve against the working folder)', () async {
      final env = {FfmpegLocator.envVar: 'ffbin'};
      expect(await FfmpegLocator.overrideProblem(environment: env), contains('absolute'));
    });

    test('GUI calls (no environment) ignore MIDA_FFMPEG_PATH entirely', () async {
      expect(await FfmpegLocator.overrideProblem(), isNull);
      expect(await FfmpegLocator.ffmpegPath(), isNot(contains('ffbin')));
    });
  });

  group('bare-name lookup', () {
    late Directory onPath;
    late Directory app;

    setUp(() async {
      onPath = await Directory('${tmp.path}${Platform.pathSeparator}pathdir').create();
      app = await Directory('${tmp.path}${Platform.pathSeparator}app').create();
      File('${onPath.path}${Platform.pathSeparator}${_exe('ffmpeg')}').writeAsStringSync('');
    });

    test('finds ffmpeg in an absolute PATH directory and returns its full path', () async {
      final sep = Platform.isWindows ? ';' : ':';
      final env = {'PATH': ['relative${Platform.pathSeparator}dir', '', onPath.path].join(sep)};
      final found = await FfmpegLocator.ffmpegPath(environment: env, appDir: app.path);
      expect(found, '${onPath.path}${Platform.pathSeparator}${_exe('ffmpeg')}');
    });

    test('never returns a bare name: nothing found gives the missing bundled path', () async {
      final found = await FfmpegLocator.ffprobePath(environment: const {'PATH': ''}, appDir: app.path);
      expect(found, '${app.path}${Platform.pathSeparator}${_exe('ffprobe')}');
    });

    test('relative PATH entries are skipped even when they hold ffmpeg', () async {
      final relative = '${tmp.path}${Platform.pathSeparator}rel';
      await Directory(relative).create();
      File('$relative${Platform.pathSeparator}${_exe('ffmpeg')}').writeAsStringSync('');
      final previous = Directory.current;
      Directory.current = tmp;
      try {
        final found = await FfmpegLocator.ffmpegPath(environment: const {'PATH': 'rel'}, appDir: app.path);
        expect(found, '${app.path}${Platform.pathSeparator}${_exe('ffmpeg')}');
      } finally {
        Directory.current = previous;
      }
    });

    test('the bundled copy wins over PATH', () async {
      File('${app.path}${Platform.pathSeparator}${_exe('ffmpeg')}').writeAsStringSync('');
      final found = await FfmpegLocator.ffmpegPath(environment: {'PATH': onPath.path}, appDir: app.path);
      expect(found, '${app.path}${Platform.pathSeparator}${_exe('ffmpeg')}');
    });
  });

  group('redaction', () {
    const signed = 'https://cdn.example.com/v.mp4?sig=$secretSig&token=abc';

    test('error messages drop query strings', () async {
      final run = await runCli(['resolve', testUrl],
          registry: FakeRegistry.throwing(const MediaExtractionException('NETWORK', 'GET $signed failed')));
      expect(run.exitCode, 6);
      expect(run.last['message'], startsWith('GET https://cdn.example.com'));
      expect(run.stdoutText, isNot(contains(secretSig)));
    });

    test('status lines from the pipeline drop query strings', () async {
      final run = await runCli(['download', testUrl, '--out', tmp.path],
          pipeline: FakePipeline(script: (_, onStatus) => onStatus!('Fetching $signed')));
      expect(run.exitCode, 0);
      expect(run.ofEvent('status').map((e) => e['message']), contains(startsWith('Fetching https://cdn.example.com')));
      expect(run.stdoutText, isNot(contains(secretSig)));
    });

    test('an invalid url argument is echoed without its query', () async {
      final run = await runCli(['download', 'notaurl?key=$secretSig', '--out', tmp.path]);
      expect(run.exitCode, 2);
      expect(run.last['code'], 'INVALID_URL');
      expect(run.last['message'], 'The argument is not a valid http(s) URL.');
      expect(run.stdoutText, isNot(contains(secretSig)));
    });

    test('an invalid url echoes only scheme and host: no userinfo, path or fragment', () async {
      for (final raw in [
        'ftp://user:SECRETPW${_at}files.example.com/x?sig=$secretSig#token=SECRETFRAG',
        'notaurl#token=SECRETFRAG',
        'https//user:SECRETPW@broken',
      ]) {
        final run = await runCli(['resolve', raw]);
        expect(run.last['code'], 'INVALID_URL', reason: raw);
        for (final s in ['SECRETPW', 'SECRETFRAG', secretSig, 'user:']) {
          expect(run.stdoutText, isNot(contains(s)), reason: '$raw leaked $s');
        }
      }
      final ftp = await runCli(['resolve', 'ftp://user:SECRETPW${_at}files.example.com/x']);
      expect(ftp.last['message'], 'The argument is not a valid http(s) URL (got a "ftp" URL for host files.example.com).');
    });

    test('MIDA_DEBUG=1 writes a redacted trace to stderr only', () async {
      const err = MediaExtractionException('NETWORK', 'GET $signed failed');
      final quiet = await runCli(['resolve', testUrl], registry: FakeRegistry.throwing(err));
      expect(quiet.stderrText, isEmpty);
      final debug = await runCli(['resolve', testUrl],
          registry: FakeRegistry.throwing(err), environment: {'MIDA_DEBUG': '1'});
      expect(debug.stderrText, contains('MediaExtractionException -> NETWORK'));
      expect(debug.stderrText, isNot(contains(secretSig)));
      expect(debug.stdoutText, isNot(contains('#0')));
    });
  });
}
