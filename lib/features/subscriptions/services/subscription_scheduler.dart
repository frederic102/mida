import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import '../../../core/extractors/media_models.dart';
import '../../../core/extractors/youtube/youtube_list_models.dart';
import '../../../core/extractors/youtube/youtube_lister.dart';
import '../../../core/subscriptions/download_archive.dart';
import '../../../core/subscriptions/run_lock.dart';
import '../../../core/subscriptions/subscription.dart';
import '../../../core/subscriptions/subscription_check.dart';
import '../../../core/utils/mida_log.dart';
import '../../download/models/download_models.dart';
import '../../download/services/download_queue_service.dart';
import '../../download/widgets/list_error_mapping.dart';
import 'subscription_list.dart';
import 'subscription_pass.dart';

typedef TimerFactory = Timer Function(Duration after, void Function() callback);

/// Checks the subscribed channels while the app is open: once at start when
/// the last check is older than the interval, then every interval, or on
/// demand. New uploads go into the normal download queue.
///
/// One pass at a time. The pass ([SubscriptionPass]) holds the archive's
/// [RunLock] until every download it admitted has ended and its archive write
/// is done, on every path: success, an error, [dispose]. When `mida-cli`
/// holds the lock the check is skipped and the status says so. A video id is
/// written to the archive only after that video was saved, always under the
/// lock; a write that cannot get the lock is kept in [_leftOver] and written
/// by the next pass. `last_checked` moves only for channels whose check worked.
class SubscriptionScheduler extends ChangeNotifier {
  SubscriptionScheduler({
    required this.subscriptions,
    required this.archiveFile,
    required YoutubeLister lister,
    required DownloadQueueService queue,
    required Duration Function() interval,
    DateTime Function()? now,
    TimerFactory? timer,
    this.lockWait = const Duration(seconds: 3),
    LockAcquirer? acquireLock,
  })  : _lister = lister,
        _queue = queue,
        _interval = interval,
        _now = now ?? DateTime.now,
        _timerFactory = timer ?? Timer.new,
        _acquire = acquireLock ?? acquireRunLock;

  final SubscriptionList subscriptions;
  final File archiveFile;
  final Duration lockWait;
  final YoutubeLister _lister;
  final DownloadQueueService _queue;
  final Duration Function() _interval;
  final DateTime Function() _now;
  final TimerFactory _timerFactory;
  final LockAcquirer _acquire;

  Timer? _timer;
  SubscriptionPass? _pass;
  bool _running = false;
  bool _draining = false;
  bool _disposed = false;
  String? _status;
  final _errors = <String, String>{};

  /// Ids saved but not yet in the archive (no lock was available); the next
  /// pass writes them.
  final _leftOver = <String>{};

  /// Queue items this scheduler already listens to (one listener per item).
  final _observed = Expando<String>();

  /// A pass is in progress (checking or draining).
  bool get isRunning => _running;

  /// The channels are checked; what remains is waiting for queued downloads.
  bool get isDraining => _running && _draining;

  /// What the last check did, in one sentence (null before the first one).
  String? get status => _status;

  /// Why the last check of [sub] failed, or null.
  String? errorFor(Subscription sub) => _errors[_key(sub)];

  static String _key(Subscription s) => '${s.source}|${s.createdAt.toUtc().toIso8601String()}';

  /// Loads the list, checks at once if some channel is overdue, and arms the
  /// repeating timer.
  Future<void> start() async {
    await subscriptions.load();
    if (_disposed) return;
    _arm();
    if (subscriptions.items.any(_isDue)) unawaited(runCheck(onlyDue: true));
  }

  /// Call after the interval setting changed.
  void restartTimer() {
    if (!_disposed && _timer != null) _arm();
  }

  bool _isDue(Subscription s) {
    final last = s.lastChecked;
    return last == null || !_now().isBefore(last.add(_interval()));
  }

  void _arm() {
    _timer?.cancel();
    _timer = _timerFactory(_interval(), () {
      if (_disposed) return;
      _arm();
      unawaited(runCheck());
    });
  }

  /// One check pass. [onlyDue] limits it to channels not checked within the
  /// interval (the start-up catch-up); the timer and "Check now" check all.
  /// Never throws: every failure ends up in [status].
  Future<void> runCheck({bool onlyDue = false}) async {
    if (_running) return; // never overlap: the running pass owns the lock and the archive
    _running = true;
    _draining = false;
    _notify();
    SubscriptionPass? pass;
    try {
      pass = await SubscriptionPass.open(archiveFile, wait: lockWait, acquire: _acquire);
      _pass = pass;
      await _flushLeftOver(pass);
      await _checkAll(pass, onlyDue);
    } on RunLockBusy {
      _status = 'Skipped this check: mida-cli is using the same archive. It will try again at the next interval.';
    } on FileSystemException {
      _status = 'The archive file could not be read, so nothing was checked.';
    } catch (e) {
      midaLog('Subscription check failed: $e');
      _status = 'The check stopped because of an unexpected error. Downloads already queued will finish.';
    } finally {
      // The one exit: drain whatever was admitted, release, reset.
      try {
        if (pass != null) {
          _draining = pass.hasWork;
          _notify();
          await pass.close();
        }
      } catch (e) {
        midaLog('Giving back the archive lock failed: $e');
      } finally {
        _pass = null;
        _draining = false;
        _running = false;
        _notify();
      }
    }
  }

  Future<void> _flushLeftOver(SubscriptionPass pass) async {
    for (final id in _leftOver.toList()) {
      if (await pass.record(id)) _leftOver.remove(id);
    }
  }

