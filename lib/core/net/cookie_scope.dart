import '../extractors/media_models.dart';

/// Picks which of a captured session's cookies actually apply to one
/// outgoing request, following the same shape RFC 6265 itself uses:
///
///  - **Domain cookie** (`cookiesByDomain` key has a leading dot, e.g.
///    `.example.com` - what CDP reports for a cookie whose `Set-Cookie`
///    carried an explicit `Domain=` attribute): matches the exact host
///    *and* every subdomain of it (`a.example.com`, `b.a.example.com`, ...).
///  - **Host-only cookie** (no leading dot, e.g. `example.com` - a cookie
///    set with no `Domain=` attribute at all): matches that exact host
///    only, never a subdomain. Widening this to match subdomains too (the
///    bug this class used to have) would let a cookie captured for one
///    exact host ride along to a completely different subdomain that
///    never actually set it.
///  - `path` is honored with the same prefix-with-boundary rule
///    `Set-Cookie`'s own `Path` attribute uses: `/api` matches `/api` and
///    `/api/x` but not `/apix`.
///  - a `secure` cookie only travels over `https`.
///
/// Used by `StreamDownloader` and `HlsFfmpegDownloader` instead of
/// forwarding one flattened `Cookie` header to every request regardless of
/// host - see `MediaInfo.cookiesByDomain`'s own doc for why that matters.
/// Callers must re-invoke this per request (including per redirect hop),
/// never reuse one call's result across hosts: `StreamDownloader._get`
/// already does this correctly (recomputed inside the redirect loop).
class CookieScope {
  const CookieScope._();

  /// Builds a `name=value; name2=value2` `Cookie` header value for
  /// [requestUrl] out of [cookiesByDomain], or `''` if nothing in it
  /// applies to this host/path at all (callers should treat an empty
  /// result as "no opinion", not "send an empty Cookie header").
  static String headerFor(Uri requestUrl, Map<String, List<CookieEntry>> cookiesByDomain) {
    final host = requestUrl.host.toLowerCase();
    if (host.isEmpty || cookiesByDomain.isEmpty) return '';
    final requestPath = requestUrl.path.isEmpty ? '/' : requestUrl.path;

    final matches = <CookieEntry>[];
    for (final entry in cookiesByDomain.entries) {
      final rawKey = entry.key.toLowerCase();
      final isDomainCookie = rawKey.startsWith('.');
      final cookieDomain = isDomainCookie ? rawKey.substring(1) : rawKey;
      if (cookieDomain.isEmpty) continue;

      final hostMatches = isDomainCookie
          ? (host == cookieDomain || host.endsWith('.$cookieDomain'))
          : host == cookieDomain; // host-only: exact match only, no subdomain widening
      if (!hostMatches) continue;

      for (final cookie in entry.value) {
        if (cookie.secure && requestUrl.scheme.toLowerCase() != 'https') continue;
        if (!_pathMatches(cookie.path, requestPath)) continue;
        matches.add(cookie);
      }
    }
    if (matches.isEmpty) return '';
    return matches.map((c) => '${c.name}=${c.value}').join('; ');
  }

  /// RFC 6265 section 5.1.4's path-match: [requestPath] must start with
  /// [cookiePath], and either be exactly it, or [cookiePath] itself ends
  /// in `/`, or the next character in [requestPath] right after
  /// [cookiePath] is `/` - so a cookie scoped to `/api` matches `/api` and
  /// `/api/x` but not `/apix` (a bare prefix check would wrongly match
  /// that last one).
  static bool _pathMatches(String cookiePath, String requestPath) {
    final cp = cookiePath.isEmpty ? '/' : cookiePath;
    if (!requestPath.startsWith(cp)) return false;
    if (requestPath.length == cp.length) return true;
    if (cp.endsWith('/')) return true;
    return requestPath[cp.length] == '/';
  }
}
