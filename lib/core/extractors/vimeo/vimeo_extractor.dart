import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import '../../net/host_policy.dart';
import '../media_extractor.dart';
import '../media_models.dart';
import 'vimeo_config_parser.dart';

/// Native Vimeo extractor for public `vimeo.com/<id>[/<hash>]` and
/// `player.vimeo.com/video/<id>[?h=<hash>]` URLs. Calls the same
/// unauthenticated player-config endpoint Vimeo's own web/embed player calls
/// to bootstrap playback (`https://player.vimeo.com/video/<id>/config`),
/// sent with a `Referer: https://vimeo.com/` header - the header the real
/// player sends and the endpoint itself requires. An unlisted video's
/// privacy hash (the `/<hash>` path segment or `?h=` query) is forwarded
/// as the config endpoint's own `h` parameter, exactly as the embed player
/// does; nothing else is added.
///
/// This is the fix for the generic tier's Vimeo failure documented in
/// `docs/coverage-corpus.md`: generic page analysis finds only byte-range
/// CMAF fragment URLs, so every candidate it builds is missing either audio
/// or video. The config endpoint's own `progressive[]` (muxed mp4) and
/// `hls.cdns[...].url` (a real HLS master) fields always carry sound.
///
/// No embed-token games, challenge solving, fingerprint spoofing, or DRM/
/// certificate bypass, per `docs/supported-sites.md`. Only an explicit
/// privacy signal from Vimeo (a `403` whose body is Vimeo's own
/// private/password JSON) is terminal `LOGIN_REQUIRED`; a `403` with any
/// other body (a WAF or address ban page, for example) is a technique
/// failure (`CHALLENGE_FAILED`) so the registry still tries the generic and
/// browser tiers, which is what worked for Vimeo before this extractor
/// existed.
class VimeoExtractor implements MediaExtractor {
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';
  static const _referer = 'https://vimeo.com/';

  /// Upper bound on the config body this extractor will read. A real
  /// config is tens of kilobytes; anything larger is not a config.
  static const int _maxBodyBytes = 2 * 1024 * 1024;
  static const Duration _requestTimeout = Duration(seconds: 20);

  /// Exactly `vimeo.com`/`www.vimeo.com`: `<numeric id>` optionally
  /// followed by `/<unlisted hash>` or a trailing slash. Channel, showcase
  /// and user pages do not match.
  static final _vimeoComIdPattern = RegExp(r'^/(\d+)(?:/([0-9a-zA-Z]+))?/?$');

  /// Exactly `player.vimeo.com`: `/video/<numeric id>` and nothing after
  /// it but an optional slash. `/video/<id>/config` or `/video/<id>junk`
  /// are not a video page and are left to the generic tier.
  static final _playerIdPattern = RegExp(r'^/video/(\d+)/?$');

  static const Set<String> _pageHosts = {'vimeo.com', 'www.vimeo.com'};
  static const Set<String> _playerHosts = {'player.vimeo.com'};

  final HttpClient Function() _httpClientFactory;
  final VimeoConfigParser _parser;

  /// Rewrites the config endpoint URL each request is sent to. Identity by
  /// default; tests point it at a local `HttpServer`.
  final Uri Function(Uri url) _configRequestUrlBuilder;

  /// Test-only: exempts the (rewritten) config URL's own host from the
  /// private-network check so a loopback fixture server can answer.
  /// Redirect hops are always checked regardless. Production code must
  /// never set this to true.
  final bool allowPrivateHosts;

