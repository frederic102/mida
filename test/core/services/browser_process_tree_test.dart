import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/services/browser_process_tree.dart';

void main() {
  group('BrowserProcessTree.kill', () {
    test('on a non-Windows platform, never invokes the runner at all', () async {
      var called = false;
      await BrowserProcessTree.kill(
        424242,
        runner: (executable, arguments) async {
          called = true;
          return ProcessResult(0, 0, '', '');
        },
      );

      // This assertion is meaningful only when this suite itself runs on
      // a non-Windows platform; guarded below so it stays correct either
      // way rather than silently mis-asserting on Windows CI.
      if (!Platform.isWindows) {
        expect(called, isFalse);
      }
    });

    test('on Windows, invokes taskkill /T /F /PID <pid> through the injected runner', () async {
      if (!Platform.isWindows) return;
      String? capturedExecutable;
      List<String>? capturedArgs;

      await BrowserProcessTree.kill(
        13579,
        runner: (executable, arguments) async {
          capturedExecutable = executable;
          capturedArgs = arguments;
          return ProcessResult(0, 0, '', '');
        },
      );

      expect(capturedExecutable, 'taskkill');
      // Guard can fail: dropping `/T` (the whole-tree flag) from
      // BrowserProcessTree.kill's argument list would leave this
      // `contains` assertion red - the whole point of this class over a
      // bare `Process.kill` is exactly that flag.
      expect(capturedArgs, contains('/T'));
      expect(capturedArgs, contains('/F'));
      expect(capturedArgs, containsAllInOrder(['/PID', '13579']));
    });

    test('a runner that throws does not propagate (best-effort only)', () async {
      if (!Platform.isWindows) return;
      await BrowserProcessTree.kill(
        1,
        runner: (executable, arguments) async => throw const OSError('taskkill missing'),
      );
      // Reaching here at all is the assertion.
    });
  });
}
