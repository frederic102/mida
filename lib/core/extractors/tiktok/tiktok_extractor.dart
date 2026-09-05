import 'dart:convert';
import 'dart:io';

import '../../net/retry_policy.dart';
import '../../utils/url_parser.dart';
import '../media_extractor.dart';
import '../media_models.dart';
import 'tiktok_challenge_solver.dart';
import 'tiktok_page_parser.dart';

/// Native TikTok extractor.
///
/// TikTok's own video page is unauthenticated but gated behind a
/// client-side proof-of-work interstitial ("wafchallenge") that most
/// requests get served on the first hit. This extractor requests the page,
/// solves that challenge when present with [TikTokChallengeSolver], and
/// re-requests with the resulting cookies to get the real
/// `__UNIVERSAL_DATA_FOR_REHYDRATION__` payload [TikTokPageParser] reads the
/// video renditions out of. Verified live 2026-09-05
/// (`docs/plan-phase2-extractors.md` TikTok section; reference spike:
/// `docs/spikes/tiktok_pow_spike.dart`).
class TikTokExtractor implements MediaExtractor {
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  static const _antiBotShellMessage =
      'TikTok served a heavier interstitial page instead of its usual '
      'anti-bot challenge, which happens when this network is being '
      'rate-limited. Wait a moment and try again.';

  /// Matches `/@<user>/video/<id>` or `/@<user>/photo/<id>` on a resolved
  /// (non-shortlink) TikTok URL. Group 2 distinguishes the two post types;
  /// group 3 is the numeric id.
  static final RegExp _canonicalPathPattern = RegExp(r'^/@([^/]+)/(video|photo)/(\d+)');

  final HttpClient Function() _httpClientFactory;
  final TikTokPageParser _parser;

  /// Rewrites the URL each actual network request is sent to, independent
  /// of the canonical TikTok URL carried through the resolve/parse logic
  /// and reported as [MediaInfo.sourceUrl]. Identity by default; tests
  /// override it to redirect every hop at a local `HttpServer` instead of
  /// the real `tiktok.com` (same seam idea as `TwitterExtractor`'s
  /// `endpointBuilder`, just path-preserving instead of query-building
  /// since TikTok's own page URL *is* the request URL).
  final Uri Function(Uri url) _requestUrlBuilder;

  /// Backs off and retries the page-fetch-and-solve sequence
  /// ([_fetchAndParse]) when it fails with `RATE_LIMITED`/`NETWORK` (the
  /// WAF interstitial, an HTTP 429, or a 5xx), per
  /// `docs/plan-phase4-cookies-resilience.md` section 3. Injectable so
  /// tests can supply an instant `sleeper` (never a real 1-8s wait) and/or
  /// a smaller `maxAttempts`; production leaves the default (real backoff,
  /// 4 attempts).
  final RetryPolicy _retryPolicy;

  /// Fires with a short human-readable line right before each backoff
  /// sleep (e.g. "Retrying (rate limited by the site)..."), mirroring the
  /// `onStatus` shape `MediaDownloadPipeline.download` already uses.
  /// `TikTokExtractor.extract`'s signature is fixed by the shared
  /// [MediaExtractor] contract (every extractor implements the same
  /// `extract(Uri url)`, with no onStatus parameter), so this is a
  /// constructor-level hook instead: a caller that wants status lines
  /// during extraction (not just during download) constructs its own
  /// [TikTokExtractor] with one, rather than the registry needing to know
  /// about it.
  final void Function(String message)? onStatus;

