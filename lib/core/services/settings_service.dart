import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService extends ChangeNotifier {
  static const String _keyDownloadPath = 'download_path';
  static const String _keyThemeMode = 'theme_mode';
  static const String _keyUseBrowserLoginSession = 'use_browser_login_session';

  SharedPreferences? _prefs;
  String _downloadPath = '';
  bool _isDarkMode = false;

  /// Settings: "Use browser login session". Off by default (privacy: no
  /// profile copy happens unless explicitly turned on). See
  /// `docs/plan-phase4-cookies-resilience.md` SCOPE 2.
  bool _useBrowserLoginSession = false;

  // Web fallback storage (for HTTP environments where localStorage is blocked)
  final Map<String, dynamic> _memoryStorage = {};
  bool _useMemoryStorage = false;

  String get downloadPath => _downloadPath;
  bool get isDarkMode => _isDarkMode;
  bool get useBrowserLoginSession => _useBrowserLoginSession;

  Future<void> init() async {
    if (kIsWeb) {
      try {
        _prefs = await SharedPreferences.getInstance();
        _downloadPath = _prefs!.getString(_keyDownloadPath) ?? '';
        _isDarkMode = _prefs!.getBool(_keyThemeMode) ?? false;
        _useBrowserLoginSession = _prefs!.getBool(_keyUseBrowserLoginSession) ?? false;
      } catch (e) {
        debugPrint('SharedPreferences blocked, using memory storage: $e');
        _useMemoryStorage = true;
        _downloadPath = '';
        _isDarkMode = false;
        _useBrowserLoginSession = false;
      }
    } else {
      _prefs = await SharedPreferences.getInstance();
      _downloadPath = _prefs!.getString(_keyDownloadPath) ?? await _getDefaultDownloadPath();
      _isDarkMode = _prefs!.getBool(_keyThemeMode) ?? false;
      _useBrowserLoginSession = _prefs!.getBool(_keyUseBrowserLoginSession) ?? false;
    }
    notifyListeners();
  }

  Future<String> _getDefaultDownloadPath() async {
    if (kIsWeb) {
      return '';
    }
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '';
      final separator = Platform.isWindows ? '\\' : '/';
      // Windows: Videos folder, macOS: Movies folder
      final videoFolder = Platform.isWindows ? 'Videos' : (Platform.isMacOS ? 'Movies' : 'Videos');
      final downloadsDir = Directory('$home$separator$videoFolder${separator}MiDa');
      if (!await downloadsDir.exists()) {
        await downloadsDir.create(recursive: true);
      }
      return downloadsDir.path;
    } else if (Platform.isAndroid) {
      // Android: Use app-specific external storage (no permission required)
      final externalDir = await getExternalStorageDirectory();
      if (externalDir != null) {
        // /storage/emulated/0/Android/data/com.mida.mida/files/MiDa
        final midaDir = Directory('${externalDir.path}/MiDa');
        if (!await midaDir.exists()) {
          await midaDir.create(recursive: true);
        }
        debugPrint('Android download path: ${midaDir.path}');
        return midaDir.path;
      }
      // fallback to app documents
      final dir = await getApplicationDocumentsDirectory();
      final midaDir = Directory('${dir.path}/MiDa');
      if (!await midaDir.exists()) {
        await midaDir.create(recursive: true);
      }
      return midaDir.path;
    } else {
      final dir = await getApplicationDocumentsDirectory();
      final midaDir = Directory('${dir.path}/MiDa');
      if (!await midaDir.exists()) {
        await midaDir.create(recursive: true);
      }
      return midaDir.path;
    }
  }

  Future<void> setDownloadPath(String path) async {
    _downloadPath = path;
    if (_useMemoryStorage) {
      _memoryStorage[_keyDownloadPath] = path;
    } else {
      await _prefs?.setString(_keyDownloadPath, path);
    }
    notifyListeners();
  }

  Future<void> setDarkMode(bool value) async {
    _isDarkMode = value;
    if (_useMemoryStorage) {
      _memoryStorage[_keyThemeMode] = value;
    } else {
      await _prefs?.setBool(_keyThemeMode, value);
    }
    notifyListeners();
  }

  Future<void> toggleTheme() async {
    await setDarkMode(!_isDarkMode);
  }

  Future<void> setUseBrowserLoginSession(bool value) async {
    _useBrowserLoginSession = value;
    if (_useMemoryStorage) {
      _memoryStorage[_keyUseBrowserLoginSession] = value;
    } else {
      await _prefs?.setBool(_keyUseBrowserLoginSession, value);
    }
    notifyListeners();
  }
}
