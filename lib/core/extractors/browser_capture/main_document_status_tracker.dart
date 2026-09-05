import '../../services/cdp_client.dart';

/// Tracks the top-level page's own main-document HTTP status, immune to a
/// child (iframe) target's or an unrelated sub-resource's status leaking
/// in - see docs/plan-phase5-coverage.md, independent review round 2: a
/// naive "first `text/html` response seen from any target" check let a
/// 404 ad iframe terminate a perfectly fine page as `NOT_FOUND`/
/// `LOGIN_REQUIRED`.
///
/// Three conditions must all hold for an event to count:
///  1. `type == 'Document'` (never a script/image/xhr/font/...).
///  2. The event's own session is the top-level target's, never a child
///     (iframe) target's.
///  3. The event's `requestId` is one already known to belong to the
///     originally-navigated URL's own chain.
///
/// Tracks a *set* of request ids for condition 3, not a single value
/// latched onto once (independent review round 3 hardening): Chrome
/// typically reuses one `requestId` across a main-frame redirect chain,
/// but this no longer assumes that is the only shape - any later Document
/// `requestWillBeSent` whose own URL still matches the navigated URL (not
/// just the first one ever seen) is added too, so a redirect chain that
/// happens to mint a fresh id per hop is still covered without needing to
/// walk `redirectResponse` links by hand.
class MainDocumentStatusTracker {
  final Set<String> _mainRequestIds = {};
  int? _status;

  int? get status => _status;

  void observe(
    CdpEvent event, {
    required Uri navigatedUrl,
    required bool isTopLevelSession,
  }) {
    if (!isTopLevelSession) return;
    final params = event.params;

    if (event.method == 'Network.requestWillBeSent') {
      if (params['type'] != 'Document') return;
      final requestId = params['requestId'] as String?;
      if (requestId == null) return;
      final request = params['request'];
      final url = request is Map ? request['url'] as String? : null;
      if (url != null && _sameDocument(url, navigatedUrl)) {
        _mainRequestIds.add(requestId);
      }
      return;
    }

    if (event.method != 'Network.responseReceived') return;
    if (params['type'] != 'Document') return;
    final requestId = params['requestId'] as String?;
    if (requestId == null || !_mainRequestIds.contains(requestId)) return;
    final response = params['response'];
    if (response is Map) _status = response['status'] as int?;
  }

  /// Host+path equality, case-insensitive, ignoring query/fragment and a
  /// trailing-slash difference - not a byte-exact match: some browsers
  /// normalize a bare-domain navigation's own request URL (adding a
  /// trailing `/`) before `Network.requestWillBeSent` ever reports it.
  static bool _sameDocument(String observedUrl, Uri navigatedUrl) {
    final parsed = Uri.tryParse(observedUrl);
    if (parsed == null) return false;
    final a = parsed.replace(query: '', fragment: '');
    final b = navigatedUrl.replace(query: '', fragment: '');
    return a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
        a.host.toLowerCase() == b.host.toLowerCase() &&
        _normalizedPath(a.path).toLowerCase() == _normalizedPath(b.path).toLowerCase();
  }

  /// An empty path (`https://example.com`) and a bare `/`
  /// (`https://example.com/`) are the same document - some browsers
  /// normalize a bare-domain navigation's own request URL by adding the
  /// trailing slash before `Network.requestWillBeSent` ever reports it,
  /// so both shapes have to compare equal here.
  static String _normalizedPath(String path) {
    if (path.isEmpty) return '/';
    return path.length > 1 && path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  }
}
