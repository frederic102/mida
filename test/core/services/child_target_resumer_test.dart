import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/services/cdp_client.dart';
import 'package:mida/core/services/child_target_resumer.dart';

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

void main() {
  group('ChildTargetResumer.handle', () {
    late HttpServer server;
    tearDown(() async => server.close(force: true));

    test('a page-typed target: Fetch.enable and Network.enable are sent, then always resumed', () async {
      final calls = <String>[];
      server = await _startFakeDevtoolsServer((socket) {
        socket.listen((raw) {
          final message = jsonDecode(raw as String) as Map<String, dynamic>;
          calls.add(message['method'] as String);
          socket.add(jsonEncode({'id': message['id'], 'result': {}}));
        });
      });
      final cdp = await CdpClient.connect(Uri.parse('ws://127.0.0.1:${server.port}/devtools/browser/fake'));

      await ChildTargetResumer.handle(cdp, 'child-1', targetType: 'page');
      await cdp.close();

      expect(calls, contains('Fetch.enable'));
      expect(calls, contains('Network.enable'));
      expect(calls.last, 'Runtime.runIfWaitingForDebugger');
    });

    for (final workerType in ['worker', 'shared_worker', 'service_worker']) {
      test(
        'a $workerType-typed target: Fetch.enable and Network.enable are ALSO attempted, then always resumed',
        () async {
          // Round 4 (coordinator security follow-up): a shared_worker or
          // service_worker target can itself issue requests, and none of
          // those were ever adjudicated by PrivateDestinationGuard while
          // Fetch/Network enabling was restricted to page/iframe only.
          // Safe to widen now that resume is unconditional (see the
          // guard-can-fail test below) - unlike round 3, a target type CDP
          // rejects these calls for can no longer get stuck.
          final calls = <String>[];
          server = await _startFakeDevtoolsServer((socket) {
            socket.listen((raw) {
              final message = jsonDecode(raw as String) as Map<String, dynamic>;
              calls.add(message['method'] as String);
              socket.add(jsonEncode({'id': message['id'], 'result': {}}));
            });
          });
          final cdp = await CdpClient.connect(Uri.parse('ws://127.0.0.1:${server.port}/devtools/browser/fake'));

          await ChildTargetResumer.handle(cdp, 'child-1', targetType: workerType);
          await cdp.close();

          expect(calls, contains('Fetch.enable'));
          expect(calls, contains('Network.enable'));
          expect(calls.last, 'Runtime.runIfWaitingForDebugger');
        },
      );
    }

    test(
      'an unrecognized target type skips Fetch.enable/Network.enable entirely but is still resumed',
      () async {
        final calls = <String>[];
        server = await _startFakeDevtoolsServer((socket) {
          socket.listen((raw) {
            final message = jsonDecode(raw as String) as Map<String, dynamic>;
            calls.add(message['method'] as String);
            socket.add(jsonEncode({'id': message['id'], 'result': {}}));
          });
        });
        final cdp = await CdpClient.connect(Uri.parse('ws://127.0.0.1:${server.port}/devtools/browser/fake'));

        await ChildTargetResumer.handle(cdp, 'child-1', targetType: 'browser');
        await cdp.close();

        expect(calls, isNot(contains('Fetch.enable')));
        expect(calls, isNot(contains('Network.enable')));
        expect(calls, ['Runtime.runIfWaitingForDebugger']);
      },
    );

    test(
      'guard can fail: Fetch.enable erroring on a service_worker-typed target still resumes it (never leaves it paused)',
      () async {
        // The exact deadlock round 3 fixed, re-proven for the round-4
        // widened target set: without the `finally`, an error reply to
        // Fetch.enable would skip Runtime.runIfWaitingForDebugger entirely,
        // leaving this target paused forever (waitForDebuggerOnStart: true) -
        // this is precisely the failure mode that made widening this set
        // to worker types safe rather than a reintroduction of round 3's bug.
        final calls = <String>[];
        server = await _startFakeDevtoolsServer((socket) {
          socket.listen((raw) {
            final message = jsonDecode(raw as String) as Map<String, dynamic>;
            final method = message['method'] as String;
            calls.add(method);
            if (method == 'Fetch.enable') {
              socket.add(jsonEncode({'id': message['id'], 'error': {'code': -32000, 'message': 'not supported'}}));
            } else {
              socket.add(jsonEncode({'id': message['id'], 'result': {}}));
            }
          });
        });
        final cdp = await CdpClient.connect(Uri.parse('ws://127.0.0.1:${server.port}/devtools/browser/fake'));

        await ChildTargetResumer.handle(cdp, 'child-1', targetType: 'service_worker');
        await cdp.close();

        expect(calls, contains('Runtime.runIfWaitingForDebugger'));
      },
    );

    test('a session that closes before resume completes does not throw', () async {
      server = await _startFakeDevtoolsServer((socket) => socket.listen((_) {}));
      final cdp = await CdpClient.connect(Uri.parse('ws://127.0.0.1:${server.port}/devtools/browser/fake'));
      await cdp.close();

      await ChildTargetResumer.handle(cdp, 'child-1', targetType: 'page');
      // Reaching here at all is the assertion.
    });
  });
}
