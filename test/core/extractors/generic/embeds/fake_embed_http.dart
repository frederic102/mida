import 'dart:io';

import 'package:mida/core/extractors/generic/embeds/embed_http.dart';
import 'package:mida/core/extractors/generic/embeds/embed_resolver.dart';
import 'package:mida/core/extractors/generic/stage_deadline.dart';

/// One request a resolver made through [FakeEmbedHttp].
class RecordedRequest {
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final Object? json;

  const RecordedRequest(this.method, this.url, this.headers, this.json);
}

/// Hermetic [EmbedHttp]: answers from a fixed `"METHOD url"` route table,
/// 404 for anything else, and records every call. No sockets at all.
class FakeEmbedHttp implements EmbedHttp {
  final Map<String, EmbedHttpResponse> routes;
  final List<RecordedRequest> requests = [];

  FakeEmbedHttp(this.routes);

  EmbedHttpResponse _answer(String method, Uri url) =>
      routes['$method $url'] ?? const EmbedHttpResponse(statusCode: 404, body: 'not found');

  @override
  Future<EmbedHttpResponse> get(Uri url, {Map<String, String> headers = const {}, StageDeadline? deadline}) async {
    requests.add(RecordedRequest('GET', url, headers, null));
    return _answer('GET', url);
  }

  @override
  Future<EmbedHttpResponse> postJson(
    Uri url,
    Object? json, {
    Map<String, String> headers = const {},
    StageDeadline? deadline,
  }) async {
    requests.add(RecordedRequest('POST', url, headers, json));
    return _answer('POST', url);
  }
}

String fixture(String name) => File('test/fixtures/embeds/$name').readAsStringSync();

EmbedHttpResponse ok(String body) => EmbedHttpResponse(statusCode: 200, body: body);

final Uri hostPage = Uri.parse('https://www.example.org/learn/tour?utm=1');

EmbedRequest requestFor(String html, FakeEmbedHttp http) =>
    EmbedRequest(pageUrl: hostPage, html: html, http: http);
