import 'dart:io';

import 'browser_profile.dart';

/// The two per-launch resources `BrowserDevtoolsSession.launch` needs
/// before it can start a process at all (a free debugging port, a
/// `--user-data-dir`) - split out to keep that file under this project's
/// 400-line cap.
class BrowserLaunchResources {
  const BrowserLaunchResources._();

  static Future<int> reserveFreePort() async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    return port;
  }

  /// A fresh empty temp dir, unless [useBrowserLoginSession] is on and
  /// staging [executable]'s real profile (see [BrowserProfile]) succeeds -
  /// staging failure (unknown browser kind, no profile present, copy
  /// error) falls back to the same empty temp dir as when the toggle is
  /// off, never throws. Same fallback shape as
  /// `BrowserPageFetcher._resolveProfileDir`.
  static Future<Directory> resolveProfileDir(
    String executable, {
    required bool useBrowserLoginSession,
    Future<Directory?> Function(BrowserProfileKind kind)? stageProfileDir,
  }) async {
    if (useBrowserLoginSession) {
      final kind = BrowserProfile.kindForExecutable(executable);
      if (kind != null) {
        final stage = stageProfileDir ?? BrowserProfile.stageCopy;
        final staged = await stage(kind);
        if (staged != null) return staged;
      }
    }
    return Directory.systemTemp.createTempSync('mida_cdp_');
  }
}
