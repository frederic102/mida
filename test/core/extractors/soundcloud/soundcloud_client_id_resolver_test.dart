import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/soundcloud/soundcloud_client_id_resolver.dart';

/// Serves a fixed script body at whatever path is requested, standing in
/// for `a-v2.sndcdn.com/assets/*.js`.
class _FixedScriptServer {
  final HttpServer server;
  final Map<String, String> bodiesByPath;

  _FixedScriptServer(this.server, this.bodiesByPath);

  static Future<_FixedScriptServer> start(Map<String, String> bodiesByPath) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _FixedScriptServer(server, bodiesByPath);
    server.listen(instance._handle);
    return instance;
  }

  Uri get baseUri => Uri(scheme: 'http', host: '127.0.0.1', port: server.port);

  Future<void> _handle(HttpRequest request) async {
    final body = bodiesByPath[request.uri.path];
    request.response.statusCode = body == null ? 404 : 200;
    request.response.write(body ?? '');
    await request.response.close();
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  test('finds client_id in the second of several script bundles', () async {
    final server = await _FixedScriptServer.start({
      '/0.js': 'var e={clientId:n(4)};',
      '/1.js': 'a.a.get=function(){return{client_id:"AbCdEf0123456789AbCdEf0123456789"}}',
    });
    addTearDown(server.close);

    final html = '<script crossorigin src="${server.baseUri.replace(path: '/0.js')}">'
        '<script crossorigin src="${server.baseUri.replace(path: '/1.js')}">';

    final clientId = await SoundCloudClientIdResolver().resolve(html);
    expect(clientId, 'AbCdEf0123456789AbCdEf0123456789');
  });

  test('throws PARSE_ERROR when no script contains a client_id literal', () async {
    final server = await _FixedScriptServer.start({'/0.js': 'no secrets here'});
    addTearDown(server.close);

    final html = '<script crossorigin src="${server.baseUri.replace(path: '/0.js')}">';
    await expectLater(
      SoundCloudClientIdResolver().resolve(html),
      throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR')),
    );
  });
}
