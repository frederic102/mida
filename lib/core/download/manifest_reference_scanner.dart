import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../extractors/media_models.dart';
import '../net/host_policy.dart';
import '../net/per_hop_credentials.dart';
import 'manifest_cookie_gate.dart';
import 'manifest_reference_walker.dart';

/// What one [ManifestReferenceScanner.scanAndCheck] found.
class ManifestScanResult {
  /// Every leaf URI (segment, key, map, DASH `BaseURL`/`SegmentTemplate`
  /// target) the scan reached - all of them already host-checked.
  final List<Uri> references;

  /// Phase 6 B-R4: what the scanned media playlists say about segment
  /// framing, in the tri-state `HlsFfmpegDownloader.buildArgs` already
  /// understands (`true` MPEG-TS/ADTS, `false` fMP4/CMAF, `null` no
  /// signal - caller keeps its own default).
  final bool? segmentsAreTransportStream;

  /// How many playlists the scan actually fetched (root included).
  final int playlistsFetched;

  /// Phase 6 B-R3-7, rescoped by B-R4-7: the length the manifest chain
  /// *declares*, scoped to what is actually being downloaded rather than
  /// blended across sibling variants - the root URL's own `#EXTINF` sum
  /// when the root itself is already a media playlist (the common case:
  /// the URL `HlsFfmpegDownloader` was handed IS the leaf ffmpeg opens),
  /// a DASH MPD's summed per-`<Period>` `duration` when every `<Period>`
  /// declares one, else its overall `mediaPresentationDuration`. Null
  /// when nothing said, or when sibling media playlists disagree by more
  /// than 10% with no root-level signal to prefer instead (B-R4-7 /
  /// Codex #12). The caller verifies the finished file against it, which
  /// is the only way a truncated download that still exits 0 gets caught.
  final Duration? declaredDuration;

  /// Phase 6 B-R3-5: hosts this manifest references, or reached via a
  /// redirect hop (B-R4-2), that lie OUTSIDE the scope of the cookie it
  /// was fetched with, sorted and de-duplicated; empty when no cookie is
  /// in play or all is in scope. Not a refusal any more (see
  /// [ManifestCookieGate.recordCookieScope]): the caller strips
  /// credential headers from what it hands ffmpeg when this is non-empty.
  final List<String> hostsOutsideCookieScope;

  const ManifestScanResult({
    required this.references,
    required this.segmentsAreTransportStream,
    required this.playlistsFetched,
    this.declaredDuration,
    this.hostsOutsideCookieScope = const [],
  });
}

/// Fetches a top-level HLS/DASH manifest and walks every playlist it
/// chains into (variants, `#EXT-X-MEDIA` renditions, nested masters) so
/// [HlsFfmpegDownloader] can host-check every URI before handing a bare
/// URL to ffmpeg (which has no concept of "refuse to follow a reference
/// to a private host"). What is enforced here, and how each part fails:
///
///  1. **Host policy on every reference.** Each URI found - fetched or
///     only read - goes through [HostPolicy.assertAllowedHost]
///     (syntactic) and [HostPolicy.assertResolvesToPublicHost]
///     (DNS-answer). A rejection refuses the whole manifest; it is never
///     downgraded to "could not read that one, carry on" (B-R1).
///  2. **Every playlist fetch must succeed, be 2xx, and look like a
///     manifest** (B-R3-1). The old "skip an unreadable variant" path is
///     gone: a playlist nothing could read is a playlist nothing
///     CHECKED, and ffmpeg would go on to open it anyway.
///  3. **Bounded traversal that refuses when the bound is hit** (B-R2,
///     B-R3-6). [maxPlaylists] caps the walk, [maxBytesPerPlaylist] caps
///     each response; hitting a cap with work still queued refuses.
///  4. **A whole-scan deadline** ([defaultTimeout], B-R3-3): on expiry
///     the client is force-closed and the scan refuses.
///  5. **Cookie containment, reported not refused** (B-R3-5, B-R4-2/6):
///     offending hosts land in [ManifestScanResult.hostsOutsideCookieScope]
///     and the caller drops the cookie before ffmpeg ever sees it.
///  6. **Every playlist body is parsed against the hop it actually came
///     from** (B-R4-1): a redirected playlist's relative references are
///     resolved against the redirect target, not the pre-redirect URL.
///
/// [allowPrivateHosts] is a *test-only* exemption scoped to the root
/// manifest's own origin (scheme + host + port). Production never sets it.
class ManifestReferenceScanner {
  final HttpClient Function() _httpClientFactory;

