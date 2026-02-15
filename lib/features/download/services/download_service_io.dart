import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../../core/services/settings_service.dart';
import '../../../core/utils/url_parser.dart';
import '../../../core/utils/file_utils.dart';

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

  DownloadTask? currentTask;
  List<DownloadTask> history = [];

  DownloadService(this._settings);

  Future<Map<String, dynamic>?> fetchVideoInfo(String url) async {
    final platform = UrlParser.detectPlatform(url);
    return _fetchVideoInfoDesktop(url, platform);
  }

  Future<Map<String, dynamic>?> _fetchVideoInfoDesktop(
      String url, PlatformType platform) async {
    try {
      final ytDlpPath = await _getYtDlpPath();
      final result = await Process.run(
        ytDlpPath,
        ['--dump-json', '--no-playlist', url],
        stdoutEncoding: const SystemEncoding(),
        stderrEncoding: const SystemEncoding(),
      );

      if (result.exitCode != 0) {
        throw Exception(result.stderr);
      }

      final json = result.stdout as String;
      final data = _parseJson(json);
      return {
        'title': data['title'] ?? 'Unknown',
        'thumbnail': data['thumbnail'],
        'duration': data['duration'] != null
            ? FileUtils.formatDuration(
                Duration(seconds: (data['duration'] as num).toInt()))
            : null,
        'platform': platform,
      };
    } catch (e) {
      debugPrint('Error fetching video info: $e');
      return null;
    }
  }

  Future<void> download(String url, DownloadType type, {DownloadOptions options = const DownloadOptions()}) async {
    final platform = UrlParser.detectPlatform(url);
    final info = await fetchVideoInfo(url);

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
      await _downloadDesktop(url, type, options);

      currentTask!.status = DownloadStatus.completed;
      history.insert(0, currentTask!);

      // Auto-open folder when download completes
      FileUtils.openFolder(_settings.downloadPath);
    } catch (e) {
      currentTask!.status = DownloadStatus.error;
      currentTask!.error = e.toString();
    }

    notifyListeners();
  }

  Future<void> _downloadDesktop(String url, DownloadType type, DownloadOptions options) async {
    final ytDlpPath = await _getYtDlpPath();
    final ffmpegPath = await _getFFmpegPath();
    final outputDir = _settings.downloadPath;
    final outputTemplate = '$outputDir/%(title)s.%(ext)s';

    currentTask!.status = DownloadStatus.downloading;
    notifyListeners();

    final args = <String>[
      '-o', outputTemplate,
      '--no-playlist',
      '--newline',
      '--ffmpeg-location', ffmpegPath,
    ];

    // Subtitle download options (video only) - saves as separate .srt file
    if (type == DownloadType.video && options.subtitleOption != SubtitleOption.none) {
      args.addAll([
        '--write-subs',
        '--write-auto-subs',
        '--sub-lang', options.subtitleOption.value,
        '--convert-subs', 'srt',
        '--ignore-errors',
      ]);
    }

    if (type == DownloadType.audio) {
      args.addAll([
        '-x',
        '--audio-format', options.audioFormat.value,
      ]);
      if (options.audioQuality != AudioQuality.best) {
        args.addAll(['--audio-quality', options.audioQuality.value]);
      }
    } else {
      // Video format and quality settings
      String formatStr;
      if (options.videoQuality == VideoQuality.best) {
        formatStr = 'bestvideo+bestaudio/best';
      } else {
        formatStr = 'bestvideo[height<=${options.videoQuality.value}]+bestaudio/best[height<=${options.videoQuality.value}]/best';
      }
      args.addAll(['-f', formatStr]);

      // Final container format (ffmpeg handles conversion)
      args.addAll(['--merge-output-format', options.videoFormat.value]);
    }

    args.add(url);

    debugPrint('yt-dlp args: $args');
    final process = await Process.start(ytDlpPath, args);

    final stderrBuffer = StringBuffer();

    process.stdout.transform(const SystemEncoding().decoder).listen((line) {
      debugPrint('yt-dlp stdout: $line');
      final progress = _parseProgress(line);
      if (progress != null) {
        currentTask!.progress = progress;
        notifyListeners();
      }
    });

    process.stderr.transform(const SystemEncoding().decoder).listen((line) {
      debugPrint('yt-dlp stderr: $line');
      stderrBuffer.writeln(line);
    });

    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      final errorMsg = stderrBuffer.toString().trim();
      throw Exception(errorMsg.isNotEmpty ? errorMsg : 'Download failed with exit code $exitCode');
    }

    currentTask!.progress = 1.0;
  }

  Future<String> _getYtDlpPath() async {
    if (Platform.isWindows) {
      final exePath = Platform.resolvedExecutable;
      final appDir = File(exePath).parent.path;
      final ytDlpPath = '$appDir/yt-dlp.exe';

      if (await File(ytDlpPath).exists()) {
        return ytDlpPath;
      }
      return 'yt-dlp';
    } else if (Platform.isMacOS) {
      final exePath = Platform.resolvedExecutable;
      final appDir = File(exePath).parent.parent.path;
      final ytDlpPath = '$appDir/Resources/yt-dlp';

      if (await File(ytDlpPath).exists()) {
        return ytDlpPath;
      }
      return 'yt-dlp';
    }
    return 'yt-dlp';
  }

  Future<String> _getFFmpegPath() async {
    if (Platform.isWindows) {
      final exePath = Platform.resolvedExecutable;
      final appDir = File(exePath).parent.path;
      final ffmpegPath = '$appDir/ffmpeg.exe';

      if (await File(ffmpegPath).exists()) {
        return appDir;
      }
      return '';
    } else if (Platform.isMacOS) {
      final exePath = Platform.resolvedExecutable;
      final appDir = File(exePath).parent.parent.path;
      final ffmpegPath = '$appDir/Resources/ffmpeg';

      if (await File(ffmpegPath).exists()) {
        return '$appDir/Resources';
      }
      return '';
    }
    return '';
  }

  double? _parseProgress(String line) {
    final match = RegExp(r'\[download\]\s+(\d+\.?\d*)%').firstMatch(line);
    if (match != null) {
      final percent = double.tryParse(match.group(1)!);
      if (percent != null) {
        return percent / 100;
      }
    }
    return null;
  }

  Map<String, dynamic> _parseJson(String json) {
    final Map<String, dynamic> result = {};
    final titleMatch = RegExp(r'"title"\s*:\s*"([^"]*)"').firstMatch(json);
    final thumbnailMatch =
        RegExp(r'"thumbnail"\s*:\s*"([^"]*)"').firstMatch(json);
    final durationMatch =
        RegExp(r'"duration"\s*:\s*(\d+\.?\d*)').firstMatch(json);

    if (titleMatch != null) result['title'] = titleMatch.group(1);
    if (thumbnailMatch != null) result['thumbnail'] = thumbnailMatch.group(1);
    if (durationMatch != null) {
      result['duration'] = double.tryParse(durationMatch.group(1)!);
    }

    return result;
  }

  void clearCurrentTask() {
    currentTask = null;
    notifyListeners();
  }
}
