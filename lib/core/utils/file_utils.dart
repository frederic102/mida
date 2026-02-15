import 'dart:io';

class FileUtils {
  static String formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static int parseTargetSize(String input) {
    final lower = input.toLowerCase().trim();
    final numMatch = RegExp(r'[\d.]+').firstMatch(lower);
    if (numMatch == null) return 0;

    final num = double.tryParse(numMatch.group(0)!) ?? 0;

    if (lower.contains('gb')) {
      return (num * 1024 * 1024 * 1024).toInt();
    }
    if (lower.contains('mb')) {
      return (num * 1024 * 1024).toInt();
    }
    if (lower.contains('kb')) {
      return (num * 1024).toInt();
    }

    // Default: assume MB
    return (num * 1024 * 1024).toInt();
  }

  static String sanitizeFileName(String name) {
    // Remove characters not allowed on Windows
    return name
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static Future<String> getUniqueFilePath(String basePath) async {
    final file = File(basePath);
    if (!await file.exists()) return basePath;

    final dir = file.parent.path;
    final extension = basePath.contains('.')
        ? '.${basePath.split('.').last}'
        : '';
    final nameWithoutExt = basePath.contains('.')
        ? basePath.substring(0, basePath.lastIndexOf('.'))
        : basePath;
    final baseName = nameWithoutExt.split(Platform.pathSeparator).last;

    int counter = 1;
    String newPath;
    do {
      newPath = '$dir${Platform.pathSeparator}$baseName ($counter)$extension';
      counter++;
    } while (await File(newPath).exists());

    return newPath;
  }

  static String formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  static String formatProgress(double progress) {
    return '${(progress * 100).toStringAsFixed(1)}%';
  }

  /// Open file location in file explorer (Windows/macOS supported)
  static Future<void> openFileLocation(String filePath) async {
    if (Platform.isWindows) {
      // Windows: explorer /select,"filepath"
      await Process.run('explorer', ['/select,', filePath]);
    } else if (Platform.isMacOS) {
      // macOS: open -R "filepath"
      await Process.run('open', ['-R', filePath]);
    } else if (Platform.isLinux) {
      // Linux: xdg-open (folder only)
      final dir = File(filePath).parent.path;
      await Process.run('xdg-open', [dir]);
    }
  }

  /// Open folder (e.g., download folder)
  static Future<void> openFolder(String folderPath) async {
    if (Platform.isWindows) {
      await Process.run('explorer', [folderPath]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [folderPath]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [folderPath]);
    }
  }
}
