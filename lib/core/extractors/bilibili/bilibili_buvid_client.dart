import 'dart:convert';
import 'dart:io';

import '../media_models.dart';

/// Fetches the anonymous `buvid3`/`buvid4` device-id cookies Bilibili's
/// WAF expects on every request to `*.bilibili.com`
/// (`x/frontend/finger/spi`, a public, unauthenticated, no-login-required
/// endpoint - this is the same bootstrap step Bilibili's own web player
/// does on first load). Verified live 2026-09-05
/// (`docs/plan-phase5-coverage.md` Lane D follow-up): this endpoint
/// answered normally even when the watch page and `x/web-interface/view`
/// were both getting a WAF-blocked 412 from the same network, so sending
/// these cookies on the subsequent page/API requests is the fix for that
/// block (see `BilibiliExtractor`'s doc for the end-to-end sequence).
class BilibiliBuvidClient {
  final HttpClient Function() _httpClientFactory;

  /// Rewrites the finger/spi endpoint URL. Identity by default; tests
  /// point it at a local `HttpServer`.
  final Uri Function(Uri url) _requestUrlBuilder;

  BilibiliBuvidClient({
    HttpClient Function()? httpClientFactory,
    Uri Function(Uri url)? requestUrlBuilder,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _requestUrlBuilder = requestUrlBuilder ?? _identity;

  static Uri _identity(Uri url) => url;

  static const _defaultEndpoint = 'https://api.bilibili.com/x/frontend/finger/spi';
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  /// Returns `{'buvid3': ..., 'buvid4': ...}`, or an empty map (not a
  /// throw) on any failure - the caller treats these cookies as
  /// best-effort hardening, not a hard requirement, so a transient
  /// failure here should not sink the whole extraction when the
  /// downstream requests might succeed without them anyway.
  Future<Map<String, String>> fetchCookies() async {
    final httpClient = _httpClientFactory();
    try {
      final request = await httpClient.getUrl(_requestUrlBuilder(Uri.parse(_defaultEndpoint)));
      request.headers.set('User-Agent', _userAgent);
      request.headers.set('Referer', 'https://www.bilibili.com/');
      final response = await request.close();
      final raw = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) return const {};

      final json = jsonDecode(raw);
      final data = json is Map ? json['data'] : null;
      if (data is! Map) return const {};

      final b3 = data['b_3'];
      final b4 = data['b_4'];
      return {
        if (b3 is String) 'buvid3': b3,
        if (b4 is String) 'buvid4': b4,
      };
    } on FormatException {
      return const {};
    } on MediaExtractionException {
      rethrow;
    } finally {
      httpClient.close(force: true);
    }
  }
}
