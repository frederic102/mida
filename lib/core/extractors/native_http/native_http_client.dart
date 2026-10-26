import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../net/host_policy.dart';
import '../../utils/url_parser.dart';
import '../generic/bounded_body.dart';
import '../generic/format_expander.dart';
import '../media_models.dart';
import 'native_host_list.dart';

/// Which body cap a request gets (phase 7 native-extractor policy).
enum NativeBodyKind {
  /// An HTML page: capped at [NativeHttpClient.pageCapBytes] (5 MiB).
  page,

  /// A JSON API answer: capped at [NativeHttpClient.apiCapBytes] (2 MiB).
  api,
}

/// One answer: the status, the URL the body actually came from after
/// redirects, and at most the kind's cap of its body.
class NativeHttpResponse {
  final int statusCode;
  final Uri effectiveUrl;
  final String body;

  /// True when the body hit its byte cap and was cut short.
  final bool truncated;

  const NativeHttpResponse({
    required this.statusCode,
    required this.effectiveUrl,
    required this.body,
    this.truncated = false,
  });
}

/// Thrown out of `HostPolicy.guardedRequest`'s `onHop` to stop a redirect
/// chain at its first `Location` target without requesting it.
class _ShortLinkTarget implements Exception {
  final Uri target;
  const _ShortLinkTarget(this.target);
}

/// The only network code shared by the Pinterest, SOOP, LinkedIn and
/// Xiaohongshu extractors: plain HTTPS GET/POST with a normal desktop
/// browser User-Agent and nothing else that identifies or fingerprints.
///
/// Policy enforced here (so each extractor cannot forget it):
/// - **HTTPS only**: every hop, the first and every redirect, must be
///   `https`. A plain-`http` URL is refused (`UNSUPPORTED_URL`), so an
///   HTTPS -> HTTP redirect is never followed.
/// - **Every hop through `HostPolicy`** (loopback/private/link-local host
///   check plus the DNS-rebinding resolve). GET follows redirects through
///   `HostPolicy.guardedRequest`; POST does the same two checks on its one
///   hop and never follows a redirect.
/// - **Per-call hop allow-list** ([get]'s `acceptHop`): a page may only
///   redirect within the platform's own hosts.
/// - **Bounded**: 5 MiB for pages, 2 MiB for JSON; the request (headers,
///   across all redirect hops) and the body read each have their own
///   [timeout], so one call can take up to 2 x [timeout] (2 x 20 s by
///   default); on expiry the client is closed. A redirect hop's own body is
///   drained by `HostPolicy.guardedRequest` (time-bounded, not byte-bounded).
/// - **No cookies**: none sent, none stored, none synthesized.
/// - Every message that can hold a URL passes `UrlParser.redactUrlsInText`.
class NativeHttpClient {
  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  static const int pageCapBytes = 5 * 1024 * 1024;
  static const int apiCapBytes = 2 * 1024 * 1024;
  static const Duration defaultTimeout = Duration(seconds: 20);

  /// Display name used in messages ("Pinterest", "SOOP", ...).
  final String service;
  final Duration timeout;
  final HttpClient Function() _httpClientFactory;
  final Future<List<InternetAddress>> Function(String host) _resolveHost;

  /// Hosts media (playlists, files) may live on. When set, [fetchText] (the
  /// HLS playlist reads) refuses an initial URL or any redirect hop outside
  /// it before requesting it, and extractors drop format URLs outside it
  /// ([mediaUrlAllowed]). Null (the default) applies no media allow-list.
  final NativeHostList? mediaHosts;

  /// [httpClientFactory] and [resolveHost] are test seams: a loopback TLS
  /// fixture server and a fake public address, so the guards run
  /// unmodified without a real network or DNS query.
  NativeHttpClient({
    required this.service,
    this.timeout = defaultTimeout,
    this.mediaHosts,
    HttpClient Function()? httpClientFactory,
    Future<List<InternetAddress>> Function(String host)? resolveHost,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _resolveHost = resolveHost ?? InternetAddress.lookup;

  /// A client with the same transport, deadline and resolver but [hosts] as
  /// its media allow-list. Extractors apply their own CDN list this way, so
  /// an injected test client cannot skip it.
  NativeHttpClient withMediaHosts(NativeHostList hosts) => NativeHttpClient(
        service: service,
        timeout: timeout,
        mediaHosts: hosts,
        httpClientFactory: _httpClientFactory,
        resolveHost: _resolveHost,
      );

  /// True when [url] may be used as a media URL: always, without a
  /// [mediaHosts] list; otherwise only when its host is on the list.
  bool mediaUrlAllowed(String url) => mediaHosts?.allowsUrl(url) ?? true;

  /// [formats] without the ones whose URL is off the media allow-list. Apply
  /// it to what `FormatExpander` returns: an HLS master on an allowed host
  /// may still list variant or rendition URLs on any other host.
  List<MediaFormat> filterAllowedFormats(List<MediaFormat> formats) =>
      [for (final f in formats) if (mediaUrlAllowed(f.url)) f];

  /// GET [url], following redirects hop by hop. [acceptHop] (when given)
  /// must return true for every hop's URL, else `PARSE_ERROR` (the chain
  /// left the platform).
  Future<NativeHttpResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
    NativeBodyKind kind = NativeBodyKind.page,
    int? maxBytes,
    bool Function(Uri hop)? acceptHop,
  }) {
    return _run(url, kind, maxBytes, (client, onHop) {
      return HostPolicy.guardedRequest(
        client,
        url,
        useHead: false,
        resolveHost: _resolveHost,
        onHop: (hop) {
          _checkHop(hop, acceptHop);
          onHop(hop);
        },
        configureRequest: (request) => _applyHeaders(request, headers),
      );
    });
  }

