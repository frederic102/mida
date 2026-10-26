import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/services/download_settings.dart';

/// GUI settings, persisted with `shared_preferences`. Lives in
/// `lib/features/settings` (not `lib/core`) because it needs Flutter;
/// `lib/core` stays Flutter-free so the agent CLI can compile it. The CLI
/// uses [DownloadSettings] directly.
///
/// There is no theme setting: the app ships one (dark) theme, so the old
/// "Dark Mode" switch was removed rather than left as a control that did
/// nothing.
class SettingsService extends ChangeNotifier {
  static const String _keyDownloadPath = 'download_path';
  static const String _keyUseBrowserLoginSession = 'use_browser_login_session';
  static const String keyOpenFolderAfterDownload = 'open_folder_after_download';

  SharedPreferences? _prefs;

  /// The Flutter-free part (download folder + "Use browser login session",
  /// off by default: no profile copy happens unless explicitly turned on,
  /// see `docs/plan-phase4-cookies-resilience.md` SCOPE 2).
  final DownloadSettings _download = DownloadSettings();

  bool _openFolderAfterDownload = true;

  DownloadSettings get downloadSettings => _download;
  String get downloadPath => _download.downloadPath;
  bool get useBrowserLoginSession => _download.useBrowserLoginSession;

  /// Whether the download folder opens once the queue finishes a batch
  /// with at least one saved file. On by default.
  bool get openFolderAfterDownload => _openFolderAfterDownload;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _download.downloadPath = _prefs!.getString(_keyDownloadPath) ?? await _getDefaultDownloadPath();
    _download.useBrowserLoginSession = _prefs!.getBool(_keyUseBrowserLoginSession) ?? false;
    _openFolderAfterDownload = _prefs!.getBool(keyOpenFolderAfterDownload) ?? true;
    notifyListeners();
  }

  Future<String> _getDefaultDownloadPath() async {
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      // Windows/Linux: Videos folder, macOS: Movies folder
      final downloadsDir = Directory(DownloadSettings.defaultDesktopDownloadPath());
      if (!await downloadsDir.exists()) {
        await downloadsDir.create(recursive: true);
      }
      return downloadsDir.path;
    }
    if (Platform.isAndroid) {
      // Android: app-specific external storage (no permission required).
      final externalDir = await getExternalStorageDirectory();
      if (externalDir != null) {
        final midaDir = Directory('${externalDir.path}/MiDa');
        if (!await midaDir.exists()) {
          await midaDir.create(recursive: true);
        }
        return midaDir.path;
      }
    }
    final dir = await getApplicationDocumentsDirectory();
    final midaDir = Directory('${dir.path}/MiDa');
    if (!await midaDir.exists()) {
      await midaDir.create(recursive: true);
    }
    return midaDir.path;
  }

  Future<void> setDownloadPath(String path) async {
    _download.downloadPath = path;
    await _prefs?.setString(_keyDownloadPath, path);
    notifyListeners();
  }

  Future<void> setUseBrowserLoginSession(bool value) async {
    _download.useBrowserLoginSession = value;
    await _prefs?.setBool(_keyUseBrowserLoginSession, value);
    notifyListeners();
  }

  Future<void> setOpenFolderAfterDownload(bool value) async {
    if (value == _openFolderAfterDownload) return;
    _openFolderAfterDownload = value;
    await _prefs?.setBool(keyOpenFolderAfterDownload, value);
    notifyListeners();
  }
}
