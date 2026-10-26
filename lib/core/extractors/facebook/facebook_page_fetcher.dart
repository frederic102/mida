import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../net/host_policy.dart';
import '../../utils/url_parser.dart';
import '../generic/bounded_body.dart';
import '../generic/format_expander.dart';
import '../generic/stage_deadline.dart';
import '../media_models.dart';
import 'facebook_url_matcher.dart';

/// One fetched Facebook page: the status, the URL the body actually came
/// from after redirects (`HostPolicy.guardedRequest`'s last `onHop`), and
/// at most [FacebookPageFetcher.maxBodyBytes] of its body.
class FacebookPage {
  final int statusCode;
  final Uri effectiveUrl;
  final String body;

  /// True when the body hit the byte cap and was cut short. The parser
  /// still runs on what was read; this only feeds diagnostics.
  final bool truncated;

  const FacebookPage({
    required this.statusCode,
    required this.effectiveUrl,
    required this.body,
    this.truncated = false,
  });
}

/// The only network code in the Facebook extractor: a plain HTTPS GET with
/// a normal desktop browser User-Agent, every hop (including the `fb.watch`
/// and `/share/v/` redirects) checked by `HostPolicy.guardedRequest`, the
/// body capped at [maxBodyBytes]. No cookies are sent or synthesized, no
/// mobile-app User-Agent, no GraphQL calls.
///
/// Transport rules, enforced per hop in `onHop` before that hop is
/// requested: HTTPS only (an `http` start URL or an HTTPS to HTTP redirect
/// is refused, `UNSUPPORTED_URL`), and a page fetch never leaves Facebook's
/// own hosts ([FacebookUrlMatcher.isFetchableHost]; an off-site hop is
/// `PARSE_ERROR`, so the registry falls through to the other tiers without
/// this class ever reading the off-site body). A private/loopback hop is
/// left to `HostPolicy`'s own `UNSUPPORTED_URL` refusal.
///
/// Time: the whole fetch (connect, every redirect hop, body) runs under one
/// [requestTimeout]; on expiry the client is force-closed. An error or
/// throttle status (404/410/429/5xx) is answered without reading its body:
/// the body is discarded unread, so a response that never finishes cannot
/// hold the extractor.
///
/// Error messages pass through `UrlParser.redactUrlsInText` so signed query
/// strings never reach the UI or the CLI's JSON error line.
class FacebookPageFetcher {
  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  /// Upper bound on any body this fetcher reads. Same 5 MiB as the generic
  /// extractor: public video pages run to a few MiB, with the playback JSON
  /// often well past the first two.
  static const int maxBodyBytes = 5 * 1024 * 1024;
  static const Duration requestTimeout = Duration(seconds: 20);

  final HttpClient Function() _httpClientFactory;
  final Future<List<InternetAddress>> Function(String host) _resolveHost;
  final Duration _timeout;

  /// [resolveHost] defaults to the real DNS lookup `HostPolicy` uses;
  /// tests inject a fake public address so the guard runs unmodified
  /// without a real DNS query. [httpClientFactory] lets tests route the
  /// client to a loopback fixture server. [timeout] exists only so a test
  /// can prove the deadline in milliseconds; production keeps the default.
  FacebookPageFetcher({
    HttpClient Function()? httpClientFactory,
    Future<List<InternetAddress>> Function(String host)? resolveHost,
    Duration timeout = requestTimeout,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _resolveHost = resolveHost ?? InternetAddress.lookup,
        _timeout = timeout;

  /// GETs [url] as a desktop browser navigation would (UA, `Accept`,
  /// `Accept-Language`). [facebookHostsOnly] is false only for a manifest
  /// fetch (`fbcdn.net`), which keeps the HTTPS-only rule. Throws `NETWORK`
  /// on timeout/IO failure and passes `HostPolicy`'s and this class's own
  /// refusals through (status kept, reason redacted).
  Future<FacebookPage> fetchPage(Uri url, {int? maxBytes, bool facebookHostsOnly = true}) async {
    _checkHop(url, facebookHostsOnly: facebookHostsOnly);
    final httpClient = _httpClientFactory();
    var effectiveUrl = url;
    try {
      return await runBounded(null, httpClient, () async {
        final response = await HostPolicy.guardedRequest(
          httpClient,
          url,
          useHead: false,
          resolveHost: _resolveHost,
          onHop: (hop) {
            _checkHop(hop, facebookHostsOnly: facebookHostsOnly);
            effectiveUrl = hop;
          },
          configureRequest: (request) {
            request.headers.set('User-Agent', userAgent);
            request.headers.set('Accept', 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8');
            request.headers.set('Accept-Language', 'en-US,en;q=0.9');
          },
        );
        final status = response.statusCode;
        // Status first: a refusal or throttle never makes this read a body.
        if (status == 404 || status == 410 || status == 429 || status >= 500) {
          await discardBody(response);
          return FacebookPage(statusCode: status, effectiveUrl: effectiveUrl, body: '');
        }
        final body = await readBoundedBytes(response, maxBytes ?? maxBodyBytes);
        return FacebookPage(
          statusCode: status,
          effectiveUrl: effectiveUrl,
          body: utf8.decode(body.bytes, allowMalformed: true),
          truncated: body.truncated,
        );
      }, timeout: _timeout);
    } on MediaExtractionException catch (e) {
      // HostPolicy's refusal names the full URL; strip its query.
      throw MediaExtractionException(e.status, e.reason == null ? null : _redact(e.reason!));
    } on TimeoutException {
      throw const MediaExtractionException('NETWORK', 'Facebook did not answer in time.');
    } on IOException catch (e) {
      throw MediaExtractionException('NETWORK', _redact('Could not reach Facebook: $e'));
    } finally {
      httpClient.close(force: true);
    }
  }

  /// Adapter for `FormatExpander.fetchText` (the DASH manifest DRM scan),
  /// so that fetch is guarded, HTTPS-only and bounded exactly like the
  /// page fetch (manifests live on `fbcdn.net`, hence no host rule).
  Future<FetchedBody> fetchText(Uri url, {Map<String, String>? extraHeaders, int? maxBytes}) async {
    final page = await fetchPage(url, maxBytes: maxBytes, facebookHostsOnly: false);
    return FetchedBody(statusCode: page.statusCode, body: page.body);
  }

  /// Runs before every hop is requested (hop 0 included).
  static void _checkHop(Uri hop, {required bool facebookHostsOnly}) {
    if (hop.scheme.toLowerCase() != 'https') {
      throw MediaExtractionException(
        'UNSUPPORTED_URL',
        'Refusing to fetch ${hop.host} over plain HTTP: Facebook pages are only fetched over HTTPS, '
            'and a redirect from HTTPS down to HTTP is never followed.',
      );
    }
    if (facebookHostsOnly && !FacebookUrlMatcher.isFetchableHost(hop.host) && !HostPolicy.isDisallowedHost(hop)) {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'This Facebook link did not lead to a Facebook page; trying another method.',
      );
    }
  }

  static String _redact(String text) => UrlParser.redactUrlsInText(text);
}
