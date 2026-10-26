import 'dart:convert';
import 'dart:io';

import '../../../net/host_policy.dart';
import '../../media_models.dart';
import '../bounded_body.dart';
import '../generic_http.dart';
import '../guarded_fetch.dart';
import '../network_budget.dart';
import '../stage_deadline.dart';

/// One bounded HTTP response as seen by an [EmbedResolver]: status code
/// plus the (possibly truncated, see [GuardedEmbedHttp.maxBodyBytes])
/// decoded body. No response headers are surfaced on purpose: no resolver
/// needs them, and that keeps any `Set-Cookie` out of reach entirely.
class EmbedHttpResponse {
  final int statusCode;
  final String body;

  const EmbedHttpResponse({required this.statusCode, required this.body});

  bool get isOk => statusCode >= 200 && statusCode < 300;
}

/// The only network surface an embed resolver gets. Injected so every
/// resolver is hermetically testable with a fake, and so the one real
/// implementation ([GuardedEmbedHttp]) is the single place SSRF guarding,
/// body bounding and header policy live for this step.
///
/// [deadline], when given, bounds the whole request (connect, headers and
/// body) and is checked before anything is sent; resolvers never pass it
/// themselves, [BudgetedEmbedHttp] forwards the chain's.
abstract class EmbedHttp {
  Future<EmbedHttpResponse> get(Uri url, {Map<String, String> headers = const {}, StageDeadline? deadline});

  /// POSTs [json] (encoded with `jsonEncode`) as `application/json`.
  Future<EmbedHttpResponse> postJson(
    Uri url,
    Object? json, {
    Map<String, String> headers = const {},
    StageDeadline? deadline,
  });
}

/// Thrown by [BudgetedEmbedHttp] once its [NetworkBudget] is spent. The
/// chain treats it like any other per-resolver failure (skip, keep going).
class EmbedBudgetExhausted implements Exception {
  const EmbedBudgetExhausted();

  @override
  String toString() => 'EmbedBudgetExhausted';
}

/// Caps how many requests one embed-resolver pass may make in total,
/// across every resolver it tries (same security rationale as the iframe
/// follower's [NetworkBudget]: a page must not be able to turn this step
/// into an unbounded number of outbound requests). Also carries the pass's
/// [deadline]: once it has expired no request is started at all, and every
/// request it lets through is bounded by it.
class BudgetedEmbedHttp implements EmbedHttp {
  final EmbedHttp inner;
  final NetworkBudget budget;
  final StageDeadline? deadline;

  BudgetedEmbedHttp(this.inner, this.budget, {this.deadline});

  StageDeadline? _admit(StageDeadline? requested) {
    final effective = requested ?? deadline;
    effective?.ensureActive();
    if (!budget.tryConsume()) throw const EmbedBudgetExhausted();
    return effective;
  }

  @override
  Future<EmbedHttpResponse> get(Uri url, {Map<String, String> headers = const {}, StageDeadline? deadline}) async {
    final effective = _admit(deadline);
    return inner.get(url, headers: headers, deadline: effective);
  }

  @override
  Future<EmbedHttpResponse> postJson(
    Uri url,
    Object? json, {
    Map<String, String> headers = const {},
    StageDeadline? deadline,
  }) async {
    final effective = _admit(deadline);
    return inner.postJson(url, json, headers: headers, deadline: effective);
  }
}

/// Production [EmbedHttp]. Every GET goes through
/// [HostPolicy.guardedRequest] (per-hop private-network and DNS-rebinding
/// checks, bounded redirects). `guardedRequest` is GET/HEAD only, so a POST
/// runs the same two [HostPolicy] checks on its single target and then
/// refuses to follow any redirect at all (a 3xx is returned as-is and
/// treated as a failure by the caller) rather than re-implementing the
/// redirect loop for a verb that should never need one.
///
/// Headers: a normal desktop User-Agent and Accept-Language, plus whatever
/// the resolver passes (Accept/Origin/Referer). Never cookies: `dart:io`'s
/// `HttpClient` keeps no cookie jar, and nothing here adds one.
class GuardedEmbedHttp implements EmbedHttp {
  final HttpClient Function() httpClientFactory;

  /// Test-only, mirrors `GenericExtractor.allowPrivateHosts`: exempts the
  /// first hop from the private-host checks. Production must never set it.
  final bool allowPrivateHosts;

  /// Player configs and playback JSON are tens of kilobytes; anything past
  /// this is not one of them and is cut off rather than buffered.
  final int maxBodyBytes;

  /// DNS lookup behind the rebinding check of every request (GET hops and
  /// the POST target). Defaults to the real lookup; a test seam, as in
  /// `NativeHttpClient`, so a fake answer can prove a public-looking host
  /// that resolves to a private address is refused before any connection.
  final Future<List<InternetAddress>> Function(String host) resolveHost;

  const GuardedEmbedHttp({
    required this.httpClientFactory,
    this.allowPrivateHosts = false,
    this.maxBodyBytes = defaultMaxBodyBytes,
    this.requestTimeout = defaultRequestTimeout,
    this.resolveHost = InternetAddress.lookup,
  });

  static const int defaultMaxBodyBytes = 2 * 1024 * 1024;

  /// Per-request limit (connect, headers and body), on top of whatever is
  /// left of the caller's [StageDeadline].
  final Duration requestTimeout;
  static const Duration defaultRequestTimeout = Duration(seconds: 10);

  @override
  Future<EmbedHttpResponse> get(Uri url, {Map<String, String> headers = const {}, StageDeadline? deadline}) async {
    final fetched = await guardedBoundedGet(
      httpClientFactory,
      url,
      maxBytes: maxBodyBytes,
      allowPrivateHosts: allowPrivateHosts,
      configureRequest: (request) => _applyHeaders(request, headers),
      deadline: deadline,
      timeout: requestTimeout,
      resolveHost: resolveHost,
    );
    return EmbedHttpResponse(statusCode: fetched.statusCode, body: fetched.body);
  }

  @override
  Future<EmbedHttpResponse> postJson(
    Uri url,
    Object? json, {
    Map<String, String> headers = const {},
    StageDeadline? deadline,
  }) async {
    deadline?.ensureActive();
    if (!allowPrivateHosts && HostPolicy.isDisallowedHost(url)) {
      throw MediaExtractionException(
        'UNSUPPORTED_URL',
        'Refusing to POST to ${url.host}: it points at a private, loopback, or link-local network address.',
      );
    }
    final client = httpClientFactory();
    try {
      return await runBounded(deadline, client, () async {
        // Inside the bound: a DNS lookup that hangs is cut off too.
        if (!allowPrivateHosts) await HostPolicy.assertResolvesToPublicHost(url, resolveHost: resolveHost);
        final request = await client.postUrl(url);
        request.followRedirects = false;
        _applyHeaders(request, headers);
        final payload = utf8.encode(jsonEncode(json));
        request.headers.contentType = ContentType.json;
        request.contentLength = payload.length;
        request.add(payload);
        final response = await request.close();
        return EmbedHttpResponse(statusCode: response.statusCode, body: await readBoundedBody(response, maxBodyBytes));
      }, timeout: requestTimeout);
    } finally {
      client.close(force: true);
    }
  }

  static void _applyHeaders(HttpClientRequest request, Map<String, String> headers) {
    request.headers.set('User-Agent', genericDesktopUserAgent);
    request.headers.set('Accept-Language', genericAcceptLanguage);
    headers.forEach(request.headers.set);
  }
}
