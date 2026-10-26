@Tags(['subprocess'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The `dart` next to the Flutter SDK running this test, else `dart` on
/// PATH. Null when neither exists (the test is then skipped, not passed).
String? _dartExecutable() {
  final root = Platform.environment['FLUTTER_ROOT'];
  final candidates = [
    if (root != null) '$root/bin/cache/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}',
    if (Platform.isWindows) 'C:/flutter/bin/cache/dart-sdk/bin/dart.exe',
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}

/// Runs `dart run bin/mida_cli.dart ...` as a real process: no in-process
/// sinks, the real stdout/stderr and exit code an agent sees.
Future<ProcessResult> _cli(String dart, List<String> args) => Process.run(
      dart,
      ['run', 'bin/mida_cli.dart', ...args],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
      environment: const {'MIDA_DEBUG': '0'},
    );

void _expectJsonOnly(ProcessResult r) {
  final lines = const LineSplitter().convert(r.stdout as String).where((l) => l.trim().isNotEmpty).toList();
  expect(lines, isNotEmpty);
  for (final line in lines) {
    expect(jsonDecode(line), isA<Map<String, Object?>>(), reason: line);
    expect(line, startsWith('{"event":"'));
  }
}

void main() {
  final dart = _dartExecutable();

  test(
    'real process: version exits 0, a download without url exits 2, stdout is JSON lines only',
    () async {
      final version = await _cli(dart!, ['version']);
      expect(version.exitCode, 0, reason: '${version.stdout}${version.stderr}');
      _expectJsonOnly(version);
      expect(version.stdout as String, contains('"kind":"version"'));
      expect((version.stderr as String).trim(), isEmpty);

      final usage = await _cli(dart, ['download']);
      expect(usage.exitCode, 2, reason: '${usage.stdout}${usage.stderr}');
      _expectJsonOnly(usage);
      expect(usage.stdout as String, contains('"code":"USAGE"'));
      expect((usage.stderr as String).trim(), isEmpty);
    },
    skip: dart == null ? 'no dart executable found' : false,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
