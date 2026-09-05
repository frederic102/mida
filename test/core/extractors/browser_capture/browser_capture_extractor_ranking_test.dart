import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/browser_capture/browser_capture_extractor.dart';
import 'package:mida/core/services/cdp_client.dart';
import 'package:mida/core/services/browser_devtools_session.dart';

/// Duplicated from `browser_capture_extractor_test.dart` (test-double,
/// not shared across test libraries per project convention).
class FakeDevtoolsSession implements DevtoolsSession {
  final _eventsController = StreamController<CdpEvent>.broadcast();
  final Future<Map<String, dynamic>> Function(String method, Map<String, dynamic>? params)? onSend;
  bool closed = false;

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
  Future<void> close() async {
    closed = true;
    await _eventsController.close();
  }
}

Map<String, dynamic> _jsonEvalResult(Map<String, dynamic> value) => {
      'result': {'value': jsonEncode(value)}
    };

/// Handles Runtime.evaluate for a session whose page has no login/DOM
/// niceties: the `querySelectorAll` (video element) probe returns
/// [videoUrls], everything else (meta title/thumbnail probe, the
/// autoplay nudge) returns an empty/no-op result.
Future<Map<String, dynamic>> _basicEvalHandler(Map<String, dynamic>? params, List<String> videoUrls) async {
  final expression = params?['expression'] as String? ?? '';
  if (expression.contains('querySelectorAll')) {
    return {
      'result': {'value': jsonEncode(videoUrls)}
    };
  }
  if (expression.contains('JSON.stringify')) {
    return _jsonEvalResult({'title': null, 'ogTitle': null, 'ogImage': null, 'href': null});
  }
  return {};
}

BrowserCaptureExtractor _fastExtractor(FakeDevtoolsSession session) => BrowserCaptureExtractor(
      sessionLauncher: ({connectTimeout = const Duration()}) async => session,
      loadTimeout: const Duration(milliseconds: 30),
      postLoadDelay: const Duration(milliseconds: 5),
      autoplayRetryDelay: const Duration(milliseconds: 5),
    );

void main() {
  group('BrowserCaptureExtractor ranking (end-to-end via fake DevtoolsSession)', () {
    test('a <video> element src outranks a much bigger unrelated captured asset', () async {
      const realUrl = 'https://cdn.example.com/the-real-post.mp4';
      late FakeDevtoolsSession session;
      session = FakeDevtoolsSession(
        onSend: (method, params) async {
          if (method == 'Page.navigate') {
            session.emit('Network.responseReceived', {
              'response': {
                'url': 'https://cdn.example.com/unrelated-big.mp4',
                'mimeType': 'video/mp4',
                'headers': {'content-length': '${50 * 1024 * 1024}'},
              },
            });
            session.emit('Network.responseReceived', {
              'response': {
                'url': realUrl,
                'mimeType': 'video/mp4',
                'headers': {'content-length': '${3 * 1024 * 1024}'},
              },
            });
            return {};
          }
          if (method == 'Runtime.evaluate') return _basicEvalHandler(params, [realUrl]);
          return {};
        },
      );

      final info = await _fastExtractor(session).extract(Uri.parse('https://example.com/page'));

      expect(info.formats.first.url, realUrl);
    });

    test('a tiny captured asset is dropped end-to-end when a much larger candidate exists', () async {
      late FakeDevtoolsSession session;
      session = FakeDevtoolsSession(
        onSend: (method, params) async {
          if (method == 'Page.navigate') {
            session.emit('Network.responseReceived', {
              'response': {
                'url': 'https://cdn.example.com/tiny-login-loop.mp4',
                'mimeType': 'video/mp4',
                'headers': {'content-length': '${40 * 1024}'},
              },
            });
            session.emit('Network.responseReceived', {
              'response': {
                'url': 'https://cdn.example.com/real-post.mp4',
                'mimeType': 'video/mp4',
                'headers': {'content-length': '${4 * 1024 * 1024}'},
              },
            });
            return {};
          }
          if (method == 'Runtime.evaluate') return _basicEvalHandler(params, const []);
          return {};
        },
      );

      final info = await _fastExtractor(session).extract(Uri.parse('https://example.com/page'));

      // Guard can fail: this exact fixture (a ~40KB and a ~4MB candidate,
      // no DOM video match) is the one the CapturedMediaRanker unit test
      // ("a tiny captured asset is dropped once a confirmed-larger
      // candidate exists") proves goes from 2 candidates to 1 once the
      // size-cutoff step is removed from `CapturedMediaRanker.rank` -
      // removing that step would turn this `hasLength(1)` red too, since
      // both extractor and ranker test exercise the identical rule.
      expect(info.formats, hasLength(1));
      expect(info.formats.single.url, 'https://cdn.example.com/real-post.mp4');
    });

    test('audio/* mimeType produces an audio-only format (hasVideo: false)', () async {
      late FakeDevtoolsSession session;
      session = FakeDevtoolsSession(
        onSend: (method, params) async {
          if (method == 'Page.navigate') {
            session.emit('Network.responseReceived', {
              // `.m4a` is not one of CapturedMediaClassifier's recognized
              // extensions (only mp4/m3u8/mpd/webm/m4s); an audio-only
              // track packaged with an `.mp4` extension is the realistic
              // shape this case actually shows up in.
              'response': {'url': 'https://cdn.example.com/track.mp4', 'mimeType': 'audio/mp4'},
            });
            return {};
          }
          if (method == 'Runtime.evaluate') return _basicEvalHandler(params, const []);
          return {};
        },
      );

      final info = await _fastExtractor(session).extract(Uri.parse('https://example.com/page'));

      expect(info.formats.single.hasVideo, isFalse);
      expect(info.formats.single.hasAudio, isTrue);
    });

    test('video/* mimeType produces a muxed format (hasVideo and hasAudio both true)', () async {
      late FakeDevtoolsSession session;
      session = FakeDevtoolsSession(
        onSend: (method, params) async {
          if (method == 'Page.navigate') {
            session.emit('Network.responseReceived', {
              'response': {'url': 'https://cdn.example.com/clip.mp4', 'mimeType': 'video/mp4'},
            });
            return {};
          }
          if (method == 'Runtime.evaluate') return _basicEvalHandler(params, const []);
          return {};
        },
      );

      final info = await _fastExtractor(session).extract(Uri.parse('https://example.com/page'));

      expect(info.formats.single.hasVideo, isTrue);
      expect(info.formats.single.hasAudio, isTrue);
    });
  });
}