  Future<void> _checkAll(SubscriptionPass pass, bool onlyDue) async {
    await subscriptions.load();
    if (subscriptions.loadError != null) {
      _status = subscriptions.loadError;
      return;
    }
    final due = [for (final s in subscriptions.items) if (!onlyDue || _isDue(s)) s];
    final checked = <Subscription>[];
    var queued = 0;
    var failed = 0;
    var archiveBroken = false;
    for (final sub in due) {
      if (_disposed) break;
      try {
        await pass.archive.reload();
      } on FileSystemException {
        archiveBroken = true;
        break;
      }
      try {
        final check = await checkSubscription(_lister, sub, pass.archive, now: _now().toUtc());
        checked.add(check.updated);
        _errors.remove(_key(sub));
        for (final item in check.fresh) {
          queued += _admit(item, sub, pass);
        }
      } catch (e) {
        failed++;
        _errors[_key(sub)] = describeListError(e).headline;
        midaLog('Subscription check failed: $e');
        if (e is MediaExtractionException && e.status == 'RATE_LIMITED') break; // do not hammer
      }
    }
    var saved = true;
    if (checked.isNotEmpty) {
      try {
        // Only channel_id (while null) and last_checked, and never backwards.
        await subscriptions.store.update((current) => mergeCheckResults(current, checked));
      } on FormatException {
        saved = false;
      } on FileSystemException {
        saved = false;
      }
      await subscriptions.load();
    }
    _status = _summary(due.length, checked.length, failed, queued, saved, archiveBroken);
    _notify();
  }

  String _summary(int channels, int checked, int failed, int queued, bool saved, bool archiveBroken) {
    if (channels == 0) return 'No channels are due for a check.';
    final parts = ['Checked $checked of $channels ${channels == 1 ? 'channel' : 'channels'}'];
    parts.add(queued == 0 ? 'no new uploads' : '$queued new ${queued == 1 ? 'upload' : 'uploads'} queued');
    if (failed > 0) parts.add('$failed failed');
    if (archiveBroken) parts.add('the archive could not be read, so the check stopped early');
    if (!saved) parts.add('the subscriptions file could not be updated');
    return '${parts.join(', ')}.';
  }

  /// Puts one upload under this pass. A video already waiting in the queue
  /// (added by hand, or by another row of this pass) is not queued again: the
  /// pass takes that very item as its own work, once. Returns 1 when a new
  /// download was queued.
  int _admit(YoutubeListItem upload, Subscription sub, SubscriptionPass pass) {
    if (!pass.admitting) return 0;
    if (_leftOver.contains(upload.id)) return 0; // saved already, only its archive entry is outstanding
    final url = upload.url.toString();
    var item = _queue.pendingItem(url);
    var queued = 0;
    // Only a job with this subscription's intent (a video, into its folder)
    // may stand for it. Any other job for the URL (audio only, another
    // folder) is left alone and does not count: the id stays out of the
    // archive and a later pass queues the real download.
    if (item != null && (item.type != DownloadType.video || item.outputDir != sub.outputDir)) return 0;
    if (item == null) {
      item = _queue.enqueue(
        url,
        type: DownloadType.video,
        options: const DownloadOptions(),
        outputDir: sub.outputDir,
        openFolderWhenDone: false,
      );
      if (item == null) return 0;
      queued = 1;
    } else if (pass.owns(item)) {
      return 0;
    }
    pass.admit(item);
    _observe(item, upload.id);
    return queued;
  }

  void _observe(QueueItem item, String id) {
    if (_observed[item] != null) return;
    _observed[item] = id;
    item.observe((saved) => unawaited(_onFinished(item, id, saved)));
  }

  /// An item this scheduler listens to ended (also again after a manual
  /// retry). Inside its pass the pass writes; otherwise the write is done
  /// under a freshly taken lock, or kept for the next pass.
  Future<void> _onFinished(QueueItem item, String id, bool saved) async {
    try {
      final pass = _pass;
      if (pass != null && pass.owns(item)) {
        if (!await pass.complete(item, id, saved)) _keep(id);
      } else if (saved) {
        await _writeLate(id);
      }
    } catch (e) {
      midaLog('Recording a finished download failed: $e');
      if (saved) _keep(id);
    }
  }

  Future<void> _writeLate(String id) async {
    // Outstanding from this instant, before any lock is awaited: no pass
    // queues this video again, and whichever pass gets the lock first writes
    // the id (see [_flushLeftOver]).
    _leftOver.add(id);
    final pass = _pass;
    if (pass != null && await pass.record(id)) { // another pass is holding the lock
      _leftOver.remove(id);
      return;
    }
    RunLock? lock;
    try {
      lock = await _acquire(archiveFile, lockWait);
      await (await DownloadArchive.open(archiveFile)).add(id);
      _leftOver.remove(id);
    } catch (_) {
      _keep(id); // no lock or no archive: the next pass records it
    } finally {
      try {
        await lock?.release();
      } catch (e) {
        midaLog('Giving back the archive lock failed: $e');
      }
    }
  }

  void _keep(String id) {
    _leftOver.add(id);
    _status = 'A video was saved but could not be recorded in the archive yet; the next check records it.';
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Stops the timer and admission at once. A pass that is running keeps
  /// the archive lock until its active download and archive write are done;
  /// downloads still waiting in the queue are taken out of it.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    final pass = _pass;
    if (pass != null) {
      pass.stopAdmitting();
      for (final item in pass.items) {
        _queue.remove(item.id);
      }
    }
    super.dispose();
  }
}
