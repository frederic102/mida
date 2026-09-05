import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/output_stream_prober.dart';

/// Covers `OutputStreamProber.streamTypes`'s distinction between "ffprobe
/// could not even be started" (null, genuinely inconclusive) and "ffprobe
/// ran but refused to parse this file" (a confirmed empty set) - live-caught
/// (coordinator repro): vimeo/facebook both exposed a CMAF media segment
/// with no init segment as if it were a complete file, and the pre-fix
/// version of this class waved that through as "inconclusive" instead of
/// treating ffprobe's own non-zero exit as the confirmation it is.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mida_prober_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('guard can fail: a non-zero exit with no parsed streams is a confirmed empty set, not null', () async {
    final scriptPath = '${tempDir.path}/fake_ffprobe_fail.bat';
    await File(scriptPath).writeAsString(
      '@echo off\r\necho trun track id unknown, no tfhd was found 1>&2\r\nexit /b 1\r\n',
    );
    final prober = OutputStreamProber(ffprobePathResolver: () async => scriptPath);

    final types = await prober.streamTypes('${tempDir.path}/whatever.mp4');

    expect(types, isNotNull, reason: 'a real parse failure must be reported as confirmed, not inconclusive');
    expect(types, isEmpty);
  });

  test('a non-zero exit that still printed some stream info keeps that info rather than discarding it', () async {
    final scriptPath = '${tempDir.path}/fake_ffprobe_partial.bat';
    await File(scriptPath).writeAsString('@echo off\r\necho video\r\nexit /b 1\r\n');
    final prober = OutputStreamProber(ffprobePathResolver: () async => scriptPath);

    final types = await prober.streamTypes('${tempDir.path}/whatever.mp4');

    expect(types, {'video'});
  });

  test('a zero exit reports the real stream types normally', () async {
    final scriptPath = '${tempDir.path}/fake_ffprobe_ok.bat';
    await File(scriptPath).writeAsString('@echo off\r\necho video\r\necho audio\r\nexit /b 0\r\n');
    final prober = OutputStreamProber(ffprobePathResolver: () async => scriptPath);

    final types = await prober.streamTypes('${tempDir.path}/whatever.mp4');

    expect(types, {'video', 'audio'});
  });

  test('ffprobe itself could not even be started (missing binary) stays null - genuinely inconclusive', () async {
    final prober = OutputStreamProber(
      ffprobePathResolver: () async => '${tempDir.path}/this_binary_does_not_exist.exe',
    );

    final types = await prober.streamTypes('${tempDir.path}/whatever.mp4');

    expect(types, isNull);
  });
}
