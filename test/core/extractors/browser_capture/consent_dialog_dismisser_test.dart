import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/browser_capture/consent_dialog_dismisser.dart';
import 'package:mida/core/services/browser_devtools_session.dart';
import 'package:mida/core/services/cdp_client.dart';

/// Records every `(sessionId, method)` pair, same pattern as
/// `playback_trigger_test.dart`'s own fake (duplicated per project
/// convention rather than shared across test libraries).
class _RecordingSession implements DevtoolsSession {
  @override
  final List<String> childSessionIds;
  final calls = <(String?, String)>[];
  final bool throwOnEvaluate;

  _RecordingSession({this.childSessionIds = const [], this.throwOnEvaluate = false});

  @override
  Stream<CdpEvent> get events => const Stream<CdpEvent>.empty();

  @override
  Future<Map<String, dynamic>> send(String method, [Map<String, dynamic>? params]) => _handle(null, method);

  @override
  Future<Map<String, dynamic>> sendBrowserLevel(String method, [Map<String, dynamic>? params]) async => const {};

  @override
  Future<Map<String, dynamic>> sendToSession(String sessionId, String method, [Map<String, dynamic>? params]) =>
      _handle(sessionId, method);

  @override
  Future<void> close() async {}

  Future<Map<String, dynamic>> _handle(String? sessionId, String method) async {
    calls.add((sessionId, method));
    if (throwOnEvaluate) throw StateError('session gone');
    return {
      'result': {'value': '2'}
    };
  }
}

void main() {
  group('ConsentDialogDismisser.dismiss', () {
    test('evaluates once on the top-level session when there are no child targets', () async {
      final session = _RecordingSession();

      await ConsentDialogDismisser.dismiss(session);

      expect(session.calls, hasLength(1));
      expect(session.calls.single, (null, 'Runtime.evaluate'));
    });

    test('also evaluates once inside each attached child (iframe) session', () async {
      // A consent overlay is sometimes itself served from a cross-origin
      // CMP iframe (OneTrust, Cookiebot); this is the case that exists
      // for.
      final session = _RecordingSession(childSessionIds: ['cmp-iframe']);

      await ConsentDialogDismisser.dismiss(session);

      expect(session.calls, containsAll([(null, 'Runtime.evaluate'), ('cmp-iframe', 'Runtime.evaluate')]));
    });

    test('a session that throws on evaluate does not propagate (best-effort only)', () async {
      final session = _RecordingSession(throwOnEvaluate: true);

      await ConsentDialogDismisser.dismiss(session);
      // Reaching here at all is the assertion.
    });

    test('guard can fail: the dismiss expression matches on button text, and stays within the click cap', () {
      // Pure-string checks on the expression ConsentDialogDismisser
      // actually sends - proves the match list includes the exact
      // English/Korean/Chinese phrases the class doc promises, and that
      // it caps how many elements it will click (a runaway match on a
      // page with hundreds of buttons must not click all of them).
      final expression = ConsentDialogDismisser.debugDismissExpression;
      expect(expression, contains('accept'));
      expect(expression, contains('동의'));
      expect(expression, contains('同意'));
      expect(expression, contains('clicked >= 5'));
    });
  });
}
