import 'dart:convert';
import 'dart:io';

import '../media_models.dart';

/// Thin HTTP wrapper around Twitch's public GQL endpoint
/// (`gql.twitch.tv/gql`), used with the same public web client id Twitch's
/// own `twitch.tv` frontend uses (`kimne78kx3ncx6brgo4mv6wki5h1ko`, long
/// public knowledge - it identifies "the web player", not a user, and
/// needs no OAuth for public VOD metadata).
///
/// Sends only `Client-ID` - no `Client-Integrity` header. An earlier
/// version of this class also called `gql.twitch.tv/integrity` to mint
/// one and attach it to every request, mirroring what a real browser
/// session does before certain queries. Policy review 2026-09-06
/// (`docs/plan-phase5-coverage.md` Lane D review round 2): that endpoint
/// *is* Twitch's own anti-abuse mechanism, and minting/replaying a token
/// for it is the kind of thing this codebase does not do (see the
/// no-evasion policy header on `BilibiliBuvidClient`/`BilibiliWbiSigner`/
/// `NaverApiSigner`). Removed. Re-verified live the same day that the
/// query [TwitchExtractor] actually needs -
/// `videoPlaybackAccessToken(id: ..., params: {...})` for a real public
/// VOD - returns the full playback token with just `Client-ID`, no
/// integrity header at all; the two ad-hoc queries that did come back
/// null/empty without it during initial investigation (`user.videos`,
/// `game.clips`) were never used by any extractor in this codebase. If a
/// query Twitch actually requires ever needs more than the plain public
/// client id, the extractor lets it fail with a fall-through-eligible
/// status (`CHALLENGE_FAILED`, see `TwitchExtractor._extractVod`'s doc)
/// rather than reaching for another anti-abuse workaround here -
/// `BrowserCaptureExtractor` is the correct next technique, not this
/// class.
class TwitchGqlClient {
  static const publicClientId = 'kimne78kx3ncx6brgo4mv6wki5h1ko';

  final HttpClient Function() _httpClientFactory;

  /// Rewrites the gql endpoint URL; tests point this at a local
  /// `HttpServer` instead of the real `gql.twitch.tv` (same seam as
  /// `TwitterExtractor.endpointBuilder`).
  final Uri Function(String path) _endpointBuilder;

  TwitchGqlClient({
    HttpClient Function()? httpClientFactory,
    Uri Function(String path)? endpointBuilder,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _endpointBuilder = endpointBuilder ?? _defaultEndpoint;

  static Uri _defaultEndpoint(String path) => Uri.parse('https://gql.twitch.tv$path');

  /// Runs a raw (non-persisted) GraphQL [query] with [variables], returning
  /// the decoded `data` object. Throws `RATE_LIMITED`/`NETWORK` for
  /// throttling/server errors, `PARSE_ERROR` for a body that is not JSON
  /// or not shaped like a GQL response. A GQL-level `errors` array with no
  /// `data` is also `PARSE_ERROR` (there is nothing to parse further); a
  /// present-but-null field inside `data` is left for the caller to
  /// interpret (that is "this id does not exist", not a transport failure).
  Future<Map<String, dynamic>> query(String gqlQuery, Map<String, dynamic> variables) async {
    final httpClient = _httpClientFactory();
    try {
      final request = await httpClient.postUrl(_endpointBuilder('/gql'));
      request.headers.set('Client-ID', publicClientId);
      request.headers.set('Content-Type', 'application/json');
      request.add(utf8.encode(jsonEncode({'query': gqlQuery, 'variables': variables})));
      final response = await request.close();
      final raw = await response.transform(utf8.decoder).join();

      if (response.statusCode == 429) {
        throw const MediaExtractionException(
          'RATE_LIMITED',
          'Twitch is throttling this request. Wait a moment and try again.',
        );
      }
      if (response.statusCode != 200) {
        throw MediaExtractionException(
          'NETWORK',
          'Twitch returned HTTP ${response.statusCode} for this request.',
        );
      }

      final Map<String, dynamic> body;
      try {
        body = jsonDecode(raw) as Map<String, dynamic>;
      } on FormatException {
        throw const MediaExtractionException(
          'PARSE_ERROR',
          'Twitch returned a response MiDa could not read as JSON.',
        );
      }

      final data = body['data'];
      if (data is! Map<String, dynamic>) {
        throw const MediaExtractionException(
          'PARSE_ERROR',
          'Twitch returned no usable data for this request.',
        );
      }
      return data;
    } finally {
      httpClient.close(force: true);
    }
  }
}
