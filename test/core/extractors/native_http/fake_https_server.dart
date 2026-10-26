import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mida/core/extractors/native_http/native_http_client.dart';

import 'fake_tls_identity.dart';

/// One canned answer the fake server gives for an exact `host + path`.
class FakeRoute {
  final int status;
  final String body;
  final String? location;
  final Map<String, String> headers;

  /// Send [body] and then never finish the response (deadline tests).
  final bool stall;

  /// When > 0, stream this many bytes (64 KiB chunks, one per 5 ms)
  /// after [body]; the server's [FakeHttpsServer.bytesSent] shows how many
  /// the client actually let through before hanging up.
  final int streamBytes;

  const FakeRoute({
    this.status = 200,
    this.body = '',
    this.location,
    this.headers = const {},
    this.stall = false,
    this.streamBytes = 0,
  });
}

/// What the fake server saw for one request.
class RecordedRequest {
  final String method;
  final String host;
  final Uri uri;
  final String body;
  final HttpHeaders headers;

  const RecordedRequest({
    required this.method,
    required this.host,
    required this.uri,
    required this.body,
    required this.headers,
  });
}

/// Loopback **TLS** `HttpServer` standing in for every platform host. The
/// client under test keeps its real-looking `https://www.pinterest.com/...`
/// URLs: `HttpClient.connectionFactory` sends every socket to this server
/// and the (self-signed) certificate is accepted, so the HTTPS-only rule,
/// the redirect handling and `HostPolicy.guardedRequest` all run unmodified.
/// DNS is never queried (the clients get a fake public address). Nothing
/// leaves the machine.
class FakeHttpsServer {
  final HttpServer _server;
  final Map<String, FakeRoute> routes = {};
  final List<RecordedRequest> requests = [];

  /// Streamed body bytes the server got through per `host + path`.
  final Map<String, int> bytesSent = {};
  final Completer<void> _closing = Completer<void>();

  FakeHttpsServer._(this._server);

  static Future<FakeHttpsServer> start() async {
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(fakeTlsCertificatePem))
      ..usePrivateKeyBytes(utf8.encode(fakeTlsPrivateKeyPem));
    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    final fake = FakeHttpsServer._(server);
    server.listen(fake._handle);
    return fake;
  }

  void route(String hostAndPath, FakeRoute answer) => routes[hostAndPath] = answer;

  /// Hosts requested, in order.
  List<String> get hosts => requests.map((r) => r.host).toList();

  Future<void> _handle(HttpRequest request) async {
    final host = request.headers.host ?? '';
    final body = await utf8.decoder.bind(request).join();
    requests.add(RecordedRequest(
      method: request.method,
      host: host,
      uri: request.uri,
      body: body,
      headers: request.headers,
    ));
    final answer = routes['$host${request.uri.path}'] ?? const FakeRoute(status: 404);
    try {
      request.response.statusCode = answer.status;
      if (answer.location != null) request.response.headers.set('location', answer.location!);
      answer.headers.forEach(request.response.headers.set);
      request.response.write(answer.body);
      if (answer.streamBytes > 0) {
        final chunk = List<int>.filled(64 * 1024, 0x61);
        var sent = 0;
        final key = '$host${request.uri.path}';
        while (sent < answer.streamBytes) {
          request.response.add(chunk);
          await request.response.flush();
          sent += chunk.length;
          bytesSent[key] = sent;
          // Paced so a client that keeps reading takes seconds, and one that
          // hangs up is noticed by the next write.
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }
      if (answer.stall) {
        await request.response.flush();
        await _closing.future;
      }
      await request.response.close();
    } on IOException {
      // The client hung up early (the body-cap and deadline tests do this on purpose).
    }
  }

  HttpClient client() {
    final client = HttpClient()
      ..badCertificateCallback = ((cert, host, port) => true)
      // A custom connectionFactory must hand back the TLS socket itself.
      ..connectionFactory = ((uri, proxyHost, proxyPort) =>
          SecureSocket.startConnect(InternetAddress.loopbackIPv4, _server.port, onBadCertificate: (_) => true));
    return client;
  }

  static Future<List<InternetAddress>> publicAddress(String host) async => [InternetAddress('151.101.0.84')];

  /// A [NativeHttpClient] wired to this server.
  ///
  /// The default deadline is generous on purpose: it must never fire on a
  /// loaded CI/dev machine (TLS handshakes included). Deadline tests pass
  /// their own short [timeout].
  NativeHttpClient httpClient(String service, {Duration timeout = const Duration(seconds: 25)}) => NativeHttpClient(
        service: service,
        timeout: timeout,
        httpClientFactory: client,
        resolveHost: publicAddress,
      );

  Future<void> close() async {
    if (!_closing.isCompleted) _closing.complete();
    await _server.close(force: true);
  }
}

String fixture(String platform, String name) => File('test/fixtures/$platform/$name').readAsStringSync();
