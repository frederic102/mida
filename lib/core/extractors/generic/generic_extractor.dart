import 'dart:async';
import 'dart:io';

import '../fallback_failure.dart';
import '../media_extractor.dart';
import '../media_models.dart';
import 'embed_media_resolver.dart';
import 'embeds/embed_delegation.dart';
import 'embeds/embed_http.dart';
import 'embeds/embed_resolver_chain.dart';
import 'format_expander.dart';
import 'generic_candidate_builder.dart';
import 'generic_http.dart';
import 'guarded_fetch.dart';
import '../../net/host_policy.dart';
import '../../utils/url_parser.dart';
import 'html_media_sniffer.dart';
import 'media_url_probe.dart';
import 'stage_deadline.dart';

/// Fallback extractor for any http(s) URL that no platform-native
/// extractor recognizes. Detection order (first success wins), per
/// `docs/plan-generic-extractor.md` plus the embedded-player addendum
/// (live Vimeo measurement: the page is a shell with an `<iframe>`, the
/// video is only in the embed document the iframe points at):
///
///   0. Is the URL itself media (extension, then Content-Type)?
///   1. Plain HTML GET, sniff `<video>` / og / JSON-LD / inline-script URLs.
///      Only candidates that survive the reachability filter count: a page
///      whose every candidate is rejected continues to the steps below.
///   1.25. A known embed platform claims the page ([EmbedResolverChain]:
///        Brightcove/Kaltura/Wistia/JW APIs, YouTube/Vimeo/Dailymotion
///        delegation) -> resolve it first, so the generic iframe follow
///        below never shadows a delegation or a platform API.
///   1.5. Nothing yet -> follow up to [IframeFollower.maxCandidates]
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
/// [StageDeadline] of [_staticStageDeadline]: a pathological or very slow
/// page must not hang `extract()` indefinitely (resource-exhaustion
/// follow-up). The deadline is a cancellation, not just a wait limit: on
/// expiry (and whenever `extract()` returns) every connection still open
/// under it is force-closed and no further request of this call starts.
///
/// `canHandle` accepts every http(s) URL, so this must be registered last
/// (Phase 2b) behind every platform-native extractor.
class GenericExtractor implements MediaExtractor {
  final HttpClient Function() _httpClientFactory;
  final Future<List<InternetAddress>> Function(String host) _resolveHost;
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

  /// Step 1.25: embed-platform families (Brightcove, Kaltura, Wistia, JW
  /// Player) via their public player APIs, plus YouTube/Vimeo/Dailymotion
  /// delegation. Runs when step 1 found nothing usable and a resolver
  /// claims the page.
  final EmbedResolverChain _embedPlatforms;

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
    // Same pass-through story as above: accepted so the registry builder
    // can hand every extractor the Phase 7 flag uniformly; this extractor
    // opens no browser (so it can never open a headed window either).
    bool forceHeadless = false,
    Duration? staticStageDeadlineForTesting,
    EmbedResolverChain? embedResolverChain,
    // DNS seam for every rebinding check (page, embeds, probe, platform
    // APIs); real lookup by default.
    Future<List<InternetAddress>> Function(String host) resolveHost = InternetAddress.lookup,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _resolveHost = resolveHost,
        _embedPlatforms = embedResolverChain ??
            EmbedResolverChain(
              http: GuardedEmbedHttp(
                httpClientFactory: httpClientFactory ?? HttpClient.new,
                allowPrivateHosts: allowPrivateHosts,
                resolveHost: resolveHost,
              ),
            ),
        _probe = probe ??
            MediaUrlProbe(
              httpClientFactory: httpClientFactory,
              allowPrivateHosts: allowPrivateHosts,
              resolveHost: resolveHost,
            ),
        _effectiveStaticStageDeadline = staticStageDeadlineForTesting ?? _staticStageDeadline;

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

  @override
  bool canHandle(Uri url) => url.scheme == 'http' || url.scheme == 'https';

  @override
  Future<MediaInfo> extract(Uri url) async {
    if (!allowPrivateHosts && HostPolicy.isDisallowedHost(url)) {
      // Host only: a refused URL's path and query can carry tokens.
      throw MediaExtractionException(
        'UNSUPPORTED_URL',
        'Refusing to fetch ${url.host}: it resolves to a private, loopback, or link-local '
            'network address. This extractor only follows public internet hosts.',
      );
    }

    final deadline = StageDeadline(_effectiveStaticStageDeadline);
    try {
      final info = await _extractStatic(url, deadline).timeout(_effectiveStaticStageDeadline);
      // A result assembled after expiry (out of failures the expiry itself
      // caused) is a timeout too, not a partial answer.
      deadline.ensureActive();
      return info;
    } on TimeoutException {
      throw const MediaExtractionException(
        'NO_MEDIA_FOUND',
        'Timed out looking for video on this page within the static-analysis time budget. '
            'The site may need a live browser session to load its player; try again or use '
            'the direct video URL if you have it.',
      );
    } on EmbedDelegationException {
      // Its message names only a canonical URL built from a validated id.
      rethrow;
    } on MediaExtractionException catch (e) {
      // Boundary sanitizing: reasons raised below (HostPolicy redirect
      // refusals, DNS failures) may interpolate full URLs; every URL in a
      // reason leaving this extractor is reduced to `scheme://host/...`.
      final reason = e.reason == null ? null : UrlParser.redactUrlsInText(e.reason!);
      // Keep the proven-offline subtype: the registry stops before a browser
      // launch only for it (`OfflineNetworkException`, fallback_failure.dart).
      if (e is OfflineNetworkException) throw OfflineNetworkException(reason ?? 'The network is unavailable.');
      throw MediaExtractionException(e.status, reason);
    } finally {
      deadline.expire();
    }
  }

