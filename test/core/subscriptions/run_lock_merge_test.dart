import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/subscriptions/run_lock.dart';
import 'package:mida/core/subscriptions/subscription.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('mida_run_'));
  tearDown(() => dir.deleteSync(recursive: true));

  File f(String name) => File('${dir.path}${Platform.pathSeparator}$name');

  group('RunLock', () {
    test('a second run on the same archive fails at once; another archive is independent', () async {
      final first = await RunLock.acquire(f('a.txt'));
      await expectLater(RunLock.acquire(f('a.txt')), throwsA(isA<RunLockBusy>()));
      final other = await RunLock.acquire(f('b.txt'));
      await other.release();
      await first.release();
    });

    test('the same archive spelled differently is the same lock', () async {
      final first = await RunLock.acquire(f('a.txt'));
      final alias = File('${dir.path}${Platform.pathSeparator}sub${Platform.pathSeparator}..${Platform.pathSeparator}a.txt');
      await expectLater(RunLock.acquire(alias), throwsA(isA<RunLockBusy>()));
      await first.release();
    });

    test('it is released for the next run, and a bounded wait gets it once the holder is done', () async {
      final first = await RunLock.acquire(f('a.txt'));
      final waiting = RunLock.acquire(f('a.txt'), wait: const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await first.release();
      final second = await waiting;
      await second.release();
      await (await RunLock.acquire(f('a.txt'))).release();
    });

    test('a bounded wait gives up when the holder never lets go', () async {
      final first = await RunLock.acquire(f('a.txt'));
      final watch = Stopwatch()..start();
      await expectLater(RunLock.acquire(f('a.txt'), wait: const Duration(milliseconds: 300)), throwsA(isA<RunLockBusy>()));
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(250));
      await first.release();
    });

    test('a lock held by another handle (another process) is respected', () async {
      final other = await File('${f('a.txt').path}.run.lock').open(mode: FileMode.append);
      await other.lock(FileLock.exclusive);
      await expectLater(RunLock.acquire(f('a.txt')), throwsA(isA<RunLockBusy>()));
      await other.unlock();
      await other.close();
      await (await RunLock.acquire(f('a.txt'))).release();
    });
  });

  group('mergeCheckResults: a run owns channel_id (while null) and last_checked (never backwards)', () {
    final created = DateTime.utc(2026, 11, 1);
    Subscription row({String source = 'S', String title = 'T', DateTime? at, String? id, DateTime? checked, String? dir}) =>
        Subscription(source: source, title: title, createdAt: at ?? created, channelId: id, lastChecked: checked, outputDir: dir);

    test('an edit made during the run survives: title, output folder, created_at', () {
      final onDisk = [row(title: 'Renamed by the user', dir: r'D:\new')];
      final result = row(title: 'old title from the start of the run', id: 'UCx', checked: DateTime.utc(2026, 11, 22));
      final merged = mergeCheckResults(onDisk, [result]).single;
      expect(merged.title, 'Renamed by the user');
      expect(merged.outputDir, r'D:\new');
      expect(merged.createdAt, created);
      expect(merged.channelId, 'UCx');
      expect(merged.lastChecked, DateTime.utc(2026, 11, 22));
    });

    test('reversed completion order never moves last_checked backward', () {
      final newer = row(id: 'UCx', checked: DateTime.utc(2026, 11, 22, 12));
      final older = row(id: 'UCx', checked: DateTime.utc(2026, 11, 22, 8));
      var disk = [row()];
      disk = mergeCheckResults(disk, [newer]); // the run that started later finishes first
      disk = mergeCheckResults(disk, [older]);
      expect(disk.single.lastChecked, DateTime.utc(2026, 11, 22, 12));
      expect(mergeCheckResults([row(checked: DateTime.utc(2026, 11, 30))], [older]).single.lastChecked, DateTime.utc(2026, 11, 30));
    });

    test('a channel id already on disk is not replaced, an empty one is filled', () {
      expect(mergeCheckResults([row(id: 'UCdisk')], [row(id: 'UCrun', checked: DateTime.utc(2026, 11, 2))]).single.channelId, 'UCdisk');
      expect(mergeCheckResults([row()], [row(id: 'UCrun')]).single.channelId, 'UCrun');
    });

    test('a removed row is not resurrected and a re-added one is not mistaken for its predecessor', () {
      final result = row(id: 'UCx', checked: DateTime.utc(2026, 11, 22));
      expect(mergeCheckResults([], [result]), isEmpty);
      final readded = row(at: DateTime.utc(2026, 11, 20));
      final merged = mergeCheckResults([readded, row(source: 'other')], [result]);
      expect(merged.map((s) => (s.channelId, s.lastChecked)), [(null, null), (null, null)]);
    });
  });
}
