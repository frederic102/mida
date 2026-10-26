import 'dart:async';
import 'dart:io';

/// Thrown once a [StageDeadline] has run out. A [TimeoutException], so a
/// caller that already maps timeouts keeps working unchanged.
class StageDeadlineExceeded extends TimeoutException {
  StageDeadlineExceeded() : super('The static-analysis time budget ran out.');
}

/// Wall-clock budget for one extraction stage that also owns every
/// `HttpClient` working under it. When the budget runs out (its own timer)
/// or the stage owner calls [expire] (the stage is over, for whatever
/// reason), every client still in [run] is force-closed and every later
/// [run]/[ensureActive] throws [StageDeadlineExceeded] before a request is
/// made. That is what turns the deadline into a cancellation: a timed-out
/// `Future` alone keeps running, its sockets stay open, and a response that
/// arrives late could still trigger follow-up requests.
class StageDeadline {
  final Duration budget;
  final Stopwatch _clock = Stopwatch()..start();
  final Set<HttpClient> _active = {};
  late final Timer _timer;
  bool _expired = false;

  StageDeadline(this.budget) {
    _timer = Timer(budget, expire);
  }

  bool get isExpired => _expired || _clock.elapsed >= budget;

  Duration get remaining {
    final left = budget - _clock.elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  /// Throws [StageDeadlineExceeded] once the stage is over.
  void ensureActive() {
    if (isExpired) throw StageDeadlineExceeded();
  }

  /// Runs [operation] (which does its I/O on [client]) under this deadline
  /// and, when given, a per-request [timeout], whichever is shorter. On
  /// expiry [client] is force-closed and [StageDeadlineExceeded] (stage) or
  /// a plain [TimeoutException] (per-request limit) is thrown; an I/O error
  /// caused by [expire] closing the client also surfaces as the former.
  Future<T> run<T>(HttpClient client, Future<T> Function() operation, {Duration? timeout}) async {
    ensureActive();
    _active.add(client);
    final stageLeft = remaining;
    final perRequest = timeout != null && timeout < stageLeft;
    try {
      return await operation().timeout(perRequest ? timeout : stageLeft, onTimeout: () {
        client.close(force: true);
        if (perRequest) throw TimeoutException('The request timed out.', timeout);
        expire();
        throw StageDeadlineExceeded();
      });
    } on StageDeadlineExceeded {
      rethrow;
    } catch (_) {
      if (isExpired) throw StageDeadlineExceeded();
      rethrow;
    } finally {
      _active.remove(client);
    }
  }

  /// Ends the stage: force-closes every client still working under it and
  /// makes every later [run]/[ensureActive] throw. Idempotent.
  void expire() {
    _expired = true;
    _timer.cancel();
    for (final client in _active.toList()) {
      client.close(force: true);
    }
    _active.clear();
  }
}

/// [StageDeadline.run] when there is a [deadline]; otherwise just the
/// optional per-request [timeout] (force-closing [client] on expiry).
Future<T> runBounded<T>(
  StageDeadline? deadline,
  HttpClient client,
  Future<T> Function() operation, {
  Duration? timeout,
}) {
  if (deadline != null) return deadline.run(client, operation, timeout: timeout);
  if (timeout == null) return operation();
  return operation().timeout(timeout, onTimeout: () {
    client.close(force: true);
    throw TimeoutException('The request timed out.', timeout);
  });
}
