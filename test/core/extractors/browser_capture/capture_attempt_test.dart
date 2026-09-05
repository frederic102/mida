import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/browser_capture/capture_attempt.dart';
import 'package:mida/core/extractors/media_models.dart';

void main() {
  group('shouldRetryHeadless', () {
    const error = MediaExtractionException('NO_MEDIA_FOUND', 'nothing found');
    final info = MediaInfo(id: 'x', title: 't', sourceUrl: Uri.parse('https://example.com'));

    test('retries: no media found, real browser (no injected launcher), page never loaded', () {
      const first = CaptureAttempt(error: error, loadFired: false);
      expect(shouldRetryHeadless(first, hasInjectedSessionLauncher: false), isTrue);
    });

    test('does not retry: media was found (nothing to retry for)', () {
      final first = CaptureAttempt(info: info, loadFired: false);
      expect(shouldRetryHeadless(first, hasInjectedSessionLauncher: false), isFalse);
    });

    test('does not retry: a test-injected session launcher has no headed/headless concept', () {
      const first = CaptureAttempt(error: error, loadFired: false);
      expect(shouldRetryHeadless(first, hasInjectedSessionLauncher: true), isFalse);
    });

    test('does not retry: the page loaded fine, it simply had no media - headless would fail identically', () {
      const first = CaptureAttempt(error: error, loadFired: true);
      expect(shouldRetryHeadless(first, hasInjectedSessionLauncher: false), isFalse);
    });

    test('guard can fail: flipping any one of the three conditions changes the verdict', () {
      // Baseline: all three conditions favor a retry.
      const baseline = CaptureAttempt(error: error, loadFired: false);
      expect(shouldRetryHeadless(baseline, hasInjectedSessionLauncher: false), isTrue);

      // Each of these individually removing one condition must flip the
      // verdict back to false - proving all three are load-bearing, not
      // just one of them doing all the work.
      expect(
        shouldRetryHeadless(CaptureAttempt(info: info, loadFired: false), hasInjectedSessionLauncher: false),
        isFalse,
      );
      expect(shouldRetryHeadless(baseline, hasInjectedSessionLauncher: true), isFalse);
      expect(
        shouldRetryHeadless(const CaptureAttempt(error: error, loadFired: true), hasInjectedSessionLauncher: false),
        isFalse,
      );
    });
  });
}
