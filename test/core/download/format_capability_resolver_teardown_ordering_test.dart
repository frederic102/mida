import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/format_capability_resolver.dart';
import 'package:mida/core/download/mp4_track_sniffer.dart';
import 'package:mida/core/extractors/media_models.dart';

import 'mp4_fixture_bytes.dart';

/// Split out of `format_capability_resolver_test.dart` purely for the
/// 400-line file cap: this file covers exactly one thing (phase 6 round 4,
/// S-R4-2, Codex #11) - that a real `Mp4TrackSniffer.sniff` call, on its
/// *normal* completion path (a small, well-formed fixture the server
/// closes naturally, not the deadline/timeout path already covered by
/// `format_capability_resolver_concurrency_test.dart`), only resolves the
/// Future `FormatCapabilityResolver`'s worker is awaiting once its own
/// read subscription has actually been cancelled - not before. With
/// `concurrency: 1` and several candidates, that means a real, independent
/// `HttpServer` per candidate should never see more than one connection
/// open at once.
///
/// `FormatCapabilityResolver._eligible` requires a format's own URL to
/// parse with an `https` scheme (round 2, S-R4), so plain loopback
/// `http://127.0.0.1:.../` URLs (as `format_capability_resolver_concurrency_test.dart`'s
/// slow-drip fixture uses, where eligibility does not matter because that
/// test only cares about the deadline path never running at all) are never
/// even picked up as candidates here. This file uses the same "pin an
/// https-scheme, public-looking IP-literal host to a local loopback
/// server via a custom `connectionFactory`" trick
/// `mp4_track_sniffer_redirect_and_window_test.dart` already relies on,
/// one fixed host (TEST-NET-3, RFC 5737) per server.
class _ConcurrencyTracker {
  int active = 0;
  int maxActive = 0;

  void inc() {
    active++;
    if (active > maxActive) maxActive = active;
  }

  void dec() => active--;
}

/// Answers with a small, well-formed fMP4 fixture and closes normally
/// (`request.response.close()`) - the *normal* completion path through
/// `Mp4TrackSniffer._readWindow` (an `onDone`, not the byte cap and not
/// `Mp4TrackSniffer.timeout`). Decrements [tracker] only once
/// `response.done` actually fires, i.e. once this connection has really
/// closed from the server's point of view.
class _FixtureServer {
  final HttpServer server;
  final _ConcurrencyTracker tracker;
  int requestCount = 0;

  _FixtureServer(this.server, this.tracker);

  static Future<_FixtureServer> start(_ConcurrencyTracker tracker) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _FixtureServer(server, tracker);
    server.listen(instance._handle);
    return instance;
  }

  Future<void> _handle(HttpRequest request) async {
    requestCount++;
    tracker.inc();
    var decremented = false;
    void decrementOnce() {
      if (decremented) return;
      decremented = true;
      tracker.dec();
    }

    unawaited(request.response.done.then((_) => decrementOnce(), onError: (_) => decrementOnce()));

    request.response.statusCode = 200;
    request.response.add(buildFmp4Init(videoFourCc: 'avc1', audioFourCc: 'mp4a', width: 640, height: 360));
    await request.response.close();
  }

  Future<void> close() => server.close(force: true);
}

MediaInfo _infoWithFormats(List<String> hosts) => MediaInfo(
      id: 'v1',
      title: 'test video',
      sourceUrl: Uri.parse('https://example.invalid/watch'),
      formats: [
        for (final host in hosts)
          MediaFormat(
            id: 'fmt-$host',
            url: 'https://$host/video.mp4',
            container: 'mp4',
            hasVideo: true,
            hasAudio: true,
            capabilitiesUnknown: true,
          ),
      ],
    );

void main() {
  test(
    'guard can fail: with concurrency: 1, FormatCapabilityResolver never has more than one real connection '
    'open at once across several candidates whose sniffs complete normally (S-R4-2)',
    () async {
      final tracker = _ConcurrencyTracker();
      final hosts = ['203.0.113.1', '203.0.113.2', '203.0.113.3', '203.0.113.4', '203.0.113.5'];
      final servers = await Future.wait(List.generate(hosts.length, (_) => _FixtureServer.start(tracker)));
      addTearDown(() async {
        for (final s in servers) {
          await s.close();
        }
      });
      final portByHost = {for (var i = 0; i < hosts.length; i++) hosts[i]: servers[i].server.port};

      HttpClient pinnedClient() {
        final client = HttpClient();
        client.connectionFactory = (uri, proxyHost, proxyPort) =>
            Socket.startConnect(InternetAddress.loopbackIPv4, portByHost[uri.host]!);
        return client;
      }

      final sniffer = Mp4TrackSniffer(httpClientFactory: pinnedClient);
      final resolver = FormatCapabilityResolver(sniffer: sniffer, concurrency: 1, maxSniffs: hosts.length);

      final result = await resolver.resolve(_infoWithFormats(hosts));

      for (final server in servers) {
        expect(server.requestCount, 1, reason: 'every candidate must actually have been sniffed');
      }
      expect(
        tracker.maxActive,
        lessThanOrEqualTo(1),
        reason: 'concurrency: 1 means the worker must not open a second connection until the first sniff\'s '
            'own Future has resolved and its subscription has actually been torn down - a real end-to-end '
            'regression check on the merged single-subscription `sniff`/`settle` (S-R4-2) against 5 real '
            'servers on the normal (non-deadline) completion path. Guard-can-fail (manually verified, see '
            'report): the pre-round-4 shape (two independent completers/settles - one inside a private '
            '`_readWindow`, one in `sniff` itself, neither aware of the other\'s subscription) let the '
            'DEADLINE-preemption path in particular open all 5 connections at once under a short timeout '
            '(observed maxActive: 5, i.e. concurrency not enforced at all) in a separate probe against that '
            'exact pre-round-4 code, since the outer `settle` there could complete `sniff`\'s Future without '
            'ever touching the still-live inner subscription. This test\'s own normal-completion scenario does '
            'not by itself distinguish an awaited vs. fire-and-forget `subscription.cancel()` (client.close '
            '(force: true) alone already orders things tightly enough on loopback for that specific case) - '
            'its value is as a standing regression guard on the merged, single-teardown-path design as a whole.',
      );
      for (final format in result.formats) {
        expect(
          format.capabilitiesUnknown,
          isFalse,
          reason: 'every fixture is well-formed and small; all should have been corrected via the normal '
              'completion path, not the deadline',
        );
        expect(format.hasVideo, isTrue);
        expect(format.hasAudio, isTrue);
      }
    },
  );
}
