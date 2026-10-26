import 'dart:async';

import 'package:flutter/foundation.dart';
import '../../../core/download/media_merger.dart';
import '../../../core/download/stream_downloader.dart';
import '../../../core/extractors/extractor_registry_builder.dart';
import '../../../core/extractors/media_extractor.dart';
import '../../../core/extractors/media_models.dart';
import '../../settings/settings_service.dart';
import '../../../core/utils/url_parser.dart';
import '../../../core/utils/file_utils.dart';
import '../models/download_models.dart';
import 'all_format_candidates_failed_exception.dart';
import 'media_download_pipeline.dart';

export '../models/download_models.dart';

class DownloadService extends ChangeNotifier {
  final SettingsService _settings;

  /// Test-only fixed registry (the `registry` constructor param). When
  /// null (production), [_registry] rebuilds from the current settings on
  /// every call instead of freezing `useBrowserLoginSession` at
  /// construction time, so flipping the Settings toggle takes effect on
  /// the next fetch/download without needing an app restart.
  final ExtractorRegistry? _fixedRegistry;
  final MediaDownloadPipeline _pipeline;

  /// The task of the latest `download()` call. The queue keeps the
  /// session's finished items itself, so there is no separate history list.
  DownloadTask? currentTask;

  /// Guards against a second `download()` call landing while one is
  /// already running (e.g. a double-tap on the download button): without
  /// this, the second call would overwrite `currentTask` out from under
  /// the first, corrupting both downloads' progress/status reporting.
  bool _isDownloading = false;

  DownloadService(
    this._settings, {
    ExtractorRegistry? registry,
    MediaDownloadPipeline? pipeline,
  })  : _fixedRegistry = registry,
        _pipeline = pipeline ?? MediaDownloadPipeline();

  ExtractorRegistry get _registry =>
      _fixedRegistry ?? buildExtractorRegistry(useBrowserLoginSession: _settings.useBrowserLoginSession);

  Future<Map<String, dynamic>?> fetchVideoInfo(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    try {
      return _mediaInfoToMap(await _registry.resolveInfo(uri), url);
    } catch (e) {
      debugPrint('Error fetching video info: ${UrlParser.redactUrlsInText(e.toString())}');
      return null;
    }
  }

  Map<String, dynamic> _mediaInfoToMap(MediaInfo info, String url) {
    return {
      'title': info.title,
      'thumbnail': info.thumbnailUrl,
      'duration': info.duration != null ? FileUtils.formatDuration(info.duration!) : null,
      'platform': UrlParser.detectPlatform(url),
    };
  }

  /// Downloads [url] and returns the task this call created, or null when
  /// another download was already running (nothing started). The returned
  /// task is the caller's own, even if [currentTask] has moved on since.
  ///
  /// [openFolderOnSuccess]: open the download folder once the file is
  /// saved. Per call, so a caller that wants to batch the opens (the queue)
  /// turns it off for its own downloads without touching anyone else's.
  Future<DownloadTask?> download(
    String url,
    DownloadType type, {
    DownloadOptions options = const DownloadOptions(),
    bool openFolderOnSuccess = true,
  }) async {
    if (_isDownloading) {
      currentTask?.statusMessage = 'A download is already in progress. Wait for it to finish and try again.';
      notifyListeners();
      return null;
    }
    _isDownloading = true;
    try {
      return await _runDownload(url, type, options, openFolderOnSuccess);
    } finally {
      _isDownloading = false;
    }
  }

