import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/browser_capture/browser_capture_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/services/browser_devtools_session.dart';
import 'package:mida/core/services/cdp_client.dart';

/// Duplicated from `browser_capture_extractor_test.dart` (test-double,
/// not shared across test libraries per project convention).
class FakeDevtoolsSession implements DevtoolsSession {
  final _eventsController = StreamController<CdpEvent>.broadcast();
  final Future<Map<String, dynamic>> Function(String method, Map<String, dynamic>? params)? onSend;

  FakeDevtoolsSession({this.onSend});

  void emit(String method, Map<String, dynamic> params) {
    _eventsController.add(CdpEvent(method: method, params: params));
  }

  @override
  Stream<CdpEvent> get events => _eventsController.stream;

  @override
  Future<Map<String, dynamic>> send(String method, [Map<String, dynamic>? params]) async =>
      (await onSend?.call(method, params)) ?? const {};

  @override
  Future<Map<String, dynamic>> sendBrowserLevel(String method, [Map<String, dynamic>? params]) async => const {};

  @override
  List<String> get childSessionIds => const [];

  @override
  Future<Map<String, dynamic>> sendToSession(String sessionId, String method, [Map<String, dynamic>? params]) =>
      send(method, params);

  @override
  Future<void> close() async {
    await _eventsController.close();
  }
}

Map<String, dynamic> _stringEvalResult(String value) => {
      'result': {'value': value}
    };

BrowserCaptureExtractor _fastExtractor(FakeDevtoolsSession session) => BrowserCaptureExtractor(
      sessionLauncher: ({connectTimeout = const Duration()}) async => session,
      loadTimeout: const Duration(milliseconds: 30),
      postLoadDelay: const Duration(milliseconds: 5),
      autoplayRetryDelay: const Duration(milliseconds: 5),
      firstCandidateTimeout: const Duration(milliseconds: 20),
      variantSettleDelay: const Duration(milliseconds: 5),
      pollInterval: const Duration(milliseconds: 5),
    );

