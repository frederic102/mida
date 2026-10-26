import 'dart:async';

import 'package:flutter/foundation.dart';
import '../../settings/settings_service.dart';
import '../../../core/utils/url_parser.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/utils/mida_log.dart';
import 'cli_command_builder.dart';
import 'download_service.dart';

/// Where one queued link is in its life.
enum QueueItemState { queued, fetching, downloading, done, failed }

/// One link in the GUI download queue. Read-only to the UI; only
/// [DownloadQueueService] changes it.
class QueueItem {
  QueueItem._(this.id, this.url, this.type, this.options);

  final int id;
  final String url;
  final DownloadType type;
  final DownloadOptions options;

  QueueItemState _state = QueueItemState.queued;
  double _progress = 0;
  String? _title;
  String? _statusMessage;
  String? _outputPath;
  String? _error;

  QueueItemState get state => _state;

  /// 0.0 to 1.0, meaningful while [state] is downloading.
  double get progress => _progress;

  /// Page title once the site has been read, else null.
  String? get title => _title;

  /// Latest pipeline status line ("Merging audio and video..."), if any.
  String? get statusMessage => _statusMessage;

  /// Saved file, set when [state] is done.
  String? get outputPath => _outputPath;

  /// Failure text with URLs already redacted, set when [state] is failed.
  String? get error => _error;

  bool get isActive => _state == QueueItemState.fetching || _state == QueueItemState.downloading;
  bool get isFinished => _state == QueueItemState.done || _state == QueueItemState.failed;
}

/// Runs queued links one at a time through the existing [DownloadService]
/// (which refuses a second concurrent `download()` call). Nothing is
/// persisted: the queue lives for one app session and is that session's
/// download history (finished items stay until "Clear finished").
///
/// Folder opening: each download runs with `openFolderOnSuccess: false`;
/// when the queue drains and at least one item of that run was saved, the
/// download folder opens once (if [SettingsService.openFolderAfterDownload]).
class DownloadQueueService extends ChangeNotifier {
  DownloadQueueService({
    required DownloadService downloads,
    required SettingsService settings,
    CliCommandBuilder? cliCommands,
  })  : _downloads = downloads,
        _settings = settings,
        _cliCommands = cliCommands ?? const CliCommandBuilder();

  final DownloadService _downloads;
  final SettingsService _settings;
  final CliCommandBuilder _cliCommands;

  final List<QueueItem> _items = [];
  int _nextId = 1;
  bool _pumping = false;
  bool _disposed = false;

  static const busyMessage =
      'Another download was already running, so this one did not start. Retry when it finishes.';
  static const noResultMessage = 'The download stopped without saving a file or reporting why.';

  List<QueueItem> get items => List.unmodifiable(_items);

  /// True while any item is being fetched or downloaded.
  bool get isBusy => _items.any((i) => i.isActive);

  bool get hasFinished => _items.any((i) => i.isFinished);

  /// Every URL currently in the list, any state (used to avoid suggesting
  /// a clipboard link the user already added).
  Set<String> get knownUrls => {for (final i in _items) i.url};

  /// Adds [urls] in order and starts the runner if idle. Skips a URL that
  /// is already waiting or running; a finished one can be added again.
  /// Returns how many were added.
  int enqueueAll(
    Iterable<String> urls, {
    required DownloadType type,
    required DownloadOptions options,
  }) {
    final pending = {for (final i in _items) if (!i.isFinished) i.url};
    var added = 0;
    for (final url in urls) {
      if (!pending.add(url)) continue;
      _items.add(QueueItem._(_nextId++, url, type, options));
      added++;
    }
    if (added > 0) {
      _notify();
      _start();
    }
    return added;
  }

  /// Removes a waiting or finished item. The running item cannot be
  /// removed because [DownloadService] has no cancel.
  void remove(int id) {
    final before = _items.length;
    _items.removeWhere((i) => i.id == id && !i.isActive);
    if (_items.length != before) _notify();
  }

