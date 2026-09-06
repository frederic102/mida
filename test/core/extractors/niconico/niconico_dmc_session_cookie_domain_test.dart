import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/niconico/niconico_dmc_session_client.dart';

/// Phase 6 round 3 (S-R3-5, Codex #8): the `Domain`-attribute vetting in
/// [NiconicoDmcSessionClient] - the widened public/private suffix set and
/// the opt-in [NiconicoDmcSessionClient.requireThreeLabelDomains] bar.
/// Split out of `niconico_dmc_session_client_test.dart` only to keep both
/// files under the project's 400-line cap.
class _FixedResponseServer {
  final HttpServer server;
  String body = '{}';
  List<String> setCookieHeaders = const [];

  _FixedResponseServer(this.server);

  static Future<_FixedResponseServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _FixedResponseServer(server);
    server.listen(instance._handle);
    return instance;
  }

  Future<void> _handle(HttpRequest request) async {
    await utf8.decoder.bind(request).join();
    for (final header in setCookieHeaders) {
      request.response.headers.add(HttpHeaders.setCookieHeader, header);
    }
    request.response.write(body);
    await request.response.close();
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  late _FixedResponseServer server;

  setUp(() async => server = await _FixedResponseServer.start());
  tearDown(() => server.close());

  test('a Set-Cookie Domain that is a widened public suffix (co.uk) is rejected (S-R3-5)', () async {
    server.body = jsonEncode({
      'data': {
        'session': {'content_uri': 'https://dmc.nico/example/master.m3u8'},
      },
    });
    server.setCookieHeaders = ['sid=abc123; Domain=co.uk; Path=/'];

    final client = HttpClient()
      ..connectionFactory =
          (uri, proxyHost, proxyPort) => Socket.startConnect(InternetAddress.loopbackIPv4, server.server.port);
    final niconicoClient = NiconicoDmcSessionClient(
      httpClientFactory: () => client,
      requestUrlBuilder: (url) => Uri(scheme: 'http', host: 'api.dmc.co.uk', path: '/api/sessions'),
    );

    final result = await niconicoClient.startSession({
      'contentId': 'c1',
      'videos': ['v1'],
      'token': 't1',
      'signature': 's1',
    });

    expect(result.cookiesByDomain, isEmpty);
  });

  test('a Set-Cookie Domain that is a private suffix (github.io) is rejected (S-R3-5)', () async {
    server.body = jsonEncode({
      'data': {
        'session': {'content_uri': 'https://dmc.nico/example/master.m3u8'},
      },
    });
    server.setCookieHeaders = ['sid=abc123; Domain=github.io; Path=/'];

    final client = HttpClient()
      ..connectionFactory =
          (uri, proxyHost, proxyPort) => Socket.startConnect(InternetAddress.loopbackIPv4, server.server.port);
    final niconicoClient = NiconicoDmcSessionClient(
      httpClientFactory: () => client,
      requestUrlBuilder: (url) => Uri(scheme: 'http', host: 'someone.github.io', path: '/api/sessions'),
    );

    final result = await niconicoClient.startSession({
      'contentId': 'c1',
      'videos': ['v1'],
      'token': 't1',
      'signature': 's1',
    });

    expect(result.cookiesByDomain, isEmpty);
  });

  test('requireThreeLabelDomains rejects an otherwise-valid two-label Domain, and is off by default (S-R3-5)',
      () async {
    server.body = jsonEncode({
      'data': {
        'session': {'content_uri': 'https://dmc.nico/example/master.m3u8'},
      },
    });
    server.setCookieHeaders = ['sid=abc123; Domain=nicovideo.jp; Path=/'];

    Future<Map<String, List<CookieEntry>>> run({required bool strict}) async {
      final client = HttpClient()
        ..connectionFactory =
            (uri, proxyHost, proxyPort) => Socket.startConnect(InternetAddress.loopbackIPv4, server.server.port);
      final niconicoClient = NiconicoDmcSessionClient(
        httpClientFactory: () => client,
        requestUrlBuilder: (url) => Uri(scheme: 'http', host: 'api.dmc.nicovideo.jp', path: '/api/sessions'),
        requireThreeLabelDomains: strict,
      );
      final result = await niconicoClient.startSession({
        'contentId': 'c1',
        'videos': ['v1'],
        'token': 't1',
        'signature': 's1',
      });
      return result.cookiesByDomain;
    }

    expect((await run(strict: false)).keys, ['.nicovideo.jp']);
    expect(await run(strict: true), isEmpty);
  });
}
