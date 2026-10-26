import 'package:flutter_test/flutter_test.dart';
import 'package:mida/features/settings/settings_service.dart';
import 'package:mida/core/utils/file_utils.dart';
import 'package:mida/core/utils/url_parser.dart';
import 'package:mida/features/download/services/download_queue_service.dart';
import 'package:mida/features/download/services/download_service.dart';

import 'fake_download_service.dart';

const _a = 'https://a.example/v/1';
const _b = 'https://b.example/v/2';
const _c = 'https://c.example/v/3';

void main() {
  late SettingsService settings;
  late FakeDownloadService downloads;
  late DownloadQueueService queue;
  late List<String> opened;

  setUp(() {
    settings = SettingsService();
    settings.downloadSettings.downloadPath = r'C:\Users\me\Videos\MiDa';
    downloads = FakeDownloadService(settings);
    queue = DownloadQueueService(downloads: downloads, settings: settings);
    opened = [];
    FileUtils.folderOpenerOverride = (path) async => opened.add(path);
  });

  tearDown(() {
    FileUtils.folderOpenerOverride = null;
    queue.dispose();
  });

  int enqueue(List<String> urls, {DownloadType type = DownloadType.video}) =>
      queue.enqueueAll(urls, type: type, options: const DownloadOptions());

  List<QueueItemState> states() => [for (final i in queue.items) i.state];

  test('runs items strictly one at a time, in the order they were added', () async {
    expect(enqueue([_a, _b, _c]), 3);
    await settle();
    expect(downloads.calls, [_a]);
    expect(states(), [QueueItemState.fetching, QueueItemState.queued, QueueItemState.queued]);

    downloads.last.succeed(r'C:\out\a.mp4');
    await settle();
    expect(downloads.calls, [_a, _b]);
    downloads.last.fail('boom');
    await settle();
    expect(downloads.calls, [_a, _b, _c]);
    downloads.last.succeed(r'C:\out\c.mp4');
    await settle();

    expect(downloads.maxActive, 1);
    expect(states(), [QueueItemState.done, QueueItemState.failed, QueueItemState.done]);
    expect(queue.isBusy, isFalse);
  });

  test('mirrors title and progress only from the new task, then records the output path', () async {
    // A finished task from an earlier download is still in currentTask.
    downloads.currentTask = DownloadTask(
      url: _c,
      title: 'Old',
      type: DownloadType.video,
      platform: PlatformType.unknown,
      status: DownloadStatus.downloading,
      progress: 0.9,
    );
    enqueue([_a]);
    await settle();
    downloads.ping(); // stale notification while the page is still being read
    final item = queue.items.single;
    expect(item.state, QueueItemState.fetching);
    expect(item.progress, 0);
    expect(item.title, isNull);

    downloads.last.startDownloading(title: 'Clip A', progress: 0.25, message: 'Downloading video');
    expect(item.state, QueueItemState.downloading);
    expect(item.progress, 0.25);
    expect(item.title, 'Clip A');
    expect(item.statusMessage, 'Downloading video');

    downloads.last.progress(0.5);
    expect(item.progress, 0.5);

    downloads.last.succeed(r'C:\out\Clip A.mp4');
    await settle();
    expect(item.state, QueueItemState.done);
    expect(item.outputPath, r'C:\out\Clip A.mp4');
    expect(item.progress, 1);
  });

  test('failure text is stored with URL query strings redacted', () async {
    enqueue([_a]);
    await settle();
    downloads.last.fail('Could not fetch https://cdn.example/x.m3u8?sig=SECRET (status: NETWORK).');
    await settle();
    final item = queue.items.single;
    expect(item.state, QueueItemState.failed);
    expect(item.error, contains('https://cdn.example'));
    expect(item.error, isNot(contains('SECRET')));
  });

  test('a thrown error and a rejected (busy) call both fail the item, and the queue moves on', () async {
    enqueue([_a, _b]);
    await settle();
    downloads.last.throwError(StateError('exploded'));
    await settle();
    expect(queue.items.first.state, QueueItemState.failed);
    expect(queue.items.first.error, contains('exploded'));
    downloads.last.succeed('b.mp4');
    await settle();

    downloads.rejectNext = true;
    enqueue([_c]);
    await settle();
    expect(queue.items.last.state, QueueItemState.failed);
    expect(queue.items.last.error, DownloadQueueService.busyMessage);
  });

  test('remove works on waiting and finished items but not on the running one', () async {
    enqueue([_a, _b]);
    await settle();
    final running = queue.items[0].id;
    final waiting = queue.items[1].id;
    queue.remove(running);
    queue.remove(waiting);
    expect([for (final i in queue.items) i.url], [_a]);

    downloads.last.succeed('a.mp4');
    await settle();
    queue.remove(running);
    expect(queue.items, isEmpty);
    expect(downloads.calls, [_a]);
  });

  test('retry re-runs a failed item; clear finished keeps waiting and running items', () async {
    enqueue([_a, _b, _c]);
    await settle();
    downloads.last.fail('first failure');
    await settle(); // b is now running
    final failedId = queue.items[0].id;
    queue.retry(failedId);
    expect(queue.items[0].state, QueueItemState.queued);
    expect(queue.items[0].error, isNull);

    queue.retry(queue.items[1].id); // running: not failed, ignored
    expect(queue.items[1].state, QueueItemState.fetching);

    downloads.last.succeed('b.mp4');
    await settle();
    // a was retried and sits before c, so it runs next.
    expect(downloads.calls, [_a, _b, _a]);

    queue.clearFinished();
    expect([for (final i in queue.items) i.url], [_a, _c]);
    expect(states(), [QueueItemState.fetching, QueueItemState.queued]);
  });

  test('a link already waiting is not added twice, a finished one can be added again', () async {
    expect(enqueue([_a, _a, _b]), 2);
    expect(enqueue([_b]), 0);
    await settle();
    downloads.last.succeed('a.mp4');
    await settle();
    expect(enqueue([_a]), 1);
    expect(queue.knownUrls, {_a, _b});
  });

  test('copy CLI command reproduces type, options, login session and folder', () async {
    queue.enqueueAll([_a], type: DownloadType.video, options: const DownloadOptions());
    queue.enqueueAll(
      [_b],
      type: DownloadType.audio,
      options: const DownloadOptions(audioFormat: AudioFormat.flac, audioQuality: AudioQuality.high),
    );
    queue.enqueueAll(
      [_c],
      type: DownloadType.video,
      options: const DownloadOptions(
        videoQuality: VideoQuality.p1440,
        videoFormat: VideoFormat.mkv,
        subtitleOption: SubtitleOption.english,
      ),
    );
    expect(
      queue.cliCommandFor(queue.items[0]).command,
      r"mida-cli download 'https://a.example/v/1' --out 'C:\Users\me\Videos\MiDa'",
    );
    expect(
      queue.cliCommandFor(queue.items[1]).command,
      r"mida-cli download 'https://b.example/v/2' --type audio --audio-format flac --audio-quality 320 "
      r"--out 'C:\Users\me\Videos\MiDa'",
    );
    await settings.setUseBrowserLoginSession(true);
    expect(
      queue.cliCommandFor(queue.items[2]).command,
      r"mida-cli download 'https://c.example/v/3' --quality 1440 --container mkv --subtitles en --login-session "
      r"--out 'C:\Users\me\Videos\MiDa'",
    );
    await settings.setDownloadPath(r"C:\Bob's clips");
    final refused = queue.cliCommandFor(queue.items[0]);
    expect(refused.command, isNull, reason: 'the folder is never silently dropped');
    expect(refused.refusal, contains('single quote'));
  });

  group('open folder after download', () {
    test('on (default): opens once when the queue drains, not once per item', () async {
      expect(settings.openFolderAfterDownload, isTrue);
      enqueue([_a, _b, _c]);
      await settle();
      downloads.last.succeed('a.mp4');
      await settle();
      downloads.last.fail('nope');
      await settle();
      expect(opened, isEmpty, reason: 'nothing opens while items are still waiting');
      downloads.last.succeed('c.mp4');
      await settle();
      expect(opened, [settings.downloadPath]);
      expect([for (final p in downloads.pending) p.openFolderOnSuccess], [false, false, false]);
    });

    test('on, but nothing was saved: the folder stays closed', () async {
      enqueue([_a]);
      await settle();
      downloads.last.fail('nope');
      await settle();
      expect(opened, isEmpty);
    });

    test('off: no open at all, other paths still open, and the global opener is never replaced', () async {
      final testOverride = FileUtils.folderOpenerOverride;
      await settings.setOpenFolderAfterDownload(false);
      enqueue([_a]);
      await settle();
      expect(identical(FileUtils.folderOpenerOverride, testOverride), isTrue);
      await FileUtils.openFileLocation(r'C:\out\earlier.mp4'); // "Show in folder" mid-download
      downloads.last.succeed('a.mp4');
      await settle();
      expect(opened, [r'C:\out\earlier.mp4']);
      expect(identical(FileUtils.folderOpenerOverride, testOverride), isTrue);
    });

    test('two queues overlapping (A start, B start, A end, B end) leave the original opener in place', () async {
      final testOverride = FileUtils.folderOpenerOverride;
      final otherDownloads = FakeDownloadService(settings);
      final other = DownloadQueueService(downloads: otherDownloads, settings: settings);
      addTearDown(other.dispose);
      await settings.setOpenFolderAfterDownload(false);
      enqueue([_a]);
      other.enqueueAll([_b], type: DownloadType.video, options: const DownloadOptions());
      await settle();
      downloads.last.succeed('a.mp4');
      await settle();
      otherDownloads.last.throwError(StateError('body threw'));
      await settle();
      expect(identical(FileUtils.folderOpenerOverride, testOverride), isTrue);
      await settings.setOpenFolderAfterDownload(true);
      await FileUtils.openFolder(r'C:\after');
      expect(opened, [r'C:\after']);
    });
  });

  test('attributes by URL: another caller\'s task is never mirrored, the returned task decides', () async {
    enqueue([_a]);
    await settle();
    // Someone else's download replaces currentTask while ours is fetching.
    downloads.currentTask = DownloadTask(
      url: _c,
      title: 'Not ours',
      type: DownloadType.video,
      platform: PlatformType.unknown,
      status: DownloadStatus.downloading,
      progress: 0.7,
    );
    downloads.ping();
    final item = queue.items.single;
    expect(item.title, isNull);
    expect(item.state, QueueItemState.fetching);

    downloads.last.startDownloading(title: 'Ours');
    // And it moves on again before ours returns.
    downloads.currentTask = DownloadTask(
      url: _c,
      title: 'Not ours',
      type: DownloadType.video,
      platform: PlatformType.unknown,
      status: DownloadStatus.completed,
    );
    downloads.last.fail('ours failed');
    await settle();
    expect(item.state, QueueItemState.failed);
    expect(item.error, 'ours failed');
    expect(item.title, 'Ours');
  });
}
