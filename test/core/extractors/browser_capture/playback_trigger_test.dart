import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/browser_capture/playback_trigger.dart';
import 'package:mida/core/services/browser_devtools_session.dart';
import 'package:mida/core/services/cdp_client.dart';

/// Records every `(sessionId, method)` pair PlaybackTrigger sends, so tests
/// can assert *which* session (top-level `null`, or a specific child) each
/// trigger step actually landed on - the whole point of
/// `PlaybackTrigger.triggerAll` iterating [childSessionIds] in the first
/// place.
class _RecordingSession implements DevtoolsSession {
  @override
  final List<String> childSessionIds;
  final bool Function(String? sessionId)? failSessionsWhere;
  final calls = <(String?, String)>[];

  _RecordingSession({this.childSessionIds = const [], this.failSessionsWhere});

  @override
  Stream<CdpEvent> get events => const Stream<CdpEvent>.empty();

  @override
  Future<Map<String, dynamic>> send(String method, [Map<String, dynamic>? params]) => _handle(null, method, params);

  @override
  Future<Map<String, dynamic>> sendBrowserLevel(String method, [Map<String, dynamic>? params]) async => const {};

  @override
  Future<Map<String, dynamic>> sendToSession(String sessionId, String method, [Map<String, dynamic>? params]) =>
      _handle(sessionId, method, params);

  @override
  Future<void> close() async {}

  Future<Map<String, dynamic>> _handle(String? sessionId, String method, Map<String, dynamic>? params) async {
    calls.add((sessionId, method));
    if (failSessionsWhere?.call(sessionId) ?? false) {
      throw StateError('session $sessionId is gone');
    }
    if (method == 'Runtime.evaluate') {
      final expression = params?['expression'] as String? ?? '';
      if (expression.contains('getBoundingClientRect')) {
        return {
          'result': {'value': '{"x":10,"y":20}'}
        };
      }
      return {
        'result': {'value': 'true'}
      };
    }
    return const {};
  }
}

void main() {
  group('PlaybackTrigger.triggerAll', () {
    test('with no attached child targets, every trigger step runs on the top-level session only', () async {
      final session = _RecordingSession();

      await PlaybackTrigger.triggerAll(session);

      expect(session.calls, isNotEmpty);
      expect(session.calls.every((call) => call.$1 == null), isTrue);
      // click-buttons eval, center-click eval, 2 Input.dispatchMouseEvent,
      // muted-play eval, scroll eval.
      expect(session.calls.where((c) => c.$2 == 'Input.dispatchMouseEvent'), hasLength(2));
    });

    test('also runs every trigger step inside each attached child (iframe) session', () async {
      final session = _RecordingSession(childSessionIds: ['child-1', 'child-2']);

      await PlaybackTrigger.triggerAll(session);

      final topLevelCalls = session.calls.where((c) => c.$1 == null);
      final child1Calls = session.calls.where((c) => c.$1 == 'child-1');
      final child2Calls = session.calls.where((c) => c.$1 == 'child-2');

      expect(topLevelCalls, isNotEmpty);
      expect(child1Calls, isNotEmpty);
      expect(child2Calls, isNotEmpty);
      expect(child1Calls.length, topLevelCalls.length);
      expect(child2Calls.length, topLevelCalls.length);
    });

    test('a child session that has already closed does not abort the remaining targets', () async {
      final session = _RecordingSession(
        childSessionIds: ['dead-child', 'live-child'],
        failSessionsWhere: (sessionId) => sessionId == 'dead-child',
      );

      // Must not throw: a closed iframe target is a partial miss, not a
      // capture failure (matches the class-level doc: "must never abort
      // the capture").
      await PlaybackTrigger.triggerAll(session);

      expect(session.calls.where((c) => c.$1 == 'live-child'), isNotEmpty);
      expect(session.calls.where((c) => c.$1 == null), isNotEmpty);
    });

    test('every Runtime.evaluate call failing outright still completes without throwing', () async {
      final session = _RecordingSession(failSessionsWhere: (_) => true);

      await PlaybackTrigger.triggerAll(session);

      expect(session.calls, isNotEmpty);
    });
  });
}
