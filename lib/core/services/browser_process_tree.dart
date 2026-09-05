import 'dart:io';

/// Belt-and-suspenders process-tree termination for a launched browser.
/// Split out of `browser_devtools_session.dart` to keep that file under
/// this project's 400-line cap.
///
/// `Process.kill()` (even escalated to `ProcessSignal.sigkill`) only
/// terminates the one PID it was called on. A browser's child processes
/// (GPU process, renderer(s), utility/network service) are not
/// automatically terminated when their parent is, unless the parent was
/// launched inside a Windows Job Object or its own POSIX process group -
/// neither of which `BrowserDevtoolsSession` sets up. Left alone, a killed
/// browser process can leave its whole child fleet running as orphans.
class BrowserProcessTree {
  const BrowserProcessTree._();

  /// Best-effort, never throws: [pid] having already fully exited, the
  /// platform tool being unavailable, or any other OS error is swallowed -
  /// this exists to reach what the caller's own SIGTERM/SIGKILL on the
  /// parent alone cannot. Must be called (see `killAndAwaitExit`) *before*
  /// the parent itself is killed, not after - see [_treeKillArgs]'s own
  /// doc.
  static Future<void> kill(
    int pid, {
    Future<ProcessResult> Function(String executable, List<String> arguments)? runner,
  }) async {
    final run = runner ?? Process.run;
    final args = _treeKillArgs(pid);
    try {
      await run(args.$1, args.$2);
    } catch (_) {
      // Nothing further to try; see class doc.
    }
  }

  /// `(executable, arguments)` for this platform's own tree-kill tool.
  ///
  /// Windows: `taskkill /T /F /PID <pid>` walks and force-kills the entire
  /// *live* tree rooted at [pid] in one call - it must run while the
  /// parent is still alive, since Windows can no longer reliably attribute
  /// descendants to a pid that has already exited.
  ///
  /// macOS/Linux: `pkill -P <pid>` kills every process whose own parent
  /// pid is [pid] - not a full recursive tree-kill (a grandchild survives
  /// this alone if the browser reparents further descendants away from
  /// its own immediate children), but the same best-effort spirit as
  /// Windows' own sweep: `BrowserDevtoolsSession` does not launch the
  /// browser in its own process group, so this is the lighter-weight
  /// alternative to that.
  static (String, List<String>) _treeKillArgs(int pid) {
    if (Platform.isWindows) return ('taskkill', ['/T', '/F', '/PID', '$pid']);
    return ('pkill', ['-P', '$pid']);
  }
}
