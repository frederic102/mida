import 'dart:async';
import 'dart:convert';

import 'package:mida/core/services/browser_devtools_session.dart';
import 'package:mida/core/services/cdp_client.dart';

/// In-memory stand-in for [DevtoolsSession] (no real browser, no
/// WebSocket): scripts what `send`/`sendBrowserLevel` return per method and
/// lets a test emit events directly onto the stream the extractor already
/// listens on. This is what makes `BrowserCaptureExtractor`'s orchestration
/// logic (event collection, dedupe, fallback ladder, metadata assembly)
/// unit-testable without a browser at all.
///
/// Shared across `browser_capture_extractor_test.dart` and
/// `browser_capture_extractor_fragments_test.dart` (split out round 5, once
/// the fragment-shape tests pushed the original single file over this
/// project's 400-line cap) - not itself a `_test.dart` file, so the test
/// runner never tries to execute it as its own suite.
class FakeDevtoolsSession implements DevtoolsSession {
  final _eventsController = StreamController<CdpEvent>.broadcast();
  final Future<Map<String, dynamic>> Function(String method, Map<String, dynamic>? params)? onSend;
  final Future<Map<String, dynamic>> Function(String method, Map<String, dynamic>? params)? onSendBrowserLevel;
  bool closed = false;

  FakeDevtoolsSession({this.onSend, this.onSendBrowserLevel});

  void emit(String method, Map<String, dynamic> params) {
    _eventsController.add(CdpEvent(method: method, params: params));
  }

  @override
  Stream<CdpEvent> get events => _eventsController.stream;

  @override
  Future<Map<String, dynamic>> send(String method, [Map<String, dynamic>? params]) async =>
      (await onSend?.call(method, params)) ?? const {};

  @override
  Future<Map<String, dynamic>> sendBrowserLevel(String method, [Map<String, dynamic>? params]) async =>
      (await onSendBrowserLevel?.call(method, params)) ?? const {};

  // No child (iframe) targets in these fixtures - PlaybackTrigger.triggerAll
  // runs only on the top-level session, exactly as before it could reach
  // into an iframe at all.
  @override
  List<String> get childSessionIds => const [];

  @override
  Future<Map<String, dynamic>> sendToSession(String sessionId, String method, [Map<String, dynamic>? params]) =>
      send(method, params);

  @override
  Future<void> close() async {
    closed = true;
    await _eventsController.close();
  }
}

Map<String, dynamic> jsonEvalResult(Map<String, dynamic> value) => {
      'result': {'value': jsonEncode(value)}
    };

Map<String, dynamic> stringEvalResult(String value) => {
      'result': {'value': value}
    };