  Future<DownloadTask> _runDownload(String url, DownloadType type, DownloadOptions options, bool openFolder) async {
    final platform = UrlParser.detectPlatform(url);
    final uri = Uri.tryParse(url);

    // Fetch once and reuse: `mediaInfo` (formats included) is what actually
    // drives the download below, so we must not throw it away and
    // re-extract inside `_pipeline.download` (that would mean a second
    // network round trip per download).
    Map<String, dynamic>? info;
    MediaInfo? mediaInfo;
    // Kept (not just logged) so the `mediaInfo == null` branch below can
    // surface *this* specific failure (its real status/reason, e.g.
    // RATE_LIMITED) through `_describeDownloadError` instead of a generic
    // "could not read this video" that throws away why.
    Object? resolveError;
    if (uri != null) {
      try {
        mediaInfo = await _registry.resolveInfo(uri);
        info = _mediaInfoToMap(mediaInfo, url);
      } catch (e) {
        resolveError = e;
        debugPrint('Error fetching video info: ${UrlParser.redactUrlsInText(e.toString())}');
      }
    }

    final task = DownloadTask(
      url: url,
      title: info?['title'] ?? 'Unknown',
      type: type,
      platform: platform,
      options: options,
      thumbnailUrl: info?['thumbnail'],
      duration: info?['duration'],
      status: DownloadStatus.fetching,
    );
    currentTask = task;
    notifyListeners();

    try {
      if (mediaInfo == null) {
        throw resolveError ?? Exception('Could not read this video. Check the URL and try again.');
      }
      task.status = DownloadStatus.downloading;
      notifyListeners();

      final outputPath = await _pipeline.download(
        info: mediaInfo,
        type: type,
        options: options,
        outputDir: _settings.downloadPath,
        onProgress: (progress) {
          task.progress = progress;
          notifyListeners();
        },
        onStatus: (message) {
          task.statusMessage = message;
          notifyListeners();
        },
      );
      task.outputPath = outputPath;
      task.status = DownloadStatus.completed;
      if (openFolder) {
        // Not awaited (the download is done); a file manager that fails to
        // start must not surface as an unhandled async error.
        unawaited(FileUtils.openFolder(_settings.downloadPath).catchError((Object e) {
          debugPrint('Could not open the download folder: $e');
        }));
      }
    } catch (e) {
      task.status = DownloadStatus.error;
      // Unknown exceptions are shown as text; strip URLs like every other path.
      task.error = UrlParser.redactUrlsInText(_describeDownloadError(e));
    }

    notifyListeners();
    return task;
  }

  /// Appended when the failure that reaches the user (directly, or as the
  /// last format candidate's error inside [AllFormatCandidatesFailedException])
  /// is a `RATE_LIMITED` [MediaExtractionException]: what happened (the
  /// site is throttling this network), why a retry alone may not be enough
  /// (some sources only serve the full result to a logged-in session), and
  /// the concrete next step, naming the exact Settings toggle another lane
  /// adds (`docs/plan-phase4-cookies-resilience.md` section 2).
  static const _browserLoginSuggestion =
      ' This can happen when a site is rate-limiting requests from this network. '
      'Try turning on "Use browser login session" in Settings so MiDa can reuse your '
      'signed-in browser session instead.';

  /// Renders any of our own exception types into the same
  /// what/why/next English shape, instead of showing a raw
  /// `Exception: ...`/stack-trace-flavored string to the user. Not
  /// YouTube-specific: every extractor (YouTube, X, Generic,
  /// browser-capture) throws [MediaExtractionException], and each one's
  /// `reason` is already a complete, source-specific sentence.
  String _describeDownloadError(Object e) {
    if (e is MediaExtractionException) {
      final base = e.reason == null
          ? 'Could not fetch this video (status: ${e.status}). Check the URL and try again later.'
          : '${e.reason} Check the URL and try again later.';
      return e.status == 'RATE_LIMITED' ? '$base$_browserLoginSuggestion' : base;
    }
    if (e is AllFormatCandidatesFailedException) {
      final last = e.lastError;
      final isRateLimited = last is MediaExtractionException && last.status == 'RATE_LIMITED';
      return isRateLimited ? '$e$_browserLoginSuggestion' : e.toString();
    }
    if (e is NoDownloadableFormatsException) {
      return 'No downloadable formats were found for this video (it may be restricted or region-locked). '
          'Check the URL and try again later.';
    }
    if (e is StreamDownloadException) {
      return 'The download failed while fetching video or audio data: ${e.message} '
          'Check your internet connection and try again.';
    }
    if (e is MediaMergeException) {
      return 'Converting or merging the downloaded file failed: ${e.message} '
          'Make sure ffmpeg is installed correctly and try again.';
    }
    return e.toString();
  }

  void clearCurrentTask() {
    currentTask = null;
    notifyListeners();
  }
}