  static const Map<String, String> _pageHeaders = {'User-Agent': genericDesktopUserAgent};

  Future<MediaInfo> _extractStatic(Uri url, StageDeadline deadline) async {
    Future<FetchedBody> fetch(Uri target, {Map<String, String>? extraHeaders, int? maxBytes}) =>
        _fetchWithStatus(target, deadline, extraHeaders: extraHeaders, maxBytes: maxBytes);
    final expander = FormatExpander(fetchText: fetch);
    final candidates = GenericCandidateBuilder(probe: _probe, expander: expander, deadline: deadline);

    final extensionContainer = MediaUrlProbe.containerFromExtension(url);
    final directContainer = extensionContainer ?? await _probe.containerFromContentType(url, deadline: deadline);
    if (directContainer != null) {
      final expanded = await expander.expandFormats(url.toString(), directContainer);
      if (expanded.formats.isEmpty && expanded.drmDetected) throw GenericCandidateBuilder.drmProtected;
      return MediaInfo(
        id: GenericCandidateBuilder.idFromUrl(url),
        title: GenericCandidateBuilder.lastSegmentOrUrl(url),
        sourceUrl: url,
        formats: expander.orderFormats(expanded.formats),
        requestHeaders: _pageHeaders,
      );
    }

    final html = (await fetch(url)).body;
    final pageSniffed = HtmlMediaSniffer.sniff(html, url);
    var anyDrmDropped = pageSniffed.anyDrmCandidatesDropped;

    // Step 1. Only candidates that survive the reachability filter AND
    // expand into at least one format count: a dead bare URL or a manifest
    // that fails to load must not hide a working embed further down.
    final fromPage = await candidates.buildIfUsable(url, pageSniffed, requestHeaders: _pageHeaders);
    if (fromPage != null) return fromPage;

    // Step 1.25, before the generic iframe follow, so a delegation (or a
    // platform API) is never shadowed by sniffing that player's own page.
    if (_embedPlatforms.claims(html)) {
      final platformInfo = await _embedPlatforms.resolve(pageUrl: url, html: html, deadline: deadline);
      if (platformInfo != null) return platformInfo;
    }

    // Step 1.5.
    final embeds = EmbedMediaResolver(
      fetchText: (target, {extraHeaders}) async => (await fetch(target, extraHeaders: extraHeaders)).body,
    );
    final embedResult = await embeds.followEmbeds(url, html);
    if (embedResult != null) {
      anyDrmDropped = anyDrmDropped || embedResult.sniffed.anyDrmCandidatesDropped;
      // Embed page's own title/thumbnail win; fall back to the outer
      // page's when the embed page didn't have one.
      final referer = embedResult.embedUrl.toString();
      final fromEmbed = await candidates.buildIfUsable(
        url,
        HtmlSniffResult(
          mediaUrls: embedResult.sniffed.mediaUrls,
          title: embedResult.sniffed.title ?? pageSniffed.title,
          thumbnailUrl: embedResult.sniffed.thumbnailUrl ?? pageSniffed.thumbnailUrl,
          anyDrmCandidatesDropped: embedResult.sniffed.anyDrmCandidatesDropped,
        ),
        requestHeaders: {'User-Agent': genericDesktopUserAgent, 'Referer': referer},
        playlistFetchHeaders: {'Referer': referer},
      );
      if (fromEmbed != null) return fromEmbed;
    }

    throw candidates.noMediaOrDrm(html, anyDrmCandidatesDropped: anyDrmDropped);
  }

  /// One guarded GET of this call ([guardedBoundedGet]): at most [maxBytes]
  /// (defaulting to [_maxBodyBytes]; [FormatExpander] passes a tighter cap
  /// for its per-variant DRM-verification fetches), bounded by [deadline].
  Future<FetchedBody> _fetchWithStatus(
    Uri url,
    StageDeadline deadline, {
    Map<String, String>? extraHeaders,
    int? maxBytes,
  }) =>
      guardedBoundedGet(
        _httpClientFactory,
        url,
        maxBytes: maxBytes ?? _maxBodyBytes,
        allowPrivateHosts: allowPrivateHosts,
        deadline: deadline,
        resolveHost: _resolveHost,
        configureRequest: (request) {
          request.headers.set('User-Agent', genericDesktopUserAgent);
          request.headers.set('Accept-Language', genericAcceptLanguage);
          extraHeaders?.forEach(request.headers.set);
        },
      );
}
