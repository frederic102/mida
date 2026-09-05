import 'dart:io';

/// Belt-and-suspenders process-tree termination for a launched browser.
/// Split out of `browser_devtools_session.dart` to keep that file under
/// this project's 400-line cap.
///
/// `Process.kill()` (even escalated to `ProcessSignal.sigkill`) only
/// terminates the one PID it was called on. On Windows, a browser's child
/// processes (GPU process, renderer(s), utility/network service) are not
/// automatically terminated when their parent is, unless the parent was
/// launched inside a Job Object - which `BrowserDevtoolsSession` does not
/// do. Left alone, a killed `msedge.exe` can leave its whole child fleet
/// running as orphans. `taskkill /T /F` explicitly walks and kills the
/// entire tree rooted at a PID.
class BrowserProcessTree {
  const BrowserProcessTree._();

  /// Best-effort, never throws: [pid] having already fully exited by the
  /// time this runs (`taskkill`'s own "not found" outcome), `taskkill`
  /// itself being unavailable, or any other OS error is swallowed - the
  /// caller's own SIGTERM/SIGKILL attempts already tried, and this is only
  /// a final sweep for whatever those could not reach. A no-op on any
  /// platform other than Windows (no equivalent tree-kill primitive is
  /// wired here yet - `Process.kill` already reaches the whole tree on
  /// POSIX when the browser was launched in its own process group, which
  /// this class does not attempt to change).
  static Future<void> kill(
    int pid, {
    Future<ProcessResult> Function(String executable, List<String> arguments)? runner,
  }) async {
    if (!Platform.isWindows) return;
    final run = runner ?? Process.run;
    try {
      await run('taskkill', ['/T', '/F', '/PID', '$pid']);
    } catch (_) {
      // Nothing further to try; see class doc.
    }
  }
}