  /// Puts a failed item back in line (same position) and starts the
  /// runner if idle.
  void retry(int id) {
    final item = _find(id);
    if (item == null || item._state != QueueItemState.failed) return;
    item
      .._state = QueueItemState.queued
      .._progress = 0
      .._error = null
      .._statusMessage = null;
    _notify();
    _start();
  }

  /// Drops every done and failed item.
  void clearFinished() {
    final before = _items.length;
    _items.removeWhere((i) => i.isFinished);
    if (_items.length != before) _notify();
  }

  /// The agent CLI command that repeats [item] (same options, current
  /// download folder and login-session setting) for PowerShell or bash, or
  /// the reason there is none (see [CliCommandBuilder]).
  CliCommandResult cliCommandFor(QueueItem item) => _cliCommands.build(
        url: item.url,
        type: item.type,
        options: item.options,
        outDir: _settings.downloadPath,
        loginSession: _settings.useBrowserLoginSession,
      );

  QueueItem? _find(int id) {
    for (final i in _items) {
      if (i.id == id) return i;
    }
    return null;
  }

  QueueItem? _nextQueued() {
    for (final i in _items) {
      if (i._state == QueueItemState.queued) return i;
    }
    return null;
  }

  /// Starts the runner without awaiting it; a failure (for example a
  /// listener that throws) is logged instead of becoming an unhandled error.
  void _start() => unawaited(_pump().catchError((Object e) => midaLog('Download queue runner failed: $e')));

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    var saved = 0;
    try {
      for (var item = _nextQueued(); item != null && !_disposed; item = _nextQueued()) {
        if (await _runOne(item)) saved++;
      }
    } finally {
      _pumping = false;
    }
    if (saved > 0 && !_disposed && _settings.openFolderAfterDownload) {
      // Best effort: _pump runs un-awaited, so a failing file manager
      // (ProcessException) must not become an unhandled async error.
      try {
        await FileUtils.openFolder(_settings.downloadPath);
      } catch (e) {
        debugPrint('Could not open the download folder: $e');
      }
    }
  }

  /// Runs [item]; true when its file was saved.
  Future<bool> _runOne(QueueItem item) async {
    item._state = QueueItemState.fetching;
    _notify();

    // DownloadService only creates its task after it has read the page.
    // Mirror progress only from a task that is new *and* for this item's
    // URL, so a stale task or another caller's download never shows up
    // on this row. The final state comes from the task download() returns.
    final before = _downloads.currentTask;
    void mirror() {
      final task = _downloads.currentTask;
      if (task == null || identical(task, before) || task.url != item.url) return;
      if (task.title != 'Unknown') item._title = task.title;
      if (task.status == DownloadStatus.downloading) {
        item
          .._state = QueueItemState.downloading
          .._progress = task.progress
          .._statusMessage = task.statusMessage;
      }
      _notify();
    }

    _downloads.addListener(mirror);
    Object? thrown;
    DownloadTask? task;
    try {
      task = await _downloads.download(item.url, item.type, options: item.options, openFolderOnSuccess: false);
    } catch (e) {
      thrown = e;
    } finally {
      _downloads.removeListener(mirror);
    }

    var saved = false;
    if (thrown != null) {
      _fail(item, thrown.toString());
    } else if (task == null) {
      _fail(item, busyMessage);
    } else if (task.status == DownloadStatus.completed) {
      if (task.title != 'Unknown') item._title = task.title;
      item
        .._state = QueueItemState.done
        .._progress = 1
        .._outputPath = task.outputPath
        .._statusMessage = null;
      saved = true;
    } else {
      _fail(item, task.error ?? noResultMessage);
    }
    _notify();
    return saved;
  }

  void _fail(QueueItem item, String message) {
    item
      .._state = QueueItemState.failed
      .._error = UrlParser.redactUrlsInText(message)
      .._statusMessage = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
