import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/services/interactive_session_detector.dart';

// The launch-level MIDA_HEADLESS tests (fake .bat browser) live in
// browser_devtools_session_test.dart's lifecycle group; see the comment there.
void main() {
  group('InteractiveSessionDetector headless decision (pure)', () {
    test('MIDA_HEADLESS truthy values force headless, others do not', () {
      for (final v in ['1', 'true', 'TRUE', 'yes', ' 1 ']) {
        expect(InteractiveSessionDetector.isHeadlessForced(environment: {'MIDA_HEADLESS': v}), isTrue, reason: v);
      }
      for (final v in ['', '0', 'false', 'no']) {
        expect(InteractiveSessionDetector.isHeadlessForced(environment: {'MIDA_HEADLESS': v}), isFalse, reason: v);
      }
      expect(InteractiveSessionDetector.isHeadlessForced(environment: const {}), isFalse);
    });

    test('MIDA_HEADLESS=1 vetoes headed even with an interactive session and preferHeaded', () {
      const interactive = {'SESSIONNAME': 'Console'};
      expect(InteractiveSessionDetector.shouldTryHeaded(preferHeaded: true, environment: interactive), isTrue);
      expect(
        InteractiveSessionDetector.shouldTryHeaded(
          preferHeaded: true,
          environment: {...interactive, 'MIDA_HEADLESS': '1'},
        ),
        isFalse,
      );
      expect(InteractiveSessionDetector.shouldTryHeaded(preferHeaded: false, environment: interactive), isFalse);
    });
  }, skip: Platform.isWindows ? false : 'SESSIONNAME semantics are Windows-only');
}
