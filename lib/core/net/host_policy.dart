import 'dart:io';

import '../extractors/media_models.dart';

/// SSRF guard shared by every network call this app makes on a page's or
/// browser capture's behalf: refuses loopback, RFC1918 private, and
/// link-local addresses (plus the literal `localhost`), including targets
/// a redirect chain leads to. A malicious page could otherwise get this
/// app to "discover" (and then GET) something like
/// `http://169.254.169.254/...` (a cloud metadata endpoint) or an address
/// on the operator's own LAN.
///
/// Single source of truth (council follow-up F1): this file replaces two
/// independently-written copies that existed side by side for one phase
/// (`lib/core/extractors/generic/host_policy.dart` and
/// `lib/core/extractors/browser_capture/host_policy.dart`, both now
/// deleted). The stronger of the two (`browser_capture`'s: it additionally
/// handled `0.0.0.0`, IPv4-mapped IPv6 like `::ffff:127.0.0.1`, IPv6
/// unique-local `fc00::/7`, and `*.localhost`) is the base; the generic
/// lane's [guardedRequest] (manual bounded redirect-following with a
/// per-hop re-check) is added on top.
///
/// [isDisallowedHost] itself is a syntactic check only (no DNS
/// resolution): it inspects [Uri.host] as written, via
/// [InternetAddress.tryParse], and stays synchronous on purpose since
/// several call sites need a quick sync check. A hostname that only
/// *resolves* to a private address (DNS rebinding) needs an async
/// resolve-then-check instead; [guardedRequest] does that itself (see
/// [assertResolvesToPublicHost]), and callers that only read a reference
/// without fetching it can call [assertResolvesToPublicHost] directly.
class HostPolicy {
  const HostPolicy._();

  /// Hard cap on redirects a single [guardedRequest] call will follow.
  static const int maxRedirectHops = 5;

  /// True when [url]'s host must not be reached: loopback (`127.0.0.0/8`,
  /// `::1`), RFC1918 private (`10.0.0.0/8`, `172.16.0.0/12`,
  /// `192.168.0.0/16`), link-local (`169.254.0.0/16`, `fe80::/10`),
  /// `0.0.0.0`/`::`, `localhost`/`*.localhost`, IPv6 unique-local
  /// (`fc00::/7`), an IPv4-mapped IPv6 literal wrapping any of the above
  /// (`::ffff:a.b.c.d`), or [url] having **no host at all** (`blob:`,
  /// `data:`, `mailto:`, ...). A hostless URI is not a private-looking
  /// destination, but it is not a fetchable one either: `HttpClient.getUrl`
  /// throws a raw `ArgumentError` ("No host specified in URI ...") for one
  /// rather than any of this app's own typed exceptions, and that
  /// `ArgumentError` (a Dart `Error`, not an `Exception`) is *not* caught by
  /// `MediaDownloadPipeline`'s per-candidate `on Exception` handler - it
  /// would crash the whole download instead of just failing that one
  /// candidate (live-caught: a browser-captured `blob:` URL surviving into
  /// `MediaInfo.formats` for one site). Treating "no host" as disallowed
  /// here turns that crash into this app's own clean `UNSUPPORTED_URL`/
  /// refusal, at the single choke point every fetch already goes through.
  static bool isDisallowedHost(Uri url) {
    final host = url.host;
    if (host.isEmpty) return true;
    final normalized = host.toLowerCase();

    if (normalized == 'localhost' || normalized.endsWith('.localhost')) return true;

    final address = InternetAddress.tryParse(normalized);
    if (address == null) return false; // A real hostname; not this check's job to resolve it.

    return _isDisallowedAddress(address);
  }

  static bool _isDisallowedAddress(InternetAddress address) {
    return address.type == InternetAddressType.IPv6
        ? _isDisallowedIPv6(address.rawAddress)
        : _isDisallowedIPv4(address.rawAddress);
  }