  TikTokExtractor({
    HttpClient Function()? httpClientFactory,
    TikTokPageParser? parser,
    Uri Function(Uri url)? requestUrlBuilder,
    RetryPolicy? retryPolicy,
    this.onStatus,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _parser = parser ?? const TikTokPageParser(),
        _requestUrlBuilder = requestUrlBuilder ?? _identityUrl,
        _retryPolicy = retryPolicy ?? RetryPolicy();

  static Uri _identityUrl(Uri url) => url;

  @override
  bool canHandle(Uri url) => UrlParser.detectPlatform(url.toString()) == PlatformType.tiktok;

  @override
  Future<MediaInfo> extract(Uri url) async {
    if (!canHandle(url)) {
      throw MediaExtractionException('UNSUPPORTED_URL', 'Not a recognizable TikTok URL: $url');
    }

    final httpClient = _httpClientFactory();
    try {
      final resolved = await _resolveCanonicalUrl(httpClient, url);
      final canonical = _canonicalPathPattern.firstMatch(resolved.path);
      if (canonical == null) {
        throw MediaExtractionException(
          'UNSUPPORTED_URL',
          'Could not find a TikTok video id in $resolved.',
        );
      }
      if (canonical.group(2) == 'photo') {
        throw const MediaExtractionException(
          'UNSUPPORTED_MEDIA',
          'This is a TikTok photo post, which MiDa does not support yet.',
        );
      }

      // Only the fetch-and-solve sequence is retried, not the shortlink
      // resolution or the photo-post check above: those either need no
      // network call at all or fail with a status (UNSUPPORTED_URL/
      // UNSUPPORTED_MEDIA) `RetryPolicy`'s default classification already
      // treats as terminal, so wrapping them would be a no-op at best.
      return await _retryPolicy.run(
        () => _fetchAndParse(httpClient, resolved),
        onRetry: (attempt, error) => onStatus?.call('Retrying (rate limited by the site)...'),
      );
    } finally {
      httpClient.close(force: true);
    }
  }

  /// One full attempt at getting the video page and parsing it: fetch,
  /// solve the PoW challenge if present, re-fetch with the solved cookie,
  /// parse. Throws `RATE_LIMITED` for the WAF interstitial (either the
  /// escalated ~44KB shell, or a plain HTTP 429) and `NETWORK` for a 5xx -
  /// both of which `RetryPolicy`'s default classification retries - and
  /// `CHALLENGE_FAILED`/`NOT_FOUND`/`UNSUPPORTED_MEDIA` for outcomes a
  /// retry cannot fix, which it does not retry. Called fresh (new cookie
  /// jar) on every [_retryPolicy] attempt in [extract].
  Future<MediaInfo> _fetchAndParse(HttpClient httpClient, Uri resolved) async {
    final cookieJar = <String, String>{};
    var (statusCode, html) = await _getPage(httpClient, resolved, cookieJar);
    _checkPageStatus(statusCode);

    if (!TikTokPageParser.hasUniversalData(html)) {
      var challenge = TikTokChallengeSolver.parse(html);
      if (challenge == null) {
        throw const MediaExtractionException(
          'RATE_LIMITED',
          _antiBotShellMessage,
        );
      }
      final solvedIndex = TikTokChallengeSolver.solve(challenge);
      cookieJar.addAll(TikTokChallengeSolver.buildCookies(challenge, solvedIndex));

      (statusCode, html) = await _getPage(httpClient, resolved, cookieJar);
      _checkPageStatus(statusCode);
      if (!TikTokPageParser.hasUniversalData(html)) {
        challenge = TikTokChallengeSolver.parse(html);
        if (challenge == null) {
          // Neither `id="cs"` nor the rehydration payload this time
          // either: TikTok swapped the usual ~1.4KB PoW challenge for a
          // heavier (~44KB) interstitial that needs a real browser
          // session to clear, observed live 2026-09-05 after repeated
          // automated requests from the same network. That is an
          // anti-bot escalation, not "the solved answer was wrong", so
          // it gets the same code the statusCode-10204 IP-block path
          // uses (RATE_LIMITED), which is what lets [_retryPolicy] back
          // off and retry, and - if every attempt exhausts - lets the
          // registry fall through to a browser-based extractor instead of
          // giving up.
          throw const MediaExtractionException(
            'RATE_LIMITED',
            _antiBotShellMessage,
          );
        }
        throw const MediaExtractionException(
          'CHALLENGE_FAILED',
          'TikTok rejected the solved challenge.',
        );
      }
    }

    final requestHeaders = <String, String>{
      'User-Agent': _userAgent,
      'Referer': 'https://www.tiktok.com/',
      if (cookieJar.isNotEmpty) 'Cookie': _cookieHeader(cookieJar),
    };

    return _parser.parse(html, sourceUrl: resolved, requestHeaders: requestHeaders);
  }

  /// Follows shortlink redirects (`vm.tiktok.com/<code>`,
  /// `tiktok.com/t/<code>`) up to 5 hops until the path matches the
  /// canonical `/@user/video|photo/id` shape, or gives up and returns
  /// whatever the last hop resolved to (letting the caller surface
  /// `UNSUPPORTED_URL` for a shape it does not recognize). Already-canonical
  /// URLs return immediately without any network call.
  Future<Uri> _resolveCanonicalUrl(HttpClient client, Uri url) async {
    var current = url;
    for (var i = 0; i < 5; i++) {
      if (_canonicalPathPattern.hasMatch(current.path)) return current;

      final request = await client.getUrl(_requestUrlBuilder(current));
      request.followRedirects = false;
      request.headers.set('User-Agent', _userAgent);
      final response = await request.close();

      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers.value('location');
        await response.drain<void>();
        if (location == null) break;
        current = current.resolve(location);
        continue;
      }
      await response.drain<void>();
      return current;
    }
    return current;
  }

  Future<(int, String)> _getPage(HttpClient client, Uri url, Map<String, String> cookies) async {
    final request = await client.getUrl(_requestUrlBuilder(url));
    request.headers.set('User-Agent', _userAgent);
    request.headers.set('Accept', 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8');
    request.headers.set('Accept-Language', 'en-US,en;q=0.9');
    if (cookies.isNotEmpty) {
      request.headers.set('Cookie', _cookieHeader(cookies));
    }
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    for (final cookie in response.cookies) {
      cookies[cookie.name] = cookie.value;
    }
    return (response.statusCode, body);
  }

  String _cookieHeader(Map<String, String> cookies) =>
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  void _checkPageStatus(int statusCode) {
    if (statusCode == 404) {
      throw const MediaExtractionException(
        'NOT_FOUND',
        'This TikTok video no longer exists or the link is wrong.',
      );
    }
    if (statusCode == 429) {
      throw const MediaExtractionException(
        'RATE_LIMITED',
        'TikTok is throttling this request. Wait a moment and try again.',
      );
    }
    if (statusCode >= 500) {
      throw MediaExtractionException('NETWORK', 'TikTok returned HTTP $statusCode for this page.');
    }
  }
}
