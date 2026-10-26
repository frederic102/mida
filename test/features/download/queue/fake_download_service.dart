import 'dart:async';

import 'package:mida/core/utils/file_utils.dart';
import 'package:mida/core/utils/url_parser.dart';
import 'package:mida/features/download/services/download_service.dart';
import 'package:mida/features/settings/settings_service.dart';

/// One `download()` call held open until the test decides how it ends.
/// Mirrors the real service's observable order: no new `currentTask`
/// while the page is being read, then a fresh task that goes to
/// downloading, then completed (plus the folder open when the caller asked
/// for it) or error. The call returns its own task, like the real one.
class PendingDownload {
  PendingDownload._(this.url, this.type, this.openFolderOnSuccess, this._svc);

  final String url;
  final DownloadType type;
  final bool openFolderOnSuccess;
  final FakeDownloadService _svc;
  final Completer<DownloadTask?> _done = Completer<DownloadTask?>();
  DownloadTask? _task;

  bool get isOpen => !_done.isCompleted;

  void startDownloading({String title = 'Unknown', double progress = 0, String? message}) {
    _task = DownloadTask(
      url: url,
      title: title,
      type: type,
      platform: UrlParser.detectPlatform(url),
      status: DownloadStatus.downloading,
      progress: progress,
      statusMessage: message,
    );
    _svc.currentTask = _task;
    _svc.ping();
  }

  void progress(double value, {String? message}) {
    _task!
      ..progress = value
      ..statusMessage = message;
    _svc.ping();
  }

  void succeed(String outputPath) {
    if (_task == null) startDownloading();
    _task!
      ..outputPath = outputPath
      ..status = DownloadStatus.completed;
    // Same unawaited call the real service makes on success.
    if (openFolderOnSuccess) FileUtils.openFolder(_svc.settings.downloadPath);
    _svc.ping();
    _done.complete(_task);
  }

  void fail(String error) {
    if (_task == null) startDownloading();
    _task!
      ..status = DownloadStatus.error
      ..error = error;
    _svc.ping();
    _done.complete(_task);
  }

  void throwError(Object error) => _done.completeError(error);
}

class FakeDownloadService extends DownloadService {
  FakeDownloadService(this.settings) : super(settings);

  final SettingsService settings;
  final List<PendingDownload> pending = [];
  int active = 0;
  int maxActive = 0;

  /// When true, the next call behaves like the real re-entry guard: it
  /// returns null at once without creating a task.
  bool rejectNext = false;

  List<String> get calls => [for (final p in pending) p.url];
  PendingDownload get last => pending.last;

  void ping() => notifyListeners();

  @override
  Future<DownloadTask?> download(
    String url,
    DownloadType type, {
    DownloadOptions options = const DownloadOptions(),
    bool openFolderOnSuccess = true,
  }) async {
    if (rejectNext) {
      rejectNext = false;
      return null;
    }
    active++;
    if (active > maxActive) maxActive = active;
    final call = PendingDownload._(url, type, openFolderOnSuccess, this);
    pending.add(call);
    try {
      return await call._done.future;
    } finally {
      active--;
    }
  }
}

/// Lets queued futures and listeners run.
Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
