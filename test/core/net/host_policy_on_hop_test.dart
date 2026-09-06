import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/net/host_policy.dart';

/// Phase 6 round 4 lead contract: `HostPolicy.guardedRequest` reports every
/// hop it is about to request through `onHop`, so a caller can learn the
/// effective URI a redirected body really came from (for resolving relative
/// references and for credential-scope decisions).
void main() {
  late HttpServer server;
  late Uri root;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    root = Uri.parse('http://127.0.0.1:${server.port}/root.m3u8');
    server.listen((request) async {
      if (request.uri.path == '/root.m3u8') {
        request.response.statusCode = 302;
        request.response.headers.set('location', 'https://cdn.example.invalid/path/final.m3u8');
      } else {
        request.response.statusCode = 200;
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('guard can fail: onHop reports hop 0 and the redirect target, in order, before the redirect hop is '
      'host-checked', () async {
    final hops = <Uri>[];
    final client = HttpClient();
    try {
      await expectLater(
        HostPolicy.guardedRequest(
          client,
          root,
          useHead: false,
          allowPrivateHosts: true,
          resolveHost: (host) async => throw const SocketException('offline'),
          onHop: hops.add,
        ),
        throwsA(isA<Object>()),
        reason: 'the redirect target is never exempt, so the second hop is refused or fails to resolve; what '
            'matters here is what onHop saw before that',
      );
    } finally {
      client.close(force: true);
    }

    expect(hops, [root, Uri.parse('https://cdn.example.invalid/path/final.m3u8')],
        reason: 'guard can fail: drop the onHop call from guardedRequest and this list is empty, so a caller '
            'parsing a redirected manifest against the pre-redirect URL has nothing to correct it with');
  });

  test('a caller that passes no onHop is unaffected', () async {
    final client = HttpClient();
    try {
      await expectLater(
        HostPolicy.guardedRequest(
          client,
          root,
          useHead: false,
          allowPrivateHosts: true,
          resolveHost: (host) async => throw const SocketException('offline'),
        ),
        throwsA(isA<Object>()),
      );
    } finally {
      client.close(force: true);
    }
  });
}
