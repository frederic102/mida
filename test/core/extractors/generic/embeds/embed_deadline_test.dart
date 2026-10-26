import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/embeds/embed_http.dart';
import 'package:mida/core/extractors/generic/embeds/embed_resolver_chain.dart';
import 'package:mida/core/extractors/generic/generic_extractor.dart';
import 'package:mida/core/extractors/generic/network_budget.dart';
import 'package:mida/core/extractors/generic/stage_deadline.dart';
import 'package:mida/core/extractors/media_models.dart';

import '../generic_test_support.dart';
import '../stall_server.dart';
import 'fake_embed_http.dart';

/// Deadline propagation through the embed step: a stalled platform API
/// must be cancelled (connection closed), not merely abandoned, and no
/// later resolver request may start. Loopback servers only.
void main() {
  final api = Uri.parse('https://players.brightcove.net/1/p_default/config.json');

  test('GET: the per-request timeout closes the stalled connection', () async {
    final stall = await StallServer.start(head: 'HTTP/1.1 200 OK\r\nContent-Length: 999999\r\n\r\n{');
    addTearDown(stall.close);
    final http = GuardedEmbedHttp(
      httpClientFactory: stall.client,
      allowPrivateHosts: true,
      requestTimeout: const Duration(milliseconds: 200),
    );
    await expectLater(http.get(api).timeout(const Duration(seconds: 3)), throwsA(isA<TimeoutException>()));
    // Every connection that did open (normally exactly one) was torn down.
    for (final closed in stall.closedByClient) {
      await closed.future.timeout(const Duration(seconds: 5));
    }
  });

  test('POST: the stage deadline closes the stalled connection and surfaces as StageDeadlineExceeded', () async {
    final stall = await StallServer.start();
    addTearDown(stall.close);
    final http = GuardedEmbedHttp(httpClientFactory: stall.client, allowPrivateHosts: true);
    final deadline = StageDeadline(const Duration(milliseconds: 200));
    await expectLater(
      http.postJson(Uri.parse('https://cdnapisec.kaltura.com/api_v3/service/multirequest'), const {}, deadline: deadline)
          .timeout(const Duration(seconds: 3)),
      throwsA(isA<StageDeadlineExceeded>()),
    );
    for (final closed in stall.closedByClient) {
      await closed.future.timeout(const Duration(seconds: 5));
    }
  });

  test('an expired deadline starts no request at all (GET, POST, budgeted)', () async {
    final stall = await StallServer.start();
    addTearDown(stall.close);
    final http = GuardedEmbedHttp(httpClientFactory: stall.client, allowPrivateHosts: true);
    final deadline = StageDeadline(const Duration(seconds: 30))..expire();
    await expectLater(http.get(api, deadline: deadline), throwsA(isA<StageDeadlineExceeded>()));
    await expectLater(http.postJson(api, const {}, deadline: deadline), throwsA(isA<StageDeadlineExceeded>()));
    final budget = NetworkBudget(maxFetches: 3);
    await expectLater(BudgetedEmbedHttp(http, budget, deadline: deadline).get(api), throwsA(isA<StageDeadlineExceeded>()));
    expect(budget.consumed, 0);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(stall.requests, isEmpty);
  });

  test('chain: an expired deadline ends the whole pass, it is not swallowed per resolver', () async {
    final fake = FakeEmbedHttp({});
    final deadline = StageDeadline(const Duration(seconds: 30))..expire();
    await expectLater(
      EmbedResolverChain(http: fake).resolve(pageUrl: hostPage, html: fixture('wistia_page.html'), deadline: deadline),
      throwsA(isA<StageDeadlineExceeded>()),
    );
    expect(fake.requests, isEmpty);
  });

  test(
    'end to end: after the static-stage deadline the stalled embed request is closed and a response that '
    'arrives later triggers no further resolver request',
    () async {
      final page = await FakePageServer.start();
      addTearDown(page.close);
      page.body = '<html><body><video-js data-account="1234567890" data-player="AbCdEf-123" data-embed="default" '
          'data-video-id="6301234567001"></video-js><div class="wistia_async_abc123xyz9"></div></body></html>';
      // Holds the Brightcove config request; after extract() has returned
      // the test answers it (if the client is still there) with a valid
      // config, which would make an uncancelled resolver go on to the
      // playback API and Wistia.
      final stall = await StallServer.start(
        release: 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n'
            '${fixture('brightcove_config.json')}',
      );
      addTearDown(stall.close);
      HttpClient routed() => HttpClient()
        ..findProxy = ((_) => 'DIRECT')
        ..connectionFactory = (uri, proxyHost, proxyPort) =>
            Socket.startConnect(InternetAddress.loopbackIPv4, uri.host == '127.0.0.1' ? uri.port : stall.port);

      final extractor = GenericExtractor(
        httpClientFactory: routed,
        allowPrivateHosts: true,
        // Long enough that the page fetch reliably reaches the embed step
        // even on a loaded machine; the stall then holds until it expires.
        staticStageDeadlineForTesting: const Duration(seconds: 2),
      );
      await expectLater(
        extractor.extract(page.urlFor('/watch')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NO_MEDIA_FOUND')),
      );
      expect(stall.requests, hasLength(1));
      expect(stall.requests.single, contains('config.json'));

      // The client itself tore the stalled request down (the server has not
      // answered or closed anything yet).
      await stall.closedByClient.single.future.timeout(const Duration(seconds: 5));
      // A late answer now reaches nobody, and starts nothing.
      stall.releaseAll();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(stall.requests, hasLength(1), reason: 'no resolver request may start after the deadline');
    },
  );
}
