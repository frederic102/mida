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

  /// Matches a `.m4s`/`.ts` fragment, or a `seg-`/`seg_`-prefixed
  /// `.mp4` chunk (a common CDN naming convention for fragmented MP4
  /// segments that would otherwise satisfy [CapturedMediaClassifier]'s
  /// plain `.mp4` check and get misread as a whole downloadable file).
  static final RegExp _segmentPattern = RegExp(
    r'(?:^|/)seg[-_][^/?#]*\.mp4(?:[?#]|$)|\.(?:m4s|ts)(?:[?#]|$)',
    caseSensitive: false,
  );

  static const List<String> _manifestNames = ['master.m3u8', 'playlist.m3u8', 'index.m3u8', 'manifest.mpd'];

  static bool looksLikeSegmentUrl(String url) => _segmentPattern.hasMatch(url);

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

    for (final name in _manifestNames) {
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
        );
        await response.drain<void>();
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

  /// Probes every distinct directory represented in [segmentUrls] (in
  /// iteration order, deduped so sibling segments from the same stream
  /// only cost one round trip of guesses each), returning the first
  /// recovered manifest, or null if none of them yielded one.
  Future<CapturedMediaCandidate?> recoverFirst(Iterable<String> segmentUrls, Map<String, String> headers) async {
    final triedDirectories = <String>{};
    for (final segmentUrl in segmentUrls) {
      final directory = directoryOf(segmentUrl);
      if (directory == null || !triedDirectories.add(directory)) continue;
      final recovered = await probe(segmentUrl, headers);
      if (recovered != null) return recovered;
    }
    return null;
  }
}
