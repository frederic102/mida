import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/browser_capture/capture_drive_loop.dart';
import 'package:mida/core/extractors/browser_capture/captured_media_classifier.dart';
import 'package:mida/core/services/browser_devtools_session.dart';
import 'package:mida/core/services/cdp_client.dart';

/// A DevtoolsSession stub whose only job is to count `Runtime.evaluate`
/// calls (one whole `PlaybackTrigger.triggerAll` pass fires several, so a
/// pass boundary is not directly observable - the count is what these
/// tests actually assert on).
class _CountingSession implements DevtoolsSession {
  int evaluateCalls = 0;

  @override
  List<String> get childSessionIds => const [];

  @override
  Stream<CdpEvent> get events => const Stream<CdpEvent>.empty();

  @override
  Future<Map<String, dynamic>> send(String method, [Map<String, dynamic>? params]) async {
    if (method == 'Runtime.evaluate') {
      evaluateCalls++;
      final expression = params?['expression'] as String? ?? '';
      if (expression.contains('getBoundingClientRect')) {
        return {
          'result': {'value': '{"x":1,"y":1}'}
        };
      }
      return {
        'result': {'value': 'true'}
      };
    }
    return const {};
  }

  @override
  Future<Map<String, dynamic>> sendBrowserLevel(String method, [Map<String, dynamic>? params]) async => const {};

  @override
  Future<Map<String, dynamic>> sendToSession(String sessionId, String method, [Map<String, dynamic>? params]) =>
      send(method, params);

  @override
  Future<void> close() async {}
}

void main() {
  group('CaptureDriveLoop.run', () {
    test('candidates already populated before the call: no poll loop, just the two fixed delays', () async {
      final session = _CountingSession();
      final candidates = {'k': const CapturedMediaCandidate(url: 'https://cdn.example.com/a.mp4', container: 'mp4')};
      final stopwatch = Stopwatch()..start();

      await CaptureDriveLoop.run(
        session,
        candidates,
        postLoadDelay: const Duration(milliseconds: 5),
        autoplayRetryDelay: const Duration(milliseconds: 5),
        // Deliberately huge: if the poll loop ran at all despite
        // candidates already being non-empty, this test would time out
        // rather than merely being slow.
        firstCandidateTimeout: const Duration(seconds: 30),
        variantSettleDelay: const Duration(milliseconds: 5),
        pollInterval: const Duration(milliseconds: 5),
      );

      stopwatch.stop();
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(session.evaluateCalls, greaterThan(0)); // still fired the first PlaybackTrigger pass
    });

    test('guard can fail: a manifest candidate (m3u8) already present skips variantSettleDelay entirely', () async {
      // A master/media playlist already enumerates every variant itself
      // (CapturedFormatBuilder parses it later); there is nothing left to
      // wait for. Bilibili diagnostic run (docs/plan-phase5-coverage.md):
      // this is one of the three latency cuts that got its capture
      // attempt under the 90s wall.
      final session = _CountingSession();
      final candidates = {'k': const CapturedMediaCandidate(url: 'https://cdn.example.com/master.m3u8', container: 'm3u8')};
      final stopwatch = Stopwatch()..start();

      await CaptureDriveLoop.run(
        session,
        candidates,
        postLoadDelay: const Duration(milliseconds: 5),
        autoplayRetryDelay: const Duration(milliseconds: 5),
        firstCandidateTimeout: const Duration(seconds: 30),
        // Deliberately huge: if variantSettleDelay were NOT skipped for a
        // manifest candidate, this test would time out rather than merely
        // being slow.
        variantSettleDelay: const Duration(seconds: 30),
        pollInterval: const Duration(milliseconds: 5),
      );

      stopwatch.stop();
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    });

    test('an mp4 (non-manifest) candidate still waits out the full variantSettleDelay', () async {
      final session = _CountingSession();
      final candidates = {'k': const CapturedMediaCandidate(url: 'https://cdn.example.com/a.mp4', container: 'mp4')};
      final stopwatch = Stopwatch()..start();

      await CaptureDriveLoop.run(
        session,
        candidates,
        postLoadDelay: const Duration(milliseconds: 5),
        autoplayRetryDelay: const Duration(milliseconds: 5),
        firstCandidateTimeout: const Duration(seconds: 30),
        variantSettleDelay: const Duration(milliseconds: 200),
        pollInterval: const Duration(milliseconds: 5),
      );

      stopwatch.stop();
      expect(stopwatch.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 200)));
    });

    test('nothing ever arrives: polls up to firstCandidateTimeout and fires a second trigger pass at the halfway point',
        () async {
      final session = _CountingSession();
      final candidates = <String, CapturedMediaCandidate>{};

      await CaptureDriveLoop.run(
        session,
        candidates,
        postLoadDelay: const Duration(milliseconds: 2),
        autoplayRetryDelay: const Duration(milliseconds: 2),
        firstCandidateTimeout: const Duration(milliseconds: 40),
        variantSettleDelay: const Duration(milliseconds: 2),
        pollInterval: const Duration(milliseconds: 5),
      );

      final twoPassCallCount = session.evaluateCalls;
      expect(twoPassCallCount, greaterThan(0));

      // Guard can fail: with a zero-length poll budget there is no room
      // for the halfway-point retry to ever fire, so only the first
      // (pre-poll-loop) PlaybackTrigger pass runs - proving the halfway
      // retry, not something else, is what produced the larger count
      // above.
      final secondSession = _CountingSession();
      final secondCandidates = <String, CapturedMediaCandidate>{};
      await CaptureDriveLoop.run(
        secondSession,
        secondCandidates,
        postLoadDelay: const Duration(milliseconds: 2),
        autoplayRetryDelay: const Duration(milliseconds: 2),
        firstCandidateTimeout: Duration.zero,
        variantSettleDelay: const Duration(milliseconds: 2),
        pollInterval: const Duration(milliseconds: 5),
      );

      expect(twoPassCallCount, greaterThan(secondSession.evaluateCalls));
    });

    test('a candidate appearing mid-poll ends the poll loop early rather than waiting out firstCandidateTimeout',
        () async {
      final session = _CountingSession();
      final candidates = <String, CapturedMediaCandidate>{};

      Future<void>.delayed(const Duration(milliseconds: 15), () {
        candidates['k'] = const CapturedMediaCandidate(url: 'https://cdn.example.com/late.mp4', container: 'mp4');
      });

      final stopwatch = Stopwatch()..start();
      await CaptureDriveLoop.run(
        session,
        candidates,
        postLoadDelay: const Duration(milliseconds: 2),
        autoplayRetryDelay: const Duration(milliseconds: 2),
        firstCandidateTimeout: const Duration(seconds: 30),
        variantSettleDelay: const Duration(milliseconds: 5),
        pollInterval: const Duration(milliseconds: 5),
      );
      stopwatch.stop();

      expect(candidates, isNotEmpty);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });
}
