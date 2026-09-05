import 'dart:convert';
import 'dart:io';

import '../../utils/url_parser.dart';
import '../media_extractor.dart';
import '../media_models.dart';
import 'syndication_token.dart';
import 'twitter_response_parser.dart';

/// Native X/Twitter extractor. Calls the same public
/// syndication endpoint X's own embedded-tweet widget uses
/// (`cdn.syndication.twimg.com/tweet-result`): a single unauthenticated GET
/// with `User-Agent: Googlebot` and a `token` computed by
/// [SyndicationToken.forTweetId]. No cookies, no guest token, no challenge
/// handling (verified live, `docs/extractor-research.md` section 1,
/// `docs/plan-phase2-extractors.md`).
class TwitterExtractor implements MediaExtractor {
  final HttpClient Function() _httpClientFactory;
  final TwitterResponseParser _parser;

  /// Builds the syndication request URL for a given tweet id + token.
  /// Overridable so tests can point the extractor at a local server
  /// instead of the real `cdn.syndication.twimg.com`.
  final Uri Function(String tweetId, String token) _endpointBuilder;

  TwitterExtractor({
    HttpClient Function()? httpClientFactory,
    TwitterResponseParser? parser,
    Uri Function(String tweetId, String token)? endpointBuilder,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _parser = parser ?? const TwitterResponseParser(),
        _endpointBuilder = endpointBuilder ?? _defaultEndpoint;

  static Uri _defaultEndpoint(String tweetId, String token) => Uri.parse(
        'https://cdn.syndication.twimg.com/tweet-result?id=$tweetId&token=$token',
      );

  @override
  bool canHandle(Uri url) => UrlParser.extractTwitterStatusId(url) != null;

  @override
  Future<MediaInfo> extract(Uri url) async {
    final tweetId = UrlParser.extractTwitterStatusId(url);
    if (tweetId == null) {
      throw MediaExtractionException(
        'UNSUPPORTED_URL',
        'Not a recognizable X/Twitter status URL: $url',
      );
    }
    return extractById(tweetId, sourceUrl: url);
  }

  Future<MediaInfo> extractById(String tweetId, {Uri? sourceUrl}) async {
    final effectiveSourceUrl = sourceUrl ?? Uri.parse('https://x.com/i/status/$tweetId');
    final token = SyndicationToken.forTweetId(tweetId);
    final httpClient = _httpClientFactory();
    try {
      final request = await httpClient.getUrl(_endpointBuilder(tweetId, token));
      request.headers.set('User-Agent', 'Googlebot');
      final response = await request.close();
      final raw = await response.transform(utf8.decoder).join();

      if (response.statusCode == 404) {
        throw const MediaExtractionException(
          'NOT_FOUND',
          'This post no longer exists or the link is wrong.',
        );
      }
      if (response.statusCode == 429) {
        throw const MediaExtractionException(
          'RATE_LIMITED',
          'X is throttling this request. Wait a moment and try again.',
        );
      }
      if (response.statusCode != 200) {
        throw MediaExtractionException(
          'NETWORK',
          'X returned HTTP ${response.statusCode} for this post.',
        );
      }

      final Map<String, dynamic> json;
      try {
        json = jsonDecode(raw) as Map<String, dynamic>;
      } on FormatException {
        throw const MediaExtractionException(
          'PARSE_ERROR',
          'X returned a response MiDa could not read as JSON.',
        );
      }

      return _parser.parse(json, sourceUrl: effectiveSourceUrl, requestHeaders: const {});
    } finally {
      httpClient.close(force: true);
    }
  }
}
