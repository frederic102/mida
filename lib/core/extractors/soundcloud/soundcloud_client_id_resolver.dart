import 'dart:convert';
import 'dart:io';

import '../media_models.dart';

/// Finds SoundCloud's web app `client_id` by fetching every
/// `<script crossorigin src="...">` bundle a track page loads and
/// regex-scanning each for the literal the bundle assigns it to
/// (`,client_id:"<32-char-id>"`), the same technique every open-source
/// SoundCloud downloader uses (SoundCloud's web client has never exposed
/// this value in the page's own HTML - only inside its JS bundles).
///
/// Not live-confirmed (`docs/plan-phase5-coverage.md` Lane D report): the
/// 8 bundles a live track page referenced 2026-09-05 did not contain the
/// literal within this pass's request budget - SoundCloud's current bundle
/// split appears to lazy-load the module that holds it only once the
/// player actually initializes (consistent with the MSE/lazy-chunk pattern
/// Lane A's plan section describes for other sites), which a plain page
/// fetch does not trigger. [resolve] is written to scan every bundle it is
/// given, not a hardcoded subset, so it will pick the id up the moment a
/// future bundle split does inline it; until then this throws
/// `PARSE_ERROR`, which `ExtractorRegistry` treats as fall-through
/// eligible (falls back to `BrowserCaptureExtractor`, which - unlike this
/// class - actually executes the page's JS and can observe the client_id
/// on a real outgoing request).
class SoundCloudClientIdResolver {
  static final _scriptSrcPattern = RegExp(r'<script[^>]*\bsrc="(https?://[^"]+\.js)"');
  static final _clientIdLiteralPattern = RegExp(r'client_id\s*:\s*"([0-9a-zA-Z_-]{16,64})"');

  final HttpClient Function() _httpClientFactory;

  SoundCloudClientIdResolver({HttpClient Function()? httpClientFactory})
      : _httpClientFactory = httpClientFactory ?? HttpClient.new;

  /// Throws [MediaExtractionException] (`PARSE_ERROR`) when no script on
  /// the page yields a match - see the class doc for what that means.
  Future<String> resolve(String pageHtml) async {
    final scriptUrls = _scriptSrcPattern.allMatches(pageHtml).map((m) => m.group(1)!).toSet();

    for (final scriptUrl in scriptUrls) {
      final httpClient = _httpClientFactory();
      try {
        final request = await httpClient.getUrl(Uri.parse(scriptUrl));
        final response = await request.close();
        if (response.statusCode != 200) {
          await response.drain<void>();
          continue;
        }
        final body = await response.transform(utf8.decoder).join();
        final match = _clientIdLiteralPattern.firstMatch(body);
        if (match != null) return match.group(1)!;
      } finally {
        httpClient.close(force: true);
      }
    }

    throw const MediaExtractionException(
      'PARSE_ERROR',
      'MiDa could not find a SoundCloud client_id in this page\'s scripts.',
    );
  }
}
