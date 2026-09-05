import 'dart:io';

import '../../net/host_policy.dart';
import '../../services/browser_devtools_session.dart';
import '../../services/cdp_client.dart';

/// Fails any request the browser itself tries to make to a disallowed
/// (loopback/RFC1918/link-local/metadata) host, using CDP's Fetch domain to
/// intercept every request a page issues *before* it ever leaves the
/// machine - not just the final candidate URLs `BrowserCaptureExtractor`
/// already checks after the fact. Without this, a hostile public page could
/// get this app's own browser to probe a LAN or cloud-metadata endpoint on
/// its behalf well before any candidate list exists for that later check to
/// filter (e.g. an `<img>`/`fetch()` to `http://169.254.169.254/`, never
/// surfaced as a media candidate at all, so never reaching the existing
/// `HostPolicy.assertAllowedHost` calls in `browser_capture_extractor.dart`).
///
/// Requires `Fetch.enable` already sent for [session]'s target (and, in
/// production, every auto-attached child target - see
/// `BrowserDevtoolsSession.attachToConnectedClient`); with `Fetch.enable`
/// off, `Fetch.requestPaused` never fires and [handle] is never called at
/// all, so this file changes nothing on its own.
class PrivateDestinationGuard {
  const PrivateDestinationGuard._();

  /// One `Fetch.requestPaused` event: continues it unless its own URL (or,
  /// for a plain hostname, one of the addresses that hostname resolves to)
  /// is disallowed by [HostPolicy], in which case it is failed instead.
  /// Never throws - a malformed event, a request already gone, or the
  /// session having since closed only means this one request could not be
  /// adjudicated, not that the whole capture should abort (every other
  /// in-flight request is handled independently).
  static Future<void> handle(
    DevtoolsSession session,
    CdpEvent event, {
    Future<List<InternetAddress>> Function(String host)? resolveHost,
  }) async {
    if (event.method != 'Fetch.requestPaused') return;
    final requestId = event.params['requestId'] as String?;
    final sessionId = event.sessionId;
    if (requestId == null || sessionId == null) return;

    final request = event.params['request'];
    final rawUrl = request is Map ? request['url'] as String? : null;
    final url = rawUrl == null ? null : Uri.tryParse(rawUrl);
    final blocked = url != null && await _isDisallowed(url, resolveHost: resolveHost ?? InternetAddress.lookup);

    try {
      if (blocked) {
        await session.sendToSession(sessionId, 'Fetch.failRequest', {
          'requestId': requestId,
          'errorReason': 'BlockedByClient',
        });
      } else {
        await session.sendToSession(sessionId, 'Fetch.continueRequest', {'requestId': requestId});
      }
    } catch (_) {
      // Target likely navigated away or closed between the pause and this
      // reply; nothing further to do for this one request either way.
    }
  }

  /// One entry per distinct hostname ever looked up, for the lifetime of
  /// the process - independent review round 3: a page making dozens of
  /// requests to the same handful of hosts (routine for a modern SPA:
  /// CDN, ads, analytics, fonts) was triggering one real
  /// `InternetAddress.lookup` *per request*, serialized behind each
  /// `Fetch.requestPaused` reply, with no reuse at all - measured
  /// regression: Douyin/VK/OK.ru/Twitch-clip all went from resolving in
  /// under 35s to hitting the full 90s wall. Caches the *Future* itself
  /// (not just its resolved value), so concurrent requests to a host
  /// whose lookup is still in flight all await that one lookup instead of
  /// each starting their own. Capped and cleared wholesale on overflow
  /// rather than an LRU - simple, and a single capture never realistically
  /// touches enough distinct hosts to make that matter.
  static final Map<String, Future<bool>> _dnsVerdictCache = {};

  static const int _maxCachedHosts = 500;

  /// Test-only: clears the process-lifetime cache so one test's lookups
  /// cannot leak into another's assertions. Never called by production
  /// code.
  static void debugClearDnsCache() => _dnsVerdictCache.clear();

  /// [HostPolicy.isDisallowedHost] is syntactic-only by design (see that
  /// file's own docstring); a plain hostname (not already a literal IP)
  /// gets an actual DNS resolution here so a name that merely *resolves*
  /// to a private/metadata address is still blocked, not just a literal
  /// `http://169.254.169.254/` in the URL itself.
  static Future<bool> _isDisallowed(
    Uri url, {
    required Future<List<InternetAddress>> Function(String host) resolveHost,
  }) async {
    if (HostPolicy.isDisallowedHost(url)) return true;
    final host = url.host;
    if (host.isEmpty || InternetAddress.tryParse(host) != null) return false;

    final cached = _dnsVerdictCache[host];
    if (cached != null) return cached;

    if (_dnsVerdictCache.length >= _maxCachedHosts) _dnsVerdictCache.clear();
    final future = _resolveVerdict(url, host, resolveHost);
    _dnsVerdictCache[host] = future;
    return future;
  }

  /// Fails **closed** on a DNS lookup failure or timeout (independent
  /// review round 2): this guard cannot confirm the host is safe, so it
  /// is blocked rather than waved through. The earlier fail-*open* shape
  /// (an unresolvable/slow hostname was allowed to proceed) meant a page
  /// could defeat this guard entirely just by pointing at a hostname
  /// whose resolution could be made to fail or time out. Timeout cut to
  /// 2s (from 3s) in round 3, alongside the cache above: it now gates at
  /// most one real lookup per distinct host per process instead of one
  /// per request, so the cost of that timeout firing occasionally no
  /// longer compounds the way it did.
  static Future<bool> _resolveVerdict(
    Uri url,
    String host,
    Future<List<InternetAddress>> Function(String host) resolveHost,
  ) async {
    try {
      final addresses = await resolveHost(host).timeout(const Duration(seconds: 2));
      for (final address in addresses) {
        final resolvedProbe = Uri(scheme: url.scheme.isEmpty ? 'https' : url.scheme, host: address.address);
        if (HostPolicy.isDisallowedHost(resolvedProbe)) return true;
      }
      return false;
    } catch (_) {
      return true;
    }
  }
}
