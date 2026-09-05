import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/services/browser_devtools_session.dart';
import 'package:mida/core/services/cdp_client.dart';

/// Same fake-endpoint helper as `browser_devtools_session_test.dart`
/// (duplicated rather than shared across test libraries, per project
/// convention of not adding cross-file test-only utility modules).
Future<HttpServer> _startFakeDevtoolsServer(void Function(WebSocket socket) onSocket) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    onSocket(socket);
  });
  return server;
}

/// Minimal `implements Process` stand-in for
/// [BrowserDevtoolsSession.attachToConnectedClient] tests: lets a test
/// drive the CDP attach/auto-attach handshake against a fake WebSocket
/// endpoint without spawning (or killing) a real OS process.
class _FakeProcess implements Process {
  bool killed = false;
  final _exitCodeCompleter = Completer<int>();

  @override
  int get pid => 424242;

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  IOSink get stdin => IOSink(StreamController<List<int>>().sink);

  @override
  Future<int> get exitCode => _exitCodeCompleter.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!_exitCodeCompleter.isCompleted) _exitCodeCompleter.complete(0);
    return true;
  }
}

void main() {
  group('BrowserDevtoolsSession endpoint identity guard (fake DevTools WebSocket endpoint)', () {
    late HttpServer server;
    late Directory profileDir;

    setUp(() {
      profileDir = Directory.systemTemp.createTempSync('mida_cdp_identity_test_');
    });

    tearDown(() async {
      await server.close(force: true);
      if (profileDir.existsSync()) profileDir.deleteSync(recursive: true);
    });

    test(
      'rejects an unexpected DevTools endpoint (bogus Browser.getVersion product) and closes the connection',
      () async {
        var serverSawClose = false;
        server = await _startFakeDevtoolsServer((socket) {
          socket.done.then((_) => serverSawClose = true);
          socket.listen((raw) {
            final message = jsonDecode(raw as String) as Map<String, dynamic>;
            if (message['method'] == 'Browser.getVersion') {
              socket.add(jsonEncode({'id': message['id'], 'result': {'product': 'EvilServer/1.0'}}));
            } else {
              socket.add(jsonEncode({'id': message['id'], 'result': {}}));
            }
          });
        });

        final cdp = await CdpClient.connect(Uri.parse('ws://127.0.0.1:${server.port}/devtools/browser/fake'));
        final process = _FakeProcess();

        await expectLater(
          BrowserDevtoolsSession.attachToConnectedClient(cdp, process, profileDir),
          throwsA(
            isA<MediaExtractionException>()
                .having((e) => e.status, 'status', 'NETWORK')
                .having((e) => e.reason, 'reason', contains('Unexpected DevTools endpoint')),
          ),
        );

        // Never got past the identity check, so no target was ever
        // created/attached on the impostor endpoint.
        expect(process.killed, isFalse);

        await Future<void>.delayed(const Duration(milliseconds: 100));
        // Guard can fail: removing the `await cdp.close()` call before the
        // throw leaves the socket open and this assertion red - verified
        // by hand while writing this test, then restored.
        expect(serverSawClose, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test('accepts Chrome/HeadlessChrome/Edg-branded products', () async {
      for (final product in ['Chrome/128.0.0.0', 'HeadlessChrome/128.0.0.0', 'Edg/128.0.0.0']) {
        server = await _startFakeDevtoolsServer((socket) {
          socket.listen((raw) {
            final message = jsonDecode(raw as String) as Map<String, dynamic>;
            if (message['method'] == 'Browser.getVersion') {
              socket.add(jsonEncode({'id': message['id'], 'result': {'product': product}}));
            } else if (message['method'] == 'Target.createTarget') {
              socket.add(jsonEncode({'id': message['id'], 'result': {'targetId': 't'}}));
            } else if (message['method'] == 'Target.attachToTarget') {
              socket.add(jsonEncode({'id': message['id'], 'result': {'sessionId': 's'}}));
            } else {
              socket.add(jsonEncode({'id': message['id'], 'result': {}}));
            }
          });
        });

        final cdp = await CdpClient.connect(Uri.parse('ws://127.0.0.1:${server.port}/devtools/browser/fake'));
        final process = _FakeProcess();
        final session = await BrowserDevtoolsSession.attachToConnectedClient(cdp, process, profileDir);
        await session.close();
        await server.close(force: true);
      }
    });
  });

  group('BrowserDevtoolsSession child-target auto-attach (fake DevTools WebSocket endpoint)', () {
    late HttpServer server;
    late Directory profileDir;

    setUp(() {
      profileDir = Directory.systemTemp.createTempSync('mida_cdp_autoattach_test_');
    });

    tearDown(() async {
      await server.close(force: true);
      if (profileDir.existsSync()) profileDir.deleteSync(recursive: true);
    });

    /// Scripts the fake DevTools endpoint through the full attach
    /// handshake `attachToConnectedClient` performs, then (once the
    /// session's own `Target.setAutoAttach` call is acked) emits a
    /// `Target.attachedToTarget` event for a make-believe child target
    /// (standing in for a cross-origin iframe like Vimeo's
    /// `player.vimeo.com`). Once the session reacts by enabling `Network`
    /// on that child session, the fake server answers with a
    /// `Network.responseReceived` event carrying a video URL, tagged with
    /// the *child's* session id - exactly what a real child-target render
    /// process would produce.
    Future<HttpServer> startAutoAttachServer() => _startFakeDevtoolsServer((socket) {
          socket.listen((raw) {
            final message = jsonDecode(raw as String) as Map<String, dynamic>;
            final method = message['method'] as String;
            final id = message['id'];
            final sessionId = message['sessionId'] as String?;

            switch (method) {
              case 'Browser.getVersion':
                socket.add(jsonEncode({'id': id, 'result': {'product': 'HeadlessChrome/128.0.0.0'}}));
                break;
              case 'Target.createTarget':
                socket.add(jsonEncode({'id': id, 'result': {'targetId': 'target-main'}}));
                break;
              case 'Target.attachToTarget':
                socket.add(jsonEncode({'id': id, 'result': {'sessionId': 'session-main'}}));
                break;
              case 'Target.setAutoAttach':
                socket.add(jsonEncode({'id': id, 'result': {}}));
                socket.add(jsonEncode({
                  'method': 'Target.attachedToTarget',
                  'sessionId': 'session-main',
                  'params': {
                    'sessionId': 'session-child',
                    'targetInfo': {
                      'targetId': 'target-child',
                      'type': 'iframe',
                      'url': 'https://player.vimeo.com/video/1',
                    },
                    'waitingForDebugger': false,
                  },
                }));
                break;
              case 'Network.enable':
                socket.add(jsonEncode({'id': id, 'result': {}}));
                if (sessionId == 'session-child') {
                  socket.add(jsonEncode({
                    'method': 'Network.responseReceived',
                    'sessionId': 'session-child',
                    'params': {
                      'response': {'url': 'https://player.vimeo.com/cdn/video.mp4', 'mimeType': 'video/mp4'}
                    },
                  }));
                }
                break;
              default:
                socket.add(jsonEncode({'id': id, 'result': {}}));
            }
          });
        });

    test('merges a Network.responseReceived event from an auto-attached child target', () async {
      server = await startAutoAttachServer();
      final cdp = await CdpClient.connect(Uri.parse('ws://127.0.0.1:${server.port}/devtools/browser/fake'));
      final process = _FakeProcess();

      final session = await BrowserDevtoolsSession.attachToConnectedClient(cdp, process, profileDir);
      addTearDown(() => session.close());

      final childEvents = await session.events
          .where((e) => e.sessionId == 'session-child')
          .take(1)
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(childEvents, hasLength(1));
      expect(childEvents.single.method, 'Network.responseReceived');
      expect((childEvents.single.params['response'] as Map)['url'], 'https://player.vimeo.com/cdn/video.mp4');

      // Guard-can-fail evidence (verified by hand while writing this
      // test, not left toggled in committed code): temporarily changing
      // `BrowserDevtoolsSession.events`'s filter back to
      // `e.sessionId == _sessionId` (the pre-auto-attach single-session
      // filter) reproduces the exact bug this feature fixes - the child's
      // `Network.responseReceived` event is silently dropped, the
      // `.timeout(...)` above fires, and this test goes red with a
      // TimeoutException instead of the expected single event.
    });
  });
}
