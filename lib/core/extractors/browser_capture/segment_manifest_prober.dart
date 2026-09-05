import 'dart:io';

import '../../net/host_policy.dart';
import 'captured_media_classifier.dart';

/// Recovers a page's HLS/DASH manifest URL when a headless capture only
/// ever observed the manifest's own segment/fragment requests
/// (`.m4s`/`.ts`/`seg-*.mp4`, none of which [CapturedMediaClassifier] ever
/// turns into a whole-file candidate on their own) - see
/// `docs/plan-phase5-coverage.md` Lane A #4. A player can resolve its
/// manifest through a code path CDP never surfaces a `Network.*` event
/// for at all (fetched inside a Worklet, or served from a warm service
/// worker cache), yet the segments it already resolved to are still
/// visible, and their CDN almost always serves the manifest from the
/// exact same directory under one of a small handful of conventional
/// names.
class SegmentManifestProber {
  final HttpClient Function() _httpClientFactory;

  /// Test-only escape hatch for the SSRF guard, mirroring
  /// `CapturedFormatBuilder.allowPrivateHosts` - exempts only the exact
  /// URL a test points this at, never a redirect target. Production code
  /// must never set this to true.
  final bool allowPrivateHosts;

  SegmentManifestProber({HttpClient Function()? httpClientFactory, this.allowPrivateHosts = false})
      : _httpClientFactory = httpClientFactory ?? HttpClient.new;

  static const List<String> _manifestNames = [
    'master.m3u8',
    'playlist.m3u8',
    'index.m3u8',
    'manifest.mpd',
    // Round 5 (real-download-gate regression): observed alongside
    // manifest.mpd on some CDNs, never tried before this round.
    'stream.mpd',
  ];

  /// Hard cap on distinct directories [recoverFirst] will ever probe.
  /// Without one, a page with many quality/CDN directories (observed live:
  /// Bilibili, dozens of distinct segment paths across renditions) turns
  /// this into `directories x 4 names` HTTP round trips, each a fresh TLS
  /// handshake to a host that may not even exist - easily the dominant
  /// cost of an entire capture attempt. See [_probeTimeout] for the other
  /// half of the worst-case bound.
  static const int _maxDirectoriesToTry = 4;

  /// Per-probe timeout: an unresponsive (not merely erroring) host must
  /// not be allowed to hang [probe] indefinitely - `HttpClient`'s own
  /// default connection timeout is unbounded.
  static const Duration _probeTimeout = Duration(seconds: 4);

  /// Forwards to [CapturedMediaClassifier.isSegmentUrl] - the single
  /// canonical "is this a fragment, not a whole file" detector as of
  /// round 5, shared with [CapturedMediaClassifier.classify] and
  /// [CapturedMediaClassifier.classifyByUrlOnly] so a URL can never be
  /// tracked as a downloadable candidate by one of those and *also* as a
  /// segment here (or vice versa) - kept as its own named method (rather
  /// than inlining the call at every existing call site) purely so this
  /// file's own doc comments and tests can keep referring to "a segment
  /// URL" in this file's own vocabulary.
  static bool looksLikeSegmentUrl(String url) => CapturedMediaClassifier.isSegmentUrl(url);

  /// [url]'s own directory, query string dropped (a manifest lives
  /// beside its segments, never behind the same signed query a segment
  /// itself might carry) - null if [url] cannot be parsed at all.
  ///
  /// Always includes a trailing slash when there is a directory at all
  /// (guard-can-fail: see `segment_manifest_prober_test.dart` "recovers
  /// the first conventional manifest name that answers 200" - drop the
  /// trailing `''` path segment below and a segment at `.../hls/720p/
  /// seg-000.ts` starts probing `.../hls/master.m3u8` instead, one
  /// directory level too high). Per RFC 3986 5.3, resolving a relative
  /// reference against a base whose path has no trailing slash treats the
  /// base's last segment as a file name and discards it; without the
  /// trailing slash here, [probe]'s later `directoryUri.resolve(name)`
  /// would silently do exactly that.
  static String? directoryOf(String url) {
    try {
      final parsed = Uri.parse(url);
      final dirSegments =
          parsed.pathSegments.isEmpty ? const <String>[] : parsed.pathSegments.sublist(0, parsed.pathSegments.length - 1);
      final resolvableSegments = dirSegments.isEmpty ? dirSegments : [...dirSegments, ''];
      return Uri(
        scheme: parsed.scheme,
        userInfo: parsed.userInfo.isEmpty ? null : parsed.userInfo,
        host: parsed.host.isEmpty ? null : parsed.host,
        port: parsed.hasPort ? parsed.port : null,
        pathSegments: resolvableSegments,
      ).toString();
    } catch (_) {
      return null;
    }
  }

