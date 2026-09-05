import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/bilibili/bilibili_wbi_key_client.dart';
import 'package:mida/core/extractors/media_models.dart';

class _FixedResponseServer {
  final HttpServer server;
  int statusCode = 200;
  String body = '{}';
  String? lastCookieHeader;

  _FixedResponseServer(this.server);

  static Future<_FixedResponseServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _FixedResponseServer(server);
    server.listen(instance._handle);
    return instance;
  }

  Uri get baseUri => Uri(scheme: 'http', host: '127.0.0.1', port: server.port);

  Future<void> _handle(HttpRequest request) async {
    lastCookieHeader = request.headers.value('cookie');
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

  BilibiliWbiKeyClient buildClient() =>
      BilibiliWbiKeyClient(requestUrlBuilder: (url) => server.baseUri.replace(path: '/nav'));

  test('extracts img/sub keys from a real-shaped nav response, even when not logged in', () async {
    server.body = jsonEncode({
      'code': -101,
      'message': 'not logged in',
      'data': {
        'isLogin': false,
        'wbi_img': {
          'img_url': 'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
          'sub_url': 'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
        },
      },
    });

    final keys = await buildClient().fetchKeys({'buvid3': 'x'});
    expect(keys.imgKey, '7cd084941338484aae1ad9425b84077c');
    expect(keys.subKey, '4932caff0ff746eab6f01bf08b70ac45');
    expect(server.lastCookieHeader, 'buvid3=x');
  });

  test('throws PARSE_ERROR when wbi_img is missing', () async {
    server.body = jsonEncode({'code': 0, 'data': {}});
    await expectLater(
      buildClient().fetchKeys(const {}),
      throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR')),
    );
  });

  test('maps a non-200 response to NETWORK', () async {
    server.statusCode = 500;
    await expectLater(
      buildClient().fetchKeys(const {}),
      throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NETWORK')),
    );
  });
}
