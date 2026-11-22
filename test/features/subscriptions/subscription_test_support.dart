import 'dart:async';
import 'dart:io';

import 'package:mida/core/extractors/youtube/youtube_list_models.dart';
import 'package:mida/core/extractors/youtube/youtube_list_target.dart';
import 'package:mida/core/extractors/youtube/youtube_lister.dart';
import 'package:mida/core/subscriptions/run_lock.dart';
import 'package:mida/core/subscriptions/subscription.dart';
import 'package:mida/core/utils/file_utils.dart';
import 'package:mida/features/download/services/download_queue_service.dart';
import 'package:mida/features/settings/settings_service.dart';
import 'package:mida/features/subscriptions/services/subscription_list.dart';
import 'package:mida/features/subscriptions/services/subscription_pass.dart';
import 'package:mida/features/subscriptions/services/subscription_paths.dart';
import 'package:mida/features/subscriptions/services/subscription_scheduler.dart';

import '../download/queue/fake_download_service.dart';

const channelUc = 'UCBR8-60-B28hp2BmDPdntcQ';
const otherChannelUc = 'UCaaaaaaaaaaaaaaaaaaaaaa';
const channelUrl = 'https://www.youtube.com/@YouTube';

/// A valid 11 character video id for [n].
String vid(int n) => 'vid${n.toString().padLeft(8, '0')}';

/// [a] and [b] around a right-to-left override, a zero width space and a BEL,
/// built from code points so no source file holds an invisible character.
String dirtyTitle(String a, String b) => '$a${String.fromCharCodes([0x202E, 0x200B, 0x07])}$b';

String watchUrl(int n) => 'https://www.youtube.com/watch?v=${vid(n)}';

YoutubeListItem item(int n, {DateTime? published}) =>
    YoutubeListItem(id: vid(n), title: 'Video $n', published: published);

/// No network: answers [list] and [latestUploads] from fields the test sets.
class FakeLister implements YoutubeLister {
  FakeLister({this.items = const [], this.latest = const [], this.title = 'The Channel', this.truncated = false});

  List<YoutubeListItem> items;
  List<YoutubeListItem> latest;
  String title;
  bool truncated;
  Object? listError;
  Object? latestError;

  /// Failures for single channel ids (the others still work).
  final latestErrors = <String, Object>{};

  /// When set, [latestUploads] waits for it (a check that is still running).
  Completer<void>? gate;

  /// Runs when [latestUploads] is asked for a channel, before it answers.
  void Function(String channelId)? onLatest;

  final listed = <YoutubeListTarget>[];
  var latestCalls = 0;

  @override
  Future<YoutubeListing> list(YoutubeListTarget target, {int maxItems = YoutubeLister.defaultMaxItems, int maxPages = 200}) async {
    listed.add(target);
    if (listError != null) throw listError!;
    return YoutubeListing(
      kind: target.kind,
      id: target.kind == YoutubeListKind.channel ? channelUc : target.id!,
      title: title,
      items: items,
      truncated: truncated,
    );
  }

  @override
  Future<List<YoutubeListItem>> latestUploads(String channelId) async {
    latestCalls++;
    onLatest?.call(channelId);
    await gate?.future;
    final error = latestErrors[channelId] ?? latestError;
    if (error != null) throw error;
    return latest;
  }
}

/// A timer the test fires by hand.
class FakeTimer implements Timer {
  FakeTimer(this.duration, this._callback);

  final Duration duration;
  final void Function() _callback;
  var cancelled = false;
  var fired = false;

  void fire() {
    fired = true;
    _callback();
  }

  @override
  void cancel() => cancelled = true;

  @override
  bool get isActive => !cancelled && !fired;

  @override
  int get tick => fired ? 1 : 0;
}

class FakeTimers {
  final created = <FakeTimer>[];

  Timer create(Duration after, void Function() callback) {
    final t = FakeTimer(after, callback);
    created.add(t);
    return t;
  }

  FakeTimer get last => created.last;
}

/// Polls (real time) until [condition] holds; file IO needs real event-loop turns.
Future<void> waitUntil(bool Function() condition, {String? what}) async {
  for (var i = 0; i < 500; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('Timed out waiting for ${what ?? 'a condition'}');
}

/// A list whose next [load] can be made to fail with an error nobody expects.
class FlakyList extends SubscriptionList {
  FlakyList({required super.store, required super.lister, super.now});

  var failNextLoad = false;

  @override
  Future<void> load() {
    if (failNextLoad) {
      failNextLoad = false;
      throw StateError('unexpected failure');
    }
    return super.load();
  }
}

/// A lock whose release really releases and then fails.
class ReleaseFailsLock implements RunLock {
  ReleaseFailsLock(this._real);

  final RunLock _real;

  @override
  Future<void> release() async {
    await _real.release();
    throw const FileSystemException('release failed');
  }
}

/// Everything a scheduler test needs, over a temp folder and fakes.
class SchedulerHarness {
  SchedulerHarness({LockAcquirer? acquireLock}) {
    dir = Directory.systemTemp.createTempSync('mida_sched_');
    paths = SubscriptionPaths.inDir(dir);
    settings = SettingsService();
    downloads = FakeDownloadService(settings);
    queue = DownloadQueueService(downloads: downloads, settings: settings);
    lister = FakeLister();
    timers = FakeTimers();
    list = FlakyList(store: SubscriptionStore(paths.subscriptions), lister: lister, now: () => clock);
    scheduler = SubscriptionScheduler(
      subscriptions: list,
      archiveFile: paths.archive,
      lister: lister,
      queue: queue,
      interval: () => Duration(minutes: intervalMinutes),
      now: () => clock,
      timer: timers.create,
      lockWait: const Duration(milliseconds: 50),
      acquireLock: acquireLock,
    );
    FileUtils.folderOpenerOverride = (path) async => folderOpens.add(path);
  }

  late final Directory dir;
  late final SubscriptionPaths paths;
  late final SettingsService settings;
  late final FakeDownloadService downloads;
  late final DownloadQueueService queue;
  late final FakeLister lister;
  late final FlakyList list;
  late final FakeTimers timers;
  late final SubscriptionScheduler scheduler;
  var clock = DateTime.utc(2026, 11, 22, 12);
  var intervalMinutes = 60;

  /// Every folder the queue decided to open.
  final folderOpens = <String>[];

  DateTime get fresh => clock.subtract(const Duration(hours: 1));

  Subscription sub({String source = channelUrl, String channelId = channelUc, DateTime? lastChecked, String? outputDir}) => Subscription(
        source: source,
        channelId: channelId,
        title: 'The Channel',
        createdAt: clock.subtract(const Duration(days: 1)),
        outputDir: outputDir,
        lastChecked: lastChecked,
      );

  Future<Subscription> seed({DateTime? lastChecked, String? outputDir}) async {
    final s = sub(lastChecked: lastChecked, outputDir: outputDir);
    await SubscriptionStore(paths.subscriptions).save([s]);
    return s;
  }

  Future<List<Subscription>> stored() => SubscriptionStore(paths.subscriptions).load();

  String archiveText() => paths.archive.existsSync() ? paths.archive.readAsStringSync() : '';

  /// True while another process (here: a competing acquire) cannot get the lock.
  Future<bool> lockIsHeld() async {
    try {
      await (await RunLock.acquire(paths.archive)).release();
      return false;
    } on RunLockBusy {
      return true;
    }
  }

  void dispose() {
    FileUtils.folderOpenerOverride = null;
    scheduler.dispose();
    queue.dispose();
    list.dispose();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // a lock file handle may linger for a moment on Windows
    }
  }
}
