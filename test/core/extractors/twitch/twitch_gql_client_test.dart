import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/twitch/twitch_gql_client.dart';

/// Local server standing in for `gql.twitch.tv`'s `/gql` endpoint.
class _FakeTwitchServer {
  final HttpServer server;
  int gqlStatusCode = 200;
  String gqlBody = '{"data":{}}';
  String? lastClientId;
  String? lastClientIntegrity;
  List<String?> requestedPaths = [];

  _FakeTwitchServer(this.server);

  static Future<_FakeTwitchServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _FakeTwitchServer(server);
    server.listen(instance._handle);
    return instance;
  }

  Uri get baseUri => Uri(scheme: 'http', host: '127.0.0.1', port: server.port);

  Future<void> _handle(HttpRequest request) async {
    requestedPaths.add(request.uri.path);
    lastClientId = request.headers.value('client-id');
    lastClientIntegrity = request.headers.value('client-integrity');
    request.response.statusCode = gqlStatusCode;
    request.response.write(gqlBody);
    await request.response.close();
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  late _FakeTwitchServer server;

  setUp(() async => server = await _FakeTwitchServer.start());
  tearDown(() => server.close());

  TwitchGqlClient buildClient() => TwitchGqlClient(
        endpointBuilder: (path) => server.baseUri.replace(path: path),
      );

  test('sends only the public Client-ID (no Client-Integrity, no /integrity call)', () async {
    // Guard-can-fail: policy check (docs/plan-phase5-coverage.md Lane D
    // review round 2) - this client must never mint/replay a
    // Client-Integrity token; re-adding that would make this test fail.
    server.gqlBody = jsonEncode({'data': {'video': null}});
    final data = await buildClient().query('query{video(id:"1"){id}}', const {});

    expect(data, {'video': null});
    expect(server.requestedPaths, ['/gql']);
    expect(server.lastClientId, TwitchGqlClient.publicClientId);
    expect(server.lastClientIntegrity, isNull);
  });

  test('maps HTTP 429 to RATE_LIMITED and other non-200 to NETWORK', () async {
    server.gqlStatusCode = 429;
    await expectLater(
      buildClient().query('query{}', const {}),
      throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'RATE_LIMITED')),
    );

    server.gqlStatusCode = 500;
    await expectLater(
      buildClient().query('query{}', const {}),
      throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NETWORK')),
    );
  });

  test('maps a non-JSON gql body to PARSE_ERROR', () async {
    server.gqlBody = 'not json';
    await expectLater(
      buildClient().query('query{}', const {}),
      throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR')),
    );
  });

  test('maps a body with no data field to PARSE_ERROR', () async {
    server.gqlBody = jsonEncode({'errors': [{'message': 'boom'}]});
    await expectLater(
      buildClient().query('query{}', const {}),
      throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR')),
    );
  });
}
