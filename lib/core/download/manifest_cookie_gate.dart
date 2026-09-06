import 'dart:async';
import 'dart:collection';
import 'dart:io';

import '../extractors/media_models.dart';
import '../net/cookie_scope.dart';
import '../net/host_policy.dart';

/// Every check one reference must pass before this app will let ffmpeg see
/// it, plus the memoized DNS answers that keep a manifest listing dozens of
/// segments on one CDN from triggering dozens of lookups. Split out of
/// `manifest_reference_scanner.dart` (phase 6 round 4) so that file stays
/// under this project's 400-line cap; still owned by the same lane.
class ManifestCookieGate {
  final Uri root;
  final bool allowPrivateHosts;
  final Future<List<InternetAddress>> Function(String host) _resolveHost;
  final Map<String, List<CookieEntry>>? cookiesByDomain;

  /// The exact `name=value` pairs ffmpeg would send as `Cookie` on every
  /// request it makes for this manifest. Taken from the headers actually
  /// in use (not recomputed from [cookiesByDomain]) because that
  /// flattened header is the thing that would leak.
  final Set<String> _sentCookiePairs;

  final Map<String, Future<List<InternetAddress>>> _lookups = {};
  final Set<String> _resolvedHosts = {};
  final SplayTreeSet<String> _outOfScopeHosts = SplayTreeSet<String>();

  static const _context = 'a segment/key/map/playlist referenced by this manifest';

  ManifestCookieGate({
    required this.root,
    required Map<String, String> headers,
    required this.cookiesByDomain,
    required this.allowPrivateHosts,
    required Future<List<InternetAddress>> Function(String host) resolveHost,
  })  : _resolveHost = resolveHost,
        _sentCookiePairs = _cookiePairs(_cookieHeaderOf(headers));

  List<String> get hostsOutsideCookieScope => List.unmodifiable(_outOfScopeHosts);

  static String _cookieHeaderOf(Map<String, String> headers) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'cookie') return entry.value;
    }
    return '';
  }

  static Set<String> _cookiePairs(String header) =>
      header.split(';').map((p) => p.trim()).where((p) => p.isNotEmpty).toSet();

  /// The test-only [allowPrivateHosts] exemption, scoped to the root
  /// manifest's own origin so a loopback fixture server can serve a whole
  /// playlist chain while every other private target stays refused.
  bool isExemptOrigin(Uri uri) =>
      allowPrivateHosts &&
      uri.scheme.toLowerCase() == root.scheme.toLowerCase() &&
      uri.host.toLowerCase() == root.host.toLowerCase() &&
      uri.port == root.port;

  /// Memoized: one lookup per host per scan, leaf check or fetch alike.
  Future<List<InternetAddress>> resolve(String host) =>
      _lookups.putIfAbsent(host.toLowerCase(), () => _resolveHost(host));

  Future<void> check(Uri uri) async {
    if (isExemptOrigin(uri)) return;
    HostPolicy.assertAllowedHost(uri, context: _context);
    if (_resolvedHosts.add(uri.host.toLowerCase())) {
      await HostPolicy.assertResolvesToPublicHost(uri, resolveHost: resolve);
    }
    recordCookieScope(uri);
  }

  /// Phase 6 B-R4-2: every hop a playlist fetch actually went through
  /// (redirects included, [HostPolicy.guardedRequest]'s `onHop`) must be
  /// run through the same cookie-scope accounting as a reference found
  /// INSIDE a manifest body. Without this, a root manifest that 302's to
  /// an out-of-scope CDN never shows up in [hostsOutsideCookieScope] as
  /// long as nothing it then references also happens to be out of scope -
  /// but ffmpeg's own request follows that exact same redirect and (unlike
  /// this scanner, which re-scopes credentials per hop via
  /// `PerHopCredentials`) sends its one flattened `-headers` blob,
  /// cookie included, straight into it.
  void recordHopHost(Uri uri) => recordCookieScope(uri);

  /// Phase 6 B-R3, revised by B-R3-5 and B-R4-2/6. ffmpeg has no
  /// per-request-host header concept: one `-headers` blob (cookie
  /// included) goes to the manifest AND to every segment, key, init map,
  /// rendition playlist and redirect hop it goes through. So a manifest
  /// carrying a cookie and reaching a host outside that cookie's scope -
  /// whether by a reference inside its body or by a plain HTTP redirect -
  /// would post the session cookie to that host.
  ///
  /// This used to refuse the download; it no longer does. Refusing broke
  /// legitimate streams whose segments live on a partner CDN, and the
  /// leak is fully closed by not sending the cookie to ffmpeg at all (the
  /// caller does that when this set is non-empty). The scanner's own
  /// manifest request still carries the cookie, per hop and per host,
  /// because that request is the one it was scoped for.
  ///
  /// In scope, precisely: any host [CookieScope] would itself send
  /// *every* cookie pair in the outgoing header to. B-R4-6 removed the
  /// old unconditional "the manifest's own host is always in scope"
  /// shortcut: with [cookiesByDomain] known, even the manifest's own host
  /// is checked against it (a `Secure` cookie reaching that same host over
  /// plain `http`, or one `Path`-scoped away from this particular
  /// reference, must still be caught). Only when there is no
  /// [cookiesByDomain] at all - a bare flattened header with no per-cookie
  /// scope to check - does the root host stay the sole fallback signal of
  /// "in scope", since that is the one host this app already knows it
  /// sent this exact header to.
  void recordCookieScope(Uri uri) {
    if (_sentCookiePairs.isEmpty) return;
    if (cookiesByDomain != null) {
      final allowed = _cookiePairs(CookieScope.headerFor(uri, cookiesByDomain!));
      if (_sentCookiePairs.every(allowed.contains)) return;
    } else if (uri.host.toLowerCase() == root.host.toLowerCase()) {
      return;
    }
    _outOfScopeHosts.add(uri.host.toLowerCase());
  }
}
