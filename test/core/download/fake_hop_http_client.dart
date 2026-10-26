import 'dart:async';
import 'dart:io';

/// One scripted answer: [status], optional [location], and [body] bytes
/// (served in 64 KiB chunks so a bounded reader can stop early).
class FakeHop {
  final int status;
  final String? location;
  final List<int> body;
  const FakeHop(this.status, {this.location, this.body = const []});
}

/// What one request carried: its URL and its headers (lower-case names).
class SentRequest {
  final Uri uri;
  final Map<String, String> headers;
  SentRequest(this.uri, this.headers);
}

/// In-memory `HttpClient` for redirect/credential tests: no sockets, no
/// DNS. [route] answers each request by URL; every request is recorded in
/// [sent] with the headers that were actually set on it.
class FakeHopHttpClient implements HttpClient {
  final FakeHop Function(Uri uri) route;
  final List<SentRequest> sent = [];
  int bodyBytesServed = 0;
  FakeHopHttpClient(this.route);

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _FakeRequest(this, url);

  @override
  Future<HttpClientRequest> headUrl(Uri url) async => _FakeRequest(this, url);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHeaders implements HttpHeaders {
  final Map<String, String> values = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) => values[name.toLowerCase()] = '$value';

  @override
  String? value(String name) => values[name.toLowerCase()];

  @override
  ContentType? get contentType => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRequest implements HttpClientRequest {
  final FakeHopHttpClient client;
  @override
  final Uri uri;
  @override
  final _FakeHeaders headers = _FakeHeaders();
  @override
  bool followRedirects = true;

  _FakeRequest(this.client, this.uri);

  @override
  Future<HttpClientResponse> close() async {
    client.sent.add(SentRequest(uri, Map.of(headers.values)));
    final hop = client.route(uri);
    final responseHeaders = _FakeHeaders();
    if (hop.location != null) responseHeaders.set('location', hop.location!);
    return _FakeResponse(client, hop, responseHeaders);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  final FakeHopHttpClient client;
  final FakeHop hop;
  @override
  final _FakeHeaders headers;

  _FakeResponse(this.client, this.hop, this.headers);

  @override
  int get statusCode => hop.status;

  @override
  int get contentLength => hop.body.length;

  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    Stream<List<int>> chunks() async* {
      for (var i = 0; i < hop.body.length; i += 65536) {
        final chunk = hop.body.sublist(i, i + 65536 > hop.body.length ? hop.body.length : i + 65536);
        client.bodyBytesServed += chunk.length;
        yield chunk;
      }
    }

    return chunks().listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
