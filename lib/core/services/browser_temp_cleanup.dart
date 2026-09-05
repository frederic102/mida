import 'dart:io';

/// Sweeps this app's own leftover `mida_cdp_*`/`mida_profile_*` temp
/// directories on browser-capture startup. Split out of
/// `browser_devtools_session.dart` to keep that file under this project's
/// 400-line cap.
///
/// Every one of these directories is already meant to be deleted by the
/// launch/close path that created it (`BrowserDevtoolsSession._launchAttempt`'s
/// catch block, `BrowserProfile.cleanup`, `BrowserDevtoolsSession.close`);
/// this exists only to catch what that per-launch cleanup could not (a
/// locked file that outlived its own retry, a process crash that skipped
/// cleanup entirely) - a slow accumulation of empty-ish temp dirs, not a
/// security boundary.
class BrowserTempCleanup {
  const BrowserTempCleanup._();

  static const List<String> _ownedPrefixes = ['mida_cdp_', 'mida_profile_'];

  /// Deletes every top-level entry of [tempDir] (defaults to
  /// [Directory.systemTemp]) whose name starts with one of
  /// [_ownedPrefixes] and whose last-modified time is older than [maxAge].
  /// Best-effort and always completes without throwing: a locked directory,
  /// a permissions error, or the temp dir listing itself failing only
  /// means this run's sweep skipped that entry (or all of them) - never a
  /// capture failure.
  static Future<void> sweepStale({
    Duration maxAge = const Duration(hours: 1),
    Directory? tempDir,
  }) async {
    final root = tempDir ?? Directory.systemTemp;
    final cutoff = DateTime.now().subtract(maxAge);

    List<FileSystemEntity> entries;
    try {
      entries = root.listSync();
    } catch (_) {
      return;
    }

    for (final entry in entries) {
      if (entry is! Directory) continue;
      final name = entry.path.split(Platform.pathSeparator).last;
      if (!_ownedPrefixes.any(name.startsWith)) continue;
      try {
        final stat = await entry.stat();
        if (stat.modified.isBefore(cutoff)) {
          await entry.delete(recursive: true);
        }
      } catch (_) {
        // One locked/already-gone directory must not stop the sweep of
        // the rest.
      }
    }
  }

  /// Deletes one just-finished launch's own profile dir, retrying once
  /// after a short delay (a just-killed browser process's profile files
  /// can stay briefly locked - Windows file-handle release, antivirus
  /// scan - and one short wait clears most of these). Returns whether the
  /// directory is confirmed gone (or never existed) - false only when a
  /// lock outlived the retry too, so a caller with its own failure to
  /// report (see `BrowserDevtoolsSession.launch`) can mention that a stray
  /// temp dir may remain, rather than staying silent about it.
  static Future<bool> deleteQuietly(Directory dir) async {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      return true;
    } catch (_) {
      // Retried once below.
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      return true;
    } catch (_) {
      return false;
    }
  }
}
