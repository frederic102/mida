import 'dart:convert';
import 'dart:io';

/// Cookies + visitorData collected from a YouTube watch page request.
/// Feeding these into the follow-up `/youtubei/v1/player` call is what
/// keeps that call from being flagged as a bot (see plan doc, 2026-09-05
/// spike). Without this step roughly 2 of 3 requests hit LOGIN_REQUIRED.
class YoutubeSessionData {
  final Map<String, String> cookies;
  final String? visitorData;
  final int watchPageStatusCode;

  const YoutubeSessionData({
    required this.cookies,
    required this.watchPageStatusCode,
    this.visitorData,
  });

  String get cookieHeader =>
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
}

/// Collects a [YoutubeSessionData] by requesting the watch page. The
/// `HttpClient` is injectable so tests can point it at a local server;
/// production code lets it default to a plain `HttpClient()`.
class YoutubeSession {
  static const _seedCookies = {'SOCS': 'CAI', 'PREF': 'hl=en&tz=UTC'};
  static final _visitorDataPattern = RegExp(r'"visitorData":"([^"]+)"');

  final HttpClient _httpClient;

  YoutubeSession({HttpClient? httpClient}) : _httpClient = httpClient ?? HttpClient();

  Future<YoutubeSessionData> create(String videoId, {required String userAgent}) async {
    final request = await _httpClient.getUrl(
      Uri.parse('https://www.youtube.com/watch?v=$videoId'),
    );
    request.headers.set('User-Agent', userAgent);
    request.headers.set('Accept-Language', 'en-us,en;q=0.5');
    request.headers.set('Cookie', mergeCookies(_seedCookies, const []));

    final response = await request.close();
    final setCookieHeaders = response.cookies.map((c) => '${c.name}=${c.value}').toList();
    final html = await response.transform(utf8.decoder).join();

    return YoutubeSessionData(
      cookies: mergeCookies(_seedCookies, setCookieHeaders, asMap: true),
      visitorData: extractVisitorData(html),
      watchPageStatusCode: response.statusCode,
    );
  }

  /// Merges the seed cookies MiDa always sends with `Set-Cookie` values
  /// collected from the watch page response. Pure function so cookie-header
  /// assembly can be unit tested without a network round trip.
  ///
  /// [setCookieHeaders] accepts raw `name=value` pairs (as produced by
  /// `HttpClientResponse.cookies`, or directly for tests).
  static Map<String, String> mergeCookies(
    Map<String, String> seed,
    List<String> setCookieHeaders, {
    bool asMap = true,
  }) {
    final merged = Map<String, String>.from(seed);
    for (final raw in setCookieHeaders) {
      final eq = raw.indexOf('=');
      if (eq <= 0) continue;
      final name = raw.substring(0, eq).trim();
      final value = raw.substring(eq + 1).trim();
      if (name.isEmpty) continue;
      merged[name] = value;
    }
    return merged;
  }

  /// Extracts `visitorData` embedded in the watch page HTML. Returns null
  /// when absent (older/edge responses) so callers can decide whether to
  /// proceed without it.
  static String? extractVisitorData(String html) {
    return _visitorDataPattern.firstMatch(html)?.group(1);
  }
}
