import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../../core/services/settings_service.dart';
import '../../../core/services/platform_service.dart';
import '../../../core/services/ffmpeg_locator.dart';
import '../../../core/utils/file_utils.dart';

enum ExtractStatus { idle, analyzing, extracting, completed, error, unsupported }

class ExtractTask {
  final String inputPath;
  String? outputPath;
  double progress;
  ExtractStatus status;
  String? error;
  Duration? duration;

  ExtractTask({
    required this.inputPath,
    this.outputPath,
    this.progress = 0,
    this.status = ExtractStatus.idle,
    this.error,
    this.duration,
  });
}

class ExtractService extends ChangeNotifier {
  final SettingsService _settings;

  ExtractTask? currentTask;
  List<ExtractTask> history = [];

  ExtractService(this._settings);

  // Local file audio extraction is only supported on desktop
  // On mobile, use MP3 download from the download screen
  bool get isLocalFileSupported => PlatformService.isDesktop;

  Future<void> extract(String inputPath) async {
    if (!isLocalFileSupported) {
      currentTask = ExtractTask(
        inputPath: inputPath,
        status: ExtractStatus.unsupported,
        error: 'Local file audio extraction is not supported on mobile.\nPlease use MP3 download from the Download tab.',
      );
      notifyListeners();
      return;
    }

    currentTask = ExtractTask(
      inputPath: inputPath,
      status: ExtractStatus.analyzing,
    );
    notifyListeners();

    try {
      await _extractDesktop(inputPath);
      currentTask!.status = ExtractStatus.completed;
      history.insert(0, currentTask!);
    } catch (e) {
      currentTask!.status = ExtractStatus.error;
      currentTask!.error = e.toString();
    }

    notifyListeners();
  }

  Future<void> _extractDesktop(String inputPath) async {
    currentTask!.status = ExtractStatus.extracting;
    notifyListeners();

    final ffmpegPath = await _getFFmpegPath();
    final ffprobePath = await _getFFprobePath();

    // Get video duration
    final probeResult = await Process.run(
      ffprobePath,
      [
        '-v', 'error',
        '-show_entries', 'format=duration',
        '-of', 'default=noprint_wrappers=1:nokey=1',
        inputPath,
      ],
    );

    final durationSeconds = double.tryParse(probeResult.stdout.toString().trim()) ?? 0;
    currentTask!.duration = Duration(seconds: durationSeconds.toInt());

    final fileName = inputPath.split(Platform.pathSeparator).last;
    final nameWithoutExt = fileName.contains('.')
        ? fileName.substring(0, fileName.lastIndexOf('.'))
        : fileName;
    final outputPath = '${_settings.downloadPath}/$nameWithoutExt.mp3';
    final uniquePath = await FileUtils.getUniqueFilePath(outputPath);

    currentTask!.outputPath = uniquePath;

    final args = [
      '-y',
      '-i', inputPath,
      '-vn', // No video
      '-acodec', 'libmp3lame',
      '-ab', '320k', // High quality
      '-ar', '44100', // Sample rate
      uniquePath,
    ];

    final process = await Process.start(ffmpegPath, args);

    process.stderr.transform(const SystemEncoding().decoder).listen((line) {
      final progress = _parseFFmpegProgress(line, durationSeconds);
      if (progress != null) {
        currentTask!.progress = progress;
        notifyListeners();
      }
    });

    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      throw Exception('Audio extraction failed');
    }

    currentTask!.progress = 1.0;
  }

  Future<String> _getFFmpegPath() => FfmpegLocator.ffmpegPath();

  Future<String> _getFFprobePath() => FfmpegLocator.ffprobePath();

  double? _parseFFmpegProgress(String line, double totalDuration) {
    final match = RegExp(r'time=(\d+):(\d+):(\d+\.?\d*)').firstMatch(line);
    if (match != null) {
      final hours = int.parse(match.group(1)!);
      final minutes = int.parse(match.group(2)!);
      final seconds = double.parse(match.group(3)!);
      final currentSeconds = hours * 3600 + minutes * 60 + seconds;
      return totalDuration > 0 ? currentSeconds / totalDuration : 0;
    }
    return null;
  }

  void clearCurrentTask() {
    currentTask = null;
    notifyListeners();
  }
}
