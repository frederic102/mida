import 'dart:convert';
import 'dart:io';

import '../media_models.dart';

/// Thin HTTP wrapper around Twitch's public GQL endpoint
/// (`gql.twitch.tv/gql`), used with the same public web client id Twitch's
/// own `twitch.tv` frontend uses (`kimne78kx3ncx6brgo4mv6wki5h1ko`, long
/// public knowledge - it identifies "the web player", not a user, and
/// needs no OAuth for public VOD/clip metadata). Verified live 2026-09-05
/// (`docs/plan-phase5-coverage.md` Lane D): ad-hoc (non-persisted) GraphQL
/// queries are accepted with just this client id; some fields
/// (`user.videos`, `game.clips`) return null/empty without also sending a
/// `Client-Integrity` token, obtained anonymously (no login) from a
/// separate `gql.twitch.tv/integrity` POST - both steps live in this
/// class so [TwitchExtractor] only ever calls [query].
class TwitchGqlClient {
  static const publicClientId = 'kimne78kx3ncx6brgo4mv6wki5h1ko';

  final HttpClient Function() _httpClientFactory;

  /// Rewrites both the integrity and gql endpoint URLs; tests point this
  /// at a local `HttpServer` instead of the real `gql.twitch.tv` (same
  /// seam as `TwitterExtractor.endpointBuilder`).
  final Uri Function(String path) _endpointBuilder;

  TwitchGqlClient({
    HttpClient Function()? httpClientFactory,
    Uri Function(String path)? endpointBuilder,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _endpointBuilder = endpointBuilder ?? _defaultEndpoint;

  static Uri _defaultEndpoint(String path) => Uri.parse('https://gql.twitch.tv$path');

  /// Fetches a fresh anonymous integrity token. Twitch's own token has a
  /// short lifetime (`expiration` in the response, typically minutes), so
  /// this is not cached across calls - each [query] call gets its own.
  Future<String> _fetchIntegrityToken(HttpClient client) async {
    final request = await client.postUrl(_endpointBuilder('/integrity'));
    request.headers.set('Client-ID', publicClientId);
    request.headers.set('Content-Type', 'application/json');
    request.add(utf8.encode('{}'));
    final response = await request.close();
    final raw = await response.transform(utf8.decoder).join();

    if (response.statusCode != 200) {
      throw MediaExtractionException(
        'NETWORK',
        'Twitch returned HTTP ${response.statusCode} while requesting an integrity token.',
      );
    }
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final token = json['token'] as String?;
    if (token == null) {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'Twitch did not return an integrity token.',
      );
    }
    return token;
  }

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
      final integrityToken = await _fetchIntegrityToken(httpClient);

      final request = await httpClient.postUrl(_endpointBuilder('/gql'));
      request.headers.set('Client-ID', publicClientId);
      request.headers.set('Client-Integrity', integrityToken);
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
