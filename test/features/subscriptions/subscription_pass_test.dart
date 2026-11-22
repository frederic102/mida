import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/subscriptions/run_lock.dart';
import 'package:mida/core/subscriptions/subscription.dart';
import 'package:mida/features/download/services/download_service.dart';

import 'subscription_test_support.dart';

/// The run lock's lifecycle: one owner (SubscriptionPass), held until every
/// admitted download and its archive write has ended, on every path.
void main() {
  late SchedulerHarness h;

  setUp(() => h = SchedulerHarness());
  tearDown(() => h.dispose());

  Future<void> pendingDownloads(int n) => waitUntil(() => h.downloads.pending.length == n, what: '$n downloads');

  group('the lock outlives every admitted download', () {
    test('an archive read failing at the second channel does not release it while the first download runs', () async {
      await SubscriptionStore(h.paths.subscriptions).save([h.sub(), h.sub(source: 'https://www.youtube.com/@other', channelId: otherChannelUc)]);
      h.lister.latest = [item(1, published: h.fresh)];
      // After the first channel was read, the archive becomes unreadable (a folder in its place).
      h.lister.onLatest = (id) {
        if (id == channelUc) Directory(h.paths.archive.path).createSync();
      };

      final run = h.scheduler.runCheck();
      await pendingDownloads(1);
      await waitUntil(() => h.scheduler.isDraining, what: 'the drain');

      expect(h.scheduler.status, contains('archive could not be read'));
      expect(await h.lockIsHeld(), isTrue);

      h.downloads.last.succeed('a.mp4');
      await run;
      expect(await h.lockIsHeld(), isFalse);
      expect(h.scheduler.status, contains('next check')); // the id could not be written, it is kept
      Directory(h.paths.archive.path).deleteSync();
    });

    test('an error of a type nobody expected, after downloads were queued, does not release it either', () async {
      await h.seed();
      h.lister.latest = [item(1, published: h.fresh)];
      h.lister.onLatest = (_) => h.list.failNextLoad = true; // the reload after the merge throws a StateError

      final run = h.scheduler.runCheck();
      await pendingDownloads(1);
      await waitUntil(() => h.scheduler.isDraining, what: 'the drain');

      expect(h.scheduler.status, contains('unexpected error'));
      expect(await h.lockIsHeld(), isTrue);

      h.downloads.last.succeed('a.mp4');
      await run;
      expect(h.archiveText(), contains(vid(1)));
      expect(await h.lockIsHeld(), isFalse);
    });

    test('dispose while a channel is being read admits nothing, and the lock lasts until that read ends', () async {
      await h.seed();
      h.lister.latest = [item(1, published: h.fresh)];
      h.lister.gate = Completer<void>();
      final run = h.scheduler.runCheck();
      await waitUntil(() => h.lister.latestCalls == 1);

      h.scheduler.dispose();
      expect(await h.lockIsHeld(), isTrue);

      h.lister.gate!.complete();
      await run;
      expect(h.queue.items, isEmpty);
      expect(h.downloads.pending, isEmpty);
      expect(h.archiveText(), isEmpty);
      expect(await h.lockIsHeld(), isFalse);
    });

    test('dispose while downloading drops waiting items, keeps the lock until the active one is archived', () async {
      await h.seed();
      h.lister.latest = [item(1, published: h.fresh), item(2, published: h.fresh)];
      final run = h.scheduler.runCheck();
      await waitUntil(() => h.queue.items.length == 2 && h.downloads.pending.length == 1);

      h.scheduler.dispose();
      expect(h.queue.items.map((i) => i.url), [watchUrl(1)]); // the waiting one is gone
      var acquired = false;
      final competing = RunLock.acquire(h.paths.archive, wait: const Duration(seconds: 5)).then((l) {
        acquired = true;
        return l;
      });
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(acquired, isFalse);

      h.downloads.last.succeed('a.mp4');
      await run;
      expect(h.archiveText(), contains(vid(1)));
      expect(h.archiveText(), isNot(contains(vid(2))));
      await (await competing).release();
      expect(acquired, isTrue);
    });
  });

  group('a failing release never wedges the scheduler', () {
    test('runCheck still returns, resets, and the next pass works', () async {
      var first = true;
      final harness = SchedulerHarness(acquireLock: (file, wait) async {
        final real = await RunLock.acquire(file, wait: wait);
        if (!first) return real;
        first = false;
        return ReleaseFailsLock(real);
      });
      addTearDown(harness.dispose);
      await harness.seed();

      await harness.scheduler.runCheck(); // must not throw

      expect(harness.scheduler.isRunning, isFalse);
      expect(harness.scheduler.isDraining, isFalse);
      await harness.scheduler.runCheck();
      expect(harness.lister.latestCalls, 2);
    });
  });

  group('every archive write happens under the lock', () {
    test('a retry that succeeds after the pass ended, while mida-cli holds the lock, is not written then', () async {
      await h.seed();
      h.lister.latest = [item(1, published: h.fresh)];
      var run = h.scheduler.runCheck();
      await pendingDownloads(1);
      h.downloads.last.fail('Could not fetch this video (status: NETWORK).');
      await run; // the pass is over, the lock is given back

      final cli = await RunLock.acquire(h.paths.archive);
      h.queue.retry(h.queue.items.single.id);
      await pendingDownloads(2);
      h.downloads.last.succeed('a.mp4');
      await waitUntil(() => h.scheduler.status?.contains('next check') ?? false, what: 'the write to be deferred');

      expect(h.archiveText(), isNot(contains(vid(1)))); // not written outside the lock
      await cli.release();

      run = h.scheduler.runCheck(); // the next pass writes it first, so nothing is downloaded twice
      await run;
      expect(h.archiveText(), contains(vid(1)));
      expect(h.downloads.pending, hasLength(2));
    });

    test('a retry that succeeds with the lock free is written, under a lock taken for it', () async {
      await h.seed();
      h.lister.latest = [item(1, published: h.fresh)];
      final run = h.scheduler.runCheck();
      await pendingDownloads(1);
      h.downloads.last.fail('Could not fetch this video (status: NETWORK).');
      await run;

      h.queue.retry(h.queue.items.single.id);
      await pendingDownloads(2);
      h.downloads.last.succeed('a.mp4');

      await waitUntil(() => h.archiveText().contains(vid(1)), what: 'the late archive write');
      expect(await h.lockIsHeld(), isFalse);
    });
  });

  group('only a job with the subscription intent stands for it', () {
    test('a pending audio job for the same video is not adopted, never archives the id, and the video is still downloaded', () async {
      await h.seed();
      h.lister.latest = [item(1, published: h.fresh)];
      h.queue.enqueueAll([watchUrl(1)], type: DownloadType.audio, options: const DownloadOptions());
      await pendingDownloads(1);

      await h.scheduler.runCheck().timeout(const Duration(seconds: 2)); // nothing adopted, nothing to wait for
      expect(h.queue.items, hasLength(1));

      h.downloads.last.succeed('a.mp3'); // the audio job saves
      await waitUntil(() => !h.queue.isBusy, what: 'the audio job to end');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(h.archiveText(), isNot(contains(vid(1))));

      final run = h.scheduler.runCheck(); // the next pass queues the real download
      await pendingDownloads(2);
      expect(h.queue.items.last.type, DownloadType.video);
      h.downloads.last.succeed('a.mp4');
      await run;
      expect(h.archiveText(), contains(vid(1)));
    });
  });

  group('a saved video is never queued again, whoever wins the lock', () {
    test('the next check wins the lock before the deferred write: no duplicate, and the id is archived', () async {
      final barrier = Completer<void>();
      var calls = 0;
      var lateWaiting = false;
      final harness = SchedulerHarness(acquireLock: (file, wait) async {
        calls++;
        if (calls == 2) {
          // The retry's own write: held back until the test lets it go.
          lateWaiting = true;
          await barrier.future;
        }
        return RunLock.acquire(file, wait: wait);
      });
      addTearDown(harness.dispose);
      await harness.seed();
      harness.lister.latest = [item(1, published: harness.fresh)];

      final first = harness.scheduler.runCheck();
      await waitUntil(() => harness.downloads.pending.length == 1);
      harness.downloads.last.fail('Could not fetch this video (status: NETWORK).');
      await first;
      harness.queue.retry(harness.queue.items.single.id);
      await waitUntil(() => harness.downloads.pending.length == 2);
      harness.downloads.last.succeed('a.mp4');
      await waitUntil(() => lateWaiting, what: 'the retry write to wait for the lock');

      await harness.scheduler.runCheck(); // wins the lock first
      expect(harness.downloads.pending, hasLength(2)); // no duplicate download
      expect(harness.archiveText(), contains(vid(1)));

      barrier.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(harness.downloads.pending, hasLength(2));
      expect(harness.archiveText().split('\n').where((l) => l == vid(1)), hasLength(1));
    });
  });

  group('ownership is by queue item', () {
    test('two rows yielding the same video keep one obligation until that download ends', () async {
      await SubscriptionStore(h.paths.subscriptions).save([
        h.sub(),
        h.sub(source: 'https://www.youtube.com/channel/$channelUc'),
      ]);
      h.lister.latest = [item(1, published: h.fresh)];

      final run = h.scheduler.runCheck();
      await pendingDownloads(1);
      await waitUntil(() => h.scheduler.isDraining, what: 'the drain');

      expect(h.queue.items, hasLength(1));
      expect(await h.lockIsHeld(), isTrue);
      h.downloads.last.succeed('a.mp4');
      await run;
      expect(h.archiveText(), contains(vid(1)));
      expect(await h.lockIsHeld(), isFalse);
    });

    test('a video already waiting in the queue (added by hand) is taken over, not queued twice, and archived', () async {
      await h.seed();
      h.lister.latest = [item(1, published: h.fresh)];
      h.queue.enqueueAll([watchUrl(1)], type: DownloadType.video, options: const DownloadOptions());
      await pendingDownloads(1);

      final run = h.scheduler.runCheck();
      await waitUntil(() => h.scheduler.isDraining, what: 'the drain');
      expect(h.queue.items, hasLength(1));
      expect(await h.lockIsHeld(), isTrue);

      h.downloads.last.succeed('a.mp4');
      await run;
      expect(h.archiveText(), contains(vid(1)));
      expect(h.downloads.pending, hasLength(1));
    });
  });

  group('the queue opens a folder window only for foreground work', () {
    Future<void> queueQuiet() async {
      await waitUntil(() => !h.queue.isBusy, what: 'the queue to stop');
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }

    test('background-only downloads open nothing', () async {
      await h.seed();
      h.lister.latest = [item(1, published: h.fresh)];
      final run = h.scheduler.runCheck();
      await pendingDownloads(1);
      h.downloads.last.succeed('a.mp4');
      await run;
      await queueQuiet();
      expect(h.folderOpens, isEmpty);
    });

    test('control: a manual download alone opens the download folder once', () async {
      h.settings.downloadSettings.downloadPath = r'C:\Out';
      h.queue.enqueueAll([watchUrl(9)], type: DownloadType.video, options: const DownloadOptions());
      await pendingDownloads(1);
      h.downloads.last.succeed('a.mp4');
      await queueQuiet();
      expect(h.folderOpens, [r'C:\Out']);
    });

    test('mixed manual and background work opens the folder once, because a manual item was saved', () async {
      h.settings.downloadSettings.downloadPath = r'C:\Out';
      await h.seed();
      h.lister.latest = [item(1, published: h.fresh)];
      h.queue.enqueueAll([watchUrl(9)], type: DownloadType.video, options: const DownloadOptions());
      final run = h.scheduler.runCheck();
      await pendingDownloads(1);
      h.downloads.last.succeed('manual.mp4');
      await pendingDownloads(2);
      h.downloads.last.succeed('background.mp4');
      await run;
      await queueQuiet();
      expect(h.folderOpens, [r'C:\Out']);
    });
  });

  group('the draining state', () {
    test('is separate from checking', () async {
      await h.seed();
      h.lister.latest = [item(1, published: h.fresh)];
      h.lister.gate = Completer<void>();
      final run = h.scheduler.runCheck();
      await waitUntil(() => h.lister.latestCalls == 1);
      expect(h.scheduler.isRunning, isTrue);
      expect(h.scheduler.isDraining, isFalse);

      h.lister.gate!.complete();
      await waitUntil(() => h.scheduler.isDraining, what: 'the drain');
      h.downloads.last.succeed('a.mp4');
      await run;
      expect(h.scheduler.isRunning, isFalse);
      expect(h.scheduler.isDraining, isFalse);
    });
  });
}
