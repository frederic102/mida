import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../../core/services/settings_service.dart';
import '../../../core/services/platform_service.dart';
import '../../../core/utils/file_utils.dart';

enum CompressStatus { idle, analyzing, compressing, completed, error, unsupported }

class CompressTask {
  final String inputPath;
  final int targetSizeBytes;
  String? outputPath;
  double progress;
  CompressStatus status;
  String? error;
  int? originalSize;
  int? compressedSize;
  Duration? duration;

  CompressTask({
    required this.inputPath,
    required this.targetSizeBytes,
    this.outputPath,
    this.progress = 0,
    this.status = CompressStatus.idle,
    this.error,
    this.originalSize,
    this.compressedSize,
    this.duration,
  });
}

class CompressService extends ChangeNotifier {
  final SettingsService _settings;

  CompressTask? currentTask;
  List<CompressTask> history = [];

  CompressService(this._settings);

  bool get isSupported => PlatformService.isDesktop;

  Future<void> compress(String inputPath, int targetSizeBytes) async {
    if (!isSupported) {
      currentTask = CompressTask(
        inputPath: inputPath,
        targetSizeBytes: targetSizeBytes,
        status: CompressStatus.unsupported,
        error: 'Compression is not supported on mobile.\nPlease use the desktop app.',
      );
      notifyListeners();
      return;
    }

    currentTask = CompressTask(
      inputPath: inputPath,
      targetSizeBytes: targetSizeBytes,
      status: CompressStatus.analyzing,
    );
    notifyListeners();

    try {
      final inputFile = File(inputPath);
      currentTask!.originalSize = await inputFile.length();

      if (currentTask!.originalSize! <= targetSizeBytes) {
        currentTask!.status = CompressStatus.error;
        currentTask!.error = 'Original file is already smaller than target size.';
        notifyListeners();
        return;
      }

      await _compressDesktop(inputPath, targetSizeBytes);

      if (currentTask!.outputPath != null) {
        final outputFile = File(currentTask!.outputPath!);
        currentTask!.compressedSize = await outputFile.length();
      }

      currentTask!.status = CompressStatus.completed;
      history.insert(0, currentTask!);
    } catch (e) {
      currentTask!.status = CompressStatus.error;
      currentTask!.error = e.toString();
    }

    notifyListeners();
  }

  Future<void> _compressDesktop(String inputPath, int targetSizeBytes) async {
    currentTask!.status = CompressStatus.compressing;
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

    // Calculate target bitrate
    final targetBitsPerSecond = (targetSizeBytes * 8 / durationSeconds * 0.95).toInt();
    final videoBitrate = (targetBitsPerSecond * 0.9).toInt(); // 90% for video
    final audioBitrate = 128000; // 128kbps for audio

    final fileName = inputPath.split(Platform.pathSeparator).last;
    final nameWithoutExt = fileName.contains('.')
        ? fileName.substring(0, fileName.lastIndexOf('.'))
        : fileName;
    final outputPath = '${_settings.downloadPath}/${nameWithoutExt}_compressed.mp4';
    final uniquePath = await FileUtils.getUniqueFilePath(outputPath);

    currentTask!.outputPath = uniquePath;

    // Use temp directory for pass log files to avoid permission issues
    final tempDir = Directory.systemTemp;
    final passLogFile = '${tempDir.path}/ffmpeg2pass_${DateTime.now().millisecondsSinceEpoch}';

    // Two-pass encoding for better quality
    final pass1Args = [
      '-y',
      '-i', inputPath,
      '-c:v', 'libx264',
      '-b:v', '${videoBitrate}',
      '-pass', '1',
      '-passlogfile', passLogFile,
      '-an',
      '-f', 'null',
      Platform.isWindows ? 'NUL' : '/dev/null',
    ];

    final pass2Args = [
      '-y',
      '-i', inputPath,
      '-c:v', 'libx264',
      '-b:v', '${videoBitrate}',
      '-pass', '2',
      '-passlogfile', passLogFile,
      '-c:a', 'aac',
      '-b:a', '${audioBitrate}',
      uniquePath,
    ];

    // Pass 1
    final pass1Stderr = StringBuffer();
    final pass1Process = await Process.start(ffmpegPath, pass1Args);
    pass1Process.stderr.transform(const SystemEncoding().decoder).listen((line) {
      pass1Stderr.write(line);
      final progress = _parseFFmpegProgress(line, durationSeconds);
      if (progress != null) {
        currentTask!.progress = progress * 0.5; // First pass = 0-50%
        notifyListeners();
      }
    });

    var exitCode = await pass1Process.exitCode;
    if (exitCode != 0) {
      final errorDetail = _extractFFmpegError(pass1Stderr.toString());
      throw Exception('Compression failed (Pass 1): $errorDetail');
    }

    // Pass 2
    final pass2Stderr = StringBuffer();
    final pass2Process = await Process.start(ffmpegPath, pass2Args);
    pass2Process.stderr.transform(const SystemEncoding().decoder).listen((line) {
      pass2Stderr.write(line);
      final progress = _parseFFmpegProgress(line, durationSeconds);
      if (progress != null) {
        currentTask!.progress = 0.5 + (progress * 0.5); // Second pass = 50-100%
        notifyListeners();
      }
    });

    exitCode = await pass2Process.exitCode;
    if (exitCode != 0) {
      final errorDetail = _extractFFmpegError(pass2Stderr.toString());
      throw Exception('Compression failed (Pass 2): $errorDetail');
    }

    // Cleanup pass log files
    try {
      await File('$passLogFile-0.log').delete();
      await File('$passLogFile-0.log.mbtree').delete();
    } catch (_) {}

    currentTask!.progress = 1.0;
  }