  ManifestReferenceScanner({HttpClient Function()? httpClientFactory})
      : _httpClientFactory = httpClientFactory ?? HttpClient.new;

  /// Hard cap on playlists one scan will fetch, well above real-world
  /// master fan-out: exhausting it is a refusal rather than a silent
  /// stop, so a cap set too tightly would reject legitimate content
  /// instead of merely under-checking it.
  static const maxPlaylists = 48;

  /// Phase 6 B-R3-6: the byte cap is *per playlist*, not a shared budget
  /// across the scan. A 12-variant master of a long VOD legitimately
  /// carries several hundred KB of `#EXTINF` lines per media playlist,
  /// and a shared total refused that shape for being long rather than
  /// hostile. [maxPlaylists] bounds the scan; this bounds one response.
  static const maxBytesPerPlaylist = 2 * 1024 * 1024;

  /// How far the playlist chain may nest (root = 0). A master pointing at
  /// a master pointing at a media playlist is depth 2; deeper is a
  /// redirection loop or a deliberate fan-out attempt.
  static const maxDepth = 4;

  /// Phase 6 B-R3-3: wall-clock cap on one whole scan - above any
  /// plausible real walk, below what a stalled server can outlast.
  static const defaultTimeout = Duration(seconds: 30);

  /// Fraction of disagreement between two declared durations, relative to
  /// the larger one, above which [_reconcileDeclaredDuration] gives up and
  /// reports null rather than guessing (B-R4-7 / Codex #12).
  static const _durationDisagreementTolerance = 0.10;

  /// Fetches [url], walks every playlist it chains into, host-checks
  /// every reference, and returns the leaves plus the framing signal,
  /// the declared duration and any out-of-cookie-scope hosts. Throws
  /// [MediaExtractionException] on any refusal: a disallowed host, an
  /// unreadable/non-2xx/non-manifest playlist, a budget exhausted with
  /// work still queued, or [timeout].
  Future<ManifestScanResult> scanAndCheck(
    Uri url,
    Map<String, String> headers, {
    bool allowPrivateHosts = false,
    Map<String, List<CookieEntry>>? cookiesByDomain,
    Future<List<InternetAddress>> Function(String host) resolveHost = InternetAddress.lookup,
    Duration timeout = defaultTimeout,
  }) async {
    final client = _httpClientFactory();
    try {
      // `.timeout` rather than a Timer racing a Completer, deliberately:
      // the wrapper future is already resolved with this refusal by the
      // time the force-close below makes the in-flight read fail, so the
      // caller cannot end up seeing that raw HttpException instead of
      // the timeout that actually happened.
      return await _walk(client, url, headers, allowPrivateHosts, cookiesByDomain, resolveHost)
          .timeout(timeout, onTimeout: () {
        // Force-closed, not merely abandoned: a body still arriving
        // would otherwise keep being read after this scan is over.
        client.close(force: true);
        throw MediaExtractionException(
          'PARSE_ERROR',
          'Refusing this manifest: reading its playlist chain did not finish within ${timeout.inSeconds}s. '
              'A manifest server that slow (or that trickles bytes indefinitely) cannot be checked, and an '
              'unchecked manifest is not one to hand to ffmpeg.',
        );
      });
    } finally {
      client.close(force: true);
    }
  }

