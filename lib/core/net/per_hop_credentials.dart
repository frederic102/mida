import 'dart:io';

import '../extractors/media_models.dart';
import 'cookie_scope.dart';

/// Sets one outgoing request's headers with its credentials re-scoped to
/// the hop that request is *actually* going to, rather than to whatever
/// URL the caller originally asked for.
///
/// Why this exists as a shared helper: `HostPolicy.guardedRequest`
/// follows redirects itself, calling `configureRequest` again for every
/// hop. A redirect can land on a different origin than the one the
/// caller's `Cookie`/`Authorization` header was collected for, and a
/// flattened header value has no per-host scoping of its own, so without
/// this it would simply ride along onto the new origin. Phase 6 round 2
/// S-R1 (`mp4_track_sniffer.dart`) and round 3 B-R3-2
/// (`manifest_reference_scanner.dart`) are the same rule; this file is
/// the single place to state it.
///
/// The API is deliberately tiny (one [apply] plus the two predicates it
/// is built from). `mp4_track_sniffer.dart` adopted [apply] in phase 6
/// round 4 (S-R4-1), so this is the single implementation for both the
/// scanner and the sniffer.
class PerHopCredentials {
  const PerHopCredentials._();

  /// Header names whose value must never travel to an origin other than
  /// the one the caller named. Unlike [CookieScope]-derived cookies
  /// (recomputed per host below), these arrive as an already-flattened
  /// string that carries no scope information at all.
  static bool isCredentialHeader(String name) {
    final lower = name.toLowerCase();
    return lower == 'cookie' || lower == 'authorization' || lower == 'proxy-authorization';
  }

  /// Scheme + host + port equality, all case-insensitive on the parts
  /// where that is correct.
  static bool sameOrigin(Uri a, Uri b) =>
      a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
      a.host.toLowerCase() == b.host.toLowerCase() &&
      a.port == b.port;

  /// Writes [headers] onto [request], dropping every
  /// [isCredentialHeader] entry when `request.uri` is not the same
  /// origin as [origin], then (when [cookiesByDomain] is given) sets a
  /// `Cookie` computed by [CookieScope] for this hop's own URL - which
  /// is host- and path-scoped by construction, so a domain cookie that
  /// genuinely covers the new origin still travels while one that does
  /// not stays behind.
  static void apply(
    HttpClientRequest request, {
    required Uri origin,
    required Map<String, String> headers,
    Map<String, List<CookieEntry>>? cookiesByDomain,
  }) {
    final hop = request.uri;
    final isSameOrigin = sameOrigin(hop, origin);
    headers.forEach((name, value) {
      if (!isSameOrigin && isCredentialHeader(name)) return;
      request.headers.set(name, value);
    });
    if (cookiesByDomain == null) return;
    final scoped = CookieScope.headerFor(hop, cookiesByDomain);
    if (scoped.isNotEmpty) request.headers.set('Cookie', scoped);
  }
}
