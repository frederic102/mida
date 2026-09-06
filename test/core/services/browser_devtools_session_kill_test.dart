import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/services/browser_devtools_session.dart';

/// `BrowserDevtoolsSession.killAndAwaitExit`'s process-tree sweep, split
/// out of `browser_devtools_session_test.dart` in round 3 (P-R3-6) purely
/// to keep that file under this project's 400-line cap - these tests are
/// unchanged, and spawn no process at all (the fake below is already
/// exited).

/// Minimal `implements Process` stand-in whose `exitCode` is already
/// complete - for exercising `killAndAwaitExit`'s process-tree sweep
/// without spawning (or waiting on) a real OS process.
class _InstantExitFakeProcess implements Process {
  @override
  final int pid;

  /// Shared with a test's own `processTreeKiller` override so the two can
  /// be compared for relative order - see the "process-tree sweep" group
  /// below.
  final List<String>? callOrder;

  _InstantExitFakeProcess({required this.pid, this.callOrder});

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  IOSink get stdin => IOSink(StreamController<List<int>>().sink);

  @override
  Future<int> get exitCode => Future.value(0);

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    callOrder?.add('processKill');
    return true;
  }
}

void main() {
  group('BrowserDevtoolsSession.killAndAwaitExit process-tree sweep', () {
    test('invokes the injected processTreeKiller with the process\'s own pid', () async {
      final process = _InstantExitFakeProcess(pid: 98765);
      int? capturedPid;

      await BrowserDevtoolsSession.killAndAwaitExit(
        process,
        processTreeKiller: (executable, arguments) async {
          capturedPid = int.parse(arguments.last);
          return ProcessResult(0, 0, '', '');
        },
      );

      expect(capturedPid, 98765);
    });

    test('guard can fail: the tree kill is issued before the parent process is killed, not after', () async {
      // Independent review round 2: `taskkill /T` (or `pkill -P` on
      // macOS/Linux) needs a *live* tree to walk - calling it after the
      // parent has already been killed and awaited orphans its children
      // instead of reaching them.
      final callOrder = <String>[];
      final process = _InstantExitFakeProcess(pid: 98765, callOrder: callOrder);

      await BrowserDevtoolsSession.killAndAwaitExit(
        process,
        processTreeKiller: (executable, arguments) async {
          callOrder.add('treeKill');
          return ProcessResult(0, 0, '', '');
        },
      );

      expect(callOrder, ['treeKill', 'processKill']);
    });
  });
}
