import 'package:flutter/foundation.dart';
import '../../../core/download/media_merger.dart';
import '../../../core/download/stream_downloader.dart';
import '../../../core/extractors/extractor_registry_builder.dart';
import '../../../core/extractors/media_extractor.dart';
import '../../../core/extractors/media_models.dart';
import '../../../core/services/settings_service.dart';
import '../../../core/utils/url_parser.dart';
import '../../../core/utils/file_utils.dart';
import 'all_format_candidates_failed_exception.dart';
import 'media_download_pipeline.dart';

enum DownloadType { video, audio }

enum DownloadStatus { idle, fetching, downloading, completed, error }

// Video quality options
enum VideoQuality {
  best('Best Quality', 'bestvideo'),
  p2160('4K (2160p)', '2160'),
  p1440('2K (1440p)', '1440'),
  p1080('1080p', '1080'),
  p720('720p', '720'),
  p480('480p', '480'),
  p360('360p', '360');

  final String label;
  final String value;
  const VideoQuality(this.label, this.value);
}

// Audio quality options
enum AudioQuality {
  best('Best Quality', '0'),
  high('320 kbps', '320'),
  medium('256 kbps', '256'),
  low('128 kbps', '128');

  final String label;
  final String value;
  const AudioQuality(this.label, this.value);
}

// Video format options
enum VideoFormat {
  mp4('MP4', 'mp4'),
  webm('WebM', 'webm'),
  mkv('MKV', 'mkv');

  final String label;
  final String value;
  const VideoFormat(this.label, this.value);
}

// Audio format options
enum AudioFormat {
  mp3('MP3', 'mp3'),
  m4a('M4A', 'm4a'),
  opus('Opus', 'opus'),
  flac('FLAC', 'flac'),
  wav('WAV', 'wav');

  final String label;
  final String value;
  const AudioFormat(this.label, this.value);
}

// Subtitle options
enum SubtitleOption {
  none('No Subtitle', ''),
  korean('Korean', 'ko'),
  english('English', 'en'),
  koreanEnglish('Korean + English', 'ko,en');

  final String label;
  final String value;
  const SubtitleOption(this.label, this.value);
}

// Download options
class DownloadOptions {
  final VideoQuality videoQuality;
  final AudioQuality audioQuality;
  final VideoFormat videoFormat;
  final AudioFormat audioFormat;
  final SubtitleOption subtitleOption;

  const DownloadOptions({
    this.videoQuality = VideoQuality.best,
    this.audioQuality = AudioQuality.best,
    this.videoFormat = VideoFormat.mp4,
    this.audioFormat = AudioFormat.mp3,
    this.subtitleOption = SubtitleOption.none,
  });

  DownloadOptions copyWith({
    VideoQuality? videoQuality,
    AudioQuality? audioQuality,
    VideoFormat? videoFormat,
    AudioFormat? audioFormat,
    SubtitleOption? subtitleOption,
  }) {
    return DownloadOptions(
      videoQuality: videoQuality ?? this.videoQuality,
      audioQuality: audioQuality ?? this.audioQuality,
      videoFormat: videoFormat ?? this.videoFormat,
      audioFormat: audioFormat ?? this.audioFormat,
      subtitleOption: subtitleOption ?? this.subtitleOption,
    );
  }
}

class DownloadTask {
  final String url;
  String title;
  final DownloadType type;
  final PlatformType platform;
  final DownloadOptions options;
  String? thumbnailUrl;
  String? duration;
  double progress;
  DownloadStatus status;
  String? error;
  String? statusMessage;
  String? outputPath;

  DownloadTask({
    required this.url,
    required this.title,
    required this.type,
    required this.platform,
    this.options = const DownloadOptions(),
    this.thumbnailUrl,
    this.duration,
    this.progress = 0,
    this.status = DownloadStatus.idle,
    this.error,
    this.statusMessage,
    this.outputPath,
  });
}

class DownloadService extends ChangeNotifier {
  final SettingsService _settings;

  /// Test-only fixed registry (the `registry` constructor param). When
  /// null (production), [_registry] rebuilds from the current settings on
  /// every call instead of freezing `useBrowserLoginSession` at
  /// construction time, so flipping the Settings toggle takes effect on
  /// the next fetch/download without needing an app restart.
  final ExtractorRegistry? _fixedRegistry;
  final MediaDownloadPipeline _pipeline;

  DownloadTask? currentTask;
  List<DownloadTask> history = [];

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

  Future<void> download(String url, DownloadType type, {DownloadOptions options = const DownloadOptions()}) async {
    if (_isDownloading) {
      currentTask?.statusMessage = 'A download is already in progress. Wait for it to finish and try again.';
      notifyListeners();
      return;
    }
    _isDownloading = true;
    try {
      await _runDownload(url, type, options);
    } finally {
      _isDownloading = false;
    }
  }

  Future<void> _runDownload(String url, DownloadType type, DownloadOptions options) async {
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

    currentTask = DownloadTask(
      url: url,
      title: info?['title'] ?? 'Unknown',
      type: type,
      platform: platform,
      options: options,
      thumbnailUrl: info?['thumbnail'],
      duration: info?['duration'],
      status: DownloadStatus.fetching,
    );
    notifyListeners();

    try {
      if (mediaInfo == null) {
        throw resolveError ?? Exception('Could not read this video. Check the URL and try again.');
      }
      currentTask!.status = DownloadStatus.downloading;
      notifyListeners();

      final outputPath = await _pipeline.download(
        info: mediaInfo,
        type: type,
        options: options,
        outputDir: _settings.downloadPath,
        onProgress: (progress) {
          currentTask!.progress = progress;
          notifyListeners();
        },
        onStatus: (message) {
          currentTask!.statusMessage = message;
          notifyListeners();
        },
      );
      currentTask!.outputPath = outputPath;

      currentTask!.status = DownloadStatus.completed;
      history.insert(0, currentTask!);

      // Auto-open folder when download completes
      FileUtils.openFolder(_settings.downloadPath);
    } catch (e) {
      currentTask!.status = DownloadStatus.error;
      currentTask!.error = _describeDownloadError(e);
    }

    notifyListeners();
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
