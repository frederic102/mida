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
  static Future<void> handle(DevtoolsSession session, CdpEvent event) async {
    if (event.method != 'Fetch.requestPaused') return;
    final requestId = event.params['requestId'] as String?;
    final sessionId = event.sessionId;
    if (requestId == null || sessionId == null) return;

    final request = event.params['request'];
    final rawUrl = request is Map ? request['url'] as String? : null;
    final url = rawUrl == null ? null : Uri.tryParse(rawUrl);
    final blocked = url != null && await _isDisallowed(url);

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

  /// [HostPolicy.isDisallowedHost] is syntactic-only by design (see that
  /// file's own docstring); a plain hostname (not already a literal IP)
  /// gets an actual DNS resolution here so a name that merely *resolves*
  /// to a private/metadata address is still blocked, not just a literal
  /// `http://169.254.169.254/` in the URL itself. A DNS failure or timeout
  /// is not this guard's job to adjudicate further - let that request
  /// proceed and fail (or succeed) on its own merits.
  static Future<bool> _isDisallowed(Uri url) async {
    if (HostPolicy.isDisallowedHost(url)) return true;
    final host = url.host;
    if (host.isEmpty || InternetAddress.tryParse(host) != null) return false;

    try {
      final addresses = await InternetAddress.lookup(host).timeout(const Duration(seconds: 3));
      for (final address in addresses) {
        final resolvedProbe = Uri(scheme: url.scheme.isEmpty ? 'https' : url.scheme, host: address.address);
        if (HostPolicy.isDisallowedHost(resolvedProbe)) return true;
      }
    } catch (_) {
      // Unresolvable or slow hostname.
    }
    return false;
  }
}
