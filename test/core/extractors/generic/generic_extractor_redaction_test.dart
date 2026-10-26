import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/generic_extractor.dart';
import 'package:mida/core/extractors/generic/media_url_probe.dart';
import 'package:mida/core/extractors/generic/stage_deadline.dart';
import 'package:mida/core/extractors/media_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';

/// Stands in for any lower layer that raises a reason with a full URL.
class _LeakyProbe extends MediaUrlProbe {
  _LeakyProbe() : super(allowPrivateHosts: true);

  @override
  Future<String?> containerFromContentType(Uri url, {StageDeadline? deadline}) async =>
      throw const MediaExtractionException(
        'UNSUPPORTED_URL',
        'Refusing to fetch https://cdn.example.net/ks/SECRET_PATH/a.m3u8?token=SECRET_QUERY: no.',
      );
}

/// Reasons leaving `GenericExtractor` (and therefore the registry) name a
/// host at most: a refused URL's path and query can carry tokens (Kaltura
/// `/ks/<token>/`, signed CDN queries). Loopback only; nothing is dialled
/// beyond the local fixture server.
void main() {
  Future<MediaExtractionException> failureOf(ExtractorRegistry registry, Uri url) async {
    try {
      await registry.resolveInfo(url);
    } on MediaExtractionException catch (e) {
      return e;
    }
    fail('expected a MediaExtractionException');
  }

  void expectNoSecrets(MediaExtractionException e) {
    final text = '${e.reason}';
    for (final secret in ['SECRET_PATH', 'SECRET_QUERY', '/ks/', 'token=']) {
      expect(text, isNot(contains(secret)), reason: text);
    }
  }

  test('a refused private URL is reported by host only', () async {
    final e = await failureOf(
      ExtractorRegistry([GenericExtractor()]),
      Uri.parse('https://127.0.0.1/ks/SECRET_PATH/a.mp4?token=SECRET_QUERY'),
    );
    expect(e.status, 'UNSUPPORTED_URL');
    expect(e.reason, contains('127.0.0.1'));
    expectNoSecrets(e);
  });

  test('a redirect into a private host is refused without echoing its path or query', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.statusCode = 302;
      request.response.headers.set('Location', 'http://10.1.2.3/ks/SECRET_PATH/x?token=SECRET_QUERY');
      await request.response.close();
    });
    final e = await failureOf(
      ExtractorRegistry([GenericExtractor(allowPrivateHosts: true)]),
      Uri.parse('http://127.0.0.1:${server.port}/watch'),
    );
    expect(e.status, 'UNSUPPORTED_URL');
    expectNoSecrets(e);
  });

  test('boundary sanitizing: a full-URL reason raised below extract() leaves it host-only', () async {
    final extractor = GenericExtractor(allowPrivateHosts: true, probe: _LeakyProbe());
    MediaExtractionException? caught;
    try {
      await extractor.extract(Uri.parse('https://cdn.example.net/watch'));
    } on MediaExtractionException catch (e) {
      caught = e;
    }
    expect(caught!.status, 'UNSUPPORTED_URL');
    expect(caught.reason, contains('cdn.example.net'));
    expectNoSecrets(caught);
  });
}
