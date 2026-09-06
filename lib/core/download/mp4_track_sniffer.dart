import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../extractors/media_models.dart';
import '../net/host_policy.dart';
import '../net/per_hop_credentials.dart';
import 'iso_bmff_reader.dart';

/// What [Mp4TrackSniffer] learned about one progressive/fragmented MP4 URL
/// from its leading bytes: which track kinds its `moov` declares, the
/// video track's dimensions, and the sample-entry fourccs (`avc1`,
/// `hvc1`, `mp4a`, ...) so `FormatSelector` can pair without transcoding.
class Mp4TrackInfo {
  final bool hasVideo;
  final bool hasAudio;
  final int? width;
  final int? height;
  final String? videoCodec;
  final String? audioCodec;

  const Mp4TrackInfo({
    required this.hasVideo,
    required this.hasAudio,
    this.width,
    this.height,
    this.videoCodec,
    this.audioCodec,
  });
}

/// Contract stub (phase 6, lead-owned signature; Lane S owns the body).
/// Reads the first window of an MP4 URL with a ranged GET and parses the
/// ISO BMFF box tree far enough to find `moov > trak > mdia > hdlr`
/// (`vide`/`soun`), `tkhd` (width/height) and `stsd` (sample-entry
/// fourcc). Returns null when `moov` is not inside the window (non
/// fast-start file), on any network/parse error, or when the host is
/// refused by `HostPolicy`. Never throws.
class Mp4TrackSniffer {
  final HttpClient Function() httpClientFactory;

  /// Test-only escape hatch mirroring `CapturedFormatBuilder.allowPrivateHosts`.
  /// Production code must never set this to true.
  final bool allowPrivateHosts;

  /// Hard ceiling on how long a single [sniff] call may take end to end
  /// (connect, redirects, reading the leading window), enforced from
  /// *inside* this method rather than left to a caller's own
  /// `.timeout()` (phase 6 round 2, S-R2). A caller-side `.timeout()`
  /// alone only abandons *waiting* on the returned Future - the real
  /// `HttpClient`/socket this method opened keeps running in the
  /// background regardless, which is exactly how
  /// `FormatCapabilityResolver`'s own concurrency cap used to leak past
  /// its stated limit against a slow/non-responding server: an abandoned
  /// sniff never frees the connection it holds, so the real number of
  /// open sockets could climb well past `concurrency` even though only
  /// `concurrency` *worker loops* were ever running. Enforcing the
  /// deadline here means [sniff] itself always force-closes [client] (and
  /// so cancels whatever subscription is reading the response) the moment
  /// [timeout] elapses, so this method's own work is bounded regardless of
  /// whether anything is still awaiting its result.
  final Duration timeout;

  const Mp4TrackSniffer({
    this.httpClientFactory = HttpClient.new,
    this.allowPrivateHosts = false,
    this.timeout = const Duration(seconds: 4),
  });

  /// Leading-bytes window requested (and hard-capped at, regardless of what
  /// a server that ignores `Range` sends back): 64 KiB is comfortably more
  /// than any real-world fast-start `moov` needs.
  static const int _windowSize = 65536;

