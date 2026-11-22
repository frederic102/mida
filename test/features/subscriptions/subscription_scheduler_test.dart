import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/subscriptions/run_lock.dart';
import 'package:mida/core/subscriptions/subscription.dart';

import '../download/queue/fake_download_service.dart';
import 'subscription_test_support.dart';

void main() {
  late SchedulerHarness h;

  setUp(() => h = SchedulerHarness());
  tearDown(() => h.dispose());

  Future<void> idle() => waitUntil(() => !h.scheduler.isRunning, what: 'the check to end');

  test('the archive sits next to the subscriptions file under the name mida-cli sync defaults to', () {
    expect(h.paths.archive.path, '${h.paths.subscriptions.path}.archive');
  });

  group('what is queued', () {
    test('only uploads after the subscription date that are not archived, into the channel folder', () async {
      await h.seed(outputDir: r'C:\Chan');
      h.paths.archive.writeAsStringSync('${vid(3)}\n');
      h.lister.latest = [
        item(1, published: h.fresh), // new
        item(2, published: h.clock.subtract(const Duration(days: 2))), // before subscribing
        item(3, published: h.fresh), // already downloaded
        item(4), // no publish time: fail closed
      ];
      final run = h.scheduler.runCheck();
      await waitUntil(() => h.downloads.pending.isNotEmpty, what: 'the first download');
      await settle();
      expect(h.downloads.calls, [watchUrl(1)]);
      expect(h.downloads.last.outputDir, r'C:\Chan');
      h.downloads.last.succeed(r'C:\Chan\one.mp4');
      await run;
      expect(h.queue.items.map((i) => i.url), [watchUrl(1)]);
    });

    test('a second pass does not queue what the first one downloaded', () async {
      await h.seed();
      h.lister.latest = [item(1, published: h.fresh)];
      var run = h.scheduler.runCheck();
      await waitUntil(() => h.downloads.pending.isNotEmpty);
      h.downloads.last.succeed('a.mp4');
      await run;

      run = h.scheduler.runCheck();
      await run;
      expect(h.queue.items, hasLength(1));
      expect(h.downloads.calls, hasLength(1));
    });
  });

  group('archive after success', () {
    test('the id is written only once the file is saved, and the lock is held until then', () async {
      await h.seed();
      h.lister.latest = [item(1, published: h.fresh)];
      final run = h.scheduler.runCheck();
      await waitUntil(() => h.downloads.pending.isNotEmpty);

      expect(h.archiveText(), isNot(contains(vid(1))));
      expect(h.scheduler.isRunning, isTrue);
      expect(await h.lockIsHeld(), isTrue);

      h.downloads.last.succeed('a.mp4');
      await run;
      expect(h.archiveText(), contains(vid(1)));
      expect(await h.lockIsHeld(), isFalse);
    });

    test('a failed download is not archived, and the lock is released', () async {
      await h.seed();
      h.lister.latest = [item(1, published: h.fresh)];
      final run = h.scheduler.runCheck();
      await waitUntil(() => h.downloads.pending.isNotEmpty);
      h.downloads.last.fail('Could not fetch this video (status: NETWORK).');
      await run;

      expect(h.archiveText(), isNot(contains(vid(1))));
      expect(h.scheduler.isRunning, isFalse);
      expect(await h.lockIsHeld(), isFalse);
    });

    test('removing a waiting item from the queue lets the pass finish, and archives only the saved one', () async {
      await h.seed();
      h.lister.latest = [item(1, published: h.fresh), item(2, published: h.fresh)];
      final run = h.scheduler.runCheck();
      await waitUntil(() => h.queue.items.length == 2 && h.downloads.pending.length == 1);
      h.queue.remove(h.queue.items.last.id); // item 2 is still waiting
      h.downloads.last.succeed('a.mp4');
      await run;

      expect(h.archiveText(), contains(vid(1)));
      expect(h.archiveText(), isNot(contains(vid(2))));
    });
  });

  group('one pass at a time', () {
    test('a check started while one is running does nothing and leaves it running', () async {
      await h.seed();
      h.lister.gate = Completer<void>();
      final first = h.scheduler.runCheck();
      await waitUntil(() => h.lister.latestCalls == 1);

      await h.scheduler.runCheck(); // the second one

      expect(h.scheduler.isRunning, isTrue);
      expect(h.scheduler.status, isNull);
      expect(h.lister.latestCalls, 1);
      h.lister.gate!.complete();
      await first;
      expect(h.scheduler.isRunning, isFalse);
    });

    test('skips and says so when mida-cli holds the archive lock', () async {
      final old = h.clock.subtract(const Duration(hours: 3));
      await h.seed(lastChecked: old);
      h.lister.latest = [item(1, published: h.fresh)];
      final cli = await RunLock.acquire(h.paths.archive);

      await h.scheduler.runCheck();

      expect(h.scheduler.status, contains('mida-cli'));
      expect(h.lister.latestCalls, 0);
      expect(h.queue.items, isEmpty);
      expect((await h.stored()).single.lastChecked, old);
      expect(h.scheduler.isRunning, isFalse);

      await cli.release();
      final run = h.scheduler.runCheck();
      await waitUntil(() => h.downloads.pending.isNotEmpty);
      h.downloads.last.succeed('a.mp4');
      await run;
      expect(h.lister.latestCalls, 1);
    });
  });

  group('last_checked', () {
    test('moves to now after a check that worked', () async {
      await h.seed(lastChecked: h.clock.subtract(const Duration(hours: 3)));
      await h.scheduler.runCheck();
      expect((await h.stored()).single.lastChecked, h.clock);
      expect(h.scheduler.status, 'Checked 1 of 1 channel, no new uploads.');
    });

    test('never moves after a failed check, and the channel shows why', () async {
      final old = h.clock.subtract(const Duration(hours: 3));
      final sub = await h.seed(lastChecked: old);
      h.lister.latestError = const MediaExtractionException('NETWORK', 'No connection.');

      await h.scheduler.runCheck();

      expect((await h.stored()).single.lastChecked, old);
      expect(h.scheduler.errorFor(sub), isNotNull);
      expect(h.scheduler.status, contains('1 failed'));

      h.lister.latestError = null;
      await h.scheduler.runCheck();
      expect((await h.stored()).single.lastChecked, h.clock);
      expect(h.scheduler.errorFor(sub), isNull);
    });

    test('with two channels only the one that worked advances', () async {
      final old = h.clock.subtract(const Duration(hours: 3));
      final a = h.sub(lastChecked: old);
      final b = h.sub(source: 'https://www.youtube.com/@other', channelId: otherChannelUc, lastChecked: old);
      await SubscriptionStore(h.paths.subscriptions).save([a, b]);
      h.lister.latestErrors[otherChannelUc] = const MediaExtractionException('NETWORK');

      await h.scheduler.runCheck();

      final rows = await h.stored();
      expect(rows[0].lastChecked, h.clock);
      expect(rows[1].lastChecked, old);
    });
  });

  group('timing', () {
    test('start checks a channel whose last check is older than the interval, and arms the timer', () async {
      await h.seed(lastChecked: h.clock.subtract(const Duration(hours: 2)));
      await h.scheduler.start();
      await waitUntil(() => h.lister.latestCalls == 1, what: 'the catch-up check');
      await idle();
      expect(h.timers.created.single.duration, const Duration(minutes: 60));
    });

    test('start checks a channel that was never checked', () async {
      await h.seed();
      await h.scheduler.start();
      await waitUntil(() => h.lister.latestCalls == 1);
      await idle();
    });

    test('start leaves a recently checked channel alone and still arms the timer', () async {
      await h.seed(lastChecked: h.clock.subtract(const Duration(minutes: 10)));
      await h.scheduler.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(h.lister.latestCalls, 0);
      expect(h.timers.created.single.duration, const Duration(minutes: 60));
    });

    test('each timer tick checks every channel and arms the next one', () async {
      await h.seed(lastChecked: h.clock.subtract(const Duration(minutes: 10)));
      await h.scheduler.start();

      h.timers.last.fire();
      await waitUntil(() => h.lister.latestCalls == 1, what: 'the timed check');
      await idle();
      expect(h.timers.created, hasLength(2));
      expect(h.timers.created.first.fired, isTrue);
      expect(h.timers.last.duration, const Duration(minutes: 60));
    });

    test('a new interval applies from the next arming', () async {
      await h.scheduler.start();
      h.intervalMinutes = 30;
      h.scheduler.restartTimer();
      expect(h.timers.created.first.cancelled, isTrue);
      expect(h.timers.last.duration, const Duration(minutes: 30));
    });

    test('dispose cancels the timer', () async {
      await h.scheduler.start();
      h.scheduler.dispose();
      expect(h.timers.last.cancelled, isTrue);
    });
  });
}
