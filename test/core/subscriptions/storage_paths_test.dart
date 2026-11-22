import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/subscriptions/storage_paths.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('mida_paths_'));
  tearDown(() => dir.deleteSync(recursive: true));

  final sep = Platform.pathSeparator;
  File f(String rel) => File('${dir.path}$sep${rel.replaceAll('/', sep)}');

  Future<void> check(File a, File b) => ensureDistinctStorage({'--subscriptions': a, '--archive': b});

  test('two different files pass, existing or not', () async {
    f('subs.json').writeAsStringSync('{}');
    await check(f('subs.json'), f('subs.json.archive'));
    await check(f('new/subs.json'), f('other/archive.txt'));
  });

  test('the same path is refused, also through .. segments and a non-existing folder', () async {
    f('subs.json').writeAsStringSync('{}');
    await expectLater(check(f('subs.json'), f('subs.json')), throwsA(isA<StorageAliasError>()));
    await expectLater(check(f('subs.json'), f('sub/../subs.json')), throwsA(isA<StorageAliasError>()));
    await expectLater(check(f('x/../subs.json'), f('y/../subs.json')), throwsA(isA<StorageAliasError>()));
  });

  test('a path that differs only by case is the same file on Windows', () async {
    f('Subs.json').writeAsStringSync('{}');
    final other = f('subs.JSON');
    if (Platform.isWindows) {
      await expectLater(check(f('Subs.json'), other), throwsA(isA<StorageAliasError>()));
    } else {
      await check(f('Subs.json'), other);
    }
  });

  test('a lock or temp file of one is refused as the other', () async {
    for (final name in ['subs.json.lock', 'subs.json.4242.1700.0.tmp', 'subs.json.tmp']) {
      await expectLater(check(f('subs.json'), f(name)), throwsA(isA<StorageAliasError>()), reason: name);
      await expectLater(check(f(name), f('subs.json')), throwsA(isA<StorageAliasError>()), reason: name);
    }
    await check(f('subs.json'), f('subs.json.archive'));
  });

  test('a symlink or junction to the other file is refused', () async {
    f('subs.json').writeAsStringSync('{}');
    final link = Link(f('alias.json').path);
    try {
      await link.create(f('subs.json').path);
    } on FileSystemException {
      markTestSkipped('This account may not create symbolic links.');
      return;
    }
    await expectLater(check(f('subs.json'), f('alias.json')), throwsA(isA<StorageAliasError>()));
  });
}