  /// POST an `application/x-www-form-urlencoded` form to [url]. The one hop
  /// gets the same `HostPolicy` checks as a GET hop; a redirect answer is
  /// returned as-is (the caller maps it to `NETWORK`), never followed.
  Future<NativeHttpResponse> postForm(
    Uri url,
    Map<String, String> fields, {
    Map<String, String> headers = const {},
    NativeBodyKind kind = NativeBodyKind.api,
  }) {
    final payload = utf8.encode(fields.entries
        .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&'));
    return _run(url, kind, null, (client, onHop) async {
      _checkHop(url, null);
      onHop(url);
      HostPolicy.assertAllowedHost(url, context: 'this request');
      await HostPolicy.assertResolvesToPublicHost(url, resolveHost: _resolveHost);
      final request = await client.postUrl(url);
      request.followRedirects = false;
      _applyHeaders(request, headers);
      request.headers.set('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
      request.contentLength = payload.length;
      request.add(payload);
      return request.close();
    });
  }

  /// Resolves a short link to its first `Location` target without
  /// requesting that target. [accept] must approve the target's URL (it is
  /// the platform's host allow-list); a target it refuses is `PARSE_ERROR`.
  /// A short link that does not redirect is `PARSE_ERROR` (or the usual
  /// status mapping for 404/429/...).
  ///
  /// Some short links go through a redirector first (`pin.it` ->
  /// `api.pinterest.com/url_shortener/<code>/redirect/` -> the pin). With
  /// [followHop], up to [maxFollowHops] such intermediate hops are requested
  /// when [followHop] approves their URL; any other non-target hop is refused
  /// before it is requested.
  Future<Uri> resolveShortLink(
    Uri url, {
    required bool Function(Uri target) accept,
    bool Function(Uri hop)? followHop,
    int maxFollowHops = 0,
    Map<String, String> headers = const {},
  }) async {
    final httpClient = _httpClientFactory();
    var hops = 0;
    try {
      final HttpClientResponse response;
      try {
        response = await HostPolicy.guardedRequest(
          httpClient,
          url,
          useHead: false,
          resolveHost: _resolveHost,
          onHop: (hop) {
            _checkHop(hop, null);
            hops++;
            if (hops < 2) return;
            final unsafe = HostPolicy.isDisallowedHost(hop);
            if (!unsafe && !accept(hop)) {
              // Not the final target: follow it (it is requested, through
              // HostPolicy) only if the caller allows this host and the
              // intermediate-hop budget is not spent.
              final follow = followHop;
              if (follow != null && hops - 1 <= maxFollowHops && follow(hop)) return;
            }
            if (unsafe || !accept(hop)) {
              throw MediaExtractionException(
                'PARSE_ERROR',
                '$service short link did not lead to a $service page; trying another method.',
              );
            }
            throw _ShortLinkTarget(hop);
          },
          configureRequest: (request) => _applyHeaders(request, headers),
        ).timeout(timeout);
      } on _ShortLinkTarget catch (found) {
        return found.target;
      } on MediaExtractionException catch (e) {
        throw _redacted(e);
      } on TimeoutException {
        throw MediaExtractionException('NETWORK', '$service did not answer in time.');
      } on IOException catch (e) {
        throw MediaExtractionException('NETWORK', _redact('Could not reach $service: $e'));
      } on FormatException {
        throw _malformedRedirect;
      } on ArgumentError {
        throw _malformedRedirect;
      }
      await discardBody(response);
      throwForStatus(response.statusCode, service);
      throw MediaExtractionException('PARSE_ERROR', '$service short link did not redirect; trying another method.');
    } finally {
      httpClient.close(force: true);
    }
  }

  /// Adapter for `FormatExpander.fetchText` (HLS playlist reads), guarded
  /// and bounded like every other fetch here. With a [mediaHosts] list the
  /// initial URL and every redirect hop must be on it, checked before the
  /// request is made (an off-list URL is `PARSE_ERROR`, which the expander
  /// turns into "no formats"). Without a list any public HTTPS host passes.
  Future<FetchedBody> fetchText(Uri url, {Map<String, String>? extraHeaders, int? maxBytes}) async {
    final hosts = mediaHosts;
    final response = await get(
      url,
      headers: extraHeaders ?? const {},
      kind: NativeBodyKind.api,
      maxBytes: maxBytes,
      acceptHop: hosts == null ? null : (hop) => hosts.allowsHost(hop.host),
    );
    return FetchedBody(statusCode: response.statusCode, body: response.body);
  }

  /// Maps a non-200 [status] to the project's exception statuses. Returns
  /// normally for 200.
  static void throwForStatus(int status, String service) {
    if (status == 200) return;
    if (status == 404 || status == 410) {
      throw MediaExtractionException('NOT_FOUND', 'This $service link no longer exists or is wrong.');
    }
    if (status == 429) {
      throw MediaExtractionException('RATE_LIMITED', '$service is throttling this request. Wait a moment and try again.');
    }
    if (status == 401 || status == 403) {
      throw MediaExtractionException(
        'CHALLENGE_FAILED',
        '$service refused the request (HTTP $status); trying another method.',
      );
    }
    throw MediaExtractionException('NETWORK', '$service returned HTTP $status.');
  }

  void _checkHop(Uri hop, bool Function(Uri hop)? acceptHop) {
    if (hop.scheme.toLowerCase() != 'https') {
      throw const MediaExtractionException(
        'UNSUPPORTED_URL',
        'Refusing a request that is not HTTPS (including a redirect from HTTPS to HTTP).',
      );
    }
    if (acceptHop != null && !acceptHop(hop)) {
      throw MediaExtractionException(
        'PARSE_ERROR',
        '$service redirected off its own site; trying another method.',
      );
    }
  }

  /// Sets the browser UA and the caller's [headers], except any `Cookie` or
  /// `Cookie2` header in any letter case: "no cookies" is enforced here, not
  /// left to each caller.
  static void _applyHeaders(HttpClientRequest request, Map<String, String> headers) {
    request.headers.set('User-Agent', userAgent);
    request.headers.set('Accept-Language', 'en-US,en;q=0.9');
    for (final entry in headers.entries) {
      final name = entry.key.trim().toLowerCase();
      if (name == 'cookie' || name == 'cookie2') continue;
      request.headers.set(entry.key, entry.value);
    }
  }

  Future<NativeHttpResponse> _run(
    Uri url,
    NativeBodyKind kind,
    int? maxBytes,
    Future<HttpClientResponse> Function(HttpClient client, void Function(Uri hop) onHop) send,
  ) async {
    final httpClient = _httpClientFactory();
    var effectiveUrl = url;
    try {
      final HttpClientResponse response;
      try {
        response = await send(httpClient, (hop) => effectiveUrl = hop).timeout(timeout);
      } on MediaExtractionException catch (e) {
        throw _redacted(e);
      } on TimeoutException {
        throw MediaExtractionException('NETWORK', '$service did not answer in time.');
      } on IOException catch (e) {
        throw MediaExtractionException('NETWORK', _redact('Could not reach $service: $e'));
      } on FormatException {
        throw _malformedRedirect;
      } on ArgumentError {
        throw _malformedRedirect;
      }

      final status = response.statusCode;
      // Status first: a refusal or throttle never reads a body (no extractor
      // needs one: they all map these by status); the response is cancelled,
      // which closes the connection, so a stalled body cannot turn a
      // 401/403/999 into a NETWORK timeout.
      if (status == 401 || status == 403 || status == 999 || status == 404 || status == 410 || status == 429 || status >= 500) {
        await discardBody(response);
        return NativeHttpResponse(statusCode: status, effectiveUrl: effectiveUrl, body: '');
      }
      final cap = maxBytes ?? (kind == NativeBodyKind.page ? pageCapBytes : apiCapBytes);
      final (body, truncated) = await _readBounded(response, cap);
      return NativeHttpResponse(statusCode: status, effectiveUrl: effectiveUrl, body: body, truncated: truncated);
    } finally {
      httpClient.close(force: true);
    }
  }

  /// Reads at most [cap] bytes through the repo's one bounded reader
  /// (`readBoundedBytes`: leaving its loop at the cap cancels the response,
  /// which abandons the rest of the body) under this client's deadline.
  /// Decoded as UTF-8 with malformed bytes replaced, so a cap that cuts a
  /// multi-byte character never flips the whole page to another charset.
  Future<(String, bool)> _readBounded(HttpClientResponse response, int cap) async {
    final BoundedBody body;
    try {
      body = await readBoundedBytes(response, cap).timeout(timeout);
    } on TimeoutException {
      throw MediaExtractionException('NETWORK', '$service stopped sending the response.');
    } on IOException catch (e) {
      throw MediaExtractionException('NETWORK', _redact('Connection to $service failed while reading: $e'));
    }
    return (utf8.decode(body.bytes, allowMalformed: true), body.truncated);
  }

  /// A hostile `Location` (`http://[`) makes `Uri.resolve` throw a raw
  /// `FormatException`/`ArgumentError` inside `HostPolicy.guardedRequest`;
  /// it must surface as this project's own status, with fixed text.
  static const MediaExtractionException _malformedRedirect =
      MediaExtractionException('PARSE_ERROR', 'The server sent a malformed redirect; trying another method.');

  static String _redact(String text) => UrlParser.redactUrlsInText(text);

  static MediaExtractionException _redacted(MediaExtractionException e) =>
      MediaExtractionException(e.status, e.reason == null ? null : _redact(e.reason!));
}