  Future<ManifestScanResult> _walk(
    HttpClient client,
    Uri url,
    Map<String, String> headers,
    bool allowPrivateHosts,
    Map<String, List<CookieEntry>>? cookiesByDomain,
    Future<List<InternetAddress>> Function(String host) resolveHost,
  ) async {
    final gate = ManifestCookieGate(
      root: url,
      headers: headers,
      cookiesByDomain: cookiesByDomain,
      allowPrivateHosts: allowPrivateHosts,
      resolveHost: resolveHost,
    );
    final queue = Queue<_PendingPlaylist>()..add(_PendingPlaylist(url, 0));
    final enqueued = <String>{url.toString()};
    final leaves = <Uri>[];
    var framing = SegmentFraming.unknown;
    Duration? rootDeclaredDuration;
    final allDeclaredDurations = <Duration>[];
    var playlistsFetched = 0;

    while (queue.isNotEmpty) {
      if (playlistsFetched >= maxPlaylists) {
        throw MediaExtractionException(
          'PARSE_ERROR',
          'Refusing this manifest: its playlist chain exceeded the scan budget ($playlistsFetched playlists '
              'read, cap $maxPlaylists) with ${queue.length} playlist(s) still unchecked. Half-checking a '
              'manifest and handing it to ffmpeg anyway would leave exactly the unchecked references this '
              'check exists to catch.',
        );
      }

      final pending = queue.removeFirst();
      final isRoot = playlistsFetched == 0;
      playlistsFetched++;
      final fetched = await _fetchBounded(client, pending.uri, headers, gate);

      // B-R4-1: parsed relative to the LAST hop this playlist's body
      // actually arrived from, not the (possibly pre-redirect) URI it was
      // requested at - a manifest that 302's to a different origin still
      // resolves its own relative segment paths against the origin it
      // redirected to, and ffmpeg (via its own HTTP client) would do the
      // same.
      final parsed = ManifestReferenceWalker.parse(fetched.text, fetched.effectiveUri);
      framing = framing.merge(parsed.framing);
      if (parsed.declaredDuration != null) {
        allDeclaredDurations.add(parsed.declaredDuration!);
        // B-R4-7: the root URL passed to `scanAndCheck` is the one ffmpeg
        // is actually handed, so when IT already declares a duration (it
        // is itself a media playlist, not a master), that duration alone
        // is exactly the leaf being downloaded - sibling variants reached
        // only by walking the chain must never blend into it.
        if (isRoot) rootDeclaredDuration = parsed.declaredDuration;
      }

      for (final reference in parsed.references) {
        await gate.check(reference.uri);
        if (reference.kind == ManifestReferenceKind.leaf) {
          leaves.add(reference.uri);
          continue;
        }
        if (!enqueued.add(reference.uri.toString())) continue;
        final depth = pending.depth + 1;
        if (depth > maxDepth) {
          throw MediaExtractionException(
            'PARSE_ERROR',
            'Refusing this manifest: its playlist chain nests deeper than $maxDepth levels '
                '(${reference.uri}). That is a redirection loop or a deliberate fan-out, not a real stream.',
          );
        }
        queue.add(_PendingPlaylist(reference.uri, depth));
      }
    }

    return ManifestScanResult(
      references: leaves,
      segmentsAreTransportStream: framing.asTransportStreamFlag,
      playlistsFetched: playlistsFetched,
      declaredDuration: rootDeclaredDuration ?? _reconcileDeclaredDuration(allDeclaredDurations),
      hostsOutsideCookieScope: gate.hostsOutsideCookieScope,
    );
  }

  /// B-R4-7 / Codex #12: when the root playlist itself declared no
  /// duration (it was a master, not a media playlist), the only signal
  /// left is whatever its children declared - but those are sibling
  /// variants of each other, not necessarily the exact one ffmpeg's own
  /// demuxer will end up consuming. Agreeing variants (within
  /// [_durationDisagreementTolerance] of each other) are trustworthy
  /// enough to report; variants that disagree by more than that are not -
  /// reporting one of them as truth risks a false "truncated download"
  /// verification failure against a variant that was never the one
  /// actually downloaded.
  static Duration? _reconcileDeclaredDuration(List<Duration> durations) {
    if (durations.isEmpty) return null;
    var maxMicros = 0;
    var minMicros = durations.first.inMicroseconds;
    for (final d in durations) {
      final micros = d.inMicroseconds;
      if (micros > maxMicros) maxMicros = micros;
      if (micros < minMicros) minMicros = micros;
    }
    if (maxMicros <= 0) return null;
    final disagreement = (maxMicros - minMicros) / maxMicros;
    if (disagreement > _durationDisagreementTolerance) return null;
    return durations.first;
  }

