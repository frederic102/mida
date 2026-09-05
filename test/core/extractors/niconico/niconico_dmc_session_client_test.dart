import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/niconico/niconico_dmc_session_client.dart';

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

  NiconicoDmcSessionClient buildClient() => NiconicoDmcSessionClient(
        requestUrlBuilder: (url) => server.baseUri.replace(path: '/api/sessions', query: url.query),
      );

  test('builds a session request from the parsed session_api fields and reads content_uri', () async {
    server.body = jsonEncode({
      'data': {
        'session': {'content_uri': 'https://dmc.nico/example/master.m3u8', 'id': 'session-1'},
      },
    });

    final contentUri = await buildClient().startSession({
      'recipeId': 'r1',
      'contentId': 'c1',
      'videos': ['archive_h264_1080p'],
      'audios': ['archive_aac_192kbps'],
      'token': 't1',
      'signature': 's1',
      'serviceUserId': 'u1',
      'playerId': 'p1',
      'priority': 0,
    });

    expect(contentUri, 'https://dmc.nico/example/master.m3u8');
    final sentBody = jsonDecode(server.lastRequestBody!) as Map<String, dynamic>;
    final session = sentBody['session'] as Map<String, dynamic>;
    expect(session['content_id'], 'c1');
    expect(session['session_operation_auth']['session_operation_auth_by_signature']['token'], 't1');
  });

  test('throws UNSUPPORTED_MEDIA when required session_api fields are missing', () {
    expect(
      () => buildClient().startSession({'videos': const <String>[]}),
      throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_MEDIA')),
    );
  });

  test('maps a non-200 response to NETWORK', () async {
    server.statusCode = 500;
    await expectLater(
      buildClient().startSession({
        'contentId': 'c1',
        'videos': ['v1'],
        'token': 't1',
        'signature': 's1',
      }),
      throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NETWORK')),
    );
  });
}
