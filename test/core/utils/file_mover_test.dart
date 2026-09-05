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
