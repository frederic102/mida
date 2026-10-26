import 'dart:io';

import 'package:mida/core/extractors/facebook/facebook_extractor.dart';
import 'package:mida/core/extractors/facebook/facebook_page_fetcher.dart';

/// One canned answer the fake server gives for an exact `host + path`.
class FakeRoute {
  final int status;
  final String body;
  final String? location;

  const FakeRoute({this.status = 200, this.body = '', this.location});
}

/// Two loopback `HttpServer`s standing in for the internet: the
/// extractor's `HttpClient` gets a `connectionFactory` that sends every
/// `https://` request to one and every `http://` request to the other, as
/// plain HTTP over a local socket (no TLS, no proxy). Requests keep their
/// real-looking `https://www.facebook.com/...`/`https://fb.watch/...` URLs
/// (the `Host` header says which), every hop goes through
/// `HostPolicy.guardedRequest` unmodified (no `allowPrivateHosts`
/// exemption), and [requested] records the scheme each request really used,
/// so a test can prove no plain-HTTP request was ever made. DNS is never
/// queried: the fetcher's `resolveHost` is a fake that answers a public
/// address. Nothing leaves the machine.
class FakeFacebookServer {
  final HttpServer _https;
  final HttpServer _http;
  final Map<String, FakeRoute> routes = {};
  final List<Uri> requested = [];
  final List<HttpHeaders> requestHeaders = [];

  FakeFacebookServer._(this._https, this._http);

  static Future<FakeFacebookServer> start() async {
    final https = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeFacebookServer._(https, http);
    https.listen((request) => fake._handle('https', request));
    http.listen((request) => fake._handle('http', request));
    return fake;
  }

  void route(String hostAndPath, FakeRoute answer) => routes[hostAndPath] = answer;

  Future<void> _handle(String scheme, HttpRequest request) async {
    final host = request.headers.host ?? '';
    requested.add(Uri(
      scheme: scheme,
      host: host,
      path: request.uri.path,
      query: request.uri.hasQuery ? request.uri.query : null,
    ));
    requestHeaders.add(request.headers);
    final answer = routes['$host${request.uri.path}'] ?? const FakeRoute(status: 404);
    try {
      request.response.statusCode = answer.status;
      if (answer.location != null) request.response.headers.set('location', answer.location!);
      request.response.write(answer.body);
      await request.response.close();
    } on IOException {
      // The client hung up early (the body-cap test does this on purpose).
    }
  }

  HttpClient _client() => HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..connectionFactory = (uri, proxyHost, proxyPort) =>
        Socket.startConnect(InternetAddress.loopbackIPv4, uri.scheme == 'https' ? _https.port : _http.port);

  static Future<List<InternetAddress>> publicAddress(String host) async => [InternetAddress('157.240.1.35')];

  FacebookPageFetcher fetcher() => FacebookPageFetcher(httpClientFactory: _client, resolveHost: publicAddress);

  FacebookExtractor extractor() => FacebookExtractor(fetcher: fetcher());

  Future<void> close() async {
    await _https.close(force: true);
    await _http.close(force: true);
  }
}

String fixture(String name) => File('test/fixtures/facebook/$name').readAsStringSync();
