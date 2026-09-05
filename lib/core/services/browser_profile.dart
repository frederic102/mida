import 'dart:io';

/// Real installed browsers this class knows how to locate and stage a
/// cookie-only profile copy for. Firefox, Safari, Brave, Vivaldi, and any
/// browser synced through the cloud are out of scope (see
/// `docs/plan-phase4-cookies-resilience.md` OUT OF SCOPE): those cases fall
/// back to an empty profile exactly as before.
enum BrowserProfileKind { edge, chrome }

/// Lets a headless browser launch load the user's own login session by
/// pointing `--user-data-dir` at a staged **copy** of the real profile,
/// instead of this app reading or decrypting the cookie database itself.
///
/// This is deliberately not an "info stealer" shortcut: we never open the
/// `Cookies` SQLite file, never touch DPAPI, and never hold a cookie value
/// in this process's memory. We copy two files (an encrypted cookie store
/// and the `Local State` file holding the key it was encrypted with) into a
/// throwaway directory shaped like a real profile, then let the browser we
/// already launch (Edge/Chrome) open its own cookies the normal way. Spec:
/// `docs/plan-phase4-cookies-resilience.md` SCOPE 1 (revised 2026-09-05).
///
/// `Login Data` (saved passwords/autofill), browsing history, bookmarks,
/// extensions, and every other profile file are never copied.
class BrowserProfile {
  const BrowserProfile._();

  /// Infers which real profile to stage from the executable path
  /// `BrowserExecutableLocator.find` resolved (e.g. a path ending in
  /// `msedge.exe` maps to [BrowserProfileKind.edge]). Returns null for a
  /// resolved browser this class does not know a profile layout for
  /// (Brave, Vivaldi): callers must treat that exactly like "no profile
  /// available" and fall back to an empty one.
  static BrowserProfileKind? kindForExecutable(String executablePath) {
    final lower = executablePath.toLowerCase();
    if (lower.contains('msedge') || lower.contains('microsoft edge')) {
      return BrowserProfileKind.edge;
    }
    if (lower.contains('chrome')) return BrowserProfileKind.chrome;
    return null;
  }

  /// The real, in-use profile root (Chromium's "User Data" directory) for
  /// [kind] on this OS, or null on a platform this class does not know a
  /// path for (Linux is out of scope per the plan: Windows Edge/Chrome +
  /// macOS equivalents only). Exposed (not inlined into [stageCopy]) so a
  /// test can assert the path shape without touching the real filesystem.
  static Directory? realUserDataDir(BrowserProfileKind kind, {Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    if (Platform.isWindows) {
      final localAppData = env['LOCALAPPDATA'];
      if (localAppData == null || localAppData.isEmpty) return null;
      switch (kind) {
        case BrowserProfileKind.edge:
          return Directory('$localAppData\\Microsoft\\Edge\\User Data');
        case BrowserProfileKind.chrome:
          return Directory('$localAppData\\Google\\Chrome\\User Data');
      }
    }
    if (Platform.isMacOS) {
      final home = env['HOME'];
      if (home == null || home.isEmpty) return null;
      switch (kind) {
        case BrowserProfileKind.edge:
          return Directory('$home/Library/Application Support/Microsoft Edge');
        case BrowserProfileKind.chrome:
          return Directory('$home/Library/Application Support/Google/Chrome');
      }
    }
    return null;
  }

  /// Stages a cookie-only copy of [kind]'s real profile into a fresh temp
  /// directory shaped like a Chromium `--user-data-dir` (`Local State` at
  /// the root, `Default/Network/Cookies` [+ `-journal` if present]
  /// underneath), and returns that directory. The real profile's `Default`
  /// folder is never opened for anything except copying those two exact
  /// files: nothing else in it (`Login Data`, `History`, `Bookmarks`,
  /// `Extensions`, ...) is read, copied, or referenced.
  ///
  /// Returns null, and never throws, when the real profile does not exist
  /// or has no cookie store (nothing logged in), or the copy fails for any
  /// reason (locked file, permission denied, disk full): callers must treat
  /// null exactly like "no login session available" and fall back to an
  /// empty profile, never crash the capture. Only ever logs the coarse
  /// outcome ("staged"/"none"), never a path or file content.
  static Future<Directory?> stageCopy(
    BrowserProfileKind kind, {
    Directory? realUserDataDirOverride,
    Map<String, String>? environment,
  }) async {
    final realDir = realUserDataDirOverride ?? realUserDataDir(kind, environment: environment);
    if (realDir == null || !await realDir.exists()) return _reportNone();

    final sep = Platform.pathSeparator;
    final cookiesFile = File('${realDir.path}${sep}Default${sep}Network${sep}Cookies');
    if (!await cookiesFile.exists()) return _reportNone();

    Directory? staged;
    try {
      staged = Directory.systemTemp.createTempSync('mida_profile_');
      final localState = File('${realDir.path}${sep}Local State');
      if (await localState.exists()) {
        await localState.copy('${staged.path}${sep}Local State');
      }

      final stagedNetworkDir = Directory('${staged.path}${sep}Default${sep}Network');
      await stagedNetworkDir.create(recursive: true);
      await cookiesFile.copy('${stagedNetworkDir.path}${sep}Cookies');

      final journal = File('${cookiesFile.path}-journal');
      if (await journal.exists()) {
        await journal.copy('${stagedNetworkDir.path}${sep}Cookies-journal');
      }

      _report('staged');
      return staged;
    } catch (_) {
      if (staged != null) await cleanup(staged);
      return _reportNone();
    }
  }

  /// Deletes a directory returned by [stageCopy]. Best-effort: a
  /// transiently locked file (the browser process that used it not fully
  /// exited yet) must never mask whatever result or error the caller
  /// already has.
  static Future<void> cleanup(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Best-effort cleanup only; see doc above.
    }
  }

  static Directory? _reportNone() {
    _report('none');
    return null;
  }

  static void _report(String outcome) {
    // Coarse-only per SCOPE 2 ("보안: ... 프로필 경로/내용 로그 금지"): never a
    // path or file content, just whether staging happened.
    stderr.writeln('[BrowserProfile] profile copy: $outcome');
  }
}
