import '../../net/cookie_scope.dart';
import '../../services/browser_devtools_session.dart';
import '../media_models.dart';
import 'captured_media_classifier.dart';

/// The request-identity pieces (`User-Agent`, cookies) a capture needs to
/// hand back alongside its media URLs, both read straight off the live
/// session rather than guessed - split out of `BrowserCaptureExtractor` to
/// keep that file under this project's 400-line cap.
class SessionRequestContext {
  const SessionRequestContext._();

  static Future<String> userAgent(DevtoolsSession session) async {
    try {
      final version = await session.sendBrowserLevel('Browser.getVersion');
      final userAgent = version['userAgent'] as String?;
      if (userAgent != null && userAgent.isNotEmpty) return userAgent;
    } catch (_) {
      // Fall through to the generic desktop UA below.
    }
    return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';
  }

  /// Every cookie CDP reports for [pageUrl] and every URL in [candidates],
  /// grouped by each cookie's own reported `domain` (never flattened into
  /// one blanket string) - see [MediaInfo.cookiesByDomain] for why a
  /// downloader needs that distinction. A cookie missing a domain/name/
  /// value entirely (malformed reply) is skipped, not a throw; any other
  /// failure (session closed, command rejected) yields an empty map, same
  /// as a page with no cookies at all.
  static Future<Map<String, List<CookieEntry>>> cookiesByDomain(
    DevtoolsSession session,
    Uri pageUrl,
    List<CapturedMediaCandidate> candidates,
  ) async {
    try {
      final urls = <String>{pageUrl.toString(), for (final c in candidates) c.url}.toList();
      final result = await session.send('Network.getCookies', {'urls': urls});
      final cookies = result['cookies'];
      if (cookies is! List) return const {};

      final grouped = <String, List<CookieEntry>>{};
      for (final raw in cookies.whereType<Map>()) {
        final domain = raw['domain'] as String?;
        final name = raw['name'] as String?;
        final value = raw['value'] as String?;
        if (domain == null || domain.isEmpty || name == null || name.isEmpty || value == null) continue;
        grouped.putIfAbsent(domain, () => []).add(CookieEntry(
              domain: domain,
              path: raw['path'] as String? ?? '/',
              secure: raw['secure'] as bool? ?? false,
              name: name,
              value: value,
            ));
      }
      return grouped;
    } catch (_) {
      return const {};
    }
  }

  /// [base] (UA/Referer) plus a `Cookie` scoped to [candidate]'s own host,
  /// for the master-playlist fetch `CapturedFormatBuilder` makes for this
  /// one candidate - never [base] widened with every domain's cookies at
  /// once (see [MediaInfo.cookiesByDomain]).
  static Map<String, String> scopedHeaders(
    CapturedMediaCandidate candidate,
    Map<String, String> base,
    Map<String, List<CookieEntry>> cookiesByDomain,
  ) {
    final candidateUri = Uri.tryParse(candidate.url);
    if (candidateUri == null) return base;
    final scopedCookie = CookieScope.headerFor(candidateUri, cookiesByDomain);
    return scopedCookie.isEmpty ? base : {...base, 'Cookie': scopedCookie};
  }
}
