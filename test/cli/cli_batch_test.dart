import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/youtube/youtube_lister.dart';
import 'package:mida/core/subscriptions/subscription.dart';

import '../core/extractors/youtube/youtube_list_support.dart';
import 'cli_test_support.dart';

const _channel = 'https://www.youtube.com/@YouTube';
const _ids = ['dD33lDxL9K0', '8vAPJgyoO9g', 'P7GTfHdl5E8']; // first three of the captured channel page

YoutubeLister _lister({Map<String, String>? pages, List<Map<String, dynamic>>? browse}) => YoutubeLister(
      transportFactory: () => FakeTransport(
        pages: pages ?? {channelPath: pageHtml(fixtureJson('channel_initial.json'))},
        browse: browse ?? const [],
      ),
      pause: (_) async {},
      pageDelay: Duration.zero,
    );

void main() {
  late Directory dir;
  late String out;
  late String archive;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('mida_batch_');
    out = '${dir.path}${Platform.pathSeparator}out';
    archive = '${dir.path}${Platform.pathSeparator}archive.txt';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  List<String> archived() => File(archive).existsSync() ? const LineSplitter().convert(File(archive).readAsStringSync()) : [];

  group('argument rules', () {
    for (final (args, why) in [
      (['download', _channel, '--limit', '3'], '--limit needs --all'),
      (['download', _channel, '--archive', 'a.txt'], '--archive needs --all'),
      (['download', _channel, '--all', '--format-id', 'x'], '--all with --format-id'),
      (['download', _channel, '--all', '--limit', '0'], 'limit 0'),
      (['download', _channel, '--all', '--limit', 'ten'], 'limit not a number'),
      (['download', _channel, '--all', '--limit', '5001'], 'limit above the cap'),
      (['list', _channel, '--out', 'x'], 'list takes no --out'),
      (['list', _channel, '--all'], 'list takes no --all'),
      (['list'], 'list needs a url'),
      (['sync'], 'sync needs --subscriptions'),
      (['sync', '--subscriptions', 's.json', '--format-id', 'x'], 'sync takes no --format-id'),
      (['sync', '--subscriptions', 's.json', '--all'], 'sync takes no --all'),
      (['sync', '--subscriptions', 's.json', _channel], 'sync takes no url'),
    ]) {
      test(why, () async {
        final run = await runCli(args, lister: _lister());
        expect(run.exitCode, 2);
        expect(run.last['event'], 'error');
      });
    }
  });

  group('list', () {
    test('result shape: kind list, extractor, items with id/url/title/published', () async {
      final run = await runCli(['list', "$_channel/videos", '--limit', '4'], lister: _lister());
      expect(run.exitCode, 0);
      final r = run.last;
      expect(r['event'], 'result');
      expect(r['kind'], 'list');
      expect(r['extractor'], 'youtube');
      expect(r['source'], 'channel');
      expect(r['id'], channelUc);
      expect(r['count'], 4);
      expect(r['truncated'], isTrue);
      final items = (r['items'] as List).cast<Map>();
      expect(items.first.keys.toSet(), {'id', 'url', 'title', 'published'});
      expect(items.first['id'], _ids.first);
      expect(items.first['url'], 'https://www.youtube.com/watch?v=${_ids.first}');
      expect(items.first['published'], isNull);
    });

    test('a single video URL is not listable (3), a bad URL is a usage error (2)', () async {
      var run = await runCli(['list', 'https://www.youtube.com/watch?v=dD33lDxL9K0'], lister: _lister());
      expect((run.exitCode, run.last['code']), (3, 'UNSUPPORTED_URL'));
      run = await runCli(['list', 'not a url'], lister: _lister());
      expect((run.exitCode, run.last['code']), (2, 'INVALID_URL'));
    });

    test('a page that is not the expected shape fails closed with PARSE_ERROR (3)', () async {
      final run = await runCli(['list', _channel], lister: _lister(pages: {channelPath: '<html>consent</html>'}));
      expect((run.exitCode, run.last['code']), (3, 'PARSE_ERROR'));
    });

    test('a page cut off by the network surfaces as the network class', () async {
      final lister = YoutubeLister(
        transportFactory: () => throw const SocketException('down'),
        pause: (_) async {},
      );
      final run = await runCli(['list', _channel], lister: lister);
      expect((run.exitCode, run.last['code']), (6, 'NETWORK'));
    });
  });

  group('download --all', () {
    test('one result per item then a batch summary; archive records ids; rerun skips them', () async {
      final registry = FakeRegistry.ok();
      final args = ['download', _channel, '--all', '--limit', '3', '--archive', archive, '--out', out];
      final pauses = <Duration>[];
      var run = await runCli(args, registry: registry, lister: _lister(), pauses: pauses);
      expect(run.exitCode, 0);
      final results = run.ofEvent('result');
      expect(results.take(3).map((e) => (e['kind'], e['id'], e['index'])), [
        for (final (i, id) in _ids.indexed) ('download', id, i + 1),
      ]);
      expect(results.last, containsPair('kind', 'batch'));
      expect(results.last, containsPair('downloaded', 3));
      expect(results.last, containsPair('skipped', 0));
      expect(results.last, containsPair('failed', 0));
      expect(results.last, containsPair('stopped', null));
      expect(run.events.last, results.last, reason: 'the batch summary is the last line');
      expect(archived(), _ids);
      expect(registry.resolved.map((u) => u.toString()), [for (final id in _ids) 'https://www.youtube.com/watch?v=$id']);
      expect(pauses, [const Duration(seconds: 2), const Duration(seconds: 2)], reason: 'a pause between items, none before the first');

      registry.resolved.clear();
      run = await runCli(args, registry: registry, lister: _lister());
      expect(run.exitCode, 0);
      expect(registry.resolved, isEmpty, reason: 'nothing is downloaded twice');
      expect(run.last, containsPair('downloaded', 0));
      expect(run.last, containsPair('skipped', 3));
      expect(run.ofEvent('result').where((e) => e['kind'] == 'skipped').length, 3);
    });

    test('without --archive nothing is recorded or skipped', () async {
      final registry = FakeRegistry.ok();
      final args = ['download', _channel, '--all', '--limit', '2', '--out', out];
      await runCli(args, registry: registry, lister: _lister());
      await runCli(args, registry: registry, lister: _lister());
      expect(registry.resolved.length, 4);
    });

    test('continuations are followed and the default cap is reported', () async {
      final run = await runCli(
        ['download', _channel, '--all', '--out', out],
        lister: _lister(browse: [lastPage(['AAAAAAAAAAA'])]),
      );
      expect(run.exitCode, 0);
      expect(run.last, containsPair('total', 7));
      expect(run.last, containsPair('truncated', false));
    });

    test('exit code is the most severe item class; failures do not stop the others', () async {
      final registry = FakeRegistry((url) async {
        final id = url.queryParameters['v'];
        if (id == _ids[0]) throw const MediaExtractionException('NO_MEDIA_FOUND', 'gone');
        if (id == _ids[1]) throw const MediaExtractionException('NETWORK', 'down');
        return sampleInfo();
      });
      final run = await runCli(['download', _channel, '--all', '--limit', '3', '--out', out], registry: registry, lister: _lister());
      expect(run.exitCode, 6, reason: 'environment (6) outranks extraction (3)');
      expect(run.ofEvent('error').map((e) => (e['code'], e['id'])), [('NO_MEDIA_FOUND', _ids[0]), ('NETWORK', _ids[1])]);
      expect(run.last, containsPair('downloaded', 1));
      expect(run.last, containsPair('failed', 2));
    });

    test('policy refusals: exit stays 5, three in a row stop the batch', () async {
      final registry = FakeRegistry((_) async => throw const MediaExtractionException('LOGIN_REQUIRED', 'members only'));
      final run = await runCli(['download', _channel, '--all', '--limit', '6', '--out', out], registry: registry, lister: _lister());
      expect(run.exitCode, 5);
      expect(registry.resolved.length, 3);
      expect(run.last, containsPair('stopped', 'policy'));
      expect(run.last, containsPair('total', 6));
      expect(run.last, containsPair('failed', 3));
    });

    test('a refusal between successes does not stop the batch', () async {
      final registry = FakeRegistry((url) async {
        if (url.queryParameters['v'] == _ids[1]) throw const MediaExtractionException('PRIVATE', 'private');
        return sampleInfo();
      });
      final run = await runCli(['download', _channel, '--all', '--limit', '3', '--out', out], registry: registry, lister: _lister());
      expect(run.exitCode, 5);
      expect(registry.resolved.length, 3);
      expect(run.last, containsPair('stopped', null));
    });

    test('rate limits back off with growing pauses, then stop (exit 7)', () async {
      final registry = FakeRegistry((_) async => throw const MediaExtractionException('RATE_LIMITED', 'slow down'));
      final pauses = <Duration>[];
      final run = await runCli(['download', _channel, '--all', '--limit', '6', '--out', out],
          registry: registry, lister: _lister(), pauses: pauses);
      expect(run.exitCode, 7);
      expect(registry.resolved.length, 3);
      expect(run.last, containsPair('stopped', 'rate_limited'));
      expect(pauses.where((d) => d >= const Duration(seconds: 30)), [const Duration(seconds: 30), const Duration(seconds: 60)]);
    });

    test('a bad --out stops at the first item instead of failing all of them', () async {
      File(out).createSync(recursive: true);
      final registry = FakeRegistry.ok();
      final run = await runCli(['download', _channel, '--all', '--limit', '3', '--out', out], registry: registry, lister: _lister());
      expect(run.exitCode, 2);
      expect(run.last, containsPair('stopped', 'usage'));
      expect(run.ofEvent('error').length, 1);
    });

    test('an unreadable archive is an environment error before anything is listed', () async {
      Directory(archive).createSync();
      final run = await runCli(['download', _channel, '--all', '--archive', archive, '--out', out], lister: _lister());
      expect((run.exitCode, run.last['code']), (6, 'ARCHIVE_UNAVAILABLE'));
    });
  });

  group('sync', () {
    late File subsFile;
    setUp(() => subsFile = File('${dir.path}${Platform.pathSeparator}subs.json'));

    Future<void> subscribe(DateTime created, {String? outputDir, String source = channelUc}) => SubscriptionStore(subsFile).save([
          Subscription(source: source, title: 'YouTube', createdAt: created, outputDir: outputDir),
        ]);

    YoutubeLister feedLister([String? feed]) =>
        _lister(pages: {'/feeds/videos.xml': feed ?? fixtureText('channel_feed.xml'), channelPath: pageHtml(fixtureJson('channel_initial.json'))});

    List<String> args(String subs) => ['sync', '--subscriptions', subs, '--out', out];

    test('first run after subscribing queues nothing; last_checked and channel id are written back', () async {
      await subscribe(DateTime.now().toUtc());
      final registry = FakeRegistry.ok();
      final run = await runCli(args(subsFile.path), registry: registry, lister: feedLister());
      expect(run.exitCode, 0);
      expect(registry.resolved, isEmpty);
      expect(run.last, containsPair('kind', 'batch'));
      expect(run.last, containsPair('source', 'sync'));
      expect(run.last, containsPair('total', 0));
      expect(run.last, containsPair('channels', 1));
      final saved = (await SubscriptionStore(subsFile).load()).single;
      expect(saved.lastChecked, isNotNull);
      expect(saved.channelId, channelUc);
    });

    test('a new upload is downloaded into the subscription folder, archived, and not repeated', () async {
      final own = '${dir.path}${Platform.pathSeparator}own';
      await subscribe(DateTime.utc(2026, 11, 21, 12), outputDir: own);
      final registry = FakeRegistry.ok();
      final pipeline = FakePipeline();
      var run = await runCli(args(subsFile.path), registry: registry, pipeline: pipeline, lister: feedLister());
      expect(run.exitCode, 0);
      expect(registry.resolved.single.queryParameters['v'], 'QwhynRkyiYQ');
      expect(pipeline.calls.single.outputDir, endsWith('own'));
      expect(run.last, containsPair('downloaded', 1));
      expect(File('${subsFile.path}.archive').readAsStringSync().trim(), 'QwhynRkyiYQ');

      registry.resolved.clear();
      run = await runCli(args(subsFile.path), registry: registry, pipeline: pipeline, lister: feedLister());
      expect(registry.resolved, isEmpty);
      expect(run.last, containsPair('total', 0));
    });

    test('--archive overrides the default archive file', () async {
      await subscribe(DateTime.utc(2026, 11, 21, 12));
      await runCli([...args(subsFile.path), '--archive', archive], registry: FakeRegistry.ok(), lister: feedLister());
      expect(archived(), ['QwhynRkyiYQ']);
    });

    test('a channel whose feed cannot be read is reported, others still run, exit is its class', () async {
      await SubscriptionStore(subsFile).save([
        Subscription(source: channelUc, title: 'A', createdAt: DateTime.utc(2026, 11, 21, 12)),
        Subscription(source: 'https://www.youtube.com/watch?v=dD33lDxL9K0', title: 'B', createdAt: DateTime.utc(2026, 1, 1)),
      ]);
      final registry = FakeRegistry.ok();
      final run = await runCli(args(subsFile.path), registry: registry, lister: feedLister());
      expect(run.exitCode, 3);
      expect(run.ofEvent('error').single, containsPair('code', 'UNSUPPORTED_URL'));
      expect(registry.resolved.length, 1);
      expect(run.last, containsPair('channels_failed', 1));
      final saved = await SubscriptionStore(subsFile).load();
      expect(saved[0].lastChecked, isNotNull);
      expect(saved[1].lastChecked, isNull, reason: 'a failed check is not recorded as checked');
    });

    test('missing or malformed subscriptions file is a usage error (2)', () async {
      var run = await runCli(args(subsFile.path), lister: feedLister());
      expect((run.exitCode, run.last['code']), (2, 'INVALID_VALUE'));
      subsFile.writeAsStringSync('{"subscriptions": 5}');
      run = await runCli(args(subsFile.path), lister: feedLister());
      expect((run.exitCode, run.last['code']), (2, 'INVALID_VALUE'));
      expect(subsFile.readAsStringSync(), '{"subscriptions": 5}', reason: 'a broken file is never overwritten');
    });

    test('an unsupported version is reported before any network use and the file is untouched', () async {
      const text = '{"version": 2, "subscriptions": [], "future": {"keep": true}}';
      subsFile.writeAsStringSync(text);
      var touched = false;
      final lister = YoutubeLister(transportFactory: () {
        touched = true;
        throw StateError('network');
      });
      final run = await runCli(args(subsFile.path), lister: lister);
      expect((run.exitCode, run.last['code']), (2, 'INVALID_VALUE'));
      expect(run.last['message'], contains('version 2'));
      expect(touched, isFalse);
      expect(subsFile.readAsStringSync(), text);
    });

    test('--archive aliasing the subscriptions file (or its lock or temp file) is refused before anything runs', () async {
      await subscribe(DateTime.utc(2026, 11, 21, 12));
      final before = subsFile.readAsBytesSync();
      var touched = false;
      final lister = YoutubeLister(transportFactory: () {
        touched = true;
        throw StateError('network');
      });
      final sep = Platform.pathSeparator;
      for (final alias in [
        subsFile.path,
        '${dir.path}${sep}sub$sep..${sep}subs.json',
        '${subsFile.path}.tmp',
        '${subsFile.path}.lock',
        '${subsFile.path}.77.123.0.tmp',
      ]) {
        final run = await runCli([...args(subsFile.path), '--archive', alias], lister: lister, registry: FakeRegistry.ok());
        expect((run.exitCode, run.last['code']), (2, 'INVALID_VALUE'), reason: alias);
        expect(run.last['message'], contains('different files'), reason: alias);
      }
      expect(touched, isFalse);
      expect(subsFile.readAsBytesSync(), before);
    });

    Future<void> subscribeMany(int n) => SubscriptionStore(subsFile).save([
          for (var i = 0; i < n; i++)
            Subscription(
              source: [channelUc, 'https://www.youtube.com/channel/$channelUc', 'https://www.youtube.com/channel/$channelUc/videos', 'http://youtube.com/channel/$channelUc'][i],
              title: 'c$i',
              createdAt: DateTime.utc(2026, 11, 21, 12),
            ),
        ]);

    test('a refusal in each of three channels in a row stops the whole sync', () async {
      await subscribeMany(4);
      final registry = FakeRegistry((_) async => throw const MediaExtractionException('LOGIN_REQUIRED', 'members only'));
      final run = await runCli(args(subsFile.path), registry: registry, lister: feedLister());
      expect(run.exitCode, 5);
      expect(registry.resolved.length, 3, reason: 'one attempt per channel, then the run stops');
      expect(run.last, containsPair('stopped', 'policy'));
      expect(run.ofEvent('status').where((e) => '${e['message']}'.startsWith('Checking')).length, 3, reason: 'the 4th channel is not even checked');
    });

    test('repeated RSS 429s back off with growing pauses and stop the run', () async {
      await subscribeMany(4);
      final before = subsFile.readAsBytesSync();
      final pauses = <Duration>[];
      final lister = YoutubeLister(
        transportFactory: () => FailingFeed(const MediaExtractionException('RATE_LIMITED', 'slow')),
        pause: (_) async {},
      );
      final run = await runCli(args(subsFile.path), lister: lister, pauses: pauses);
      expect(run.exitCode, 7);
      expect(run.last, containsPair('stopped', 'rate_limited'));
      expect(run.last, containsPair('channels_failed', 3));
      expect(pauses, [const Duration(seconds: 30), const Duration(seconds: 60)]);
      expect(subsFile.readAsBytesSync(), before, reason: 'a failed check never advances last_checked');
    });

    test('a truncated feed fails that channel, keeps its last_checked, and the others still run', () async {
      final full = fixtureText('channel_feed.xml');
      await SubscriptionStore(subsFile).save([
        Subscription(source: channelUc, title: 'A', createdAt: DateTime.utc(2026, 11, 21, 12), lastChecked: DateTime.utc(2026, 11, 22)),
      ]);
      final cut = full.substring(0, full.indexOf('</entry>') + 8);
      final run = await runCli(args(subsFile.path), registry: FakeRegistry.ok(), lister: feedLister(cut));
      expect((run.exitCode, run.ofEvent('error').single['code']), (3, 'PARSE_ERROR'));
      expect(run.last, containsPair('downloaded', 0));
      expect((await SubscriptionStore(subsFile).load()).single.lastChecked, DateTime.utc(2026, 11, 22));
    });

    test('a subscription added by another writer during the run is kept, and our check results are merged in', () async {
      await subscribe(DateTime.utc(2026, 11, 21, 12));
      final registry = FakeRegistry((_) async {
        await SubscriptionStore(subsFile).update((c) => [
              ...c,
              Subscription(source: 'https://www.youtube.com/@Other', title: 'Added meanwhile', createdAt: DateTime.utc(2026, 11, 22)),
            ]);
        return sampleInfo();
      });
      final run = await runCli(args(subsFile.path), registry: registry, lister: feedLister());
      expect(run.exitCode, 0);
      final saved = await SubscriptionStore(subsFile).load();
      expect(saved.map((s) => s.title), ['YouTube', 'Added meanwhile']);
      expect(saved.first.lastChecked, isNotNull);
      expect(saved.first.channelId, channelUc);
    });
  });
}
