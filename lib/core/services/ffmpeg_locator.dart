import 'dart:io';

import 'package:path/path.dart' as p;

/// Single source for finding the ffmpeg/ffprobe executables bundled next to
/// the app. Extracted so compress/extract/download all resolve the same
/// way instead of each carrying its own copy.
///
/// Resolution order:
/// 1. `MIDA_FFMPEG_PATH` ([envVar]), but only when the caller passes an
///    explicit `environment` map. The agent CLI does that per run; the GUI
///    passes nothing, so a stray `MIDA_FFMPEG_PATH` in the user's
///    environment never redirects the GUI to another executable.
/// 2. The copy next to the running executable (macOS: `Resources/`).
/// 3. The first absolute `PATH` directory that holds the executable.
///
/// Never a bare name: Windows `CreateProcess` searches the current
/// directory for a bare name before `PATH`, so a planted `ffmpeg.exe` in
/// the working folder would run. When nothing is found, the (missing)
/// bundled path is returned so the spawn fails with a clear
/// `ProcessException` naming it.
class FfmpegLocator {
  const FfmpegLocator._();

  /// Environment variable holding either a directory that contains
  /// `ffmpeg.exe`/`ffprobe.exe`, or the path to the ffmpeg executable itself
  /// (its sibling `ffprobe` is then used for ffprobe). Must be absolute.
  static const envVar = 'MIDA_FFMPEG_PATH';

  static Future<String> ffmpegPath({Map<String, String>? environment, String? appDir, bool? isWindows}) =>
      _resolve('ffmpeg', environment, appDir, isWindows ?? Platform.isWindows);

  static Future<String> ffprobePath({Map<String, String>? environment, String? appDir, bool? isWindows}) =>
      _resolve('ffprobe', environment, appDir, isWindows ?? Platform.isWindows);

  /// Why [envVar] in [environment] is set but unusable, or null when it is
  /// unset, valid, or [environment] is null (GUI). [ffmpegPath] still falls
  /// back to the bundled/PATH copies in that case; a caller that wants to
  /// fail loudly instead (the CLI) asks this first.
  static Future<String?> overrideProblem({Map<String, String>? environment}) async {
    if (environment == null) return null;
    final raw = environment[envVar]?.trim();
    if (raw == null || raw.isEmpty) return null;
    if (await _fromOverride('ffmpeg', environment, Platform.isWindows) != null) return null;
    return '$envVar="$raw" is not an absolute path to a directory containing '
        '${_exeName('ffmpeg', Platform.isWindows)} or to an existing ffmpeg executable.';
  }

  static String _exeName(String base, bool windows) => windows ? '$base.exe' : base;

  static Future<String?> _fromOverride(String base, Map<String, String> environment, bool windows) async {
    final raw = environment[envVar]?.trim();
    if (raw == null || raw.isEmpty || !p.isAbsolute(raw)) return null;
    final String candidate;
    switch (await FileSystemEntity.type(raw)) {
      case FileSystemEntityType.directory:
        candidate = p.join(raw, _exeName(base, windows));
      case FileSystemEntityType.file:
        candidate = base == 'ffmpeg' ? raw : p.join(p.dirname(raw), _exeName(base, windows));
      default:
        return null;
    }
    return await File(candidate).exists() ? candidate : null;
  }

  /// Folder of the running executable that should hold the bundled copy.
  static String _defaultAppDir() {
    final exeDir = File(Platform.resolvedExecutable).parent;
    return Platform.isMacOS ? p.join(exeDir.parent.path, 'Resources') : exeDir.path;
  }

  static Future<String> _resolve(
    String base,
    Map<String, String>? environment,
    String? appDir,
    bool windows,
  ) async {
    if (environment != null) {
      final overridden = await _fromOverride(base, environment, windows);
      if (overridden != null) return overridden;
    }
    final bundled = p.join(appDir ?? _defaultAppDir(), _exeName(base, windows));
    if (await File(bundled).exists()) return bundled;
    final onPath = await searchPath(_exeName(base, windows), environment ?? Platform.environment, windows: windows);
    return onPath ?? bundled;
  }

  /// First absolute directory in the `PATH` of [environment] containing
  /// [fileName]. Relative and empty entries are skipped: they resolve
  /// against the current directory, which is exactly what this avoids.
  static Future<String?> searchPath(String fileName, Map<String, String> environment, {required bool windows}) async {
    final raw = _pathValue(environment);
    if (raw == null || raw.isEmpty) return null;
    for (var dir in raw.split(windows ? ';' : ':')) {
      dir = dir.trim();
      if (dir.length >= 2 && dir.startsWith('"') && dir.endsWith('"')) dir = dir.substring(1, dir.length - 1);
      if (dir.isEmpty || !_isAbsolute(dir, windows)) continue;
      final candidate = p.join(dir, fileName);
      if (await File(candidate).exists()) return candidate;
    }
    return null;
  }

  /// Fully qualified only: `C:\dir` or a UNC `\\server\share`. A
  /// root-relative `\dir` or drive-relative `C:dir` depends on the current
  /// drive or folder, so it does not count.
  static bool _isAbsolute(String dir, bool windows) =>
      windows ? RegExp(r'^[A-Za-z]:[\\/]').hasMatch(dir) || dir.startsWith(r'\\') : dir.startsWith('/');

  static String? _pathValue(Map<String, String> environment) {
    final direct = environment['PATH'] ?? environment['Path'];
    if (direct != null) return direct;
    for (final entry in environment.entries) {
      if (entry.key.toUpperCase() == 'PATH') return entry.value;
    }
    return null;
  }
}