  Future<String> _getFFmpegPath() async {
    if (Platform.isWindows) {
      final exePath = Platform.resolvedExecutable;
      final appDir = File(exePath).parent.path;
      final ffmpegPath = '$appDir/ffmpeg.exe';

      if (await File(ffmpegPath).exists()) {
        return ffmpegPath;
      }
      return 'ffmpeg';
    } else if (Platform.isMacOS) {
      final exePath = Platform.resolvedExecutable;
      final appDir = File(exePath).parent.parent.path;
      final ffmpegPath = '$appDir/Resources/ffmpeg';

      if (await File(ffmpegPath).exists()) {
        return ffmpegPath;
      }
      return 'ffmpeg';
    }
    return 'ffmpeg';
  }

  Future<String> _getFFprobePath() async {
    if (Platform.isWindows) {
      final exePath = Platform.resolvedExecutable;
      final appDir = File(exePath).parent.path;
      final ffprobePath = '$appDir/ffprobe.exe';

      if (await File(ffprobePath).exists()) {
        return ffprobePath;
      }
      return 'ffprobe';
    } else if (Platform.isMacOS) {
      final exePath = Platform.resolvedExecutable;
      final appDir = File(exePath).parent.parent.path;
      final ffprobePath = '$appDir/Resources/ffprobe';

      if (await File(ffprobePath).exists()) {
        return ffprobePath;
      }
      return 'ffprobe';
    }
    return 'ffprobe';
  }

  double? _parseFFmpegProgress(String line, double totalDuration) {
    // time=00:01:23.45
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

  String _extractFFmpegError(String stderr) {
    // Look for the last meaningful error line from ffmpeg
    final lines = stderr.split('\n').where((l) => l.trim().isNotEmpty).toList();
    for (final line in lines.reversed) {
      final trimmed = line.trim();
      if (trimmed.startsWith('Error') ||
          trimmed.startsWith('error') ||
          trimmed.contains('No such file') ||
          trimmed.contains('Invalid') ||
          trimmed.contains('Permission denied') ||
          trimmed.contains('could not')) {
        return trimmed;
      }
    }
    // Return last few lines if no specific error found
    final tail = lines.length > 3 ? lines.sublist(lines.length - 3) : lines;
    return tail.join(' | ');
  }

  void clearCurrentTask() {
    currentTask = null;
    notifyListeners();
  }
}
