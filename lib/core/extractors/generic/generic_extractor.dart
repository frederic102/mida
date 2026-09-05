import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../media_extractor.dart';
import '../media_models.dart';
import 'embed_media_resolver.dart';
import 'format_expander.dart';
import 'generic_http.dart';
import '../../net/host_policy.dart';
import 'html_media_sniffer.dart';
import 'media_url_probe.dart';

/// Fallback extractor for any http(s) URL that no platform-native
/// extractor recognizes. Detection order (first success wins), per
/// `docs/plan-generic-extractor.md` plus the embedded-player addendum
/// (live Vimeo measurement: the page is a shell with an `<iframe>`, the
/// video is only in the embed document the iframe points at):
///
///   0. Is the URL itself media (extension, then Content-Type)?
///   1. Plain HTML GET, sniff `<video>` / og / JSON-LD / inline-script URLs.
///   1.5. Nothing found -> follow up to [IframeFollower.maxCandidates]
///        `<iframe>`/`<embed>`/`og:video:url` embed pages (one level deep),
///        GET each with `Referer: <page url>`, sniff those; only if none of
///        those yield anything, try oEmbed discovery too. Both draw from
///        one shared [NetworkBudget] (security follow-up: this step must
///        not become an unbounded number of outbound requests).
///   2. Still nothing -> `DRM_PROTECTED` if DRM markers are present (in the
///      page text, because every sniffed candidate URL was itself
///      DRM-wrapped, or because a candidate's own manifest body carried
///      DRM key material - see [FormatExpander]/`DrmPlaylistScanner`),
///      else `NO_MEDIA_FOUND`.
///
/// Rendering a page with a headless browser when static HTML/embeds yield
/// nothing used to be step 2 here; that responsibility now belongs
/// entirely to the browser-capture fallback tier (a different, more
/// capable renderer covering the same "needs real JS" gap), so this
/// extractor no longer touches `BrowserPageFetcher` at all - a page that
/// needs a real browser session now surfaces `NO_MEDIA_FOUND` straight
/// from this extractor and falls through to that tier instead.
///
/// Every network request (page GET, embed GET, playlist GET, step-0
/// probe) goes through [HostPolicy.guardedRequest], which refuses
/// loopback/private/link-local hosts, including ones a redirect chain
/// leads to (SSRF guard: a malicious page must not be able to make this
/// app reach the user's local network), and also - for a hostname that is
/// not itself a literal IP - resolves it and rejects a private/loopback
/// DNS answer (rebinding guard).
///
/// The entire static-analysis stage (everything above) runs under one
/// [_staticStageDeadline]: a pathological or very slow page must not hang
/// `extract()` indefinitely (resource-exhaustion follow-up).
///
/// `canHandle` accepts every http(s) URL, so this must be registered last
/// (Phase 2b) behind every platform-native extractor.
class GenericExtractor implements MediaExtractor {
  final HttpClient Function() _httpClientFactory;
  final MediaUrlProbe _probe;

  /// Test-only escape hatch for [HostPolicy]'s SSRF guard so tests can
  /// point this extractor straight at a local fixture `HttpServer` (a
  /// single hop, no redirect). Any redirect hop encountered mid-flight is
  /// always checked regardless of this flag. Production code must never
  /// set this to true.
  final bool allowPrivateHosts;

  /// The actual static-analysis-stage deadline this instance uses; see
  /// [_staticStageDeadline] for the production default. Overridable only
  /// so a test can prove the deadline fires (against a server that never
  /// responds) in milliseconds instead of actually waiting the real 20s
  /// out. Production code must never set this.
  final Duration _effectiveStaticStageDeadline;

  late final FormatExpander _formatExpander = FormatExpander(fetchText: _fetchWithStatus);
  late final EmbedMediaResolver _embedResolver = EmbedMediaResolver(fetchText: _fetchText);

