import 'package:flutter_test/flutter_test.dart';
import 'package:mida/cli/cli_args.dart';
import 'package:mida/features/download/models/download_models.dart';
import 'package:mida/features/download/services/cli_command_builder.dart';

const _builder = CliCommandBuilder();
const _dir = r'C:\Users\me\Videos\MiDa';

CliCommandResult _build(String url, {String outDir = _dir}) =>
    _builder.build(url: url, type: DownloadType.video, options: const DownloadOptions(), outDir: outDir);

/// Splits like PowerShell and bash read this command: single-quoted
/// stretches are literal, spaces separate arguments.
List<String> _argv(String command) {
  final args = <String>[];
  final cur = StringBuffer();
  var quoted = false;
  var any = false;
  for (final ch in command.split('')) {
    if (ch == "'") {
      quoted = !quoted;
      any = true;
    } else if (ch == ' ' && !quoted) {
      if (any) args.add(cur.toString());
      cur.clear();
      any = false;
    } else {
      cur.write(ch);
      any = true;
    }
  }
  if (any) args.add(cur.toString());
  return args;
}

void main() {
  group('the URL and folder are copied byte for byte inside single quotes', () {
    const urls = [
      r'https://evil.example/$(echo PWNED)',
      'https://evil.example/`echo PWNED`',
      'https://evil.example/%CD:~0,1%25',
      'https://evil.example/a!x',
      r'https://evil.example/a$b',
      'https://www.youtube.com/watch?v=abc&t=30;x=1&q=a%20b',
      'https://e.example/caf\u00e9 menu/(1)|x<y>^z',
    ];
    for (final url in urls) {
      test(url, () {
        final command = _build(url).command!;
        expect(command, startsWith("mida-cli download '$url' "));
        expect(_argv(command)[2], url);
        expect(_argv(command).sublist(_argv(command).length - 2), ['--out', _dir]);
      });
    }

    test(r'folders with $ % ! spaces & and UNC paths are kept, never dropped', () {
      for (final dir in [
        r'C:\a$b\%PATH%\x!y',
        r'D:\Tom & Jerry (1)\clips',
        r'\\server\share\videos',
        r'C:\',
      ]) {
        final argv = _argv(_build('https://e.example/v', outDir: dir).command!);
        expect(argv.sublist(argv.length - 2), ['--out', dir], reason: dir);
      }
      final trimmed = _argv(_build('https://e.example/v', outDir: r'C:\My Videos\').command!);
      expect(trimmed.last, r'C:\My Videos');
    });
  });

  group('declined, with a reason, when single quotes cannot carry it', () {
    final cases = <String, (String, String)>{
      'single quote in URL': ("https://e.example/it's", 'single quote'),
      'typographic quote in URL': ('https://e.example/\u2019x', 'single quote'),
      'double quote in URL': ('https://e.example/"x', 'double quote'),
      'newline in URL': ('https://e.example/a\nb', 'control character'),
      'NUL in URL': ('https://e.example/a\u0000b', 'control character'),
    };
    cases.forEach((name, c) {
      test(name, () {
        final r = _build(c.$1);
        expect(r.command, isNull);
        expect(r.refusal, contains(c.$2));
        expect(r.refusal, contains('link'));
      });
    });

    test("a folder with ' or a control character declines the whole command", () {
      for (final dir in [r"C:\Bob's videos", 'C:\\a\tb', '']) {
        final r = _build('https://e.example/v', outDir: dir);
        expect(r.command, isNull, reason: dir);
        expect(r.refusal, isNotEmpty);
      }
      expect(_build('https://e.example/v', outDir: r"C:\Bob's").refusal, contains('folder'));
    });

    test('folder bytes are exact: a trailing space is kept, a trailing newline refuses', () {
      final argv = _argv(_build('https://e.example/v', outDir: '/tmp/MiDa ').command!);
      expect(argv.last, '/tmp/MiDa ');
      final refused = _build('https://e.example/v', outDir: 'C:\\x\n');
      expect(refused.command, isNull);
      expect(refused.refusal, contains('control character'));
    });
  });

  test('options round-trip through the real CLI parser', () {
    const cases = <(DownloadType, DownloadOptions)>[
      (DownloadType.video, DownloadOptions()),
      (DownloadType.video, DownloadOptions(videoQuality: VideoQuality.p2160, videoFormat: VideoFormat.webm)),
      (DownloadType.video, DownloadOptions(subtitleOption: SubtitleOption.koreanEnglish)),
      (DownloadType.video, DownloadOptions(subtitleOption: SubtitleOption.korean)),
      (DownloadType.audio, DownloadOptions(audioFormat: AudioFormat.opus, audioQuality: AudioQuality.low)),
      (DownloadType.audio, DownloadOptions(audioFormat: AudioFormat.wav)),
    ];
    for (final (type, options) in cases) {
      for (final login in [false, true]) {
        final command = _builder
            .build(
              url: r'https://e.example/v$1?a=1&b=2',
              type: type,
              options: options,
              outDir: r'C:\Tom & Jerry (old)\clips\',
              loginSession: login,
            )
            .command!;
        final request = parseCliArgs(_argv(command).skip(1).toList());
        expect(request.url, r'https://e.example/v$1?a=1&b=2');
        expect(request.type, type);
        expect(request.loginSession, login);
        expect(request.outDir, r'C:\Tom & Jerry (old)\clips');
        final got = request.downloadOptions;
        if (type == DownloadType.video) {
          expect(got.videoQuality, options.videoQuality, reason: command);
          expect(got.videoFormat, options.videoFormat, reason: command);
          expect(got.subtitleOption, options.subtitleOption, reason: command);
        } else {
          expect(got.audioFormat, options.audioFormat, reason: command);
          expect(got.audioQuality, options.audioQuality, reason: command);
        }
      }
    }
  });
}
