import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/odysee/odysee_extractor.dart';

class _FixedResponseServer {
  final HttpServer server;
  int statusCode = 200;
  String body = '{}';
  String? lastRequestBody;

  _FixedResponseServer(this.server);

  static Future<_FixedResponseServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _FixedResponseServer(server);
    server.listen(instance._handle);
    return instance;
  }

  Uri get baseUri => Uri(scheme: 'http', host: '127.0.0.1', port: server.port);

  Future<void> _handle(HttpRequest request) async {
    lastRequestBody = await utf8.decoder.bind(request).join();
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

  OdyseeExtractor buildExtractor() =>
      OdyseeExtractor(resolveRequestUrlBuilder: (url) => server.baseUri.replace(path: '/proxy', query: url.query));

  group('OdyseeExtractor.canHandle', () {
    test('accepts a channel+content URL and a channel-less content URL', () {
      final extractor = buildExtractor();
      expect(extractor.canHandle(Uri.parse('https://odysee.com/@lbry:3f/odysee:7')), isTrue);
      expect(extractor.canHandle(Uri.parse('https://odysee.com/some-video:abc123')), isTrue);
      expect(extractor.canHandle(Uri.parse('https://odysee.com/@lbry:3f/odysee')), isTrue);
    });

    test('rejects a channel page with no content path and unrelated hosts', () {
      final extractor = buildExtractor();
      expect(extractor.canHandle(Uri.parse('https://odysee.com/@lbry:3f')), isFalse);
      expect(extractor.canHandle(Uri.parse('https://evil.example/@lbry:3f/odysee:7')), isFalse);
    });
  });

  group('OdyseeExtractor.extract against a local fake resolve server', () {
    test('builds the lbry:// url, resolves the claim, and constructs the tc/master.m3u8 stream url', () async {
      server.body = await File('test/fixtures/odysee_resolve.json').readAsString();

      final info = await buildExtractor().extract(Uri.parse('https://odysee.com/@lbry:3f/odysee:7'));
      expect(info.id, '7a416c44a6888d94fe045241bbac055c726332aa');
      expect(info.title, 'Introducing Odysee: A Short Video');
      expect(info.formats.single.url, contains('/api/v4/streams/tc/odysee/'));
      expect(info.formats.single.url, endsWith('/master.m3u8'));
      expect(info.formats.single.container, 'm3u8');
      expect(info.requestHeaders['Referer'], 'https://odysee.com/');
      expect(info.requestHeaders['Origin'], 'https://odysee.com');

      final sentBody = jsonDecode(server.lastRequestBody!) as Map<String, dynamic>;
      expect(sentBody['method'], 'resolve');
      expect(sentBody['params']['urls'], ['lbry://@lbry#3f/odysee#7']);
    });

    test('propagates NOT_FOUND from the resolve parser', () async {
      server.body = jsonEncode({'result': {}});
      await expectLater(
        buildExtractor().extract(Uri.parse('https://odysee.com/@lbry:3f/gone:1')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NOT_FOUND')),
      );
    });

    test('maps HTTP 429 to RATE_LIMITED and other non-200 to NETWORK', () async {
      server.statusCode = 429;
      await expectLater(
        buildExtractor().extract(Uri.parse('https://odysee.com/@lbry:3f/odysee:7')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'RATE_LIMITED')),
      );

      server.statusCode = 500;
      await expectLater(
        buildExtractor().extract(Uri.parse('https://odysee.com/@lbry:3f/odysee:7')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NETWORK')),
      );
    });
  });
}