  GenericExtractor({
    HttpClient Function()? httpClientFactory,
    MediaUrlProbe? probe,
    this.allowPrivateHosts = false,
    // Accepted for constructor-signature compatibility with
    // `buildExtractorRegistry` (which passes this through to every
    // extractor uniformly) but otherwise unused: this extractor no longer
    // drives a browser session at all (see class doc), so there is no
    // login-session mode of its own to toggle.
    bool useBrowserLoginSession = false,
    Duration? staticStageDeadlineForTesting,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _probe = probe ?? MediaUrlProbe(httpClientFactory: httpClientFactory, allowPrivateHosts: allowPrivateHosts),
        _effectiveStaticStageDeadline = staticStageDeadlineForTesting ?? _staticStageDeadline;

  static final RegExp _emePattern = RegExp(r'\bEME\b', caseSensitive: false);
  static const List<String> _drmMarkers = [
    'widevine',
    'playready',
    'fairplay',
    'encrypted-media',
    'license_url',
  ];

  /// Resource-exhaustion guard: a pathological or very slow page must not
  /// hang `extract()` indefinitely. Covers the whole static-analysis stage
  /// (page GET, embed follow, sniffing, format expansion) in one deadline
  /// rather than piecemeal per-fetch timeouts, since it is the end-to-end
  /// wall-clock budget that matters to a caller.
  static const Duration _staticStageDeadline = Duration(seconds: 20);

  /// Resource-exhaustion guard: caps how many bytes of any single fetch
  /// (page HTML, embed HTML, oEmbed JSON, HLS/DASH manifest) this
  /// extractor will buffer into memory. A multi-hundred-MB response is cut
  /// off at this point rather than read in full.
  static const int _maxBodyBytes = 5 * 1024 * 1024;

  /// Reachability-probe guard: caps how many non-context-backed candidates
  /// (see `SniffedMedia.contextBacked`) get an actual HEAD/Range network
  /// probe per `extract()` call, on top of the sniffer's own 200-candidate
  /// cap - a page with dozens of bare URL-shaped matches must not turn
  /// into dozens of extra HTTP round-trips.
  static const int _maxReachabilityProbes = 10;

  @override
  bool canHandle(Uri url) => url.scheme == 'http' || url.scheme == 'https';

  @override
  Future<MediaInfo> extract(Uri url) async {
    if (!allowPrivateHosts && HostPolicy.isDisallowedHost(url)) {
      throw MediaExtractionException(
        'UNSUPPORTED_URL',
        'Refusing to fetch $url: it resolves to a private, loopback, or link-local '
            'network address. This extractor only follows public internet hosts.',
      );
    }

    try {
      return await _extractStatic(url).timeout(_effectiveStaticStageDeadline);
    } on TimeoutException {
      throw const MediaExtractionException(
        'NO_MEDIA_FOUND',
        'Timed out looking for video on this page within the static-analysis time budget. '
            'The site may need a live browser session to load its player; try again or use '
            'the direct video URL if you have it.',
      );
    }
  }

  Future<MediaInfo> _extractStatic(Uri url) async {
    final extensionContainer = MediaUrlProbe.containerFromExtension(url);
    final directContainer = extensionContainer ?? await _probe.containerFromContentType(url);
    if (directContainer != null) {
      final expanded = await _formatExpander.expandFormats(url.toString(), directContainer);
      if (expanded.formats.isEmpty && expanded.drmDetected) {
        throw const MediaExtractionException(
          'DRM_PROTECTED',
          'This video is protected by DRM (Widevine, PlayReady, or FairPlay) and cannot be downloaded.',
        );
      }
      return MediaInfo(
        id: _idFromUrl(url),
        title: _lastSegmentOrUrl(url),
        sourceUrl: url,
        formats: _formatExpander.orderFormats(expanded.formats),
        requestHeaders: const {'User-Agent': genericDesktopUserAgent},
      );
    }

    final html = await _fetchText(url);
    final pageSniffed = HtmlMediaSniffer.sniff(html, url);
    var sniffed = pageSniffed;
    var corpusForDrmCheck = html;
    var anyDrmDropped = pageSniffed.anyDrmCandidatesDropped;
    Map<String, String> requestHeaders = const {'User-Agent': genericDesktopUserAgent};
    Map<String, String>? playlistFetchHeaders;

    if (sniffed.isEmpty) {
      final embedResult = await _embedResolver.followEmbeds(url, html);
      if (embedResult != null) {
        // Embed page's own title/thumbnail win; fall back to the outer
        // page's when the embed page didn't have one.
        sniffed = HtmlSniffResult(
          mediaUrls: embedResult.sniffed.mediaUrls,
          title: embedResult.sniffed.title ?? pageSniffed.title,
          thumbnailUrl: embedResult.sniffed.thumbnailUrl ?? pageSniffed.thumbnailUrl,
          anyDrmCandidatesDropped: embedResult.sniffed.anyDrmCandidatesDropped,
        );
        anyDrmDropped = anyDrmDropped || embedResult.sniffed.anyDrmCandidatesDropped;
        final referer = embedResult.embedUrl.toString();
        requestHeaders = {'User-Agent': genericDesktopUserAgent, 'Referer': referer};
        playlistFetchHeaders = {'Referer': referer};
      }
    }

    if (sniffed.isEmpty) {
      throw _noMediaOrDrmException(corpusForDrmCheck, anyDrmCandidatesDropped: anyDrmDropped);
    }

    // False-positive guard (security follow-up): a candidate the sniffer
    // itself vouches for (`contextBacked`) is kept unconditionally; one
    // with no context at all (found only by the raw-text catch-all, or a
    // bare URL-shaped JSON string with no player-ish metadata around it)
    // must pass a cheap reachability probe first. Context-backed
    // candidates are placed first so they rank ahead of merely-probed ones
    // (ties within a format-expansion tier are otherwise stable-ordered by
    // discovery order; see `FormatExpander.orderFormats`).
    final rankedCandidates = await _rankAndFilterCandidates(sniffed.mediaUrls);
    if (rankedCandidates.isEmpty) {
      throw _noMediaOrDrmException(corpusForDrmCheck, anyDrmCandidatesDropped: anyDrmDropped);
    }

    return _buildMediaInfo(
      url,
      HtmlSniffResult(
        mediaUrls: rankedCandidates,
        title: sniffed.title,
        thumbnailUrl: sniffed.thumbnailUrl,
        anyDrmCandidatesDropped: sniffed.anyDrmCandidatesDropped,
      ),
      requestHeaders: requestHeaders,
      playlistFetchHeaders: playlistFetchHeaders,
    );
  }

  Future<List<SniffedMedia>> _rankAndFilterCandidates(List<SniffedMedia> candidates) async {
    final contextBacked = <SniffedMedia>[];
    final bare = <SniffedMedia>[];
    for (final candidate in candidates) {
      (candidate.contextBacked ? contextBacked : bare).add(candidate);
    }

    final probed = <SniffedMedia>[];
    var probesUsed = 0;
    for (final candidate in bare) {
      if (probesUsed >= _maxReachabilityProbes) break;
      probesUsed++;
      Uri parsed;
      try {
        parsed = Uri.parse(candidate.url);
      } catch (_) {
        continue;
      }
      final passed = await _probe.isPlausibleMediaCandidate(parsed);
      if (passed) probed.add(candidate);
    }
    return [...contextBacked, ...probed];
  }

  Future<MediaInfo> _buildMediaInfo(
    Uri sourceUrl,
    HtmlSniffResult sniffed, {
    required Map<String, String> requestHeaders,
    Map<String, String>? playlistFetchHeaders,
  }) async {
    final formats = <MediaFormat>[];
    var anyManifestDrm = false;
    for (final media in sniffed.mediaUrls) {
      final expanded = await _formatExpander.expandFormats(
        media.url,
        media.container,
        extraHeaders: playlistFetchHeaders,
        width: media.width,
        height: media.height,
        bitrate: media.bitrate,
        capabilities: media.capabilities,
      );
      anyManifestDrm = anyManifestDrm || expanded.drmDetected;
      formats.addAll(expanded.formats);
    }
    if (formats.isEmpty && anyManifestDrm) {
      throw const MediaExtractionException(
        'DRM_PROTECTED',
        'This video is protected by DRM (Widevine, PlayReady, or FairPlay) and cannot be downloaded.',
      );
    }
    return MediaInfo(
      id: _idFromUrl(sourceUrl),
      title: sniffed.title ?? _lastSegmentOrUrl(sourceUrl),
      thumbnailUrl: sniffed.thumbnailUrl,
      sourceUrl: sourceUrl,
      formats: _formatExpander.orderFormats(formats),
      requestHeaders: requestHeaders,
    );
  }

  Future<String> _fetchText(Uri url, {Map<String, String>? extraHeaders}) async {
    return (await _fetchWithStatus(url, extraHeaders: extraHeaders)).body;
  }

  /// Resource-exhaustion guard: stops buffering a response body once
  /// [maxBytes] (defaulting to [_maxBodyBytes]) have been read, rather
  /// than accumulating an unbounded amount of memory for a pathologically
  /// large (or deliberately hostile) response. [FormatExpander] passes a
  /// tighter cap for its per-variant DRM-verification fetches. Breaking
  /// out of the `await for` loop cancels the underlying stream
  /// subscription; `client.close(force: true)` in the `finally` block
  /// below additionally tears down the connection regardless.
  Future<FetchedBody> _fetchWithStatus(Uri url, {Map<String, String>? extraHeaders, int? maxBytes}) async {
    final effectiveMaxBytes = maxBytes ?? _maxBodyBytes;
    final client = _httpClientFactory();
    try {
      final response = await HostPolicy.guardedRequest(
        client,
        url,
        useHead: false,
        allowPrivateHosts: allowPrivateHosts,
        configureRequest: (request) {
          request.headers.set('User-Agent', genericDesktopUserAgent);
          request.headers.set('Accept-Language', genericAcceptLanguage);
          extraHeaders?.forEach(request.headers.set);
        },
      );
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length >= effectiveMaxBytes) break;
      }
      final capped = bytes.length > effectiveMaxBytes ? bytes.sublist(0, effectiveMaxBytes) : bytes;
      String body;
      try {
        body = utf8.decode(capped);
      } on FormatException {
        body = latin1.decode(capped);
      }
      return FetchedBody(statusCode: response.statusCode, body: body);
    } finally {
      client.close(force: true);
    }
  }

  MediaExtractionException _noMediaOrDrmException(String corpus, {bool anyDrmCandidatesDropped = false}) {
    final lower = corpus.toLowerCase();
    final hasDrmMarker =
        anyDrmCandidatesDropped || _drmMarkers.any(lower.contains) || _emePattern.hasMatch(corpus);
    if (hasDrmMarker) {
      return const MediaExtractionException(
        'DRM_PROTECTED',
        'This video is protected by DRM (Widevine, PlayReady, or FairPlay) and cannot be downloaded.',
      );
    }
    return const MediaExtractionException(
      'NO_MEDIA_FOUND',
      'No video found on this page. The site may load video only after '
          'sign-in or interaction. Try the direct video URL if you have it.',
    );
  }

  String _idFromUrl(Uri url) => 'generic-${url.toString().hashCode.toUnsigned(31)}';

  String _lastSegmentOrUrl(Uri url) {
    final segments = url.pathSegments.where((s) => s.isNotEmpty).toList();
    return segments.isEmpty ? url.toString() : segments.last;
  }
}
