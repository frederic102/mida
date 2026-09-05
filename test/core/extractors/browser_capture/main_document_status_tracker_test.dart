import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/browser_capture/main_document_status_tracker.dart';
import 'package:mida/core/services/cdp_client.dart';

void main() {
  final navigatedUrl = Uri.parse('https://example.com/watch?v=1');

  CdpEvent requestWillBeSent({required String requestId, required String url, String type = 'Document'}) => CdpEvent(
        method: 'Network.requestWillBeSent',
        sessionId: 'top',
        params: {'requestId': requestId, 'type': type, 'request': {'url': url}},
      );

  CdpEvent responseReceived({
    required String requestId,
    required int status,
    String type = 'Document',
    String sessionId = 'top',
  }) =>
      CdpEvent(
        method: 'Network.responseReceived',
        sessionId: sessionId,
        params: {'requestId': requestId, 'type': type, 'response': {'status': status}},
      );

  group('MainDocumentStatusTracker', () {
    test('a 404 Document response on the top-level session for the navigated URL sets status', () {
      final tracker = MainDocumentStatusTracker();
      tracker.observe(
        requestWillBeSent(requestId: 'r1', url: navigatedUrl.toString()),
        navigatedUrl: navigatedUrl,
        isTopLevelSession: true,
      );
      tracker.observe(
        responseReceived(requestId: 'r1', status: 404),
        navigatedUrl: navigatedUrl,
        isTopLevelSession: true,
      );

      expect(tracker.status, 404);
    });

    test('guard can fail: a 404 Document response on a CHILD (iframe) session never changes status', () {
      // The exact bug this class exists to fix: a 404 ad iframe must not
      // be able to terminate a perfectly fine top-level page as
      // NOT_FOUND.
      final tracker = MainDocumentStatusTracker();
      tracker.observe(
        requestWillBeSent(requestId: 'r1', url: navigatedUrl.toString()),
        navigatedUrl: navigatedUrl,
        isTopLevelSession: true,
      );
      // A 404 Document from a child session, wired up as isTopLevelSession:
      // false (as BrowserCaptureExtractor computes via
      // `!session.childSessionIds.contains(event.sessionId)`).
      tracker.observe(
        responseReceived(requestId: 'child-r1', status: 404, sessionId: 'child'),
        navigatedUrl: navigatedUrl,
        isTopLevelSession: false,
      );

      expect(tracker.status, isNull);
    });

    test('guard can fail: a 404 on a non-Document resource type (e.g. an ad image) never changes status', () {
      final tracker = MainDocumentStatusTracker();
      tracker.observe(
        requestWillBeSent(requestId: 'r1', url: navigatedUrl.toString()),
        navigatedUrl: navigatedUrl,
        isTopLevelSession: true,
      );
      tracker.observe(
        responseReceived(requestId: 'r2', status: 404, type: 'Image'),
        navigatedUrl: navigatedUrl,
        isTopLevelSession: true,
      );

      expect(tracker.status, isNull);
    });

    test('a 200 that later redirects (same requestId across the chain) is superseded by the final status', () {
      final tracker = MainDocumentStatusTracker();
      tracker.observe(
        requestWillBeSent(requestId: 'r1', url: navigatedUrl.toString()),
        navigatedUrl: navigatedUrl,
        isTopLevelSession: true,
      );
      // Chrome reuses the same requestId across a main-frame redirect
      // chain; only the final Network.responseReceived for it should win.
      tracker.observe(
        responseReceived(requestId: 'r1', status: 200),
        navigatedUrl: navigatedUrl,
        isTopLevelSession: true,
      );

      expect(tracker.status, 200);
    });

    test('guard can fail: a redirect that mints a FRESH requestId per hop is still tracked, not stuck on the first',
        () {
      // Independent review round 3 hardening: does not assume Chrome
      // always reuses one requestId across a redirect chain - a second
      // Document requestWillBeSent whose own URL also matches the
      // navigated URL (a fresh id, not a continuation of the first) must
      // still be tracked, or a real redirecting site's final status
      // would silently never be observed.
      final tracker = MainDocumentStatusTracker();
      tracker.observe(
        requestWillBeSent(requestId: 'r1', url: navigatedUrl.toString()),
        navigatedUrl: navigatedUrl,
        isTopLevelSession: true,
      );
      tracker.observe(
        requestWillBeSent(requestId: 'r2-fresh-id', url: navigatedUrl.toString()),
        navigatedUrl: navigatedUrl,
        isTopLevelSession: true,
      );
      tracker.observe(
        responseReceived(requestId: 'r2-fresh-id', status: 404),
        navigatedUrl: navigatedUrl,
        isTopLevelSession: true,
      );

      expect(tracker.status, 404);
    });

    test('a Document response whose requestId never matched the navigated URL is ignored', () {
      final tracker = MainDocumentStatusTracker();
      tracker.observe(
        requestWillBeSent(requestId: 'r1', url: navigatedUrl.toString()),
        navigatedUrl: navigatedUrl,
        isTopLevelSession: true,
      );
      // A same-origin iframe's own Document load, on the same (top-level)
      // session, with a different requestId - must not overwrite the
      // real main document's status.
      tracker.observe(
        responseReceived(requestId: 'unrelated', status: 404),
        navigatedUrl: navigatedUrl,
        isTopLevelSession: true,
      );

      expect(tracker.status, isNull);
    });

    test('a trailing-slash difference in the requestWillBeSent URL still latches on', () {
      final tracker = MainDocumentStatusTracker();
      final bareOrigin = Uri.parse('https://example.com/');
      tracker.observe(
        requestWillBeSent(requestId: 'r1', url: 'https://example.com'),
        navigatedUrl: bareOrigin,
        isTopLevelSession: true,
      );
      tracker.observe(
        responseReceived(requestId: 'r1', status: 404),
        navigatedUrl: bareOrigin,
        isTopLevelSession: true,
      );

      expect(tracker.status, 404);
    });
  });
}
