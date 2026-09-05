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

  static const _reservedDeviceNames = {
    'CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
  };

  static const _maxFileNameLength = 150;

  /// Unicode `Cf` (format, invisible) and `Cc` (control) characters that
  /// must never survive into a filename: bidi overrides (`U+202A`-`U+202E`,
  /// `U+2066`-`U+2069`) can visually reverse/hide a file's real extension
  /// (the classic RLO spoof: a name ending in `<U+202E>gnp.exe` displays
  /// with its last two segments reversed, i.e. as if it ended in
  /// `exe.png`, while the bytes on disk stay `.exe`), zero-width
  /// characters (`U+200B`-`U+200F`, `U+FEFF`) are invisible but still
  /// distinguish two filenames from each other, and raw control bytes
  /// (`\x00`-`\x1F`, `\x7F`) have no place in a displayed title at all.
  /// Stripped outright (not substituted), unlike the Windows-illegal
  /// characters below, which have a visible replacement.
  static final RegExp _invisibleAndControlChars = RegExp(
    '[\\x00-\\x1F\\x7F\\u200B-\\u200F\\u202A-\\u202E\\u2066-\\u2069\\uFEFF]',
  );

  static String sanitizeFileName(String name) {
    // Remove characters not allowed on Windows.
    var result = name
        .replaceAll(_invisibleAndControlChars, '')
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    // Windows silently drops trailing dots/spaces on a path segment, which
    // can make two different titles collide on disk; strip them ourselves
    // so the name we show the user is the name that actually gets written.
    result = _stripTrailingDotsAndSpaces(result);
    if (result.isEmpty) result = '_';

    if (result.length > _maxFileNameLength) {
      result = _stripTrailingDotsAndSpaces(_truncateAtRuneBoundary(result, _maxFileNameLength));
      if (result.isEmpty) result = '_';
    }

    // Windows reserves these names for devices even with an extension
    // attached (`con.txt` is just as blocked as `con`).
    if (_isReservedDeviceName(result)) {
      result = '_$result';
    }

    return result;
  }

  /// Truncates [value] to at most [maxCodeUnits] UTF-16 code units without
  /// ever splitting a surrogate pair: an emoji or other astral-plane
  /// character that would land exactly on the cut boundary is dropped
  /// whole rather than left as a dangling (invalid) lone surrogate.
  static String _truncateAtRuneBoundary(String value, int maxCodeUnits) {
    if (value.length <= maxCodeUnits) return value;
    final buffer = StringBuffer();
    var used = 0;
    for (final rune in value.runes) {
      final unitLength = rune > 0xFFFF ? 2 : 1;
      if (used + unitLength > maxCodeUnits) break;
      buffer.writeCharCode(rune);
      used += unitLength;
    }
    return buffer.toString();
  }

  static String _stripTrailingDotsAndSpaces(String value) {
    return value.replaceAll(RegExp(r'[. ]+$'), '');
  }

  static bool _isReservedDeviceName(String name) {
    final base = name.contains('.') ? name.substring(0, name.indexOf('.')) : name;
    return _reservedDeviceNames.contains(base.toUpperCase());
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

  /// Test seam: when set, [openFileLocation] and [openFolder] call this
  /// instead of spawning a real OS file-manager process. Tests should set
  /// this (and reset it to null in `tearDown`) whenever they exercise a
  /// success path that reaches either method, so a real Explorer/Finder
  /// window never appears as a side effect of running `flutter test`.
  static Future<void> Function(String path)? folderOpenerOverride;

  /// Open file location in file explorer (Windows/macOS/Linux supported)
  static Future<void> openFileLocation(String filePath) => _open(filePath, select: true);

  /// Open folder (e.g., download folder)
  static Future<void> openFolder(String folderPath) => _open(folderPath, select: false);

  static Future<void> _open(String path, {required bool select}) async {
    final override = folderOpenerOverride;
    if (override != null) {
      await override(path);
      return;
    }
    // Safety net: even if a test forgets to set folderOpenerOverride, never
    // spawn a real file-manager process while running under `flutter test`
    // (which always sets this environment variable).
    if (Platform.environment['FLUTTER_TEST'] == 'true') return;

    if (Platform.isWindows) {
      // Windows accepts both separators for `/select,`, but normalize to
      // match the OS's own convention rather than relying on that.
      final windowsPath = path.replaceAll('/', '\\');
      await Process.run('explorer', select ? ['/select,', windowsPath] : [windowsPath]);
    } else if (Platform.isMacOS) {
      await Process.run('open', select ? ['-R', path] : [path]);
    } else if (Platform.isLinux) {
      // xdg-open only understands folders, so selecting a file location
      // opens its parent directory instead.
      final target = select ? File(path).parent.path : path;
      await Process.run('xdg-open', [target]);
    }
  }
}
