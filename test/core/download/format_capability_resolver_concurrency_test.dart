import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/format_capability_resolver.dart';
import 'package:mida/core/download/mp4_track_sniffer.dart';
import 'package:mida/core/extractors/media_models.dart';

/// Split out of `format_capability_resolver_test.dart` purely for the
/// 400-line file cap: this file covers exactly one thing (phase 6 round 2,
/// S-R2) - that `FormatCapabilityResolver.concurrency` bounds *real* open
/// connections against a real `Mp4TrackSniffer`, not just the number of
/// worker loops running. The rest of that class's behavior (selection,
/// field-merge, cap, fake-sniffer-based concurrency/timeout shape) is
/// covered there with a stand-in sniffer; this file is the one place a
/// genuine `HttpServer` fixture is involved.

/// Shared counter so several independent [_SlowDripServer]s can be
/// checked together for "how many were actually connected to at once",
/// not just each one's own trivial 0-or-1.
class _ConcurrencyTracker {
  int active = 0;
  int maxActive = 0;

  void inc() {
    active++;
    if (active > maxActive) maxActive = active;
  }

  void dec() => active--;
}

/// A server that answers 200 and then drips one byte at a time forever,
/// never completing and never erroring on its own - the shape a
/// `Mp4TrackSniffer.sniff` call must not be allowed to hold open past its
/// own [Mp4TrackSniffer.timeout]. Decrements [tracker] the moment the
/// connection actually closes (`response.done`, which fires whether the
/// client closed it gracefully or - the case this guard is about - force-
/// closed it), not when this handler's own loop happens to notice.
class _SlowDripServer {
  final HttpServer server;
  final _ConcurrencyTracker tracker;

  _SlowDripServer(this.server, this.tracker);

  static Future<_SlowDripServer> start(_ConcurrencyTracker tracker) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _SlowDripServer(server, tracker);
    server.listen(instance._handle);
    return instance;
  }

  String get url => 'http://127.0.0.1:${server.port}/video.mp4';

  Future<void> _handle(HttpRequest request) async {
    tracker.inc();
    var decremented = false;
    void decrementOnce() {
      if (decremented) return;
      decremented = true;
      tracker.dec();
    }

    unawaited(request.response.done.then((_) => decrementOnce(), onError: (_) => decrementOnce()));

    request.response.statusCode = 200;
    try {
      while (true) {
        await Future.delayed(const Duration(milliseconds: 15));
        request.response.add(const [0]);
        await request.response.flush();
      }
    } catch (_) {
      decrementOnce();
    }
  }

  Future<void> close() => server.close(force: true);
}

MediaInfo _infoWithSlowFormats(List<_SlowDripServer> servers) => MediaInfo(
      id: 'v1',
      title: 'test video',
      sourceUrl: Uri.parse('https://example.invalid/watch'),
      formats: [
        for (var i = 0; i < servers.length; i++)
          MediaFormat(
            id: 'slow$i',
            url: servers[i].url,
            container: 'mp4',
            hasVideo: true,
            hasAudio: true,
            capabilitiesUnknown: true,
          ),
      ],
    );

void main() {
  test(
    'guard can fail: FormatCapabilityResolver.concurrency bounds real open connections against a real '
    'Mp4TrackSniffer talking to a slow-drip server that never completes on its own (S-R2)',
    () async {
      final tracker = _ConcurrencyTracker();
      final servers = await Future.wait(List.generate(4, (_) => _SlowDripServer.start(tracker)));
      addTearDown(() async {
        for (final s in servers) {
          await s.close();
        }
      });

      const sniffer = Mp4TrackSniffer(allowPrivateHosts: true, timeout: Duration(milliseconds: 80));
      const resolver = FormatCapabilityResolver(
        sniffer: sniffer,
        concurrency: 2,
        maxSniffs: 4,
        // Phase 6 round 3 (S-R3-4, Codex #12): the resolver no longer has
        // an external `.timeout()` at all, so [Mp4TrackSniffer.timeout]
        // (80ms) is the only thing that can end a sniff here. If it did
        // not, this would not merely be slow - it would never finish,
        // because the drip server never completes on its own.
      );

      final stopwatch = Stopwatch()..start();
      final result = await resolver.resolve(_infoWithSlowFormats(servers));
      stopwatch.stop();

      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 2)),
        reason: 'each sniff must be cut short by its own internal deadline (80ms), not run until the 5s '
            'external timeout - guard-can-fail (manually verified, see report): reverting Mp4TrackSniffer.sniff '
            'to rely only on the resolver\'s external .timeout() makes this take multiple seconds instead.',
      );
      expect(
        tracker.maxActive,
        lessThanOrEqualTo(2),
        reason: 'a sniff abandoned only by an external .timeout() leaks its real connection open past the '
            'concurrency cap - guard-can-fail (manually verified, see report): the same revert above makes this '
            'climb toward 4 (every candidate\'s connection staying open at once) instead of holding at 2.',
      );
      // Never corrected (each sniff hits its own deadline before reading
      // a usable moov out of the 1-byte-at-a-time drip) but must not have
      // thrown or hung resolve() as a whole.
      expect(result.formats, hasLength(4));
      for (final format in result.formats) {
        expect(format.capabilitiesUnknown, isTrue);
      }
    },
  );
}
