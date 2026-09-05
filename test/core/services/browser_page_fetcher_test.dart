import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/services/browser_page_fetcher.dart';

/// Writes a fake "browser" executable (a `.bat` that echoes fixed HTML,
/// matching the plan's own test guidance) and returns its path. Windows
/// can run a `.bat` directly via `Process.start` without a shell (proven
/// against this checkout before writing this test), which keeps the
/// production code's "argument lists only, no shell" rule intact even in
/// the fake.
File _writeFakeBrowser(Directory dir, {required String name, required List<String> script}) {
  final file = File('${dir.path}/$name.bat');
  file.writeAsStringSync(script.join('\r\n'));
  return file;
}

void main() {
  late Directory workDir;

  setUp(() {
    workDir = Directory.systemTemp.createTempSync('mida_bpf_test_');
  });

  tearDown(() {
    if (workDir.existsSync()) workDir.deleteSync(recursive: true);
  });

  group('BrowserPageFetcher.fetchDom', () {
    test('a loopback target URL is rejected with UNSUPPORTED_URL before touching the executable (SSRF guard)',
        () async {
      // A candidate path that would succeed if reached, so a false-pass
      // (guard not applied) would show up as a different failure/success
      // shape instead of silently matching for the wrong reason.
      final bat = _writeFakeBrowser(
        workDir,
        name: 'would_have_run',
        script: const ['@echo off', 'echo ^<html^>should not run^</html^>'],
      );
      final fetcher = BrowserPageFetcher(candidatePaths: () => [bat.path]);

      await expectLater(
        fetcher.fetchDom(Uri.parse('http://127.0.0.1:1/private')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL')),
      );
    });

    test('an IPv4-mapped IPv6 loopback target (::ffff:127.0.0.1) is rejected with UNSUPPORTED_URL (F2)', () async {
      final bat = _writeFakeBrowser(
        workDir,
        name: 'would_have_run_v4mapped',
        script: const ['@echo off', 'echo ^<html^>should not run^</html^>'],
      );
      final fetcher = BrowserPageFetcher(candidatePaths: () => [bat.path]);

      await expectLater(
        fetcher.fetchDom(Uri.parse('http://[::ffff:127.0.0.1]/private')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL')),
      );
    });

    test('allowPrivateHosts lets a test point fetchDom at a loopback target', () async {
      final bat = _writeFakeBrowser(
        workDir,
        name: 'allowed_loopback',
        script: const ['@echo off', 'echo ^<html^>ok^</html^>'],
      );
      final fetcher = BrowserPageFetcher(candidatePaths: () => [bat.path], allowPrivateHosts: true);

      final dom = await fetcher.fetchDom(Uri.parse('http://127.0.0.1:1/private'));
      expect(dom, contains('ok'));
    });

    test('BROWSER_MISSING when no candidate executable exists on disk', () async {
      final fetcher = BrowserPageFetcher(candidatePaths: () => ['${workDir.path}/does-not-exist.exe']);

      await expectLater(
        fetcher.fetchDom(Uri.parse('https://example.com')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'BROWSER_MISSING')),
      );
    });

    test('runs the executable with the expected headless argument list and returns its stdout', () async {
      final bat = _writeFakeBrowser(
        workDir,
        name: 'echo_html',
        script: const [
          '@echo off',
          'echo ARGS:%*',
          'echo ^<html^>^<video src="https://cdn.example.com/v.mp4"^>^</video^>^</html^>',
        ],
      );
      final fetcher = BrowserPageFetcher(candidatePaths: () => [bat.path]);

      final dom = await fetcher.fetchDom(Uri.parse('https://example.com/post/1'));

      expect(dom, contains('<video src="https://cdn.example.com/v.mp4">'));
      expect(dom, contains('--headless=new'));
      expect(dom, contains('--dump-dom'));
      expect(dom, contains('https://example.com/post/1'));
    });

    test('passes a unique --user-data-dir per call', () async {
      final bat = _writeFakeBrowser(
        workDir,
        name: 'echo_args',
        script: const ['@echo off', 'echo ARGS:%*'],
      );
      final fetcher = BrowserPageFetcher(candidatePaths: () => [bat.path]);

      final domA = await fetcher.fetchDom(Uri.parse('https://example.com/a'));
      final domB = await fetcher.fetchDom(Uri.parse('https://example.com/b'));

      final dirA = RegExp(r'--user-data-dir=(\S+)').firstMatch(domA)!.group(1);
      final dirB = RegExp(r'--user-data-dir=(\S+)').firstMatch(domB)!.group(1);
      expect(dirA, isNot(equals(dirB)));
    });

    Set<String> midaBrowserTempDirs() => Directory.systemTemp
        .listSync()
        .whereType<Directory>()
        .map((d) => d.path)
        .where((p) => p.contains('mida_browser_'))
        .toSet();

    test('deletes the temporary profile directory after a successful run', () async {
      final bat = _writeFakeBrowser(
        workDir,
        name: 'capture_profile',
        script: const ['@echo off', 'echo ^<html^>ok^</html^>'],
      );
      final fetcher = BrowserPageFetcher(candidatePaths: () => [bat.path]);

      final before = midaBrowserTempDirs();
      await fetcher.fetchDom(Uri.parse('https://example.com/c'));
      final after = midaBrowserTempDirs();

      expect(after, equals(before));
      // Guard-can-fail evidence (see report): temporarily commenting out
      // the `profileDir.deleteSync(recursive: true)` line in
      // `BrowserPageFetcher.fetchDom`'s `finally` block leaves a new
      // `mida_browser_*` directory behind and turns this expect() red,
      // proving the assertion exercises real cleanup rather than a
      // directory that was never created.
    });

    test('deletes the temporary profile directory even when the run fails (empty stdout -> NETWORK)', () async {
      // No echo of any HTML: fetchDom treats empty stdout as a failure.
      final bat = _writeFakeBrowser(workDir, name: 'empty_output', script: const ['@echo off']);
      final fetcher = BrowserPageFetcher(candidatePaths: () => [bat.path]);

      final before = midaBrowserTempDirs();
      await expectLater(
        fetcher.fetchDom(Uri.parse('https://example.com/d')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NETWORK')),
      );
      final after = midaBrowserTempDirs();

      expect(after, equals(before));
    });

    test('kills the process and throws NETWORK when it exceeds the timeout', () async {
      final bat = _writeFakeBrowser(
        workDir,
        name: 'hang',
        script: const [
          '@echo off',
          ':loop',
          'ping -n 2 127.0.0.1 >nul',
          'goto loop',
        ],
      );
      final fetcher = BrowserPageFetcher(
        candidatePaths: () => [bat.path],
        timeout: const Duration(milliseconds: 300),
      );

      final stopwatch = Stopwatch()..start();
      await expectLater(
        fetcher.fetchDom(Uri.parse('https://example.com/e')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NETWORK')),
      );
      stopwatch.stop();

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    }, timeout: const Timeout(Duration(seconds: 15)));
  });
}
