import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/services/browser_temp_cleanup.dart';

void main() {
  group('BrowserTempCleanup.sweepStale', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('mida_sweep_test_root_');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    // `dart:io`'s `Directory` has no `setLastModifiedSync` (only `File`
    // does), so "older than maxAge" is exercised via `maxAge: Duration.zero`
    // instead of backdating a real timestamp: by the time `sweepStale`
    // stats a directory created moments earlier, its real mtime is already
    // (by however many microseconds elapsed) before `DateTime.now()` at the
    // moment of that stat - which is exactly what "older than a zero-length
    // window" means. A large `maxAge` (1 hour) is used for the "leave it
    // alone" cases, which a just-created directory never exceeds.
    Directory makeDir(String name) => Directory('${root.path}${Platform.pathSeparator}$name')..createSync();

    test('deletes an owned-prefix directory once it counts as older than maxAge', () async {
      final stale = makeDir('mida_cdp_abc123');

      await BrowserTempCleanup.sweepStale(maxAge: Duration.zero, tempDir: root);

      expect(stale.existsSync(), isFalse);
    });

    test('leaves a recent owned-prefix directory alone', () async {
      final fresh = makeDir('mida_profile_recent');

      await BrowserTempCleanup.sweepStale(maxAge: const Duration(hours: 1), tempDir: root);

      expect(fresh.existsSync(), isTrue);
    });

    test('guard can fail: a directory with no owned prefix is never touched even under maxAge=zero', () async {
      // Proves the prefix filter, not just age, gates deletion - a naive
      // "delete anything old in temp" sweep would be far too broad
      // (it is the OS temp directory, shared with everything else on the
      // machine) and this is exactly the check that stops that.
      final unrelated = makeDir('some_other_apps_cache');

      await BrowserTempCleanup.sweepStale(maxAge: Duration.zero, tempDir: root);

      expect(unrelated.existsSync(), isTrue);
    });

    test('a plain file (not a directory) with an owned prefix is ignored, not deleted or thrown on', () async {
      final file = File('${root.path}${Platform.pathSeparator}mida_cdp_not_a_dir')..createSync();

      await BrowserTempCleanup.sweepStale(maxAge: Duration.zero, tempDir: root);

      expect(file.existsSync(), isTrue);
    });

    test('an unreadable/nonexistent root directory is a no-op, not a throw', () async {
      final missing = Directory('${root.path}${Platform.pathSeparator}does-not-exist');
      await BrowserTempCleanup.sweepStale(tempDir: missing);
    });
  });

  group('BrowserTempCleanup.deleteQuietly', () {
    test('deletes an existing directory and reports success', () async {
      final dir = Directory.systemTemp.createTempSync('mida_cdp_delete_test_');
      expect(await BrowserTempCleanup.deleteQuietly(dir), isTrue);
      expect(dir.existsSync(), isFalse);
    });

    test('a directory that never existed is reported as success (nothing to clean up)', () async {
      final dir = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}mida_cdp_never_existed_xyz');
      expect(await BrowserTempCleanup.deleteQuietly(dir), isTrue);
    });
  });
}
