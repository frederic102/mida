import 'dart:io';

import '../extractors/fallback_failure.dart';
import '../extractors/generic/bounded_body.dart';
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
  /// (`fc00::/7`), site-local (`fec0::/10`), CGNAT (`100.64.0.0/10`),
  /// benchmarking (`198.18.0.0/15`), multicast and reserved
  /// (`224.0.0.0/4`, `240.0.0.0/4` incl. `255.255.255.255`), an IPv6
  /// literal wrapping any disallowed IPv4 (IPv4-mapped `::ffff:a.b.c.d`,
  /// IPv4-compatible `::a.b.c.d`, NAT64 `64:ff9b::/96`, 6to4 `2002::/16`),
  /// or [url] having **no host at all** (`blob:`,
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
    if (address != null) return _isDisallowedAddress(address);

    // Legacy numeric IPv4 forms (`2130706433`, `127.1`, `0x7f.1`, `0177.0.0.1`)
    // that tryParse rejects but the OS resolver accepts (Bulwark round 2).
    final legacy = legacyIPv4(normalized);
    if (legacy == null) return false; // A real hostname; not this check's job to resolve it.
    return legacy.isEmpty || _isDisallowedIPv4(legacy);
  }

  /// The WHATWG URL rule: a host whose last label is a number (decimal,
  /// `0x` hex, or leading-`0` octal) is an IPv4 address, possibly in a
  /// shortened or single-number form. Returns its 4 bytes, an EMPTY list
  /// when it is numeric-looking but not a valid address (refused: never
  /// guess), or null when [host] is an ordinary hostname.
  static List<int>? legacyIPv4(String host) {
    final labels = host.split('.');
    if (labels.length > 1 && labels.last.isEmpty) labels.removeLast();
    if (labels.isEmpty || !_numericLabel.hasMatch(labels.last)) return null;
    if (labels.length > 4) return const [];
    final parts = <int>[];
    for (final label in labels) {
      final value = _parseIPv4Number(label);
      if (value == null) return const [];
      parts.add(value);
    }
    for (var i = 0; i < parts.length - 1; i++) {
      if (parts[i] > 255) return const [];
    }
    final lastBytes = 5 - parts.length;
    if (parts.last >= (1 << (8 * lastBytes))) return const [];
    final bytes = [...parts.sublist(0, parts.length - 1)];
    for (var shift = 8 * (lastBytes - 1); shift >= 0; shift -= 8) {
      bytes.add((parts.last >> shift) & 0xff);
    }
    return bytes;
  }

  static final RegExp _numericLabel = RegExp(r'^(?:0x[0-9a-f]*|[0-9]+)$');

  static int? _parseIPv4Number(String label) {
    if (label.isEmpty) return null;
    if (label.startsWith('0x')) {
      final digits = label.substring(2);
      return digits.isEmpty ? 0 : int.tryParse(digits, radix: 16);
    }
    if (label.length > 1 && label.startsWith('0')) return int.tryParse(label.substring(1), radix: 8);
    return int.tryParse(label);
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
    if (a == 100 && b >= 64 && b <= 127) return true; // CGNAT shared space 100.64.0.0/10
    if (a == 198 && (b == 18 || b == 19)) return true; // benchmarking 198.18.0.0/15
    final c = bytes[2];
    if (a == 192 && b == 0 && (c == 0 || c == 2)) return true; // IETF 192.0.0.0/24, TEST-NET-1 192.0.2.0/24
    if (a == 198 && b == 51 && c == 100) return true; // TEST-NET-2 198.51.100.0/24
    if (a == 203 && b == 0 && c == 113) return true; // TEST-NET-3 203.0.113.0/24
    if (a >= 224) return true; // multicast 224.0.0.0/4, reserved 240.0.0.0/4, broadcast 255.255.255.255
    return false;
  }

  static bool _isDisallowedIPv6(List<int> bytes) {
    if (bytes.length != 16) return false;
    if (bytes.every((b) => b == 0)) return true; // :: (unspecified)
    if (bytes.sublist(0, 15).every((b) => b == 0) && bytes[15] == 1) return true; // ::1 loopback
    if (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) return true; // fe80::/10 link-local
    if ((bytes[0] & 0xfe) == 0xfc) return true; // fc00::/7 unique-local
    if (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0xc0) return true; // fec0::/10 site-local (deprecated)
    if (bytes[0] == 0xff) return true; // ff00::/8 multicast
    if (bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8) {
      return true; // 2001:db8::/32 documentation
    }
    if (bytes[0] == 0x3f && bytes[1] == 0xff && (bytes[2] & 0xf0) == 0x00) return true; // 3fff::/20 documentation
    if (bytes[0] == 0x01 && bytes.sublist(1, 8).every((b) => b == 0)) return true; // 100::/64 discard-only
    if (bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0 && bytes[3] == 0) {
      return true; // Teredo 2001::/32: tunnels to an obfuscated IPv4 this check cannot vouch for
    }
    if (bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xff && bytes[3] == 0x9b && bytes[4] == 0x00 && bytes[5] == 0x01) {
      return true; // local-use NAT64 64:ff9b:1::/48 (RFC 8215): operator-defined embedding
    }

    // IPv4-mapped IPv6 (`::ffff:a.b.c.d`): unwrap and re-check the
    // embedded IPv4 rather than waving it through as "not IPv4". This is
    // the unwrap step F1's guard-can-fail evidence targets: disabling it
    // (see report) lets `::ffff:127.0.0.1` and `::ffff:169.254.169.254`
    // straight through.
    final isV4Mapped = bytes.sublist(0, 10).every((b) => b == 0) && bytes[10] == 0xff && bytes[11] == 0xff;
    if (isV4Mapped) return _isDisallowedIPv4(bytes.sublist(12, 16));

    // IPv4-compatible (`::a.b.c.d`, deprecated; `::` and `::1` handled
    // above): unwrap the same way.
    if (bytes.sublist(0, 12).every((b) => b == 0)) return _isDisallowedIPv4(bytes.sublist(12, 16));

    // NAT64 well-known prefix 64:ff9b::/96: a translator turns it into the
    // embedded IPv4, so a private one is reachable through it.
    const nat64 = [0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0];
    var isNat64 = true;
    for (var i = 0; i < 12; i++) {
      if (bytes[i] != nat64[i]) isNat64 = false;
    }
    if (isNat64) return _isDisallowedIPv4(bytes.sublist(12, 16));

    // 6to4 2002::/16 carries its IPv4 in bytes 2-5.
    if (bytes[0] == 0x20 && bytes[1] == 0x02) return _isDisallowedIPv4(bytes.sublist(2, 6));

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
  /// NXDOMAIN, ...) fails CLOSED: it throws (status `NETWORK`, since it
  /// is a connectivity condition rather than a refused URL) instead of
  /// being waved through as "inconclusive". A
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
    } catch (_) {
      // Still fails CLOSED (nothing is fetched), but a lookup failure is a
      // network condition, not a refusal of the URL: NETWORK, so the user
      // and the CLI exit code say "check your connection" rather than
      // "unsupported URL" (Phase 7 round 2, Assay D1). Only the host is
      // named; the raw error text is not echoed.
      // A failed lookup is the proven-offline kind of NETWORK (Vigil r3 M1).
      throw OfflineNetworkException(
        'Could not resolve "$host" to check that it points at a public address, so nothing was fetched. '
            'Check your connection and try again.',
      );
    }
    for (final address in addresses) {
      if (_isDisallowedAddress(address)) {
        throw MediaExtractionException(
          'UNSUPPORTED_URL',
          // Host only: the URL's path and query can carry tokens, and this
          // reason reaches user-facing output (astra round 2).
          'Refusing to fetch from "$host": it resolves to a private, loopback, link-local or otherwise '
              'non-public network address (${address.address}). This extractor only follows public '
              'internet hosts, including ones a hostname\'s own DNS answer points at.',
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
            'Refusing to fetch from "${currentUrl.host}": it points at a private, loopback, link-local or '
                'otherwise non-public network address. This extractor only follows public internet hosts, '
                'including through redirects, to avoid a page making this app reach your local network.',
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

      // Discard, never drain (astra round 2): cancelling makes dart:io drop
      // the connection instead of reading the rest, so a huge or endless
      // redirect body cannot stall the next-hop check or bypass a body cap.
      await discardBody(response);
      currentUrl = currentUrl.resolve(location);
    }
    return response!;
  }
}
