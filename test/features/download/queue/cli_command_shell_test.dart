@Tags(['subprocess'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/features/download/models/download_models.dart';
import 'package:mida/features/download/services/cli_command_builder.dart';

/// Runs the copied command in the real target shells (Windows PowerShell
/// and Git Bash) with `mida-cli` replaced by an argv recorder, and checks
/// that the URL and folder arrive byte for byte. Payloads only ever `echo`
/// a marker, so a failure prints a word instead of running anything.
const _marker = 'PWNED42';

const _payloads = [
  'https://e.example/\$(echo $_marker)',
  'https://e.example/`echo $_marker`',
  'https://e.example/%CD:~0,1%25',
  'https://e.example/a!x',
  r'https://e.example/a$b',
  r'https://e.example/v?x=$env:USERNAME&y=${PATH}',
  'https://e.example/?a=1& echo $_marker',
  'https://e.example/?a=1|echo $_marker; echo $_marker',
  'https://www.youtube.com/watch?v=abc&t=30',
];

const _dirs = [
  r'C:\Tom & Jerry (1)\clips',
  r'C:\a$b\%PATH%\x!y',
  r'\\server\share\videos',
];

String? _dart() {
  final root = Platform.environment['FLUTTER_ROOT'];
  for (final c in [
    if (root != null) '$root/bin/cache/dart-sdk/bin/dart.exe',
    'C:/flutter/bin/cache/dart-sdk/bin/dart.exe',
  ]) {
    if (File(c).existsSync()) return c;
  }
  return null;
}

const _gitBash = r'C:\Program Files\Git\bin\bash.exe';

/// Feeds [line] to [shell] on stdin (no argument re-quoting by Dart) and
/// returns everything it printed.
Future<String> _runIn(String shell, List<String> args, String line) async {
  final p = await Process.start(shell, args);
  p.stdin.write('$line\n');
  await p.stdin.close();
  final out = p.stdout.transform(const SystemEncoding().decoder).join();
  final err = p.stderr.transform(const SystemEncoding().decoder).join();
  await p.exitCode.timeout(const Duration(seconds: 60));
  return '${await out}\n${await err}';
}

List<String> _recorded(String output) {
  final line = const LineSplitter().convert(output).lastWhere((l) => l.contains('["'), orElse: () => '');
  expect(line, isNotEmpty, reason: 'recorder printed nothing:\n$output');
  return (jsonDecode(line.substring(line.indexOf('["')).trim()) as List).cast<String>();
}

void main() {
  final dart = _dart();
  final skip = !Platform.isWindows
      ? 'Windows shells only'
      : dart == null
          ? 'no dart executable found'
          : false;

  test('PowerShell and bash receive URL and folder unchanged and run nothing', () async {
    final tmp = await Directory.systemTemp.createTemp('mida_shell_');
    addTearDown(() => tmp.delete(recursive: true));
    final recorder = File('${tmp.path}${Platform.pathSeparator}rec.dart')
      ..writeAsStringSync("import 'dart:convert';\nvoid main(List<String> a) => print(jsonEncode(a));\n");
    final dartFwd = dart!.replaceAll(r'\', '/');
    final recFwd = recorder.path.replaceAll(r'\', '/');
    const builder = CliCommandBuilder();
    var checked = 0;

    final pairs = [
      for (final url in _payloads) (url, _dirs.first),
      for (final dir in _dirs.skip(1)) (_payloads.first, dir),
    ];
    for (final (url, dir) in pairs) {
      {
        final command =
            builder.build(url: url, type: DownloadType.video, options: const DownloadOptions(), outDir: dir).command!;
        final tail = command.substring('mida-cli '.length);
        final shells = <String, Future<String>>{
          'powershell': _runIn('powershell', ['-NoProfile', '-NonInteractive', '-Command', '-'], "& '$dartFwd' '$recFwd' $tail"),
          if (File(_gitBash).existsSync()) 'bash': _runIn(_gitBash, ['-s'], "'$dartFwd' '$recFwd' $tail"),
        };
        for (final entry in shells.entries) {
          final output = await entry.value;
          final where = '${entry.key}: $command\n$output';
          expect(_recorded(output), ['download', url, '--out', dir], reason: where);
          final bare = RegExp('(^|>)\\s*$_marker\\s*\$');
          expect(const LineSplitter().convert(output).where(bare.hasMatch), isEmpty, reason: where);
          checked++;
        }
      }
    }
    expect(checked, greaterThanOrEqualTo(pairs.length));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 10)));
}
