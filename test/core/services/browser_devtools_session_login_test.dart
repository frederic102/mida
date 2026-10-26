import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/services/browser_devtools_session.dart';

/// Launch wiring for the Chrome-only login session. The fake `msedge.exe` is
/// a text file: no browser is ever started.
void main() {
  group('BrowserDevtoolsSession.launch login session is Chrome only', () {
    File fakeEdge() {
      final dir = Directory.systemTemp.createTempSync('mida_cdp_session_edge_only_');
      addTearDown(() {
        try {
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      return File('${dir.path}/msedge.exe')..writeAsStringSync('not a program');
    }

    test('useBrowserLoginSession: true with only msedge.exe present -> BROWSER_MISSING asking for Chrome', () async {
      final edge = fakeEdge();
      await expectLater(
        BrowserDevtoolsSession.launch(candidatePaths: () => [edge.path], useBrowserLoginSession: true),
        throwsA(
          isA<MediaExtractionException>()
              .having((e) => e.status, 'status', 'BROWSER_MISSING')
              .having((e) => e.reason, 'reason', contains('needs Google Chrome')),
        ),
      );
    });

    test('useBrowserLoginSession: false gets past the lookup with the same msedge.exe', () async {
      final edge = fakeEdge();
      Object? thrown;
      try {
        await BrowserDevtoolsSession.launch(
          candidatePaths: () => [edge.path],
          connectTimeout: const Duration(milliseconds: 150),
          preferHeaded: false,
        );
      } catch (e) {
        thrown = e;
      }
      // The text file cannot start, so launch fails later: anything but BROWSER_MISSING proves the lookup passed.
      expect(thrown, isNotNull);
      expect(thrown is MediaExtractionException && thrown.status == 'BROWSER_MISSING', isFalse);
    });
  });
}
