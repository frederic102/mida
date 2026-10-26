import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/fallback_failure.dart';
import 'package:mida/core/extractors/generic/generic_extractor.dart';
import 'package:mida/core/extractors/media_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/net/retry_policy.dart';

class _RecordingBrowser implements MediaExtractor {
  final List<Uri> calls = [];

  @override
  bool canHandle(Uri url) => true;

  @override
  Future<MediaInfo> extract(Uri url) async {
    calls.add(url);
    throw const MediaExtractionException('NO_MEDIA_FOUND', 'browser fake');
  }
}

/// PENTAD Assay: a DNS failure inside the REAL GenericExtractor must leave
/// it as `OfflineNetworkException`, so the REAL registry stops before a
/// browser launch. Hermetic: the resolver fails on purpose and the HTTP
/// client refuses every connection, so nothing is looked up or dialled.
void main() {
  test('offline / NXDOMAIN through GenericExtractor surfaces NETWORK and never launches the browser', () async {
    final lookups = <String>[];
    final dialled = <Uri>[];
    Future<List<InternetAddress>> failingLookup(String host) async {
      lookups.add(host);
      throw const SocketException('Failed host lookup (fake)');
    }

    HttpClient refusingClient() => HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = (uri, proxyHost, proxyPort) {
        dialled.add(uri);
        return Future.error(const SocketException('offline test'));
      };

    final browser = _RecordingBrowser();
    final registry = ExtractorRegistry(
      [GenericExtractor(httpClientFactory: refusingClient, resolveHost: failingLookup)],
      fallbacks: [browser],
      retryPolicy: RetryPolicy(maxAttempts: 2, sleeper: (_) async {}),
    );

    MediaExtractionException? failure;
    try {
      await registry.resolveInfo(Uri.parse('https://offline.example/watch?token=SECRET'));
    } on MediaExtractionException catch (e) {
      failure = e;
    }

    expect(failure, isA<OfflineNetworkException>());
    expect(failure!.status, 'NETWORK');
    expect(failure.reason, isNot(contains('SECRET')));
    expect(browser.calls, isEmpty, reason: 'an offline machine must not launch a browser');
    expect(lookups, everyElement('offline.example'));
    expect(dialled, isEmpty);
  });
}
