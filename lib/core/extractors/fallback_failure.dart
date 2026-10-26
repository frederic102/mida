import 'dart:async';
import 'dart:io';

import '../services/cdp_client.dart';
import 'media_models.dart';

/// Statuses a fallback attempt (catch-all or browser capture) can report
/// that name *why* the chain could not get the media: a site or policy
/// wall, or a rate limit. When the whole chain fails, `ExtractorRegistry`
/// surfaces the latest of these over the first extractor's status so the
/// caller (CLI exit code, GUI action) sees the actionable reason instead of
/// a bare `NO_MEDIA_FOUND` (Vigil H1, Phase 7 round 2).
const Set<String> fallbackSurfacedStatuses = {
  'HEADLESS_BLOCKED',
  'BOT_CHECK_REQUIRED',
  'LOGIN_REQUIRED',
  'DRM_PROTECTED',
  'PRIVATE',
  'AGE_VERIFICATION_REQUIRED',
  'CONTENT_CHECK_REQUIRED',
  'RATE_LIMITED',
};

/// Turns anything an extractor attempt threw into a
/// [MediaExtractionException] (Vigil H2, N2): a [MediaExtractionException]
/// passes through unchanged; anything else becomes one with a FIXED message:
///  - a failed process launch or CDP command -> `BROWSER_CAPTURE_FAILED`,
///  - a socket/HTTP/TLS error or a timeout -> `NETWORK`,
///  - anything else, [Error]s included (`TypeError`, `StateError`, a
///    `FormatException` from a parser) -> `PARSE_ERROR`, a fall-through
///    status, so a parser bug degrades to the next technique instead of
///    crashing the caller.
/// The original text is deliberately dropped: it can carry a signed URL, a
/// cookie, or a DevTools payload, and this message ends up in user-facing
/// output.
MediaExtractionException asFallbackFailure(Object error) {
  if (error is MediaExtractionException) return error;
  // ProcessException implements IOException, so it must be checked first.
  if (error is ProcessException || error is CdpCommandException) {
    return const MediaExtractionException(
      'BROWSER_CAPTURE_FAILED',
      'An extractor could not drive the browser it needed.',
    );
  }
  if (error is SocketException && isOfflineSocketError(error)) {
    return const OfflineNetworkException('This machine could not resolve or reach the host. Check your connection.');
  }
  if (error is SocketException || error is HttpException || error is TlsException ||
      error is WebSocketException || error is TimeoutException) {
    return const MediaExtractionException(
      'NETWORK',
      'An extractor hit a network error or timed out.',
    );
  }
  // Vigil r3 M2: a FileSystemException or any other non-socket IOException is not a network fault.
  if (error is IOException) {
    return const MediaExtractionException(
      'EXTRACTION_FAILED',
      'An extractor failed on a local input/output error.',
    );
  }
  return const MediaExtractionException(
    'PARSE_ERROR',
    'An extractor failed unexpectedly while reading the response.',
  );
}

/// A `NETWORK` failure that proves this machine is offline or cannot
/// resolve the host (DNS lookup failure, no route, network down), as
/// opposed to one server refusing or resetting the connection. Only this
/// kind may stop the fallback chain before a browser launch (Vigil r3 M1).
class OfflineNetworkException extends MediaExtractionException {
  const OfflineNetworkException(String reason) : super('NETWORK', reason);
}

/// Windows WSA and POSIX errnos for "cannot resolve / cannot route".
const Set<int> _offlineErrnos = {
  11001, 11002, 11004, // WSAHOST_NOT_FOUND, WSATRY_AGAIN, WSANO_DATA
  10050, 10051, 10065, // WSAENETDOWN, WSAENETUNREACH, WSAEHOSTUNREACH
  100, 101, 113, // ENETDOWN, ENETUNREACH, EHOSTUNREACH (Linux)
};

/// True for a DNS / host-lookup / no-route [SocketException].
bool isOfflineSocketError(SocketException error) {
  final code = error.osError?.errorCode;
  if (code != null && _offlineErrnos.contains(code)) return true;
  return error.message.toLowerCase().contains('host lookup');
}
