import '../extractors/media_models.dart';

/// Picks which of a captured session's cookies actually apply to one
/// outgoing request - domain suffix match (a cookie scoped to
/// `example.com` applies to `a.example.com`, but a cookie scoped to
/// `other.example.com` never applies to `a.example.com`), and a `secure`
/// cookie only travels over `https`. Used by `StreamDownloader` and
/// `HlsFfmpegDownloader` instead of forwarding one flattened `Cookie`
/// header to every request regardless of host - see
/// `MediaInfo.cookiesByDomain`'s own doc for why that matters.
class CookieScope {
  const CookieScope._();

  /// Builds a `name=value; name2=value2` `Cookie` header value for
  /// [requestUrl] out of [cookiesByDomain], or `''` if nothing in it
  /// applies to this host at all (callers should treat an empty result as
  /// "no opinion", not "send an empty Cookie header").
  static String headerFor(Uri requestUrl, Map<String, List<CookieEntry>> cookiesByDomain) {
    final host = requestUrl.host.toLowerCase();
    if (host.isEmpty || cookiesByDomain.isEmpty) return '';

    final matches = <CookieEntry>[];
    for (final entry in cookiesByDomain.entries) {
      // CDP itself reports a leading-dot domain for a cookie set without
      // `Domain=` explicitly (host-only); strip it before comparing so
      // both shapes match the same way.
      final cookieDomain = entry.key.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
      if (cookieDomain.isEmpty) continue;
      if (host != cookieDomain && !host.endsWith('.$cookieDomain')) continue;
      for (final cookie in entry.value) {
        if (cookie.secure && requestUrl.scheme.toLowerCase() != 'https') continue;
        matches.add(cookie);
      }
    }
    if (matches.isEmpty) return '';
    return matches.map((c) => '${c.name}=${c.value}').join('; ');
  }
}
