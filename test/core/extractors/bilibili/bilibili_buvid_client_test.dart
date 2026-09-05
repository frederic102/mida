import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/bilibili/bilibili_buvid_client.dart';

class _FixedResponseServer {
  final HttpServer server;
  int statusCode = 200;
  String body = '{}';

  _FixedResponseServer(this.server);

  static Future<_FixedResponseServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _FixedResponseServer(server);
    server.listen(instance._handle);
    return instance;
  }

  Uri get baseUri => Uri(scheme: 'http', host: '127.0.0.1', port: server.port);

  Future<void> _handle(HttpRequest request) async {
    request.response.statusCode = statusCode;
    request.response.write(body);
    await request.response.close();
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  late _FixedResponseServer server;

  setUp(() async => server = await _FixedResponseServer.start());
  tearDown(() => server.close());

  BilibiliBuvidClient buildClient() =>
      BilibiliBuvidClient(requestUrlBuilder: (url) => server.baseUri.replace(path: '/finger/spi'));

  test('parses b_3/b_4 from a real-shaped finger/spi response into buvid3/buvid4', () async {
    server.body = jsonEncode({
      'code': 0,
      'data': {'b_3': 'F54EE94E-EXAMPLE-infoc', 'b_4': '90D2EA1D-EXAMPLE=='},
      'message': 'ok',
    });

    final cookies = await buildClient().fetchCookies();
    expect(cookies['buvid3'], 'F54EE94E-EXAMPLE-infoc');
    expect(cookies['buvid4'], '90D2EA1D-EXAMPLE==');
  });

  test('returns an empty map (not a throw) on a non-200 response', () async {
    server.statusCode = 412;
    server.body = 'blocked';
    final cookies = await buildClient().fetchCookies();
    expect(cookies, isEmpty);
  });

  test('returns an empty map on an unparsable body', () async {
    server.body = 'not json';
    final cookies = await buildClient().fetchCookies();
    expect(cookies, isEmpty);
  });
}
