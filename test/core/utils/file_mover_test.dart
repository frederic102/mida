import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/utils/file_mover.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mida_file_mover_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('the default rename path moves the file (src gone, dst has the bytes)', () async {
    final src = File('${tempDir.path}/src.txt')..writeAsStringSync('hello');
    final dstPath = '${tempDir.path}/dst.txt';
    final mover = FileMover();

    await mover.move(src.path, dstPath);

    expect(await src.exists(), isFalse);
    expect(await File(dstPath).readAsString(), 'hello');
  });

  test('guard-can-fail: when rename fails (e.g. cross-volume), it falls back to copy+delete and preserves data', () async {
    final src = File('${tempDir.path}/src.txt')..writeAsStringSync('cross-volume payload');
    final dstPath = '${tempDir.path}/dst.txt';

    var renameAttempted = false;
    final mover = FileMover(
      rename: (srcFile, dst) {
        renameAttempted = true;
        throw const FileSystemException('simulated cross-volume rename failure');
      },
    );

    await mover.move(src.path, dstPath);

    expect(renameAttempted, isTrue, reason: 'the injected rename must actually have been tried first');
    expect(await src.exists(), isFalse, reason: 'copy+delete fallback must still remove the source');
    expect(await File(dstPath).readAsString(), 'cross-volume payload', reason: 'the data must survive the fallback');
  });

  test('the injected rename function proves it is live: a version that always succeeds is never asked to copy', () async {
    final src = File('${tempDir.path}/src.txt')..writeAsStringSync('ok');
    final dstPath = '${tempDir.path}/dst.txt';
    var renameCalls = 0;

    final mover = FileMover(
      rename: (srcFile, dst) async {
        renameCalls++;
        return srcFile.rename(dst);
      },
    );

    await mover.move(src.path, dstPath);

    expect(renameCalls, 1);
    expect(await File(dstPath).exists(), isTrue);
  });

  test('guard-can-fail: a throwing copy (during the rename-failed fallback) leaves no file at dst, '
      'only a cleaned-up .part', () async {
    final src = File('${tempDir.path}/src.txt')..writeAsStringSync('should never land at dst');
    final dstPath = '${tempDir.path}/dst.txt';

    final mover = FileMover(
      rename: (srcFile, dst) => throw const FileSystemException('simulated cross-volume rename failure'),
      copy: (srcFile, dst) => throw const FileSystemException('simulated disk-full copy failure'),
    );

    await expectLater(mover.move(src.path, dstPath), throwsA(isA<FileSystemException>()));

    expect(await File(dstPath).exists(), isFalse, reason: 'dst must never be created when the copy fails');
    expect(await File('$dstPath.part').exists(), isFalse, reason: 'the .part sibling must be cleaned up too');
    expect(await src.exists(), isTrue, reason: 'src must be left alone (not deleted) when the whole move failed');
  });

  group('PathAccessException retry (transient Windows AV/indexer lock right after a large download finishes)', () {
    PathAccessException fakeLock(String path) =>
        PathAccessException(path, const OSError('Access is denied', 5), 'simulated transient AV/indexer lock');

    test('guard can fail: the default window is 6 attempts with exponential backoff (~15.5s total), '
        'not the original 3 attempts/~1s that still lost the race live', () async {
      final src = File('${tempDir.path}/src.txt')..writeAsStringSync('long lock payload');
      final dstPath = '${tempDir.path}/dst.txt';
      var attempts = 0;
      final delays = <Duration>[];

      final mover = FileMover(
        rename: (srcFile, dst) async {
          attempts++;
          if (attempts < 6) throw fakeLock(dst);
          return srcFile.rename(dst);
        },
        backoff: (attempt) {
          final d = FileMover().backoff(attempt);
          delays.add(d);
          return Duration.zero; // still keep the test itself fast
        },
      );

      await mover.move(src.path, dstPath);

      expect(attempts, 6, reason: 'the default must give a real AV/indexer scan (observed live to '
          'outlast the original 3-attempt/~1s window) enough room to clear');
      expect(delays, [
        const Duration(milliseconds: 500),
        const Duration(milliseconds: 1000),
        const Duration(milliseconds: 2000),
        const Duration(milliseconds: 4000),
        const Duration(milliseconds: 8000),
      ]);
    });

    test('guard can fail: a rename that fails with PathAccessException twice then succeeds is retried, '
        'never falls back to copy at all', () async {
      final src = File('${tempDir.path}/src.txt')..writeAsStringSync('retry payload');
      final dstPath = '${tempDir.path}/dst.txt';
      var attempts = 0;
      var copyAttempted = false;

      final mover = FileMover(
        rename: (srcFile, dst) async {
          attempts++;
          if (attempts < 3) throw fakeLock(dst);
          return srcFile.rename(dst);
        },
        copy: (srcFile, dst) {
          copyAttempted = true;
          return srcFile.copy(dst);
        },
        backoff: (_) => Duration.zero,
      );

      await mover.move(src.path, dstPath);

      expect(attempts, 3, reason: 'must retry exactly up to the point of success, not give up early');
      expect(copyAttempted, isFalse, reason: 'a rename that eventually succeeds must never fall back to copy');
      expect(await File(dstPath).readAsString(), 'retry payload');
    });

    test('guard can fail: a rename that keeps failing with PathAccessException past maxRenameAttempts '
        'falls back to copy (not left unresolved)', () async {
      final src = File('${tempDir.path}/src.txt')..writeAsStringSync('exhausted retries payload');
      final dstPath = '${tempDir.path}/dst.txt';
      var attempts = 0;

      final mover = FileMover(
        rename: (srcFile, dst) {
          attempts++;
          throw fakeLock(dst);
        },
        maxRenameAttempts: 3,
        backoff: (_) => Duration.zero,
      );

      await mover.move(src.path, dstPath);

      expect(attempts, 3, reason: 'must exhaust maxRenameAttempts before giving up on the primary rename');
      expect(await File(dstPath).readAsString(), 'exhausted retries payload', reason: 'the copy fallback must still land the data');
    });

    test(
      "guard can fail: the fallback path's own final rename (.part -> dst) is retried too, and rethrows "
      'PathAccessException if it never clears',
      () async {
        final src = File('${tempDir.path}/src.txt')..writeAsStringSync('should not land anywhere');
        final dstPath = '${tempDir.path}/dst.txt';
        var finalRenameAttempts = 0;

        final mover = FileMover(
          rename: (srcFile, dst) => throw const FileSystemException('simulated cross-volume rename failure'),
          finalRename: (srcFile, dst) {
            finalRenameAttempts++;
            throw fakeLock(dst);
          },
          maxRenameAttempts: 3,
          backoff: (_) => Duration.zero,
        );

        await expectLater(mover.move(src.path, dstPath), throwsA(isA<PathAccessException>()));
        expect(finalRenameAttempts, 3, reason: 'must exhaust maxRenameAttempts before giving up');
        expect(await File(dstPath).exists(), isFalse);
        // The .part sibling is intentionally left behind here (unlike the
        // primary-rename-fails-then-copy-fails case above): the copy
        // itself succeeded, only the final rename into place never
        // cleared, so there is real data sitting in `<dst>.part` worth
        // recovering rather than silently deleting.
      },
    );
  });

  test('the copy+rename fallback writes to <dst>.part first, not directly to dst '
      '(observed via an injected copy that records its target)', () async {
    final src = File('${tempDir.path}/src.txt')..writeAsStringSync('cross-volume payload 2');
    final dstPath = '${tempDir.path}/dst.txt';
    String? copyTargetSeen;

    final mover = FileMover(
      rename: (srcFile, dst) => throw const FileSystemException('simulated cross-volume rename failure'),
      copy: (srcFile, dst) {
        copyTargetSeen = dst;
        return srcFile.copy(dst);
      },
    );

    await mover.move(src.path, dstPath);

    expect(copyTargetSeen, '$dstPath.part');
    expect(await File(dstPath).readAsString(), 'cross-volume payload 2');
    expect(await File('$dstPath.part').exists(), isFalse, reason: 'the .part sibling must be renamed away, not left behind');
  });
}