  Future<Mp4TrackInfo?> sniff(
    Uri url,
    Map<String, String> headers, {
    Map<String, List<CookieEntry>>? cookiesByDomain,
  }) async {
    final client = httpClientFactory();
    final completer = Completer<Mp4TrackInfo?>();
    var settled = false;
    // The one subscription this call is ever reading from at a given
    // moment (the leading-window read below) - tracked here, not just
    // locally inside the read, so [settle] (called both from the normal
    // completion path and from the deadline timer that can fire *while*
    // that read is still in flight) always has it in reach.
    StreamSubscription<List<int>>? subscription;

    // Phase 6 round 4 (S-R4-2, Codex #11): asynchronous, and awaits the
    // active subscription's cancellation *before* completing [completer] -
    // not fire-and-forget. `FormatCapabilityResolver`'s worker loop only
    // advances to its next candidate once the Future [sniff] returns has
    // actually resolved; completing that Future before this method's own
    // subscription has finished tearing down is exactly how a second
    // connection could start opening while the first one's is still being
    // unwound, letting the real number of open connections climb past the
    // resolver's `concurrency` cap even though [client] is force-closed
    // right here.
    Future<void> settle(Mp4TrackInfo? value) async {
      if (settled) return;
      settled = true;
      final sub = subscription;
      subscription = null;
      if (sub != null) await sub.cancel();
      client.close(force: true);
      if (!completer.isCompleted) completer.complete(value);
    }

    final deadlineTimer = Timer(timeout, () => settle(null));

    Future<void> run() async {
      try {
        final response = await HostPolicy.guardedRequest(
          client,
          url,
          useHead: false,
          allowPrivateHosts: allowPrivateHosts,
          configureRequest: (request) {
            // Recomputed per hop off `request.uri` (the URL this
            // particular hop is actually going to), never the original
            // [url] - a redirect can land on a different origin than
            // [url] itself, and neither a caller-supplied `Cookie`/
            // `Authorization` header nor a cookie scoped for the
            // original host may simply ride along onto that new origin
            // unexamined (phase 6 round 2, S-R1; phase 6 round 4, S-R4-1:
            // shares this logic with `manifest_reference_scanner.dart`
            // via `PerHopCredentials` rather than keeping its own copy).
            PerHopCredentials.apply(request, origin: url, headers: headers, cookiesByDomain: cookiesByDomain);
            request.headers.set('Range', 'bytes=0-${_windowSize - 1}');
          },
        );

        // A range request answered with anything but 200 (server ignored
        // the Range header and sent the whole thing - fine, the byte cap
        // below still applies regardless of status code, it is not what
        // gates the cap) or 206 (proper partial content) is treated as
        // "could not read this" - a 403/404/416/5xx is common for an
        // expired or single-use signed URL and is not this sniffer's
        // problem to solve, just something it must not throw over.
        if (response.statusCode != HttpStatus.ok && response.statusCode != HttpStatus.partialContent) {
          await settle(null);
          return;
        }

        final bytes = await _readWindow(response, (sub) => subscription = sub);
        if (settled) return; // the deadline already fired while we were reading

        final parsed = IsoBmffReader.parse(bytes);
        if (parsed == null) {
          await settle(null);
          return;
        }
        await settle(Mp4TrackInfo(
          hasVideo: parsed.hasVideo,
          hasAudio: parsed.hasAudio,
          width: parsed.width,
          height: parsed.height,
          videoCodec: parsed.videoCodec,
          audioCodec: parsed.audioCodec,
        ));
      } catch (_) {
        // Never throws: a refused host (SSRF guard), a network error, a
        // TLS failure, a malformed URL - all of it just means "could not
        // sniff this one", not a reason to fail the caller's own work.
        await settle(null);
      }
    }

    unawaited(run());
    return completer.future.whenComplete(deadlineTimer.cancel);
  }

  /// Reads at most [_windowSize] bytes off [response], reporting the live
  /// subscription to [onSubscribed] the moment it starts (so [sniff]'s own
  /// [settle] can cancel it from outside if the deadline fires first).
  /// Does **not** rely on the response ever reaching a natural end, or on
  /// the status code (a server that ignores `Range` and answers 200 with
  /// its whole, multi-gigabyte file is exactly the case this guards): the
  /// moment the cap is hit, this settles right there, not after some later
  /// point - so a non-cooperating server cannot make this hang or buffer
  /// unbounded memory while we wait for something (the parse, the caller,
  /// GC) that only happens later.
  Future<Uint8List> _readWindow(
    HttpClientResponse response,
    void Function(StreamSubscription<List<int>> subscription) onSubscribed,
  ) {
    final builder = BytesBuilder(copy: false);
    final completer = Completer<Uint8List>();
    var total = 0;
    late final StreamSubscription<List<int>> subscription;

    // Cancels the subscription the moment this read is done, whichever way
    // it ended - the cap being hit, a natural `onDone`, or a stream error -
    // rather than leaving it to whoever calls [sniff]'s own outer `settle`
    // next. That outer `settle` still awaits `subscription.cancel()` of its
    // own accord before it completes the Future [sniff] returns (S-R4-2);
    // cancelling here first only means that second call is a no-op, not a
    // race - Dart's own `StreamSubscription.cancel()` contract is silent
    // about (and safe for) being called more than once.
    void finish() {
      subscription.cancel();
      if (!completer.isCompleted) completer.complete(builder.toBytes());
    }

    subscription = response.listen(
      null,
      onDone: finish,
      onError: (Object _, StackTrace __) => finish(),
      cancelOnError: true,
    );
    onSubscribed(subscription);
    subscription.onData((chunk) {
      // Only ever adds up to what is still missing from the window
      // (phase 6 round 2, S-R3): a chunk that arrives once `total` is
      // already close to `_windowSize` can itself be far larger than
      // the remaining space (network reads are not obligated to align
      // with our own cap), and appending it whole would let the buffer
      // - and whatever `IsoBmffReader.parse` sees - grow past the
      // window this class advertises everywhere else (its own doc,
      // `_windowSize`'s doc, the `Range` header sent) as a hard cap.
      final remaining = _windowSize - total;
      final toAdd = chunk.length < remaining ? chunk.length : remaining;
      if (toAdd > 0) {
        builder.add(toAdd == chunk.length ? chunk : chunk.sublist(0, toAdd));
        total += toAdd;
      }
      if (total >= _windowSize) finish();
    });

    return completer.future;
  }
}