  /// Throws [MediaExtractionException] (`UNSUPPORTED_URL`, what/why/next)
  /// when [isDisallowedHost] rejects [url]. [context] names what the URL
  /// was for (e.g. `'this page'`, `'a captured media URL'`) so the message
  /// stays specific to the call site.
  static void assertAllowedHost(Uri url, {required String context}) {
    if (!isDisallowedHost(url)) return;
    throw MediaExtractionException(
      'UNSUPPORTED_URL',
      'Refusing to load $context because its host ("${url.host}") points at '
          'this machine\'s own loopback interface or an internal/private '
          'network. This app must never be allowed to reach those. Use a '
          'public http(s) URL instead.',
    );
  }

  static bool _isDisallowedIPv4(List<int> bytes) {
    if (bytes.length != 4) return false;
    final a = bytes[0], b = bytes[1];
    if (a == 127) return true; // loopback 127.0.0.0/8
    if (a == 10) return true; // RFC1918 10.0.0.0/8
    if (a == 172 && b >= 16 && b <= 31) return true; // RFC1918 172.16.0.0/12
    if (a == 192 && b == 168) return true; // RFC1918 192.168.0.0/16
    if (a == 169 && b == 254) return true; // link-local 169.254.0.0/16
    if (a == 0) return true; // 0.0.0.0/8 ("this network")
    return false;
  }

  static bool _isDisallowedIPv6(List<int> bytes) {
    if (bytes.length != 16) return false;
    if (bytes.every((b) => b == 0)) return true; // :: (unspecified)
    if (bytes.sublist(0, 15).every((b) => b == 0) && bytes[15] == 1) return true; // ::1 loopback
    if (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) return true; // fe80::/10 link-local
    if ((bytes[0] & 0xfe) == 0xfc) return true; // fc00::/7 unique-local

    // IPv4-mapped IPv6 (`::ffff:a.b.c.d`): unwrap and re-check the
    // embedded IPv4 rather than waving it through as "not IPv4". This is
    // the unwrap step F1's guard-can-fail evidence targets: disabling it
    // (see report) lets `::ffff:127.0.0.1` and `::ffff:169.254.169.254`
    // straight through.
    final isV4Mapped = bytes.sublist(0, 10).every((b) => b == 0) && bytes[10] == 0xff && bytes[11] == 0xff;
    if (isV4Mapped) return _isDisallowedIPv4(bytes.sublist(12, 16));

    return false;
  }

  /// DNS-rebinding guard (security follow-up): [isDisallowedHost] only
  /// looks at the literal text of a URL's host, so a hostname that is
  /// itself syntactically public (`evil.example.com`) but whose DNS
  /// answer is a private/loopback/link-local address slips straight
  /// through that check. This resolves [url]'s host (skipped entirely for
  /// a literal IP host - [isDisallowedHost] already covers that case) via
  /// [resolveHost] and rejects if *any* returned address is disallowed.
  /// Public so callers that only ever *read* a reference (never fetch it
  /// themselves - e.g. [ManifestReferenceScanner]'s segment/key/map leaves)
  /// can still run this same check without going through [guardedRequest].
  ///
  /// Residual risk, documented rather than hidden: `dart:io`'s
  /// `HttpClient` does its own independent DNS resolution moments later,
  /// when it actually opens the socket for the request this check guards.
  /// A DNS answer that changes between these two resolutions (the classic
  /// rebind) is not something this check - or anything short of pinning
  /// the resolved address into the socket connect call itself, which
  /// `dart:io`'s `HttpClient` does not expose a hook for - can close.
  ///
  /// A lookup failure (offline sandbox, transient DNS error, genuine
  /// NXDOMAIN, ...) now fails CLOSED: it is refused with the same
  /// `UNSUPPORTED_URL` rather than waved through as "inconclusive". A
  /// silent DNS failure is exactly the condition an attacker controlling
  /// the network path (the same threat model this whole guard exists for)
  /// can induce on purpose to bypass a fail-open check; the real request
  /// this guards would very likely fail too if the lookup was a genuine
  /// transient error, so failing closed here costs little in practice.
  static Future<void> assertResolvesToPublicHost(
    Uri url, {
    Future<List<InternetAddress>> Function(String host) resolveHost = InternetAddress.lookup,
  }) async {
    final host = url.host;
    if (host.isEmpty || InternetAddress.tryParse(host) != null) return;
    List<InternetAddress> addresses;
    try {
      addresses = await resolveHost(host);
    } catch (e) {
      throw MediaExtractionException(
        'UNSUPPORTED_URL',
        'Refusing to fetch $url: could not resolve its hostname ("$host") to check whether it points at a '
            'private, loopback, or link-local network address ($e). Failing closed rather than proceeding '
            'without that check.',
      );
    }
    for (final address in addresses) {
      if (_isDisallowedAddress(address)) {
        throw MediaExtractionException(
          'UNSUPPORTED_URL',
          'Refusing to fetch $url: its hostname ("$host") resolves to a private, loopback, or '
              'link-local network address (${address.address}). This extractor only follows '
              'public internet hosts, including ones a hostname\'s own DNS answer points at.',
        );
      }
    }
  }

