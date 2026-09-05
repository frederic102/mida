import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/services/browser_devtools_session.dart';

/// Unlike `_FakeProcess` in the other test files (which auto-completes
/// `exitCode` the instant `kill()` is called, so `close()` in those tests
/// returns promptly), this one lets a test control *exactly* when the
/// process appears to exit - the only way to prove
/// `BrowserDevtoolsSession.killAndAwaitExit` really waits for that instead
/// of racing ahead to delete the profile dir.
class _ControllableFakeProcess implements Process {
  final List<ProcessSignal> killSignals = [];
  final _exitCodeCompleter = Completer<int>();

  @override
  int get pid => 1;

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  IOSink get stdin => IOSink(StreamController<List<int>>().sink);

  @override
  Future<int> get exitCode => _exitCodeCompleter.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killSignals.add(signal);
    return true;
  }

  void completeExit() {
    if (!_exitCodeCompleter.isCompleted) _exitCodeCompleter.complete(0);
  }
}

void main() {
  group('BrowserDevtoolsSession.killAndAwaitExit', () {
    test('waits for exitCode to actually complete before returning (no delete-before-exit race)', () async {
      final process = _ControllableFakeProcess();
      var finished = false;

      // A no-op fake processTreeKiller: killAndAwaitExit now runs the
      // tree-kill *before* the parent's own kill/wait (independent review
      // round 2 - taskkill/pkill need a still-live tree to act on), so
      // without this override this test would spawn a real OS process
      // trying to tree-kill fake pid 1, adding real (if usually brief)
      // wall-clock latency ahead of the `process.kill()` this test's own
      // timing assertions are about.
      final future = BrowserDevtoolsSession.killAndAwaitExit(
        process,
        processTreeKiller: (executable, arguments) async => ProcessResult(0, 0, '', ''),
      ).then((_) => finished = true);

      // The process has been asked to terminate but has not "exited" yet;
      // killAndAwaitExit must still be waiting.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(process.killSignals, [ProcessSignal.sigterm]);
      // Guard can fail: a fire-and-forget `process.kill()` with no await
      // on `exitCode` (the pre-fix shape) would already have set
      // `finished = true` here - this is exactly the race a caller
      // deleting the profile dir immediately after would lose.
      expect(finished, isFalse);

      process.completeExit();
      await future;
      expect(finished, isTrue);
      // Never had to escalate: a single SIGTERM was enough.
      expect(process.killSignals, [ProcessSignal.sigterm]);
    });

    test('escalates to SIGKILL and waits again when exitCode never resolves within the timeout', () async {
      final process = _ControllableFakeProcess(); // completeExit() deliberately never called.

      await BrowserDevtoolsSession.killAndAwaitExit(
        process,
        timeout: const Duration(milliseconds: 100),
        processTreeKiller: (executable, arguments) async => ProcessResult(0, 0, '', ''),
      );

      expect(process.killSignals, [ProcessSignal.sigterm, ProcessSignal.sigkill]);
    });
  });
}
