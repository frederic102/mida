import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/net/retry_policy.dart';

void main() {
  group('isRetryableStatus (pure classification)', () {
    test('RATE_LIMITED and NETWORK are retryable', () {
      expect(isRetryableStatus('RATE_LIMITED'), isTrue);
      expect(isRetryableStatus('NETWORK'), isTrue);
    });

    // Guard-can-fail: every status the plan explicitly forbids retrying
    // must classify false. If `isRetryableStatus` were ever widened (e.g.
    // to `true` unconditionally), every case in this loop turns red.
    for (final terminal in [
      'PRIVATE',
      'NOT_FOUND',
      'DRM_PROTECTED',
      'UNSUPPORTED_URL',
      'PARSE_ERROR',
      'CHALLENGE_FAILED',
      'NO_MEDIA_FOUND',
      'UNSUPPORTED_MEDIA',
      'LOGIN_REQUIRED',
    ]) {
      test('$terminal is not retryable', () {
        expect(isRetryableStatus(terminal), isFalse);
      });
    }
  });

  group('isRetryableHttpStatusCode', () {
    test('429 and 503 are retryable', () {
      expect(isRetryableHttpStatusCode(429), isTrue);
      expect(isRetryableHttpStatusCode(503), isTrue);
    });

    test('other codes (including other 5xx) are not retryable by this narrow check', () {
      expect(isRetryableHttpStatusCode(500), isFalse);
      expect(isRetryableHttpStatusCode(404), isFalse);
      expect(isRetryableHttpStatusCode(200), isFalse);
    });
  });

  group('isRetryableError', () {
    test('a MediaExtractionException delegates to isRetryableStatus', () {
      expect(isRetryableError(const MediaExtractionException('RATE_LIMITED')), isTrue);
      expect(isRetryableError(const MediaExtractionException('PRIVATE')), isFalse);
    });

    test('a non-MediaExtractionException error is never retryable by default', () {
      expect(isRetryableError(Exception('boom')), isFalse);
      expect(isRetryableError(429), isFalse);
    });
  });

  group('RetryPolicy.run', () {
    /// Records every delay [RetryPolicy] asked it to wait, without ever
    /// actually waiting - the hermetic sleeper every test in this group
    /// injects so no test takes real wall-clock seconds.
    ({Future<void> Function(Duration) sleeper, List<Duration> delays}) fakeSleeper() {
      final delays = <Duration>[];
      return (
        sleeper: (Duration d) async {
          delays.add(d);
        },
        delays: delays,
      );
    }

    test('succeeds on the first attempt: action runs once, sleeper never called', () async {
      final fake = fakeSleeper();
      final policy = RetryPolicy(sleeper: fake.sleeper);
      var calls = 0;

      final result = await policy.run(() async {
        calls++;
        return 'ok';
      });

      expect(result, 'ok');
      expect(calls, 1);
      expect(fake.delays, isEmpty);
    });

    test('a retryable failure is retried and can eventually succeed', () async {
      final fake = fakeSleeper();
      final policy = RetryPolicy(sleeper: fake.sleeper);
      var calls = 0;

      final result = await policy.run(() async {
        calls++;
        if (calls < 3) {
          throw const MediaExtractionException('RATE_LIMITED', 'throttled');
        }
        return 'recovered';
      });

      expect(result, 'recovered');
      expect(calls, 3, reason: 'two failures then a success: three actual invocations');
      expect(fake.delays.length, 2, reason: 'a sleep before each of the two retries, none after the final success');
    });

    // Guard-can-fail: a terminal status must not be retried at all. If the
    // classifier (or the `attempt == maxAttempts || !_isRetryable` check)
    // were ever inverted/removed, `calls` here would become `4` (the
    // default maxAttempts) instead of `1`, and this assertion goes red.
    test('a non-retryable (terminal) failure is not retried: action runs exactly once', () async {
      final fake = fakeSleeper();
      final policy = RetryPolicy(sleeper: fake.sleeper);
      var calls = 0;

      await expectLater(
        policy.run(() async {
          calls++;
          throw const MediaExtractionException('PRIVATE', 'this video is private');
        }),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PRIVATE')),
      );

      expect(calls, 1);
      expect(fake.delays, isEmpty, reason: 'no backoff sleep for a status that will never be retried');
    });

    test('exhausts maxAttempts on a persistently retryable failure, then rethrows the last error', () async {
      final fake = fakeSleeper();
      final policy = RetryPolicy(maxAttempts: 4, sleeper: fake.sleeper);
      var calls = 0;

      await expectLater(
        policy.run(() async {
          calls++;
          throw const MediaExtractionException('NETWORK', 'connection reset');
        }),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NETWORK')),
      );

      expect(calls, 4);
      expect(fake.delays.length, 3, reason: 'a sleep between each of the 4 attempts, none after the last');
      // Base delays are 1s, 2s, 4s (the 4th attempt is last and never sleeps).
      for (var i = 0; i < fake.delays.length; i++) {
        final base = Duration(seconds: 1 << i);
        expect(fake.delays[i] >= base, isTrue, reason: 'delay $i must be at least the base backoff');
        expect(fake.delays[i] < base + const Duration(milliseconds: 251), isTrue,
            reason: 'jitter must be bounded (<=250ms) on top of the base backoff');
      }
    });

    test('onRetry fires once per retry with the failing attempt number and error', () async {
      final fake = fakeSleeper();
      final policy = RetryPolicy(sleeper: fake.sleeper);
      final seen = <(int, Object)>[];
      var calls = 0;

      await policy.run(
        () async {
          calls++;
          if (calls < 2) throw const MediaExtractionException('RATE_LIMITED', 'wait');
          return 'ok';
        },
        onRetry: (attempt, error) => seen.add((attempt, error)),
      );

      expect(seen.length, 1);
      expect(seen.single.$1, 1);
      expect(seen.single.$2, isA<MediaExtractionException>());
    });

    test('a custom isRetryable classifier overrides the default', () async {
      final fake = fakeSleeper();
      final policy = RetryPolicy(
        sleeper: fake.sleeper,
        isRetryable: (error) => error is FormatException,
      );
      var calls = 0;

      final result = await policy.run(() async {
        calls++;
        if (calls < 2) throw const FormatException('transient for this test');
        return 'ok';
      });

      expect(result, 'ok');
      expect(calls, 2);
    });

    test('a seeded Random makes jitter deterministic across runs', () async {
      Duration? capturedDelay;
      final policy = RetryPolicy(
        sleeper: (d) async => capturedDelay = d,
        random: Random(1234),
      );
      var calls = 0;

      await policy.run(() async {
        calls++;
        if (calls < 2) throw const MediaExtractionException('NETWORK', 'flaky');
        return 'ok';
      });

      final expectedJitter = Random(1234).nextInt(251);
      expect(capturedDelay, const Duration(seconds: 1) + Duration(milliseconds: expectedJitter));
    });
  });
}