void main() {
  group('BrowserCaptureExtractor page-status detection (end-to-end via fake DevtoolsSession)', () {
    test('redirect to /accounts/login with no media throws LOGIN_REQUIRED', () async {
      final session = FakeDevtoolsSession(
        onSend: (method, params) async {
          if (method == 'Runtime.evaluate') {
            final expression = params?['expression'] as String? ?? '';
            if (expression.contains('querySelectorAll')) return _stringEvalResult('[]');
            if (expression.contains('outerHTML')) return _stringEvalResult('<html><body>nothing</body></html>');
            if (expression.contains('JSON.stringify')) {
              return _stringEvalResult(jsonEncode({
                'title': null,
                'ogTitle': null,
                'ogImage': null,
                'href': 'https://www.instagram.com/accounts/login/?next=/reel/xyz/',
              }));
            }
          }
          return {};
        },
      );

      await expectLater(
        _fastExtractor(session).extract(Uri.parse('https://www.instagram.com/reel/xyz/')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'LOGIN_REQUIRED')),
      );
    });

    test('a title containing "Log in" with no media throws LOGIN_REQUIRED even without a redirect', () async {
      final session = FakeDevtoolsSession(
        onSend: (method, params) async {
          if (method == 'Runtime.evaluate') {
            final expression = params?['expression'] as String? ?? '';
            if (expression.contains('querySelectorAll')) return _stringEvalResult('[]');
            if (expression.contains('outerHTML')) return _stringEvalResult('<html><body>nothing</body></html>');
            if (expression.contains('JSON.stringify')) {
              return _stringEvalResult(jsonEncode({
                'title': 'Log in • Example',
                'ogTitle': null,
                'ogImage': null,
                'href': 'https://example.com/watch?v=1',
              }));
            }
          }
          return {};
        },
      );

      await expectLater(
        _fastExtractor(session).extract(Uri.parse('https://example.com/watch?v=1')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'LOGIN_REQUIRED')),
      );
    });

    test('a "Prove your humanity" title with no media throws BOT_CHECK_REQUIRED (fast, no drive-capture wait)', () async {
      final session = FakeDevtoolsSession(
        onSend: (method, params) async {
          if (method == 'Runtime.evaluate') {
            final expression = params?['expression'] as String? ?? '';
            if (expression.contains('querySelectorAll')) return _stringEvalResult('[]');
            if (expression.contains('outerHTML')) return _stringEvalResult('<html><body>nothing</body></html>');
            if (expression.contains('JSON.stringify')) {
              return _stringEvalResult(jsonEncode({
                'title': 'Reddit - Prove your humanity',
                'ogTitle': null,
                'ogImage': null,
                'href': 'https://www.reddit.com/r/aww/comments/1c0xhqk/',
              }));
            }
          }
          return {};
        },
      );

      // firstCandidateTimeout deliberately left at its (real, seconds-long)
      // default: if the early-exit did not fire, this test would time out
      // rather than merely being slow - proving BOT_CHECK_REQUIRED really
      // is detected before _driveCapture's poll loop, not after it.
      final extractor = BrowserCaptureExtractor(
        sessionLauncher: ({connectTimeout = const Duration()}) async => session,
        loadTimeout: const Duration(milliseconds: 30),
        postLoadDelay: const Duration(milliseconds: 5),
        autoplayRetryDelay: const Duration(milliseconds: 5),
      );

      await expectLater(
        extractor.extract(Uri.parse('https://www.reddit.com/r/aww/comments/1c0xhqk/')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'BOT_CHECK_REQUIRED')),
      );
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('a main-document 404 with no media throws NOT_FOUND', () async {
      late FakeDevtoolsSession session;
      session = FakeDevtoolsSession(
        onSend: (method, params) async {
          if (method == 'Page.navigate') {
            session.emit('Network.responseReceived', {
              'response': {'url': 'https://example.com/gone', 'mimeType': 'text/html', 'status': 404},
            });
            return {};
          }
          if (method == 'Runtime.evaluate') {
            final expression = params?['expression'] as String? ?? '';
            if (expression.contains('querySelectorAll')) return _stringEvalResult('[]');
            if (expression.contains('outerHTML')) return _stringEvalResult('<html><body>nothing</body></html>');
            if (expression.contains('JSON.stringify')) {
              return _stringEvalResult(jsonEncode({'title': null, 'ogTitle': null, 'ogImage': null, 'href': null}));
            }
          }
          return {};
        },
      );

      await expectLater(
        _fastExtractor(session).extract(Uri.parse('https://example.com/gone')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NOT_FOUND')),
      );
    });

    test('an ordinary empty page (no login, no 404) still throws the generic NO_MEDIA_FOUND', () async {
      final session = FakeDevtoolsSession(
        onSend: (method, params) async {
          if (method == 'Runtime.evaluate') {
            final expression = params?['expression'] as String? ?? '';
            if (expression.contains('querySelectorAll')) return _stringEvalResult('[]');
            if (expression.contains('outerHTML')) return _stringEvalResult('<html><body>nothing</body></html>');
            if (expression.contains('JSON.stringify')) {
              return _stringEvalResult(jsonEncode({'title': 'A perfectly normal page', 'ogTitle': null, 'ogImage': null, 'href': null}));
            }
          }
          return {};
        },
      );

      await expectLater(
        _fastExtractor(session).extract(Uri.parse('https://example.com/normal')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NO_MEDIA_FOUND')),
      );
    });
  });

  group('BrowserCaptureExtractor SSRF host guard (end-to-end via fake DevtoolsSession)', () {
    test('a loopback page URL is rejected before a session is ever launched', () async {
      var launched = false;
      final extractor = BrowserCaptureExtractor(
        sessionLauncher: ({connectTimeout = const Duration()}) async {
          launched = true;
          return FakeDevtoolsSession();
        },
      );

      await expectLater(
        extractor.extract(Uri.parse('http://127.0.0.1:9222/json/version')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL')),
      );
      expect(launched, isFalse);
    });

    test('a captured media candidate on a private-network host is rejected (UNSUPPORTED_URL)', () async {
      late FakeDevtoolsSession session;
      session = FakeDevtoolsSession(
        onSend: (method, params) async {
          if (method == 'Page.navigate') {
            session.emit('Network.responseReceived', {
              // Needs a recognized extension so CapturedMediaClassifier
              // actually accepts it as a candidate in the first place -
              // this test is specifically about the *host* guard firing
              // on an already-classified candidate, not about classify().
              'response': {'url': 'http://169.254.169.254/latest/meta-data/video.mp4', 'mimeType': 'video/mp4'},
            });
            return {};
          }
          return {};
        },
      );

      await expectLater(
        _fastExtractor(session).extract(Uri.parse('https://example.com/page')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL')),
      );
    });
  });
}
