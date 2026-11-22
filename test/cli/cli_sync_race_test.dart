import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/youtube/youtube_lister.dart';
import 'package:mida/core/subscriptions/subscription.dart';

import '../core/extractors/youtube/youtube_list_support.dart';
import 'cli_test_support.dart';

const _channel = 'https://www.youtube.com/@YouTube';

YoutubeLister _lister() => YoutubeLister(
      transportFactory: () => FakeTransport(pages: {
        channelPath: pageHtml(fixtureJson('channel_initial.json')),
        '/feeds/videos.xml': fixtureText('channel_feed.xml'),
      }),
      pause: (_) async {},
      pageDelay: Duration.zero,
    );

void main() {
  late Directory dir;
  late File subsFile;
  late String archive;
  late String out;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('mida_race_');
    final sep = Platform.pathSeparator;
    subsFile = File('${dir.path}${sep}subs.json');
    archive = '${dir.path}${sep}archive.txt';
    out = '${dir.path}${sep}out';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// A pipeline that reports it started and then waits for [release].
  FakePipeline blocked(Completer<void> started, Completer<void> release) => FakePipeline(script: (_, __) async {
        started.complete();
        await release.future;
      });

  List<String> args(String subs) => ['sync', '--subscriptions', subs, '--archive', archive, '--out', out];

  Future<void> subscribe({int n = 1}) => SubscriptionStore(subsFile).save([
        for (var i = 0; i < n; i++)
          Subscription(
            source: [channelUc, 'https://www.youtube.com/channel/$channelUc', 'https://www.youtube.com/channel/$channelUc/videos', 'http://youtube.com/channel/$channelUc'][i],
            title: 'c$i',
            createdAt: DateTime.utc(2026, 11, 21, 12),
          ),
      ]);

  group('one run at a time per archive', () {
    test('download --all: two overlapping runs over the same id download it exactly once', () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final first = blocked(started, release);
      final run1 = runCli(['download', _channel, '--all', '--limit', '1', '--archive', archive, '--out', out],
          registry: FakeRegistry.ok(), pipeline: first, lister: _lister());
      await started.future;
      final second = FakePipeline();
      final run2 = await runCli(['download', _channel, '--all', '--limit', '1', '--archive', archive, '--out', out],
          registry: FakeRegistry.ok(), pipeline: second, lister: _lister());
      expect((run2.exitCode, run2.last['code']), (6, 'RUN_IN_PROGRESS'));
      expect(second.calls, isEmpty);
      release.complete();
      expect((await run1).exitCode, 0);
      expect(first.calls.length + second.calls.length, 1);
      // Once the first run is done the archive makes a later run skip it.
      final third = await runCli(['download', _channel, '--all', '--limit', '1', '--archive', archive, '--out', out],
          registry: FakeRegistry.ok(), lister: _lister());
      expect(third.last, containsPair('skipped', 1));
    });

    test('sync: an overlapping sync is refused while the first is downloading, and the upload is fetched once', () async {
      await subscribe();
      final started = Completer<void>();
      final release = Completer<void>();
      final first = blocked(started, release);
      final run1 = runCli(args(subsFile.path), registry: FakeRegistry.ok(), pipeline: first, lister: _lister());
      await started.future;
      final second = FakePipeline();
      final run2 = await runCli(args(subsFile.path), registry: FakeRegistry.ok(), pipeline: second, lister: _lister());
      expect((run2.exitCode, run2.last['code']), (6, 'RUN_IN_PROGRESS'));
      release.complete();
      expect((await run1).exitCode, 0);
      expect(first.calls.length + second.calls.length, 1);
    });

    test('the lock is released after a failed run', () async {
      await subscribe();
      final failing = FakeRegistry((_) async => throw const MediaExtractionException('NO_MEDIA_FOUND', 'gone'));
      expect((await runCli(args(subsFile.path), registry: failing, lister: _lister())).exitCode, 3);
      expect((await runCli(args(subsFile.path), registry: FakeRegistry.ok(), lister: _lister())).exitCode, 0);
    });
  });

  group('one archive reached through an alias is still one archive', () {
    final sep = Platform.pathSeparator;

    /// (name, builder) -> path of an alias of `<dir>/real/archive.txt`, or null if it cannot be made.
    final aliases = <String, Future<String?> Function(Directory)>{
      'a .. spelling': (d) async => [d.path, 'real', '..', 'real', 'archive.txt'].join(sep),
      'a junction or directory link to the folder': (d) async {
        try {
          await Link('${d.path}${sep}via').create('${d.path}${sep}real');
        } on FileSystemException {
          return null;
        }
        return '${d.path}${sep}via${sep}archive.txt';
      },
      'a file symlink to the archive': (d) async {
        try {
          await Link('${d.path}${sep}link.txt').create('${d.path}${sep}real${sep}archive.txt');
        } on FileSystemException {
          return null;
        }
        return '${d.path}${sep}link.txt';
      },
    };

    aliases.forEach((name, make) {
      for (final aliasFirst in [false, true]) {
        test('$name: ${aliasFirst ?'alias first, real path second' : 'real path first, alias second'} -> one RUN_IN_PROGRESS, one download', () async {
          final real = '${dir.path}${sep}real${sep}archive.txt';
          Directory('${dir.path}${sep}real').createSync();
          File(real).writeAsStringSync('');
          final alias = await make(dir);
          if (alias == null) {
            markTestSkipped('Creating this kind of link is not permitted for this account (Windows needs developer mode for file symlinks).');
            return;
          }
          final spellings = aliasFirst ? [alias, real] : [real, alias];
          List<String> cmd(String a) => ['download', _channel, '--all', '--limit', '1', '--archive', a, '--out', out];
          final started = Completer<void>();
          final release = Completer<void>();
          final first = blocked(started, release);
          final run1 = runCli(cmd(spellings[0]), registry: FakeRegistry.ok(), pipeline: first, lister: _lister());
          await started.future;
          final second = FakePipeline();
          final run2 = await runCli(cmd(spellings[1]), registry: FakeRegistry.ok(), pipeline: second, lister: _lister());
          expect((run2.exitCode, run2.last['code']), (6, 'RUN_IN_PROGRESS'));
          expect(second.calls, isEmpty);
          release.complete();
          expect((await run1).exitCode, 0);
          expect(first.calls.length + second.calls.length, 1);
          expect(File(real).readAsStringSync().trim(), isNotEmpty, reason: 'the id landed in the real file');
          if (name.contains('symlink')) expect(FileSystemEntity.isLinkSync(alias), isTrue, reason: 'the link itself is not replaced by a plain file');
        });
      }
    });
  });

  group('a run only writes what it owns', () {
    test('a title edited while the run is downloading survives, and last_checked is set', () async {
      await subscribe();
      final registry = FakeRegistry((_) async {
        await SubscriptionStore(subsFile).update((c) => [for (final s in c) Subscription(source: s.source, title: 'Edited meanwhile', createdAt: s.createdAt, outputDir: r'D:\elsewhere')]);
        return sampleInfo();
      });
      final run = await runCli(args(subsFile.path), registry: registry, lister: _lister());
      expect(run.exitCode, 0);
      final saved = (await SubscriptionStore(subsFile).load()).single;
      expect(saved.title, 'Edited meanwhile');
      expect(saved.outputDir, r'D:\elsewhere');
      expect(saved.lastChecked, isNotNull);
      expect(saved.channelId, channelUc);
    });

    test('a row removed while the run is going is not brought back', () async {
      await subscribe();
      final registry = FakeRegistry((_) async {
        await SubscriptionStore(subsFile).update((_) => []);
        return sampleInfo();
      });
      await runCli(args(subsFile.path), registry: registry, lister: _lister());
      expect(await SubscriptionStore(subsFile).load(), isEmpty);
    });
  });

  group('download and RSS histories are separate', () {
    test('feeds succeed, every download is rate limited: 30 s, 60 s, stop after the third, 4th channel unchecked', () async {
      await subscribe(n: 4);
      final registry = FakeRegistry((_) async => throw const MediaExtractionException('RATE_LIMITED', 'slow down'));
      final pauses = <Duration>[];
      final run = await runCli(args(subsFile.path), registry: registry, lister: _lister(), pauses: pauses);
      expect(run.exitCode, 7);
      expect(pauses.where((d) => d >= const Duration(seconds: 30)), [const Duration(seconds: 30), const Duration(seconds: 60)]);
      expect(run.last, containsPair('stopped', 'rate_limited'));
      expect(run.last, containsPair('failed', 3));
      expect(registry.resolved.length, 3);
      expect(run.ofEvent('status').where((e) => '${e['message']}'.startsWith('Checking')).length, 3);
    });
  });
}
