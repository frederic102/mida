import 'dart:convert';
import 'dart:io';

import '../media_extractor.dart';
import '../media_models.dart';
import 'odysee_resolve_parser.dart';

/// Native Odysee extractor for `odysee.com/@<channel>[:<id>]/<name>[:<id>]`
/// (and channel-less `odysee.com/<name>[:<id>]`) URLs.
///
/// Sequence, verified live 2026-09-05 (`docs/plan-phase5-coverage.md`
/// Lane D follow-up, real claim `@lbry:3f/odysee:7`):
/// 1. Convert the URL's `:`-separated claim id shorthand into the
///    `lbry://name#id` form the resolver expects, and POST it to
///    `api.na-backend.odysee.com/api/v1/proxy?m=resolve`
///    ([OdyseeResolveParser]) - the same public, unauthenticated
///    JSON-RPC backend Odysee's own web player calls.
/// 2. Build the stream URL directly from the resolved claim's `name`,
///    `claim_id`, and `value.source.sd_hash`:
///    `player.odycdn.com/api/v4/streams/tc/<name>/<claim_id>/<sd_hash>/master.m3u8`.
///    Confirmed live: the sibling `streams/free/.../<sd_hash prefix>`
///    shape (no extension) 401s without a `Referer`/`Origin`, then
///    308-redirects to this exact `streams/tc/.../master.m3u8` URL once
///    they are sent - so this extractor builds the `tc` URL directly
///    (skipping the redirect hop) and always sends both headers.
class OdyseeExtractor implements MediaExtractor {
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';
  static const _referer = 'https://odysee.com/';
  static const _origin = 'https://odysee.com';

  /// `/@<channel>[:<channelId>]/<name>[:<nameId>]`.
  static final _channelPathPattern = RegExp(r'^/(@[^/:]+)(?::([0-9a-fA-F]+))?/([^/:]+)(?::([0-9a-fA-F]+))?$');

  /// `/<name>[:<nameId>]` (channel-less content - `name` must not start
  /// with `@`, that shape is [_channelPathPattern]'s job).
  static final _directPathPattern = RegExp(r'^/([^/@:][^/:]*)(?::([0-9a-fA-F]+))?$');

  final HttpClient Function() _httpClientFactory;
  final OdyseeResolveParser _parser;

  /// Rewrites the resolve endpoint URL. Identity by default; tests point
  /// it at a local `HttpServer`.
  final Uri Function(Uri url) _resolveRequestUrlBuilder;

  OdyseeExtractor({
    HttpClient Function()? httpClientFactory,
    OdyseeResolveParser? parser,
    Uri Function(Uri url)? resolveRequestUrlBuilder,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _parser = parser ?? const OdyseeResolveParser(),
        _resolveRequestUrlBuilder = resolveRequestUrlBuilder ?? _identity;

  static Uri _identity(Uri url) => url;

  static bool _hostMatches(String host, String domain) => host == domain || host.endsWith('.$domain');

  /// Returns the `lbry://` form of [url]'s path, or `null` if the path
  /// does not match either recognized shape.
  String? _lbryUrlFor(Uri url) {
    if (!_hostMatches(url.host.toLowerCase(), 'odysee.com')) return null;

    final channelMatch = _channelPathPattern.firstMatch(url.path);
    if (channelMatch != null) {
      final channel = channelMatch.group(1)!;
      final channelId = channelMatch.group(2);
      final name = channelMatch.group(3)!;
      final nameId = channelMatch.group(4);
      final channelPart = channelId != null ? '$channel#$channelId' : channel;
      final namePart = nameId != null ? '$name#$nameId' : name;
      return 'lbry://$channelPart/$namePart';
    }

    final directMatch = _directPathPattern.firstMatch(url.path);
    if (directMatch != null) {
      final name = directMatch.group(1)!;
      final nameId = directMatch.group(2);
      return 'lbry://${nameId != null ? '$name#$nameId' : name}';
    }
    return null;
  }

  @override
  bool canHandle(Uri url) => _lbryUrlFor(url) != null;

  @override
  Future<MediaInfo> extract(Uri url) async {
    final lbryUrl = _lbryUrlFor(url);
    if (lbryUrl == null) {
      throw MediaExtractionException('UNSUPPORTED_URL', 'Not a recognizable Odysee URL: $url');
    }

    final json = await _resolve(lbryUrl);
    final claim = _parser.parse(json, lbryUrl: lbryUrl);

    final streamUrl = 'https://player.odycdn.com/api/v4/streams/tc/${claim.name}/${claim.claimId}/'
        '${claim.sdHash}/master.m3u8';

    return MediaInfo(
      id: claim.claimId,
      title: claim.title,
      author: claim.author,
      thumbnailUrl: claim.thumbnailUrl,
      duration: claim.duration,
      formats: [
        MediaFormat(
          id: 'master',
          url: streamUrl,
          container: 'm3u8',
          width: claim.width,
          height: claim.height,
          hasVideo: true,
          hasAudio: true,
        ),
      ],
      sourceUrl: url,
      requestHeaders: const {'User-Agent': _userAgent, 'Referer': _referer, 'Origin': _origin},
    );
  }

  Future<Map<String, dynamic>> _resolve(String lbryUrl) async {
    final httpClient = _httpClientFactory();
    try {
      final endpoint = Uri.parse('https://api.na-backend.odysee.com/api/v1/proxy?m=resolve');
      final request = await httpClient.postUrl(_resolveRequestUrlBuilder(endpoint));
      request.headers.set('Content-Type', 'application/json');
      request.add(utf8.encode(jsonEncode({
        'jsonrpc': '2.0',
        'method': 'resolve',
        'params': {
          'urls': [lbryUrl],
        },
      })));
      final response = await request.close();
      final raw = await response.transform(utf8.decoder).join();

      if (response.statusCode == 429) {
        throw const MediaExtractionException(
          'RATE_LIMITED',
          'Odysee is throttling this request. Wait a moment and try again.',
        );
      }
      if (response.statusCode != 200) {
        throw MediaExtractionException(
          'NETWORK',
          'Odysee returned HTTP ${response.statusCode} for this claim.',
        );
      }

      try {
        return jsonDecode(raw) as Map<String, dynamic>;
      } on FormatException {
        throw const MediaExtractionException(
          'PARSE_ERROR',
          'Odysee returned a response MiDa could not read as JSON.',
        );
      }
    } finally {
      httpClient.close(force: true);
    }
  }
}
