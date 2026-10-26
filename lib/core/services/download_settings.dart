import 'dart:io';

/// The two settings the download chain actually reads, as a plain object with
/// no Flutter, no `shared_preferences`, and no `ChangeNotifier`. The GUI's
/// `SettingsService` wraps one of these (and adds persistence + theme); the
/// agent CLI (`lib/cli/`) builds one straight from its arguments.
class DownloadSettings {
  /// Folder finished downloads are written to. Empty until resolved.
  String downloadPath;

  /// "Use browser login session" (privacy: off unless explicitly enabled).
  /// See `docs/plan-phase4-cookies-resilience.md` SCOPE 2.
  bool useBrowserLoginSession;

  DownloadSettings({this.downloadPath = '', this.useBrowserLoginSession = false});

  /// The desktop default download folder: `<home>/Videos/MiDa` (Windows and
  /// Linux) or `<home>/Movies/MiDa` (macOS). Pure path math, does not create
  /// the directory. [environment] and the platform flags exist so tests can
  /// pin the result; production callers pass nothing.
  static String defaultDesktopDownloadPath({
    Map<String, String>? environment,
    bool? isWindows,
    bool? isMacOS,
  }) {
    final env = environment ?? Platform.environment;
    final windows = isWindows ?? Platform.isWindows;
    final macos = isMacOS ?? Platform.isMacOS;
    final home = env['USERPROFILE'] ?? env['HOME'] ?? '';
    final separator = windows ? '\\' : '/';
    final videoFolder = macos ? 'Movies' : 'Videos';
    return '$home$separator$videoFolder${separator}MiDa';
  }
}
