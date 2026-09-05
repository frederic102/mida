import 'dart:convert';
import 'dart:io';

import '../media_models.dart';

/// Finds and caches SoundCloud's web app `client_id`: fetches a track
/// page once, then scans every `<script crossorigin src="https://
/// a-v2.sndcdn.com/assets/...js">` bundle it references for the literal
/// `client_id:"<token>"` one of them embeds - the same technique every
/// open-source SoundCloud downloader uses (SoundCloud's web client has
/// never exposed this value in the page's own HTML, only inside its JS
/// bundles). Verified live 2026-09-05
/// (`docs/plan-phase5-coverage.md` Lane D follow-up report): a real page
/// fetch's bundle `55-<hash>.js` contained
/// `client_id:"Pb72ranhoyt6gw7hM7TkzUItXlMWSNSo"`, confirmed valid by a
/// live `api-v2.soundcloud.com/search/tracks` call (a bad client_id gets
/// `401`; this one got `200`).
///
/// [get] caches the found id in a static field for the process lifetime
/// (SoundCloud does not rotate it on every deploy, and re-scanning 8
/// bundles on every single track resolution this app makes would be
/// wasteful) - the coordinator's explicit ask ("cache it in memory").
/// Call [reset] (tests only) to clear the cache between cases.
class SoundCloudClientIdResolver {
  static String? _cachedClientId;

  static final _scriptSrcPattern = RegExp(r'<script[^>]*\bsrc="(https?://[^"]+\.js)"');
  static final _clientIdLiteralPattern = RegExp(r'client_id\s*:\s*"([0-9a-zA-Z_-]{16,64})"');

  final HttpClient Function() _httpClientFactory;
  final Uri Function(Uri url) _pageRequestUrlBuilder;
  final Uri Function(Uri url) _scriptRequestUrlBuilder;

  SoundCloudClientIdResolver({
    HttpClient Function()? httpClientFactory,
    Uri Function(Uri url)? pageRequestUrlBuilder,
    Uri Function(Uri url)? scriptRequestUrlBuilder,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _pageRequestUrlBuilder = pageRequestUrlBuilder ?? _identity,
        _scriptRequestUrlBuilder = scriptRequestUrlBuilder ?? _identity;

  static Uri _identity(Uri url) => url;

  /// Test-only: clears the in-memory cache so each test starts fresh.
  static void reset() => _cachedClientId = null;

  /// Returns the cached client_id if one is already known; otherwise
  /// fetches [pageUrl] and scans its script bundles for one, caching
  /// whatever is found. Throws [MediaExtractionException] (`PARSE_ERROR`,
  /// fall-through eligible) when no bundle yields a match - see the class
  /// doc for what that means.
  Future<String> get(Uri pageUrl) async {
    final cached = _cachedClientId;
    if (cached != null) return cached;

    final html = await _fetchPage(pageUrl);
    final scriptUrls = _scriptSrcPattern.allMatches(html).map((m) => m.group(1)!).toSet();

    for (final scriptUrl in scriptUrls) {
      final body = await _fetchScript(scriptUrl);
      if (body == null) continue;
      final match = _clientIdLiteralPattern.firstMatch(body);
      if (match != null) {
        _cachedClientId = match.group(1)!;
        return _cachedClientId!;
      }
    }

    throw const MediaExtractionException(
      'PARSE_ERROR',
      'MiDa could not find a SoundCloud client_id in this page\'s scripts.',
    );
  }

  Future<String> _fetchPage(Uri pageUrl) async {
    final httpClient = _httpClientFactory();
    try {
      final request = await httpClient.getUrl(_pageRequestUrlBuilder(pageUrl));
      final response = await request.close();
      return await response.transform(utf8.decoder).join();
    } finally {
      httpClient.close(force: true);
    }
  }

  Future<String?> _fetchScript(String scriptUrl) async {
    final httpClient = _httpClientFactory();
    try {
      final request = await httpClient.getUrl(_scriptRequestUrlBuilder(Uri.parse(scriptUrl)));
      final response = await request.close();
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      return await response.transform(utf8.decoder).join();
    } finally {
      httpClient.close(force: true);
    }
  }
}
