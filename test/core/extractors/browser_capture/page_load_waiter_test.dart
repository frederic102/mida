import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/browser_capture/captured_media_classifier.dart';
import 'package:mida/core/extractors/browser_capture/page_load_waiter.dart';
import 'package:mida/core/services/browser_devtools_session.dart';
import 'package:mida/core/services/cdp_client.dart';

/// A DevtoolsSession stub with a controllable event stream (no send/eval
/// needed - PageLoadWaiter only ever listens).
class _EventStreamSession implements DevtoolsSession {
  final _controller = StreamController<CdpEvent>.broadcast();

  void emit(String method) => _controller.add(CdpEvent(method: method, params: const {}));

  @override
  Stream<CdpEvent> get events => _controller.stream;

  @override
  List<String> get childSessionIds => const [];

  @override
  Future<Map<String, dynamic>> send(String method, [Map<String, dynamic>? params]) async => const {};

  @override
  Future<Map<String, dynamic>> sendBrowserLevel(String method, [Map<String, dynamic>? params]) async => const {};

  @override
  Future<Map<String, dynamic>> sendToSession(String sessionId, String method, [Map<String, dynamic>? params]) async =>
      const {};

  @override
  Future<void> close() async {}
}

void main() {
  group('PageLoadWaiter.wait', () {
    test('returns true as soon as Page.loadEventFired arrives', () async {
      final session = _EventStreamSession();
      final future = PageLoadWaiter.wait(session, {}, loadTimeout: const Duration(seconds: 30));
      session.emit('Page.loadEventFired');

      expect(await future, isTrue);
    });

    test('guard can fail: returns before loadTimeout once candidates becomes non-empty, '
        'even though Page.loadEventFired never arrives at all', () async {
      // Bilibili diagnostic run (docs/plan-phase5-coverage.md): real media
      // requests can start well before a heavy page's own load event
      // fires at all - waiting out the full loadTimeout regardless would
      // waste that time for nothing.
      final session = _EventStreamSession();
      final candidates = <String, CapturedMediaCandidate>{};
      final stopwatch = Stopwatch()..start();

      final future = PageLoadWaiter.wait(session, candidates, loadTimeout: const Duration(seconds: 30));
      Future<void>.delayed(const Duration(milliseconds: 50), () {
        candidates['k'] = const CapturedMediaCandidate(url: 'https://cdn.example.com/a.mp4', container: 'mp4');
      });

      final loadFired = await future;
      stopwatch.stop();

      expect(loadFired, isFalse); // the load event itself never arrived
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('returns false once loadTimeout elapses with neither signal', () async {
      final session = _EventStreamSession();
      final result = await PageLoadWaiter.wait(session, {}, loadTimeout: const Duration(milliseconds: 50));
      expect(result, isFalse);
    });
  });
}
