import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/cli/cli_args.dart';
import 'package:mida/cli/cli_events.dart';
import 'package:mida/cli/cli_exit.dart';
import 'package:mida/cli/mida_cli.dart';
import 'package:mida/features/download/models/download_models.dart';

import 'cli_test_support.dart';

void main() {
  late Directory tmp;

  setUp(() async => tmp = await Directory.systemTemp.createTemp('mida_cli_parse_'));
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('help', () {
    for (final args in [
      ['--help'],
      ['help'],
      ['-h'],
      ['download', '--help'],
    ]) {
      test(args.join(' '), () async {
        final run = await runCli(args);
        expect(run.exitCode, 0);
        expect(run.lines, hasLength(1));
        expect(run.last['kind'], 'help');
        expect(run.last['usage'], cliUsage);
      });
    }
  });

  test('global flags may come before the command', () async {
    final run = await runCli(['--quiet', '--json', 'version']);
    expect(run.exitCode, 0);
    expect(run.last['version'], midaCliVersion);
    expect(parseCliArgs(['--quiet', 'download', testUrl]).quiet, isTrue);
  });

  group('duplicate value options are refused (exit 2)', () {
    for (final args in [
      ['download', testUrl, '--out', 'a', '--out', 'b'],
      ['download', testUrl, '--format-id', 'a', '--format-id=b'],
      ['download', testUrl, '--quality', '720', '--quality', '1080'],
    ]) {
      test(args.skip(2).join(' '), () async {
        final run = await runCli(args, registry: FakeRegistry.ok(), pipeline: FakePipeline());
        expect(run.exitCode, CliExit.usage);
        expect(run.last['code'], 'INVALID_VALUE');
        expect(run.last['message'], contains('more than once'));
      });
    }
  });

  test('every --quality and --audio-format value in the usage text parses', () {
    for (final q in ['best', '2160', '1440', '1080', '720', '480', '360']) {
      expect(cliUsage, contains(q));
      parseCliArgs(['download', testUrl, '--quality', q]);
    }
    for (final f in AudioFormat.values) {
      expect(cliUsage, contains(f.value));
      expect(parseCliArgs(['download', testUrl, '--audio-format', f.value]).audioFormat, f);
    }
    expect(parseCliArgs(['download', testUrl, '--container', 'mkv']).container, VideoFormat.mkv);
    expect(parseCliArgs(['download', testUrl, '--audio-quality', '256']).audioQuality, AudioQuality.medium);
    expect(parseCliArgs(['download', testUrl, '--subtitles', 'en']).downloadOptions.subtitleOption, SubtitleOption.english);
    expect(parseCliArgs(['download', testUrl, '--captions']).downloadOptions.subtitleOption, SubtitleOption.koreanEnglish);
  });

  test('no-op combinations are reported as status notes, the download still runs', () async {
    final pipeline = FakePipeline(fileName: 'a.mp3');
    final run = await runCli(['download', testUrl, '--out', tmp.path, '--type', 'audio', '--quality', '720', '--captions'],
        registry: FakeRegistry.ok(), pipeline: pipeline);
    expect(run.exitCode, 0, reason: run.stdoutText);
    final notes = [for (final e in run.ofEvent('status')) e['message'] as String].where((m) => m.startsWith('Note: '));
    expect(notes, ['Note: --quality has no effect with --type audio.', 'Note: --captions has no effect with --type audio.']);
    final video = await runCli(['download', testUrl, '--out', tmp.path, '--audio-format', 'flac'],
        registry: FakeRegistry.ok(), pipeline: FakePipeline());
    expect(video.ofEvent('status').first['message'], contains('--audio-format has no effect'));
  });

  test('a relative --out gives an absolute output_path', () async {
    final previous = Directory.current;
    Directory.current = tmp;
    addTearDown(() => Directory.current = previous);
    final pipeline = FakePipeline();
    final run = await runCli(['download', testUrl, '--out', 'rel'], registry: FakeRegistry.ok(), pipeline: pipeline);
    expect(run.exitCode, 0, reason: run.stdoutText);
    final path = run.last['output_path']! as String;
    expect(File(path).isAbsolute, isTrue, reason: path);
    expect(pipeline.calls.single.outputDir, '${tmp.path}${Platform.pathSeparator}rel');
  });

  test('non-finite doubles are written as null, never crash the encoder', () {
    final out = StringBuffer();
    CliEmitter(out).result('t', {
      'nan': double.nan,
      'inf': double.infinity,
      'nested': {'fps': double.negativeInfinity, 'list': [1.5, double.nan]},
    });
    expect(jsonDecode(out.toString()), {
      'event': 'result',
      'kind': 't',
      'nan': null,
      'inf': null,
      'nested': {'fps': null, 'list': [1.5, null]},
    });
  });

  group('ProcessException is classified by executable', () {
    final cases = {
      r'C:\Program Files\MiDa\ffmpeg.exe': 'FFMPEG_MISSING',
      '/usr/bin/ffprobe': 'FFMPEG_MISSING',
      r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe': 'BROWSER_MISSING',
      'google-chrome': 'BROWSER_MISSING',
      'python': 'PROCESS_START_FAILED',
    };
    cases.forEach((exe, code) {
      test(exe, () {
        final f = classifyError(ProcessException(exe, const [], '\uc9c0\uc815\ub41c \ud30c\uc77c\uc744 \ucc3e\uc744 \uc218 \uc5c6\uc2b5\ub2c8\ub2e4', 2),
            stage: CliStage.download);
        expect(f.code, code);
        expect(f.exitCode, CliExit.environment);
        expect(f.message.runes.every((c) => c < 0x80), isTrue, reason: f.message);
        expect(f.message, contains('(OS error 2)'));
        expect(f.message, isNot(contains('Program Files')), reason: 'only the file name is named');
      });
    });
  });

  test('OS-localized SocketException text is replaced by an English sentence plus the errno', () async {
    const korean = '\ub300\uc0c1 \ucef4\ud4e8\ud130\uc5d0\uc11c \uc5f0\uacb0\uc744 \uac70\ubd80\ud588\uc2b5\ub2c8\ub2e4';
    final run = await runCli(['resolve', testUrl],
        registry: FakeRegistry.throwing(const SocketException('connect failed', osError: OSError(korean, 10061))));
    expect(run.exitCode, CliExit.environment);
    expect(run.last['code'], 'NETWORK');
    final message = run.last['message']! as String;
    expect(message.runes.every((c) => c < 0x80), isTrue, reason: message);
    expect(message, contains('10061'));
  });

  test('the version constant matches pubspec.yaml and installer.iss', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(r'^version:\s*([0-9.]+)\+(\d+)', multiLine: true).firstMatch(pubspec)!;
    expect(version.group(1), midaCliVersion);
    final iss = File('installer.iss').readAsStringSync();
    expect(iss, contains('AppVersion=$midaCliVersion'));
    expect(iss, contains('OutputBaseFilename=MiDa_Setup_v$midaCliVersion'));
    expect(File('CHANGELOG.md').readAsStringSync(), contains('## [$midaCliVersion]'));
  });
}
