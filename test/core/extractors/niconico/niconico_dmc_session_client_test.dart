import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/net/cookie_scope.dart';
import 'package:mida/core/extractors/niconico/niconico_dmc_session_client.dart';

class _FixedResponseServer {
  final HttpServer server;
  int statusCode = 200;
  String body = '{}';
  String? lastRequestBody;

  /// When set, added as a raw `Set-Cookie` header on the response - lets
  /// tests exercise [NiconicoDmcSessionClient]'s cookie-capture path (see
  /// its class doc, N2) without a real domand session.
  List<String> setCookieHeaders = const [];

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

  NiconicoDmcSessionClient buildClient() => NiconicoDmcSessionClient(
        requestUrlBuilder: (url) => server.baseUri.replace(path: '/api/sessions', query: url.query),
      );

  test('builds a session request from the parsed session_api fields and reads content_uri', () async {
    server.body = jsonEncode({
      'data': {
        'session': {'content_uri': 'https://dmc.nico/example/master.m3u8', 'id': 'session-1'},
      },
    });

    final result = await buildClient().startSession({
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

    expect(result.contentUri, 'https://dmc.nico/example/master.m3u8');
    expect(result.cookiesByDomain, isEmpty);
    final sentBody = jsonDecode(server.lastRequestBody!) as Map<String, dynamic>;
    final session = sentBody['session'] as Map<String, dynamic>;
    expect(session['content_id'], 'c1');
    expect(session['session_operation_auth']['session_operation_auth_by_signature']['token'], 't1');
  });

  test(
    'guard can fail: a Set-Cookie Domain that does not domain-match the response host is dropped entirely, '
    'never filed under that unrelated domain (S-R6)',
    () async {
      server.body = jsonEncode({
        'data': {
          'session': {'content_uri': 'https://dmc.nico/example/master.m3u8'},
        },
      });
      // The response actually came from 127.0.0.1 (this test server), but
      // claims a Domain for a completely different, unrelated host - the
      // exact shape a compromised/misbehaving endpoint could use to scope
      // a cookie onto some other CDN this client will later trust.
      server.setCookieHeaders = ['domand_bid=abc123; Domain=delivery.domand.nicovideo.jp; Path=/; Secure'];

      final result = await buildClient().startSession({
        'contentId': 'c1',
        'videos': ['v1'],
        'token': 't1',
        'signature': 's1',
      });

      // Guard-can-fail (manually verified, see report): before S-R6, this
      // cookie was filed straight under 'delivery.domand.nicovideo.jp'
      // regardless of who actually sent it - reverting `_cookiesByDomain`
      // to `cookie.domain ?? fallbackHost` (no domain-match check) makes
      // this map non-empty again.
      expect(result.cookiesByDomain, isEmpty);
    },
  );

  test('a Set-Cookie Domain equal to the exact response host is accepted (S-R6)', () async {
    server.body = jsonEncode({
      'data': {
        'session': {'content_uri': 'https://dmc.nico/example/master.m3u8'},
      },
    });
    server.setCookieHeaders = ['sid=abc123; Domain=127.0.0.1; Path=/'];

    final result = await buildClient().startSession({
      'contentId': 'c1',
      'videos': ['v1'],
      'token': 't1',
      'signature': 's1',
    });

    // S-R3-1: it carried an explicit `Domain`, so it is a domain cookie
    // and must be filed under the leading-dot key, never the bare host.
    expect(result.cookiesByDomain.keys, ['.127.0.0.1']);
    final cookies = result.cookiesByDomain['.127.0.0.1'];
    expect(cookies, isNotNull);
    expect(cookies!.single.name, 'sid');
    expect(cookies.single.domain, '.127.0.0.1');
  });

  test(
    'a Set-Cookie Domain that is a real, multi-label parent of the response host is accepted (S-R6)',
    () async {
      server.body = jsonEncode({
        'data': {
          'session': {'content_uri': 'https://dmc.nico/example/master.m3u8'},
        },
      });
      server.setCookieHeaders = ['domand_bid=abc123; Domain=nicovideo.jp; Path=/; Secure'];

      // The actual connection still goes to the local fixture server -
      // `connectionFactory` pins every socket regardless of the URL's own
      // host - but the request URL itself carries a realistic multi-label
      // hostname so the domain-match check has a real parent/child
      // relationship to evaluate, not just an IP-literal equality.
      final client = HttpClient()
        ..connectionFactory =
            (uri, proxyHost, proxyPort) => Socket.startConnect(InternetAddress.loopbackIPv4, server.server.port);
      final niconicoClient = NiconicoDmcSessionClient(
        httpClientFactory: () => client,
        requestUrlBuilder: (url) => Uri(scheme: 'http', host: 'api.dmc.nicovideo.jp', path: '/api/sessions'),
      );

      final result = await niconicoClient.startSession({
        'contentId': 'c1',
        'videos': ['v1'],
        'token': 't1',
        'signature': 's1',
      });

      final cookies = result.cookiesByDomain['.nicovideo.jp'];
      expect(cookies, isNotNull);
      expect(cookies!.single.name, 'domand_bid');
      expect(result.cookiesByDomain.containsKey('nicovideo.jp'), isFalse);
    },
  );

  test('a Set-Cookie Domain that is a bare single-label TLD is rejected even though it dot-suffix-matches (S-R6)',
      () async {
    server.body = jsonEncode({
      'data': {
        'session': {'content_uri': 'https://dmc.nico/example/master.m3u8'},
      },
    });
    server.setCookieHeaders = ['sid=abc123; Domain=jp; Path=/'];

    final client = HttpClient()
      ..connectionFactory =
          (uri, proxyHost, proxyPort) => Socket.startConnect(InternetAddress.loopbackIPv4, server.server.port);
    final niconicoClient = NiconicoDmcSessionClient(
      httpClientFactory: () => client,
      requestUrlBuilder: (url) => Uri(scheme: 'http', host: 'api.dmc.nicovideo.jp', path: '/api/sessions'),
    );

    final result = await niconicoClient.startSession({
      'contentId': 'c1',
      'videos': ['v1'],
      'token': 't1',
      'signature': 's1',
    });

    expect(result.cookiesByDomain, isEmpty);
  });

  test('a Set-Cookie Domain that is a known multi-label public suffix (co.jp) is rejected (S-R6)', () async {
    server.body = jsonEncode({
      'data': {
        'session': {'content_uri': 'https://dmc.nico/example/master.m3u8'},
      },
    });
    server.setCookieHeaders = ['sid=abc123; Domain=co.jp; Path=/'];

    final client = HttpClient()
      ..connectionFactory =
          (uri, proxyHost, proxyPort) => Socket.startConnect(InternetAddress.loopbackIPv4, server.server.port);
    final niconicoClient = NiconicoDmcSessionClient(
      httpClientFactory: () => client,
      requestUrlBuilder: (url) => Uri(scheme: 'http', host: 'api.dmc.co.jp', path: '/api/sessions'),
    );

    final result = await niconicoClient.startSession({
      'contentId': 'c1',
      'videos': ['v1'],
      'token': 't1',
      'signature': 's1',
    });

    expect(result.cookiesByDomain, isEmpty);
  });

  test('falls back to the request host when a Set-Cookie omits Domain (N2)', () async {
    server.body = jsonEncode({
      'data': {
        'session': {'content_uri': 'https://dmc.nico/example/master.m3u8'},
      },
    });
    server.setCookieHeaders = ['sid=xyz; Path=/'];

    final result = await buildClient().startSession({
      'contentId': 'c1',
      'videos': ['v1'],
      'token': 't1',
      'signature': 's1',
    });

    // No `Domain` attribute at all: host-only, so the key stays bare
    // (S-R3-1 - the leading dot is reserved for real domain cookies).
    expect(result.cookiesByDomain.keys, ['127.0.0.1']);
    expect(result.cookiesByDomain['127.0.0.1']!.single.name, 'sid');
  });

  test(
    'a Domain cookie is filed under a leading-dot key, so CookieScope sends it to a sibling host (S-R3-1)',
    () async {
      server.body = jsonEncode({
        'data': {
          'session': {'content_uri': 'https://dmc.example/example/master.m3u8'},
        },
      });
      // The realistic shape of the bug this fixes: the session-create API
      // host sets a session cookie for the whole delivery domain, and the
      // media playlist that actually needs it lives on a *sibling* CDN
      // host under that same domain.
      server.setCookieHeaders = ['domand_bid=abc123; Domain=dmc.example; Path=/'];

      final client = HttpClient()
        ..connectionFactory =
            (uri, proxyHost, proxyPort) => Socket.startConnect(InternetAddress.loopbackIPv4, server.server.port);
      final niconicoClient = NiconicoDmcSessionClient(
        httpClientFactory: () => client,
        requestUrlBuilder: (url) => Uri(scheme: 'http', host: 'api.dmc.example', path: '/api/sessions'),
      );

      final result = await niconicoClient.startSession({
        'contentId': 'c1',
        'videos': ['v1'],
        'token': 't1',
        'signature': 's1',
      });

      // Guard-can-fail (verified in the round 3 report): dropping the
      // leading dot from the key (what round 2 filed) makes
      // `CookieScope.headerFor` treat this as host-only, and this
      // sibling-host expectation goes red with an empty header. Asserted
      // before the key shape itself so the flip's first failure is the
      // behaviour, not the representation.
      expect(
        CookieScope.headerFor(Uri.parse('http://cdn.dmc.example/playlist.m3u8'), result.cookiesByDomain),
        'domand_bid=abc123',
      );
      expect(result.cookiesByDomain.keys, ['.dmc.example']);
      // Still reaches the host that set it, and still does not leak to an
      // unrelated domain.
      expect(
        CookieScope.headerFor(Uri.parse('http://api.dmc.example/api/sessions'), result.cookiesByDomain),
        'domand_bid=abc123',
      );
      expect(
        CookieScope.headerFor(Uri.parse('http://cdn.other.example/playlist.m3u8'), result.cookiesByDomain),
        '',
      );
    },
  );

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