  /// GET/HEAD with `followRedirects` handled manually so every hop
  /// (starting from [url]) can be re-checked against [isDisallowedHost]
  /// (and, for a non-literal-IP hostname, [_assertResolvesToPublicHost])
  /// before it is fetched, up to [maxRedirectHops] redirects.
  ///
  /// [allowPrivateHosts] exempts only hop 0 (the URL the caller
  /// explicitly asked for) from both checks; every hop reached via a
  /// redirect is always checked regardless. This is what lets tests point
  /// a fetcher straight at a local fixture server (single hop, no
  /// redirect) while keeping the redirect-to-private-network guard fully
  /// strict and independently testable even in a hermetic suite.
  /// Production code must never set it.
  ///
  /// [resolveHost] defaults to the real `InternetAddress.lookup`; tests
  /// inject a fake to prove the DNS-rebinding guard above without making
  /// a real DNS query.
  ///
  /// [onHop] (phase 6 round 4, lead contract) is invoked with the exact
  /// URI about to be requested on hop 0 and on every redirect hop that is
  /// followed, in order. The last value it receives is the effective URI
  /// the returned [HttpClientResponse] actually came from - the base a
  /// caller must resolve relative references in that body against, and
  /// the host a caller must include in any credential-scope decision
  /// (`ManifestReferenceScanner`). Without it a caller only ever sees the
  /// pre-redirect [url], so a manifest that redirected elsewhere was being
  /// parsed against, and cookie-scoped for, the wrong origin.
  static Future<HttpClientResponse> guardedRequest(
    HttpClient client,
    Uri url, {
    required bool useHead,
    void Function(HttpClientRequest request)? configureRequest,
    bool allowPrivateHosts = false,
    Future<List<InternetAddress>> Function(String host) resolveHost = InternetAddress.lookup,
    void Function(Uri hop)? onHop,
  }) async {
    var currentUrl = url;
    HttpClientResponse? response;

    for (var hop = 0; hop <= maxRedirectHops; hop++) {
      onHop?.call(currentUrl);
      final hopIsExempt = allowPrivateHosts && hop == 0;
      if (!hopIsExempt) {
        if (isDisallowedHost(currentUrl)) {
          throw MediaExtractionException(
            'UNSUPPORTED_URL',
            'Refusing to fetch $currentUrl: it resolves to a private, loopback, or link-local '
                'network address. This extractor only follows public internet hosts, including '
                'through redirects, to avoid a page making this app reach your local network.',
          );
        }
        await assertResolvesToPublicHost(currentUrl, resolveHost: resolveHost);
      }

      final request = useHead ? await client.headUrl(currentUrl) : await client.getUrl(currentUrl);
      request.followRedirects = false;
      configureRequest?.call(request);
      response = await request.close();

      final location = response.headers.value('location');
      final isRedirect = response.statusCode >= 300 && response.statusCode < 400 && location != null;
      if (!isRedirect || hop == maxRedirectHops) return response;

      await response.drain<void>();
      currentUrl = currentUrl.resolve(location);
    }
    return response!;
  }
}
