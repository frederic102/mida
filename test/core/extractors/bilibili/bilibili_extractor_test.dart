import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/bilibili/bilibili_buvid_client.dart';
import 'package:mida/core/extractors/bilibili/bilibili_extractor.dart';
import 'package:mida/core/extractors/bilibili/bilibili_wbi_key_client.dart';
import 'package:mida/core/extractors/media_models.dart';

class _FixedResponseServer {
  final HttpServer server;
  int statusCode = 200;
  String body = '';

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
  late _FixedResponseServer pageServer;
  late _FixedResponseServer playurlServer;
  late _FixedResponseServer buvidServer;
  late _FixedResponseServer wbiServer;

  setUp(() async {
    pageServer = await _FixedResponseServer.start();
    playurlServer = await _FixedResponseServer.start();
    buvidServer = await _FixedResponseServer.start();
    wbiServer = await _FixedResponseServer.start();

    buvidServer.body = jsonEncode({
      'code': 0,
      'data': {'b_3': 'fake-buvid3', 'b_4': 'fake-buvid4'},
    });
    wbiServer.body = jsonEncode({
      'code': 0,
      'data': {
        'wbi_img': {
          'img_url': 'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
          'sub_url': 'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
        },
      },
    });
  });
  tearDown(() async {
    await pageServer.close();
    await playurlServer.close();
    await buvidServer.close();
    await wbiServer.close();
  });

  BilibiliExtractor buildExtractor() => BilibiliExtractor(
        buvidClient: BilibiliBuvidClient(requestUrlBuilder: (url) => buvidServer.baseUri.replace(path: '/spi')),
        wbiKeyClient: BilibiliWbiKeyClient(requestUrlBuilder: (url) => wbiServer.baseUri.replace(path: '/nav')),
        pageRequestUrlBuilder: (url) => pageServer.baseUri.replace(path: url.path),
        playurlRequestUrlBuilder: (url) => playurlServer.baseUri.replace(path: url.path, query: url.query),
      );

  group('BilibiliExtractor.canHandle', () {
    test('accepts /video/BV... URLs', () {
      expect(
        buildExtractor().canHandle(Uri.parse('https://www.bilibili.com/video/BV1GJ411x7h7')),
        isTrue,
      );
    });

    test('rejects non-BV paths and unrelated hosts', () {
      final extractor = buildExtractor();
      expect(extractor.canHandle(Uri.parse('https://www.bilibili.com/anime/1')), isFalse);
      expect(extractor.canHandle(Uri.parse('https://evil.example/video/BV1')), isFalse);
    });
  });

  group('BilibiliExtractor.extract against local fake buvid/wbi/page/playurl servers', () {
    test('bootstraps buvid + wbi keys, signs playurl, and resolves a MediaInfo', () async {
      pageServer.body = await File('test/fixtures/bilibili_initial_state.html').readAsString();
      playurlServer.body = await File('test/fixtures/bilibili_playurl.json').readAsString();

      final info = await buildExtractor().extract(Uri.parse('https://www.bilibili.com/video/BV1GJ411x7h7'));
      expect(info.id, 'BV1GJ411x7h7');
      expect(info.title, 'Example Video Title');
      expect(info.author, 'ExampleUploader');
      expect(info.formats, hasLength(3));
      expect(info.requestHeaders['Referer'], contains('BV1GJ411x7h7'));
    });

    test('maps HTTP 412 on the page to CHALLENGE_FAILED', () async {
      pageServer.statusCode = 412;
      await expectLater(
        buildExtractor().extract(Uri.parse('https://www.bilibili.com/video/BV1GJ411x7h7')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'CHALLENGE_FAILED')),
      );
    });

    test('propagates LOGIN_REQUIRED from the playurl API', () async {
      pageServer.body = await File('test/fixtures/bilibili_initial_state.html').readAsString();
      playurlServer.body = jsonEncode({'code': -403, 'message': 'login required'});

      await expectLater(
        buildExtractor().extract(Uri.parse('https://www.bilibili.com/video/BV1GJ411x7h7')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'LOGIN_REQUIRED')),
      );
    });

    test('still resolves when the buvid bootstrap fails (best-effort, not required)', () async {
      buvidServer.statusCode = 500;
      pageServer.body = await File('test/fixtures/bilibili_initial_state.html').readAsString();
      playurlServer.body = await File('test/fixtures/bilibili_playurl.json').readAsString();

      final info = await buildExtractor().extract(Uri.parse('https://www.bilibili.com/video/BV1GJ411x7h7'));
      expect(info.formats, isNotEmpty);
    });
  });
}
