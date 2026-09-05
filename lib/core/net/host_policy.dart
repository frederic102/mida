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
/// This is a syntactic check only (no DNS resolution): it inspects
/// [Uri.host] as written, via [InternetAddress.tryParse]. A hostname that
/// only *resolves* to a private address later (DNS rebinding) is a
/// different, larger defense (would need an async resolve-then-check at
/// the point of the actual socket connect) and is out of scope here.
class HostPolicy {
  const HostPolicy._();

  /// Hard cap on redirects a single [guardedRequest] call will follow.
  static const int maxRedirectHops = 5;

  /// True when [url]'s host must not be reached: loopback (`127.0.0.0/8`,
  /// `::1`), RFC1918 private (`10.0.0.0/8`, `172.16.0.0/12`,
  /// `192.168.0.0/16`), link-local (`169.254.0.0/16`, `fe80::/10`),
  /// `0.0.0.0`/`::`, `localhost`/`*.localhost`, IPv6 unique-local
  /// (`fc00::/7`), or an IPv4-mapped IPv6 literal wrapping any of the
  /// above (`::ffff:a.b.c.d`).
  static bool isDisallowedHost(Uri url) {
    final host = url.host;
    if (host.isEmpty) return false;
    final normalized = host.toLowerCase();

    if (normalized == 'localhost' || normalized.endsWith('.localhost')) return true;

    final address = InternetAddress.tryParse(normalized);
    if (address == null) return false; // A real hostname; not this check's job to resolve it.

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

  /// GET/HEAD with `followRedirects` handled manually so every hop
  /// (starting from [url]) can be re-checked against [isDisallowedHost]
  /// before it is fetched, up to [maxRedirectHops] redirects.
  ///
  /// [allowPrivateHosts] exempts only hop 0 (the URL the caller
  /// explicitly asked for) from the host check; every hop reached via a
  /// redirect is always checked regardless. This is what lets tests point
  /// a fetcher straight at a local fixture server (single hop, no
  /// redirect) while keeping the redirect-to-private-network guard fully
  /// strict and independently testable even in a hermetic suite.
  /// Production code must never set it.
  static Future<HttpClientResponse> guardedRequest(
    HttpClient client,
    Uri url, {
    required bool useHead,
    void Function(HttpClientRequest request)? configureRequest,
    bool allowPrivateHosts = false,
  }) async {
    var currentUrl = url;
    HttpClientResponse? response;

    for (var hop = 0; hop <= maxRedirectHops; hop++) {
      final hopIsExempt = allowPrivateHosts && hop == 0;
      if (!hopIsExempt && isDisallowedHost(currentUrl)) {
        throw MediaExtractionException(
          'UNSUPPORTED_URL',
          'Refusing to fetch $currentUrl: it resolves to a private, loopback, or link-local '
              'network address. This extractor only follows public internet hosts, including '
              'through redirects, to avoid a page making this app reach your local network.',
        );
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