  /// One host-checked GET whose response must be 2xx, must stay under
  /// [maxBytesPerPlaylist] WHILE being read (not once already buffered),
  /// and must look like a manifest. Phase 6 B-R3-1: every one of those
  /// failures - a transport error included - refuses the whole scan.
  /// Credentials are re-scoped per hop (B-R3-2) by [PerHopCredentials].
  /// Returns the body text alongside the effective (last-hop) URI it came
  /// from (B-R4-1), having already fed every hop into [gate]'s
  /// cookie-scope accounting (B-R4-2).
  Future<({String text, Uri effectiveUri})> _fetchBounded(
    HttpClient client,
    Uri target,
    Map<String, String> headers,
    ManifestCookieGate gate,
  ) async {
    final HttpClientResponse response;
    final hops = <Uri>[];
    try {
      response = await HostPolicy.guardedRequest(
        client,
        target,
        useHead: false,
        configureRequest: (request) => PerHopCredentials.apply(
          request,
          origin: gate.root,
          headers: headers,
          cookiesByDomain: gate.cookiesByDomain,
        ),
        allowPrivateHosts: gate.isExemptOrigin(target),
        resolveHost: gate.resolve,
        onHop: hops.add,
      );
    } on MediaExtractionException {
      rethrow; // A host-policy refusal, including one raised on a redirect hop.
    } on IOException catch (e) {
      throw MediaExtractionException(
        'PARSE_ERROR',
        'Refusing this manifest: its playlist $target could not be read ($e), so nothing checked what that '
            'playlist references - and ffmpeg would go on to open it anyway. If the source is simply '
            'unavailable right now, retry the download.',
      );
    } on TimeoutException catch (e) {
      throw MediaExtractionException(
        'PARSE_ERROR',
        'Refusing this manifest: its playlist $target timed out while being read ($e), so nothing checked '
            'what that playlist references.',
      );
    }

    // B-R4-2: every hop this fetch actually went through - including
    // ones a redirect led to - is fed into the same cookie-scope
    // accounting as an in-body reference. ffmpeg's own request follows
    // the identical redirect chain but (unlike this scanner) never
    // re-scopes its one flattened `-headers` blob per hop.
    for (final hop in hops) {
      gate.recordHopHost(hop);
    }
    final effectiveUri = hops.isNotEmpty ? hops.last : target;

    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>().catchError((_) {});
      throw MediaExtractionException(
        'PARSE_ERROR',
        'Refusing this manifest: its playlist $target answered HTTP ${response.statusCode} instead of a '
            'manifest, so nothing checked what that playlist references. If this stream needs a login, the '
            'session that captured it has probably expired.',
      );
    }

    final builder = BytesBuilder(copy: false);
    var read = 0;
    await for (final chunk in response) {
      read += chunk.length;
      if (read > maxBytesPerPlaylist) {
        throw MediaExtractionException(
          'PARSE_ERROR',
          'Refusing this manifest: its playlist $target exceeded the '
              '${maxBytesPerPlaylist ~/ (1024 * 1024)}MB per-playlist size limit while being read, rather '
              'than buffering an unbounded response body.',
        );
      }
      builder.add(chunk);
    }
    // allowMalformed: a body that is not valid UTF-8 is not a manifest,
    // and the shape check right below is what refuses it - not a
    // FormatException that would read as a transport error.
    final text = utf8.decode(builder.takeBytes(), allowMalformed: true);
    if (!ManifestReferenceWalker.looksLikeManifest(text)) {
      throw MediaExtractionException(
        'PARSE_ERROR',
        'Refusing this manifest: what $target returned is not a playlist at all (no #EXTM3U and no DASH '
            '<MPD> root) - it is an error page, a login wall, or an interstitial. Treating it as an empty '
            'manifest would silently pass a scan that checked nothing.',
      );
    }
    return (text: text, effectiveUri: effectiveUri);
  }
}

class _PendingPlaylist {
  final Uri uri;
  final int depth;
  const _PendingPlaylist(this.uri, this.depth);
}
