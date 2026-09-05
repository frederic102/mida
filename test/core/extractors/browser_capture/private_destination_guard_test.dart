import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/browser_capture/private_destination_guard.dart';
import 'package:mida/core/services/browser_devtools_session.dart';
import 'package:mida/core/services/cdp_client.dart';

/// Records every `(sessionId, method, params)` triple sent through
/// [DevtoolsSession.sendToSession] - all [PrivateDestinationGuard] ever
/// calls - so a test can assert exactly which of `Fetch.failRequest` /
/// `Fetch.continueRequest` was chosen for a given `Fetch.requestPaused`.
class _RecordingSession implements DevtoolsSession {
  final calls = <(String, String, Map<String, dynamic>?)>[];

  @override
  List<String> get childSessionIds => const [];

  @override
  Stream<CdpEvent> get events => const Stream<CdpEvent>.empty();

  @override
  Future<Map<String, dynamic>> send(String method, [Map<String, dynamic>? params]) async => const {};

  @override
  Future<Map<String, dynamic>> sendBrowserLevel(String method, [Map<String, dynamic>? params]) async => const {};

  @override
  Future<Map<String, dynamic>> sendToSession(String sessionId, String method, [Map<String, dynamic>? params]) async {
    calls.add((sessionId, method, params));
    return const {};
  }

  @override
  Future<void> close() async {}
}

CdpEvent _requestPaused(String url, {String requestId = 'req-1', String sessionId = 'session-1'}) => CdpEvent(
      method: 'Fetch.requestPaused',
      sessionId: sessionId,
      params: {'requestId': requestId, 'request': {'url': url}},
    );

void main() {
  group('PrivateDestinationGuard.handle', () {
    test('a literal cloud-metadata address is failed, not continued', () async {
      final session = _RecordingSession();

      await PrivateDestinationGuard.handle(session, _requestPaused('http://169.254.169.254/latest/meta-data/'));

      expect(session.calls, hasLength(1));
      final (sessionId, method, params) = session.calls.single;
      expect(sessionId, 'session-1');
      expect(method, 'Fetch.failRequest');
      expect(params?['requestId'], 'req-1');
    });

    test('a literal loopback address is failed', () async {
      final session = _RecordingSession();

      await PrivateDestinationGuard.handle(session, _requestPaused('http://127.0.0.1:8080/steal'));

      expect(session.calls.single.$2, 'Fetch.failRequest');
    });

    test('an ordinary public URL is continued, not failed', () async {
      final session = _RecordingSession();

      await PrivateDestinationGuard.handle(session, _requestPaused('https://cdn.example.com/video.mp4'));

      expect(session.calls, hasLength(1));
      final (sessionId, method, params) = session.calls.single;
      expect(sessionId, 'session-1');
      expect(method, 'Fetch.continueRequest');
      expect(params?['requestId'], 'req-1');
    });

    test('guard can fail: an RFC1918 private address is failed exactly like loopback', () async {
      // Proves the block covers more than just 127.0.0.1: a page that
      // targets an internal LAN address (10.x/172.16-31.x/192.168.x) must
      // be treated the same as a literal loopback/metadata address.
      final session = _RecordingSession();

      await PrivateDestinationGuard.handle(session, _requestPaused('http://192.168.1.1/admin'));

      expect(session.calls.single.$2, 'Fetch.failRequest');
    });

    test('a non-Fetch.requestPaused event is ignored entirely', () async {
      final session = _RecordingSession();

      await PrivateDestinationGuard.handle(
        session,
        const CdpEvent(method: 'Network.responseReceived', params: {}, sessionId: 'session-1'),
      );

      expect(session.calls, isEmpty);
    });

    test('an event missing requestId or sessionId is a no-op, not a throw', () async {
      final session = _RecordingSession();

      await PrivateDestinationGuard.handle(
        session,
        const CdpEvent(method: 'Fetch.requestPaused', params: {'request': {'url': 'https://cdn.example.com/a.mp4'}}),
      );

      expect(session.calls, isEmpty);
    });

    test('an unparseable request URL is continued (fail-open on the guard itself, not silently dropped)', () async {
      final session = _RecordingSession();

      await PrivateDestinationGuard.handle(session, _requestPaused('::not a uri at all::'));

      expect(session.calls.single.$2, 'Fetch.continueRequest');
    });
  });
}
