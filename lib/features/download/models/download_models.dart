import '../../../core/utils/url_parser.dart';

/// Download value types (what to download, in which quality/format, and the
/// task state). Pure Dart: no `package:flutter`, so the agent CLI
/// (`lib/cli/`) and every download-chain file can import this without
/// pulling the GUI in. `download_service_io.dart` re-exports this file, so
/// existing `import '.../download_service_io.dart'` call sites keep working.

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
