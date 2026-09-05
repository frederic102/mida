import 'dart:async';
import 'dart:io';

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
    // The DNS verdict cache is process-lifetime, not per-instance (there
    // is no instance - every method here is static) - clear it before
    // each test so one test's lookups can never leak into another's
    // assertions about whether a *fresh* lookup happened.
    setUp(PrivateDestinationGuard.debugClearDnsCache);

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
      // A literal public IP, not a hostname: `HostPolicy.isDisallowedHost`
      // resolves this branch entirely syntactically (no real DNS lookup
      // at all), keeping this test hermetic and network-independent -
      // deliberately not `cdn.example.com`-style, which would exercise
      // the real DNS-resolving branch (and, since the fail-closed fix
      // below, go the *other* way if that particular subdomain happens
      // not to resolve at all in whatever environment runs this suite).
      final session = _RecordingSession();

      await PrivateDestinationGuard.handle(session, _requestPaused('https://8.8.8.8/video.mp4'));

      expect(session.calls, hasLength(1));
      final (sessionId, method, params) = session.calls.single;
      expect(sessionId, 'session-1');
      expect(method, 'Fetch.continueRequest');
      expect(params?['requestId'], 'req-1');
    });

    test('guard can fail: a hostname whose DNS lookup fails is blocked (fails closed), not waved through', () async {
      // `.invalid` is reserved by RFC 2606 to never resolve - a
      // deterministic, offline-safe way to trigger a real lookup
      // failure. Before this fix, an unresolvable hostname was allowed
      // through (fail-open); a page could have defeated the whole guard
      // just by using a hostname whose resolution could be made to fail
      // or time out.
      final session = _RecordingSession();

      await PrivateDestinationGuard.handle(
        session,
        _requestPaused('https://this-host-does-not-exist-anywhere.invalid/video.mp4'),
      );

      expect(session.calls.single.$2, 'Fetch.failRequest');
    }, timeout: const Timeout(Duration(seconds: 10)));

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

    test('guard can fail: two requests to the same host reuse one cached lookup, not one lookup each', () async {
      // Independent review round 3: a page making dozens of requests to
      // the same handful of hosts (routine for a modern SPA) was
      // triggering one real DNS lookup *per request*, with no reuse -
      // measured regression: Douyin/VK/OK.ru/Twitch-clip all went from
      // resolving in well under 35s to the full 90s wall. This asserts
      // the injected resolver is invoked exactly once for two separate
      // Fetch.requestPaused events against the same host.
      var lookupCount = 0;
      Future<List<InternetAddress>> countingResolver(String host) async {
        lookupCount++;
        return [InternetAddress('93.184.216.34')];
      }

      final session = _RecordingSession();
      await PrivateDestinationGuard.handle(
        session,
        _requestPaused('https://shared-host.example/a.mp4', requestId: 'req-1'),
        resolveHost: countingResolver,
      );
      await PrivateDestinationGuard.handle(
        session,
        _requestPaused('https://shared-host.example/b.mp4', requestId: 'req-2'),
        resolveHost: countingResolver,
      );

      expect(lookupCount, 1);
      expect(session.calls, hasLength(2));
      expect(session.calls.every((c) => c.$2 == 'Fetch.continueRequest'), isTrue);
    });

    test('concurrent requests to the same in-flight host share one lookup, not one each', () async {
      var lookupCount = 0;
      final resolverCompleter = Completer<List<InternetAddress>>();
      Future<List<InternetAddress>> slowResolver(String host) {
        lookupCount++;
        return resolverCompleter.future;
      }

      final session = _RecordingSession();
      final first = PrivateDestinationGuard.handle(
        session,
        _requestPaused('https://shared-slow-host.example/a.mp4', requestId: 'req-1'),
        resolveHost: slowResolver,
      );
      final second = PrivateDestinationGuard.handle(
        session,
        _requestPaused('https://shared-slow-host.example/b.mp4', requestId: 'req-2'),
        resolveHost: slowResolver,
      );

      resolverCompleter.complete([InternetAddress('93.184.216.34')]);
      await Future.wait([first, second]);

      expect(lookupCount, 1);
    });
  });
}
