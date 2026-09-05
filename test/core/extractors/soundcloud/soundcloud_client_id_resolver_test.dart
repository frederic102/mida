import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/soundcloud/soundcloud_client_id_resolver.dart';

class _FakeServer {
  final HttpServer server;
  String pageHtml = '';
  Map<String, String> scriptBodies = {};
  int pageRequestCount = 0;

  _FakeServer(this.server);

  static Future<_FakeServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _FakeServer(server);
    server.listen(instance._handle);
    return instance;
  }

  Uri get baseUri => Uri(scheme: 'http', host: '127.0.0.1', port: server.port);

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path == '/track') {
      pageRequestCount++;
      request.response.write(pageHtml);
      await request.response.close();
      return;
    }
    final body = scriptBodies[request.uri.path];
    request.response.statusCode = body == null ? 404 : 200;
    request.response.write(body ?? '');
    await request.response.close();
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  late _FakeServer server;

  setUp(() async {
    server = await _FakeServer.start();
    SoundCloudClientIdResolver.reset();
  });
  tearDown(() => server.close());

  SoundCloudClientIdResolver buildResolver() => SoundCloudClientIdResolver(
        pageRequestUrlBuilder: (url) => server.baseUri.replace(path: '/track'),
        scriptRequestUrlBuilder: (url) => server.baseUri.replace(path: Uri.parse(url.path).path),
      );

  test('scans the page\'s script bundles and finds a client_id literal', () async {
    server.pageHtml = '<script crossorigin src="${server.baseUri.replace(path: '/0.js')}"></script>'
        '<script crossorigin src="${server.baseUri.replace(path: '/1.js')}"></script>';
    server.scriptBodies = {
      '/0.js': 'var e={clientId:n(4)};',
      '/1.js': 'a.a.get=function(){return{client_id:"Pb72ranhoyt6gw7hM7TkzUItXlMWSNSo"}}',
    };

    final clientId = await buildResolver().get(Uri.parse('https://soundcloud.com/artist/track'));
    expect(clientId, 'Pb72ranhoyt6gw7hM7TkzUItXlMWSNSo');
  });

  test('caches the client_id across calls (only fetches the page once)', () async {
    server.pageHtml = '<script crossorigin src="${server.baseUri.replace(path: '/0.js')}"></script>';
    server.scriptBodies = {'/0.js': 'x={client_id:"AbCdEf0123456789AbCdEf0123456789"}'};

    final resolver = buildResolver();
    final first = await resolver.get(Uri.parse('https://soundcloud.com/artist/track'));
    final second = await resolver.get(Uri.parse('https://soundcloud.com/artist/other-track'));

    expect(first, 'AbCdEf0123456789AbCdEf0123456789');
    expect(second, first);
    expect(server.pageRequestCount, 1);
  });

  test('throws PARSE_ERROR when no script contains a client_id literal', () async {
    server.pageHtml = '<script crossorigin src="${server.baseUri.replace(path: '/0.js')}"></script>';
    server.scriptBodies = {'/0.js': 'no secrets here'};

    await expectLater(
      buildResolver().get(Uri.parse('https://soundcloud.com/artist/track')),
      throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR')),
    );
  });
}
