import 'dart:async';
import 'dart:io';

import '../../../core/subscriptions/download_archive.dart';
import '../../../core/subscriptions/run_lock.dart';
import '../../download/services/download_queue_service.dart';

typedef LockAcquirer = Future<RunLock> Function(File archive, Duration wait);

Future<RunLock> acquireRunLock(File archive, Duration wait) => RunLock.acquire(archive, wait: wait);

/// One subscription pass: the ONLY place that holds the archive [RunLock].
///
/// - [open] takes the lock (bounded wait) and reads the archive.
/// - Work is tracked by identity: every [QueueItem] the pass admitted, and
///   every archive write it started, is one entry. Two rows that yield the
///   same video admit the same item once; nothing removes another's entry.
/// - [close] stops admitting, waits until every entry is done (items
///   finished or removed, writes finished), and only then releases the lock.
///   It does so whatever happened before it was called, so an error in the
///   middle of a pass cannot release the lock while a download is running.
class SubscriptionPass {
  SubscriptionPass._(this._lock, this.archive);

  /// Throws [RunLockBusy] when the lock stays taken for [wait]. A failure
  /// after the lock was taken gives the lock back before it propagates.
  static Future<SubscriptionPass> open(File archiveFile, {required Duration wait, LockAcquirer acquire = acquireRunLock}) async {
    final lock = await acquire(archiveFile, wait);
    try {
      return SubscriptionPass._(lock, await DownloadArchive.open(archiveFile));
    } catch (_) {
      try {
        await lock.release();
      } catch (_) {
        // the open failure is the one to report
      }
      rethrow;
    }
  }

  final RunLock _lock;
  final DownloadArchive archive;
  final _work = <Object>{};
  Completer<void>? _changed;
  var _admitting = true;
  var _sealed = false;
  Future<void>? _closing;

  /// False once [close] or [stopAdmitting] was called.
  bool get admitting => _admitting;

  /// Work is still outstanding (queued or running downloads, archive writes).
  bool get hasWork => _work.isNotEmpty;

  bool owns(QueueItem item) => _work.contains(item);

  /// The queue items still outstanding.
  List<QueueItem> get items => _work.whereType<QueueItem>().toList();

  /// Takes [item] as outstanding. False once admission stopped; the caller
  /// then must not queue anything.
  bool admit(QueueItem item) {
    if (!_admitting) return false;
    _work.add(item);
    return true;
  }

  void stopAdmitting() => _admitting = false;

  /// [item] ended. A saved file is archived first, then the entry is done, so
  /// the lock outlives the write. Returns false when the write failed (the
  /// caller keeps the id for the next pass).
  Future<bool> complete(QueueItem item, String id, bool saved) async {
    try {
      return !saved || await _write(id);
    } finally {
      _done(item);
    }
  }

  /// Archives [id] under this pass's lock (an id left over from earlier, or a
  /// retry that succeeded). False when the lock is already given back or the
  /// write failed.
  Future<bool> record(String id) async {
    if (_sealed) return false;
    final token = Object();
    _work.add(token);
    try {
      return await _write(id);
    } finally {
      _done(token);
    }
  }

  Future<bool> _write(String id) async {
    try {
      await archive.add(id);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _done(Object entry) {
    _work.remove(entry);
    final waiting = _changed;
    _changed = null;
    waiting?.complete();
  }

  /// Stops admitting, drains, releases. Safe to call twice. A release
  /// failure is thrown to the first caller after the pass is already closed.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _admitting = false;
    try {
      while (_work.isNotEmpty) {
        final changed = _changed = Completer<void>();
        await changed.future;
      }
    } finally {
      _sealed = true; // from here on [record] refuses, so no write can race the release
      await _lock.release();
    }
  }
}
