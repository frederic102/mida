import 'dart:math';

import '../extractors/media_models.dart';

/// True for a [MediaExtractionException.status] this policy is willing to
/// retry: `RATE_LIMITED` (source told us to slow down, or a WAF served an
/// interstitial) and `NETWORK` (a transient 5xx/connection failure). Every
/// other status (`PRIVATE`, `NOT_FOUND`, `DRM_PROTECTED`, `UNSUPPORTED_URL`,
/// `PARSE_ERROR`, `CHALLENGE_FAILED`, `NO_MEDIA_FOUND`, ...) means the
/// source told us definitively that there is nothing a retry would fix, so
/// [RetryPolicy] must not spend an attempt on those (and, for a WAF,
/// retrying a rejected challenge only makes the next request look more
/// suspicious, not less).
///
/// Exposed as a free function, not buried inside [RetryPolicy], so callers
/// and tests can classify a status without constructing a whole policy.
bool isRetryableStatus(String status) => status == 'RATE_LIMITED' || status == 'NETWORK';

/// True for an HTTP status code this policy is willing to retry: 429 (rate
/// limited) and 503 (service unavailable, usually momentary). For a caller
/// that already has the raw response code in hand (rather than a wrapped
/// [MediaExtractionException]) and wants to decide before building one.
bool isRetryableHttpStatusCode(int code) => code == 429 || code == 503;

/// Default classification [RetryPolicy] uses when a caller does not supply
/// its own `isRetryable`: retryable only for a [MediaExtractionException]
/// whose status passes [isRetryableStatus]. A bare `int` status code is
/// deliberately not handled here - a caller that wants HTTP-code based
/// classification (nothing has thrown yet) should pass a custom
/// `isRetryable` built on [isRetryableHttpStatusCode] instead of relying on
/// this default.
bool isRetryableError(Object error) =>
    error is MediaExtractionException && isRetryableStatus(error.status);

/// Reusable exponential-backoff retry wrapper for a fallible async
/// operation (`docs/plan-phase4-cookies-resilience.md` section 3).
///
/// Delays 1s, 2s, 4s, 8s between attempts (plus up to 250ms of jitter, so
/// two callers backing off at the same moment do not retry in lockstep),
/// for up to [maxAttempts] total tries (4 by default). Only retries a
/// failure [isRetryable] accepts (by default [isRetryableError]); anything
/// else is rethrown immediately on the first attempt, without waiting.
///
/// [sleeper] and [random] exist so tests can make every attempt hermetic:
/// inject a `sleeper` that resolves immediately instead of actually
/// waiting, and/or a seeded [Random] to assert exact delays. Production
/// code should leave both at their defaults.
class RetryPolicy {
  static const List<Duration> _baseDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
  ];

  static const _maxJitter = Duration(milliseconds: 250);

  final int maxAttempts;
  final Future<void> Function(Duration delay) _sleeper;
  final Random _random;
  final bool Function(Object error) _isRetryable;

  RetryPolicy({
    this.maxAttempts = 4,
    Future<void> Function(Duration delay)? sleeper,
    Random? random,
    bool Function(Object error)? isRetryable,
  })  : assert(maxAttempts >= 1, 'maxAttempts must be at least 1 (the first attempt is not a retry)'),
        _sleeper = sleeper ?? Future.delayed,
        _random = random ?? Random(),
        _isRetryable = isRetryable ?? isRetryableError;

  /// Runs [action], retrying it when it throws an error [isRetryable]
  /// (constructor param) accepts, until it either succeeds or [maxAttempts]
  /// is reached. [onRetry] - if given - fires right before each backoff
  /// sleep with the 1-based attempt number that just failed and the error
  /// that failed it; callers use it to surface a status line (e.g.
  /// "Retrying (rate limited by the site)...") without [RetryPolicy] itself
  /// knowing anything about UI.
  ///
  /// The most recent failure is rethrown as-is (same type, same message)
  /// once retrying stops being worthwhile, whether that is because
  /// [isRetryable] rejected it or because [maxAttempts] was reached - so a
  /// caller catching a specific exception type/status around [run] behaves
  /// exactly as it would around a bare, unwrapped call to [action].
  Future<T> run<T>(
    Future<T> Function() action, {
    void Function(int attempt, Object error) onRetry = _noopOnRetry,
  }) async {
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await action();
      } catch (error) {
        if (attempt == maxAttempts || !_isRetryable(error)) rethrow;
        onRetry(attempt, error);
        await _sleeper(_delayFor(attempt));
      }
    }
    // Unreachable: every loop iteration above either returns or rethrows.
    throw StateError('RetryPolicy.run exhausted attempts without throwing');
  }

  static void _noopOnRetry(int attempt, Object error) {}

  Duration _delayFor(int attempt) {
    final index = attempt - 1 < _baseDelays.length ? attempt - 1 : _baseDelays.length - 1;
    final jitterMs = _random.nextInt(_maxJitter.inMilliseconds + 1);
    return _baseDelays[index] + Duration(milliseconds: jitterMs);
  }
}