  /// Tries every conventional manifest filename in [segmentUrl]'s own
  /// directory (HEAD, so a wrong guess costs one round trip and no
  /// body), returning the first that answers `200`, or null if none does
  /// - including when [segmentUrl] cannot be parsed, or every guess is
  /// blocked by [HostPolicy] (guard-can-fail: see
  /// `segment_manifest_prober_test.dart` "never sends a request for a
  /// directory that resolves to a disallowed host").
  Future<CapturedMediaCandidate?> probe(String segmentUrl, Map<String, String> headers) async {
    final directory = directoryOf(segmentUrl);
    if (directory == null) return null;
    final directoryUri = Uri.parse(directory);

    for (final name in [..._manifestNames, ..._basenameManifestGuesses(segmentUrl)]) {
      final candidateUrl = directoryUri.resolve(name);
      if (!allowPrivateHosts && HostPolicy.isDisallowedHost(candidateUrl)) continue;

      final client = _httpClientFactory();
      try {
        final response = await HostPolicy.guardedRequest(
          client,
          candidateUrl,
          useHead: true,
          allowPrivateHosts: allowPrivateHosts,
          configureRequest: (request) => headers.forEach(request.headers.set),
        ).timeout(_probeTimeout);
        await response.drain<void>().timeout(_probeTimeout);
        if (response.statusCode == 200) {
          final container = name.endsWith('.mpd') ? 'mpd' : 'm3u8';
          return CapturedMediaCandidate(url: candidateUrl.toString(), container: container);
        }
      } catch (_) {
        // Try the next conventional name; a network error or a
        // HostPolicy rejection on a redirect hop is not fatal to the
        // remaining guesses.
      } finally {
        client.close(force: true);
      }
    }
    return null;
  }

  /// Round 5 (real-download-gate regression): a `master.m3u8`-shaped guess
  /// only ever tries a fixed handful of names an operator invented, but
  /// some CDNs name a segment's own sibling manifest after the segment's
  /// own base filename instead (e.g. `01.cmfv` beside `01.m3u8`, or an
  /// `init.mp4` beside `init.m3u8`) - two extra, cheap guesses derived
  /// from [segmentUrl] itself rather than a fixed vocabulary. Returns an
  /// empty list (not a throw) for anything unparseable or with no
  /// filename at all.
  static List<String> _basenameManifestGuesses(String segmentUrl) {
    try {
      final uri = Uri.parse(segmentUrl);
      if (uri.pathSegments.isEmpty) return const [];
      final last = uri.pathSegments.last;
      final dot = last.lastIndexOf('.');
      final base = dot > 0 ? last.substring(0, dot) : last;
      if (base.isEmpty) return const [];
      return ['$base.m3u8', '$base.mpd'];
    } catch (_) {
      return const [];
    }
  }

  /// Probes distinct directories represented in [segmentUrls] (in
  /// iteration order, deduped so sibling segments from the same stream
  /// only cost one round trip of guesses each, capped at
  /// [_maxDirectoriesToTry]), returning the first recovered manifest, or
  /// null if none of them yielded one.
  ///
  /// Snapshots [segmentUrls] into a fixed list before iterating (guard can
  /// fail: `BrowserCaptureExtractor` calls this with its own running,
  /// still-`add`-ing-to `Set` - a real page keeps firing
  /// `Network.responseReceived`/`requestWillBeSent` on the very same event
  /// loop this method's own `await`s yield to, so iterating that Set
  /// directly throws `ConcurrentModificationError` the instant a new
  /// segment URL arrives mid-probe; observed live on Bilibili, see
  /// docs/plan-phase5-coverage.md). `ConcurrentModificationError` is a
  /// Dart `Error`, not an `Exception` - it would have skipped every
  /// `on Exception` handler between here and the extractor's own caller
  /// entirely, surfacing as a raw crash instead of a clean
  /// `NO_MEDIA_FOUND`.
  Future<CapturedMediaCandidate?> recoverFirst(Iterable<String> segmentUrls, Map<String, String> headers) async {
    final snapshot = segmentUrls.toList(growable: false);
    final triedDirectories = <String>{};
    for (final segmentUrl in snapshot) {
      if (triedDirectories.length >= _maxDirectoriesToTry) break;
      final directory = directoryOf(segmentUrl);
      if (directory == null || !triedDirectories.add(directory)) continue;
      final recovered = await probe(segmentUrl, headers);
      if (recovered != null) return recovered;
    }
    return null;
  }
}
