import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/embeds/embed_http.dart';
import 'package:mida/core/extractors/generic/generic_http.dart';
import 'package:mida/core/extractors/media_models.dart';

/// Local loopback server only (hermetic): records what arrived and
/// answers per path.
void main() {
  late HttpServer server;
  final received = <String, Map<String, String>>{};
  final bodies = <String, String>{};

  setUp(() async {
    received.clear();
    bodies.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final headers = <String, String>{};
      request.headers.forEach((name, values) => headers[name] = values.join(','));
      received[request.uri.path] = headers;
      bodies[request.uri.path] = await utf8.decoder.bind(request).join();
      switch (request.uri.path) {
        case '/big':
          request.response.write('x' * 50000);
        case '/redirect':
          request.response.statusCode = 302;
          request.response.headers.set('Location', 'http://127.0.0.1:${server.port}/target');
        default:
          request.response.write('{"ok":true}');
      }
      await request.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  Uri local(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  test('GET: desktop UA, caller headers, no cookie, bounded body', () async {
    const http = GuardedEmbedHttp(httpClientFactory: HttpClient.new, allowPrivateHosts: true, maxBodyBytes: 1000);
    final response = await http.get(local('/big'), headers: {'Accept': 'application/json;pk=abc'});
    expect(response.statusCode, 200);
    expect(response.body.length, 1000);
    final headers = received['/big']!;
    expect(headers['user-agent'], genericDesktopUserAgent);
    expect(headers['accept'], 'application/json;pk=abc');
    expect(headers.containsKey('cookie'), isFalse);
  });

  test('POST: JSON body and content type; a redirect is returned, never followed', () async {
    const http = GuardedEmbedHttp(httpClientFactory: HttpClient.new, allowPrivateHosts: true);
    final ok = await http.postJson(local('/api'), {'1': {'service': 'session'}});
    expect(ok.isOk, isTrue);
    expect(jsonDecode(bodies['/api']!), {'1': {'service': 'session'}});
    expect(received['/api']!['content-type'], startsWith('application/json'));

    final redirected = await http.postJson(local('/redirect'), const {});
    expect(redirected.statusCode, 302);
    expect(redirected.isOk, isFalse);
    expect(received.containsKey('/target'), isFalse);
  });

  test('GET redirect into a private host is refused even with the hop-0 test exemption', () async {
    const http = GuardedEmbedHttp(httpClientFactory: HttpClient.new, allowPrivateHosts: true);
    await expectLater(
      http.get(local('/redirect')),
      throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL')),
    );
    expect(received.containsKey('/target'), isFalse);
  });

  test('production mode refuses loopback for GET and POST before connecting', () async {
    const http = GuardedEmbedHttp(httpClientFactory: HttpClient.new);
    final unsupported = throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL'));
    await expectLater(http.get(local('/api')), unsupported);
    await expectLater(http.postJson(local('/api'), const {}), unsupported);
    expect(received, isEmpty);
  });

  test('DNS rebinding: a public-looking POST/GET host that resolves to 10.0.0.1 is refused before connecting',
      () async {
    final lookups = <String>[];
    final dialled = <Uri>[];
    Future<List<InternetAddress>> privateAnswer(String host) async {
      lookups.add(host);
      return [InternetAddress('10.0.0.1')];
    }

    // Records any connection attempt and refuses it: nothing is ever dialled.
    HttpClient recordingClient() => HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = (uri, proxyHost, proxyPort) {
        dialled.add(uri);
        return Future.error(const SocketException('offline test'));
      };

    final http = GuardedEmbedHttp(httpClientFactory: recordingClient, resolveHost: privateAnswer);
    final api = Uri.parse('https://cdnapisec.kaltura.com/api_v3/service/multirequest');
    final refused = throwsA(isA<MediaExtractionException>()
        .having((e) => e.status, 'status', 'UNSUPPORTED_URL')
        .having((e) => e.reason, 'reason', contains('10.0.0.1')));

    await expectLater(http.postJson(api, const {'1': {'service': 'session'}}), refused);
    await expectLater(http.get(Uri.parse('https://cdnapisec.kaltura.com/p/1/x.json')), refused);
    expect(lookups, ['cdnapisec.kaltura.com', 'cdnapisec.kaltura.com'], reason: 'the injected resolver answered');
    expect(dialled, isEmpty, reason: 'refused before any connection');
  });
}