  VimeoExtractor({
    HttpClient Function()? httpClientFactory,
    VimeoConfigParser? parser,
    Uri Function(Uri url)? configRequestUrlBuilder,
    this.allowPrivateHosts = false,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _parser = parser ?? const VimeoConfigParser(),
        _configRequestUrlBuilder = configRequestUrlBuilder ?? _identity;

  static Uri _identity(Uri url) => url;

  /// `(id, privacy hash or null)` for a URL this extractor owns, else null.
  static (String, String?)? _videoRefFor(Uri url) {
    final scheme = url.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') return null;
    final host = url.host.toLowerCase();
    if (_pageHosts.contains(host)) {
      final match = _vimeoComIdPattern.firstMatch(url.path);
      if (match == null) return null;
      return (match.group(1)!, match.group(2) ?? _hashQuery(url));
    }
    if (_playerHosts.contains(host)) {
      final match = _playerIdPattern.firstMatch(url.path);
      if (match == null) return null;
      return (match.group(1)!, _hashQuery(url));
    }
    return null;
  }

  static String? _hashQuery(Uri url) {
    final h = url.queryParameters['h'];
    if (h == null || h.isEmpty || !RegExp(r'^[0-9a-zA-Z]+$').hasMatch(h)) return null;
    return h;
  }

  @override
  bool canHandle(Uri url) => _videoRefFor(url) != null;

  @override
  Future<MediaInfo> extract(Uri url) async {
    final ref = _videoRefFor(url);
    if (ref == null) {
      throw MediaExtractionException('UNSUPPORTED_URL', 'Not a recognizable Vimeo video URL: $url');
    }
    return extractById(ref.$1, privacyHash: ref.$2, sourceUrl: url);
  }

  Future<MediaInfo> extractById(String id, {String? privacyHash, Uri? sourceUrl}) async {
    final effectiveSourceUrl = sourceUrl ?? Uri.parse('https://vimeo.com/$id');
    const requestHeaders = {'User-Agent': _userAgent, 'Referer': _referer};

    final endpoint = Uri.https('player.vimeo.com', '/video/$id/config', privacyHash == null ? null : {'h': privacyHash});
    final requestUrl = _configRequestUrlBuilder(endpoint);

    final httpClient = _httpClientFactory();
    try {
      final HttpClientResponse response;
      try {
        response = await HostPolicy.guardedRequest(
          httpClient,
          requestUrl,
          useHead: false,
          allowPrivateHosts: allowPrivateHosts,
          configureRequest: (request) {
            request.headers.set('User-Agent', _userAgent);
            request.headers.set('Referer', _referer);
            request.headers.set('Accept', 'application/json');
          },
        ).timeout(_requestTimeout);
      } on MediaExtractionException {
        rethrow;
      } on TimeoutException {
        throw const MediaExtractionException('NETWORK', 'Vimeo did not answer in time.');
      } on IOException catch (e) {
        throw MediaExtractionException('NETWORK', 'Could not reach Vimeo: $e');
      }

      final status = response.statusCode;
      // Status first, body second: a refusal must never make this read an
      // unbounded body before deciding what it means.
      if (status == 404) {
        await response.drain<void>();
        throw const MediaExtractionException('NOT_FOUND', 'This Vimeo video no longer exists or the link is wrong.');
      }
      if (status == 429) {
        await response.drain<void>();
        throw const MediaExtractionException('RATE_LIMITED', 'Vimeo is throttling this request. Wait a moment and try again.');
      }

      final raw = await _readBounded(response);

      if (status == 403 || status == 401) {
        // Only Vimeo's own privacy answer is terminal. Anything else at
        // 403 (an HTML "Sorry" page, an address ban, an edge WAF) is a
        // technique failure and must fall through to the other tiers.
        if (VimeoConfigParser.isPrivacyRefusal(raw)) {
          throw const MediaExtractionException(
            'LOGIN_REQUIRED',
            'This Vimeo video is private, unlisted without its hash, or password protected.',
          );
        }
        throw MediaExtractionException(
          'CHALLENGE_FAILED',
          'Vimeo refused the player config request (HTTP $status) without a privacy reason; trying another method.',
        );
      }
      if (status != 200) {
        throw MediaExtractionException('NETWORK', 'Vimeo returned HTTP $status for this video.');
      }

      final Object? decoded;
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        throw const MediaExtractionException('PARSE_ERROR', 'Vimeo returned a response MiDa could not read as JSON.');
      }
      if (decoded is! Map<String, dynamic>) {
        throw const MediaExtractionException('PARSE_ERROR', 'Vimeo returned JSON that is not a player config object.');
      }

      return _parser.parse(decoded, sourceUrl: effectiveSourceUrl, requestHeaders: requestHeaders);
    } finally {
      httpClient.close(force: true);
    }
  }

  /// Reads at most [_maxBodyBytes] of [response] as UTF-8, cancelling the
  /// stream the moment the cap is hit.
  static Future<String> _readBounded(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    final completer = Completer<void>();
    late final StreamSubscription<List<int>> sub;
    sub = response.listen(
      (chunk) {
        final remaining = _maxBodyBytes - total;
        if (remaining <= 0) return;
        final take = chunk.length < remaining ? chunk.length : remaining;
        builder.add(take == chunk.length ? chunk : chunk.sublist(0, take));
        total += take;
        if (total >= _maxBodyBytes) {
          sub.cancel();
          if (!completer.isCompleted) completer.complete();
        }
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (Object e, StackTrace _) {
        if (!completer.isCompleted) completer.completeError(e);
      },
      cancelOnError: true,
    );
    try {
      await completer.future.timeout(_requestTimeout);
    } on TimeoutException {
      await sub.cancel();
      throw const MediaExtractionException('NETWORK', 'Vimeo stopped sending the player config.');
    } on IOException catch (e) {
      throw MediaExtractionException('NETWORK', 'Connection to Vimeo failed while reading: $e');
    }
    return utf8.decode(builder.toBytes(), allowMalformed: true);
  }
}
