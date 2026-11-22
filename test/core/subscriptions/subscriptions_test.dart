import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/youtube/youtube_list_models.dart';
import 'package:mida/core/subscriptions/download_archive.dart';
import 'package:mida/core/subscriptions/safe_file.dart';
import 'package:mida/core/subscriptions/subscription.dart';
import 'package:mida/core/subscriptions/subscription_check.dart';

import '../extractors/youtube/youtube_list_support.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('mida_subs_'));
  tearDown(() => dir.deleteSync(recursive: true));

  File f(String name) => File('${dir.path}${Platform.pathSeparator}$name');
  List<String> leftovers() => [for (final e in dir.listSync()) e.path.split(Platform.pathSeparator).last]..removeWhere((n) => !n.endsWith('.tmp'));

  group('DownloadArchive', () {
    test('missing file is empty; add persists across reopen, one id per line', () async {
      final file = f('archive.txt');
      final a = await DownloadArchive.open(file);
      expect(a.length, 0);
      await a.add('dD33lDxL9K0');
      await a.add('8vAPJgyoO9g');
      await a.add('dD33lDxL9K0');
      expect(file.readAsStringSync(), 'dD33lDxL9K0\n8vAPJgyoO9g\n');
      final b = await DownloadArchive.open(file);
      expect(b.contains('dD33lDxL9K0'), isTrue);
      expect(b.contains('QwhynRkyiYQ'), isFalse);
      expect(b.length, 2);
    });

    test('ignores junk lines and CRLF, refuses to record a non-id, refuses a folder', () async {
      final file = f('archive.txt')..writeAsStringSync('dD33lDxL9K0\r\n# note\r\n\r\n../../x\r\n8vAPJgyoO9g');
      final a = await DownloadArchive.open(file);
      expect(a.length, 2);
      await expectLater(a.add('nope'), throwsArgumentError);
      Directory(f('folder').path).createSync();
      await expectLater(DownloadArchive.open(f('folder')), throwsA(isA<FileSystemException>()));
    });

    test('a stale snapshot does not lose another writer\'s id', () async {
      final file = f('archive.txt');
      final cli = await DownloadArchive.open(file);
      final app = await DownloadArchive.open(file); // both snapshots are empty
      await cli.add('aaaaaaaaaaa');
      await app.add('bbbbbbbbbbb');
      expect(file.readAsStringSync().trim().split('\n').toSet(), {'aaaaaaaaaaa', 'bbbbbbbbbbb'});
      expect(app.contains('aaaaaaaaaaa'), isTrue, reason: 'the merge is visible in the writer that merged');
      await cli.reload();
      expect(cli.contains('bbbbbbbbbbb'), isTrue);
    });

    test('concurrent adds from several writers all persist, with no temp files left', () async {
      final file = f('archive.txt');
      final writers = [for (var i = 0; i < 4; i++) await DownloadArchive.open(file)];
      final ids = [for (var i = 0; i < 20; i++) 'id${i.toString().padLeft(9, '0')}'];
      await Future.wait([for (var i = 0; i < ids.length; i++) writers[i % 4].add(ids[i])]);
      expect((await DownloadArchive.open(file)).length, 20);
      expect(leftovers(), isEmpty);
    });

    test('a writer waits for the cross-process lock instead of overwriting', () async {
      final file = f('archive.txt');
      final a = await DownloadArchive.open(file);
      // Another process holds the OS lock (this handle is outside our own queue).
      final other = await File('${file.path}.lock').open(mode: FileMode.append);
      await other.lock(FileLock.blockingExclusive);
      var done = false;
      final pending = a.add('aaaaaaaaaaa').then((_) => done = true);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(done, isFalse, reason: 'the add must wait while another process holds the lock');
      expect(file.existsSync(), isFalse);
      await other.unlock();
      await other.close();
      await pending;
      expect(file.readAsStringSync(), 'aaaaaaaaaaa\n');
    });

    test('a failure before the replace keeps the original bytes and leaves no temp file', () async {
      final file = f('archive.txt')..writeAsStringSync('dD33lDxL9K0\n');
      final a = await DownloadArchive.open(file);
      await expectLater(
        a.add('8vAPJgyoO9g', beforeReplace: () async => throw const FileSystemException('died here')),
        throwsA(isA<FileSystemException>()),
      );
      expect(file.readAsStringSync(), 'dD33lDxL9K0\n');
      expect(leftovers(), isEmpty);
    });

    test('SafeFile.writeAtomic: unique exclusive temp names, original survives a failed replace', () async {
      final target = f('data.txt')..writeAsStringSync('original');
      final names = <String>[];
      for (var i = 0; i < 3; i++) {
        await SafeFile.writeAtomic(target, 'v$i', beforeReplace: () async {
          names.addAll(dir.listSync().map((e) => e.path).where((p) => p.endsWith('.tmp')));
        });
      }
      expect(names.toSet().length, 3, reason: 'every write used its own temp file');
      expect(target.readAsStringSync(), 'v2');
      await expectLater(
        SafeFile.writeAtomic(target, 'never', beforeReplace: () async => throw StateError('crash')),
        throwsStateError,
      );
      expect(target.readAsStringSync(), 'v2');
      expect(leftovers(), isEmpty);
    });

    test('a failed write is not remembered as downloaded', () async {
      final path = '${dir.path}${Platform.pathSeparator}other${Platform.pathSeparator}a.txt';
      final a = await DownloadArchive.open(File(path));
      Directory(path).createSync(recursive: true); // the final rename now fails
      await expectLater(a.add('dD33lDxL9K0'), throwsA(isA<FileSystemException>()));
      expect(a.contains('dD33lDxL9K0'), isFalse);
    });
  });

  group('newUploadsSince (only uploads after the subscription was created)', () {
    final created = DateTime.utc(2026, 11, 21);
    YoutubeListItem item(String id, DateTime? at) => YoutubeListItem(id: id, title: id, published: at);

    test('keeps only newer, unarchived, dated items', () async {
      final archive = await DownloadArchive.open(f('a.txt'));
      await archive.add('ccccccccccc');
      final fresh = newUploadsSince([
        item('aaaaaaaaaaa', DateTime.utc(2026, 11, 21, 0, 0, 1)), // after
        item('bbbbbbbbbbb', DateTime.utc(2026, 11, 20)), // before: back catalogue
        item('ccccccccccc', DateTime.utc(2026, 11, 22)), // after but archived
        item('ddddddddddd', created), // exactly at created: not after
        item('eeeeeeeeeee', null), // undated: skipped
      ], createdAt: created, archive: archive);
      expect(fresh.map((i) => i.id), ['aaaaaaaaaaa']);
    });
  });

  group('SubscriptionStore', () {
    final sub = Subscription(
      source: 'https://www.youtube.com/@YouTube',
      title: 'YouTube',
      createdAt: DateTime.utc(2026, 11, 22, 1, 2, 3),
      outputDir: r'D:\Videos\yt',
    );

    test('round trip keeps every field, null output dir and last checked included', () async {
      final store = SubscriptionStore(f('subs.json'));
      expect(await store.load(), isEmpty);
      await store.save([sub, sub.copyWith(channelId: channelUc, lastChecked: DateTime.utc(2026, 11, 22, 5))]);
      final back = await store.load();
      expect(back.length, 2);
      expect(back[0].outputDir, r'D:\Videos\yt');
      expect(back[0].channelId, isNull);
      expect(back[0].lastChecked, isNull);
      expect(back[1].channelId, channelUc);
      expect(back[1].lastChecked, DateTime.utc(2026, 11, 22, 5));
      expect(back[1].createdAt, sub.createdAt);
      expect(leftovers(), isEmpty);
    });

    test('update merges into what is on disk now', () async {
      final store = SubscriptionStore(f('subs.json'));
      await store.save([sub]);
      final other = Subscription(source: channelUc, title: 'B', createdAt: DateTime.utc(2026, 1, 1));
      await store.save([sub, other]); // another writer adds B
      await store.update((current) => [for (final c in current) c.source == sub.source ? c.copyWith(lastChecked: DateTime.utc(2026, 11, 23)) : c]);
      final back = await store.load();
      expect(back.map((s) => s.source), [sub.source, channelUc]);
      expect(back.first.lastChecked, DateTime.utc(2026, 11, 23));
    });

    test('malformed files fail instead of being treated as empty', () async {
      final store = SubscriptionStore(f('subs.json'));
      const v = '"version": 1';
      for (final bad in [
        'not json',
        '[]',
        '{}',
        '{$v}',
        '{$v, "subscriptions": [1]}',
        '{$v, "subscriptions": [{"source": "x"}]}',
        '{$v, "subscriptions": [{"created_at": "2026-01-01T00:00:00Z"}]}',
        '{$v, "subscriptions": [{"source": "x", "created_at": "yesterday"}]}',
        '{$v, "subscriptions": [{"source": "x", "created_at": "2026-01-01T00:00:00Z", "output_dir": 5}]}',
      ]) {
        f('subs.json').writeAsStringSync(bad);
        await expectLater(store.load(), throwsFormatException, reason: bad);
      }
    });

    test('an unsupported or missing version is refused and the file is never rewritten', () async {
      final store = SubscriptionStore(f('subs.json'));
      for (final text in [
        '{"version": 2, "subscriptions": [], "future_field": {"keep": "me"}}',
        '{"version": "1", "subscriptions": []}',
        '{"version": null, "subscriptions": []}',
        '{"subscriptions": []}',
      ]) {
        f('subs.json').writeAsStringSync(text);
        final before = f('subs.json').readAsBytesSync();
        await expectLater(store.load(), throwsFormatException, reason: text);
        await expectLater(store.save([sub]), throwsFormatException, reason: text);
        await expectLater(store.update((c) => c), throwsFormatException, reason: text);
        expect(f('subs.json').readAsBytesSync(), before, reason: text);
      }
    });
  });

  group('checkSubscription', () {
    FakeTransport feed() => FakeTransport(pages: {'/feeds/videos.xml': fixtureText('channel_feed.xml')});

    Future<DownloadArchive> emptyArchive() => DownloadArchive.open(f('a.txt'));

    test('first run right after subscribing queues nothing and records the check', () async {
      final sub = Subscription(source: channelUc, title: 'YouTube', createdAt: DateTime.utc(2026, 11, 22, 6));
      final check = await checkSubscription(listerOver(feed()), sub, await emptyArchive(), now: DateTime.utc(2026, 11, 22, 6, 1));
      expect(check.fresh, isEmpty);
      expect(check.updated.channelId, channelUc);
      expect(check.updated.lastChecked, DateTime.utc(2026, 11, 22, 6, 1));
    });

    test('a new upload after created is queued once, then skipped via the archive', () async {
      final sub = Subscription(source: channelUc, title: 'YouTube', createdAt: DateTime.utc(2026, 11, 21, 12), channelId: channelUc);
      final archive = await emptyArchive();
      final check = await checkSubscription(listerOver(feed()), sub, archive);
      expect(check.fresh.map((i) => i.id), ['QwhynRkyiYQ']);
      await archive.add('QwhynRkyiYQ');
      expect((await checkSubscription(listerOver(feed()), sub, archive)).fresh, isEmpty);
    });

    test('a handle URL is resolved to its channel id through the channel page', () async {
      final t = FakeTransport(pages: {
        channelPath: pageHtml(fixtureJson('channel_initial.json')),
        '/feeds/videos.xml': fixtureText('channel_feed.xml'),
      });
      final sub = Subscription(source: 'https://www.youtube.com/@YouTube', title: '', createdAt: DateTime.utc(2026, 1, 1));
      final check = await checkSubscription(listerOver(t), sub, await emptyArchive());
      expect(check.updated.channelId, channelUc);
      expect(check.updated.title, 'YouTube');
      expect(check.fresh.length, 3);
    });

    test('a handle subscription on an empty channel resolves, then finds an upload later', () async {
      final created = DateTime.utc(2026, 11, 22, 8);
      final emptyChannel = {channelPath: pageHtml(channelPageWith([])), '/feeds/videos.xml': feedXml()};
      var sub = Subscription(source: 'https://www.youtube.com/@YouTube', title: '', createdAt: created);
      final first = await checkSubscription(listerOver(FakeTransport(pages: emptyChannel)), sub, await emptyArchive(), now: DateTime.utc(2026, 11, 22, 9));
      expect(first.fresh, isEmpty);
      expect(first.updated.channelId, channelUc, reason: 'the id is learned even though the channel has no videos');
      expect(first.updated.lastChecked, DateTime.utc(2026, 11, 22, 9));
      sub = first.updated;

      final later = FakeTransport(pages: {
        '/feeds/videos.xml': feedXml([('QwhynRkyiYQ', '2026-11-22T10:30:00+00:00')]),
      });
      final second = await checkSubscription(listerOver(later), sub, await emptyArchive());
      expect(second.fresh.map((i) => i.id), ['QwhynRkyiYQ']);
      expect(later.fetched.single.path, '/feeds/videos.xml', reason: 'the channel page is not read again');
    });

    test('a truncated feed fails the check and the returned state is never advanced', () async {
      final full = fixtureText('channel_feed.xml');
      final cut = full.substring(0, full.indexOf('</entry>') + 8);
      final sub = Subscription(source: channelUc, title: 'YouTube', createdAt: DateTime.utc(2026, 1, 1), channelId: channelUc);
      await expectLater(
        checkSubscription(listerOver(FakeTransport(pages: {'/feeds/videos.xml': cut})), sub, await emptyArchive()),
        throwsA(isA<MediaExtractionException>()),
      );
    });

    test('a source that is not a channel is refused', () async {
      final sub = Subscription(source: 'https://www.youtube.com/watch?v=dD33lDxL9K0', title: '', createdAt: DateTime.utc(2026, 1, 1));
      await expectLater(
        checkSubscription(listerOver(feed()), sub, await emptyArchive()),
        throwsA(isA<MediaExtractionException>()),
      );
    });
  });
}
