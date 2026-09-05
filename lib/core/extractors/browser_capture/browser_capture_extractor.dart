import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../services/browser_devtools_session.dart';
import '../../services/cdp_client.dart';
import '../generic/html_media_sniffer.dart';
import '../media_extractor.dart';
import '../media_models.dart';
import 'captured_format_builder.dart';
import 'captured_media_classifier.dart';
import '../../net/host_policy.dart';
import 'page_status_detector.dart';

/// Last-resort extractor: drives a real headless browser and records
/// whatever media URLs the page itself requests, per
/// `docs/plan-browser-capture.md`. Meant to sit behind every platform
/// extractor and the generic (DOM-sniffing) extractor in
/// `ExtractorRegistry` - it is slow (seconds, not milliseconds) and only
/// worth paying for once cheaper detection has already failed.
class BrowserCaptureExtractor implements MediaExtractor {
  /// Test-only override (tests own their own launch behavior entirely,
  /// including whatever login-session shape they want). Null in
  /// production, where [_launchSession] calls [BrowserDevtoolsSession.launch]
  /// directly with [useBrowserLoginSession].
  final Future<DevtoolsSession> Function({Duration connectTimeout})? _sessionLauncher;
  final CapturedFormatBuilder _formatBuilder;
  final Duration connectTimeout;
  final Duration loadTimeout;
  final Duration postLoadDelay;
  final Duration autoplayRetryDelay;

  /// When true (Settings: "Use browser login session"), the launched
  /// browser uses a staged copy of the user's real profile so the capture
  /// sees their own login (e.g. Vimeo's plaintext HLS, Instagram's
  /// audio-bearing rendition). Ignored when [sessionLauncher] is supplied
  /// (tests own their own launch behavior). Default false: byte-identical
  /// to today. See `docs/plan-phase4-cookies-resilience.md` SCOPE 1-2.
  final bool useBrowserLoginSession;

  BrowserCaptureExtractor({
    Future<DevtoolsSession> Function({Duration connectTimeout})? sessionLauncher,
    HttpClient Function()? httpClientFactory,
    this.connectTimeout = const Duration(seconds: 10),
    this.loadTimeout = const Duration(seconds: 20),
    this.postLoadDelay = const Duration(seconds: 3),
    this.autoplayRetryDelay = const Duration(seconds: 5),
    this.useBrowserLoginSession = false,
  })  : _sessionLauncher = sessionLauncher,
        _formatBuilder = CapturedFormatBuilder(httpClientFactory: httpClientFactory);

  @override
  bool canHandle(Uri url) => url.scheme == 'http' || url.scheme == 'https';

  /// Production default (no [_sessionLauncher] injected) launches directly
  /// with [useBrowserLoginSession] threaded through, rather than closing
  /// over it in a stored function literal (a function literal cannot
  /// itself declare an optional parameter's default value in Dart, which
  /// the `{Duration connectTimeout}` shape here would otherwise need).
  Future<DevtoolsSession> _launchSession({required Duration connectTimeout}) {
    final launcher = _sessionLauncher;
    if (launcher != null) return launcher(connectTimeout: connectTimeout);
    return BrowserDevtoolsSession.launch(
      connectTimeout: connectTimeout,
      useBrowserLoginSession: useBrowserLoginSession,
    );
  }

  @override
  Future<MediaInfo> extract(Uri url) async {
    HostPolicy.assertAllowedHost(url, context: 'this page');
    final session = await _launchSession(connectTimeout: connectTimeout);
    try {
      return await _captureWith(session, url);
    } finally {
      await session.close();
    }
  }

  Future<MediaInfo> _captureWith(DevtoolsSession session, Uri url) async {
    final candidates = <String, CapturedMediaCandidate>{};
    int? mainDocumentStatus;

    final subscription = session.events.listen((event) {
      _observe(event, candidates);
      mainDocumentStatus ??= _mainDocumentStatus(event);
    });
    try {
      await session.send('Page.navigate', {'url': url.toString()});
      await _waitForLoad(session);
      await Future<void>.delayed(postLoadDelay);

      if (candidates.isEmpty) {
        await _tryAutoplay(session);
        await Future<void>.delayed(autoplayRetryDelay);
      }

      final domVideoUrls = await _domVideoElementUrls(session);
      var finalCandidates = CapturedMediaRanker.rank(candidates.values.toList(growable: false), domVideoUrls);

      HtmlSniffResult? domFallback;
      if (finalCandidates.isEmpty) {
        final outerHtml = await _evalString(session, 'document.documentElement.outerHTML');
        if (outerHtml != null) {
          domFallback = HtmlMediaSniffer.sniff(outerHtml, url);
          finalCandidates = [
            for (final media in domFallback.mediaUrls) CapturedMediaCandidate(url: media.url, container: media.container),
          ];
        }
      }

      if (finalCandidates.isEmpty) {
        throw await _noMediaException(session, url, domFallback, mainDocumentStatus);
      }

      // Reject before doing anything further with these URLs (our own
      // m3u8 GET below, or handing them back to the caller at all): a
      // page could otherwise get a capture pass to "discover" (and this
      // app to later fetch) an internal/private network address.
      for (final candidate in finalCandidates) {
        final candidateUrl = Uri.tryParse(candidate.url);
        if (candidateUrl != null) HostPolicy.assertAllowedHost(candidateUrl, context: 'a captured media URL');
      }

      final meta = await _pageMeta(session);
      final title = _titleFromMeta(meta) ?? domFallback?.title;
      final thumbnailUrl = _thumbnailFromMeta(meta) ?? domFallback?.thumbnailUrl;
      final userAgent = await _userAgent(session);
      final cookieHeader = await _cookieHeader(session, url, finalCandidates);

      final requestHeaders = <String, String>{
        'User-Agent': userAgent,
        'Referer': url.toString(),
        if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
      };

      final formats = <MediaFormat>[];
      for (final candidate in finalCandidates) {
        formats.addAll(await _formatBuilder.expandFormats(candidate, requestHeaders));
      }

      return MediaInfo(
        id: _idFromUrl(url),
        title: title ?? _lastSegmentOrUrl(url),
        thumbnailUrl: thumbnailUrl,
        sourceUrl: url,
        formats: formats,
        requestHeaders: requestHeaders,
      );
    } finally {
      await subscription.cancel();
    }
  }

  void _observe(CdpEvent event, Map<String, CapturedMediaCandidate> candidates) {
    if (event.method != 'Network.responseReceived') return;
    final response = event.params['response'];
    if (response is! Map) return;
    final responseUrl = response['url'];
    if (responseUrl is! String) return;
    final mimeType = response['mimeType'] as String?;

    final classified = CapturedMediaClassifier.classify(responseUrl, mimeType);
    if (classified == null) return;

    final contentLength = _parseContentLength(response['headers']);
    final key = CapturedMediaClassifier.dedupeKey(classified.url);
    final existing = candidates[key];
    candidates[key] = existing == null
        ? classified.copyWith(contentLength: contentLength, mimeType: mimeType)
        : existing.copyWith(
            // Prefer the largest content-length seen across every
            // request for this URL (a Range-fragmented request's
            // Content-Length is only that fragment's size, not the whole
            // file's), and keep whichever mimeType we saw first.
            contentLength: (contentLength != null && (existing.contentLength == null || contentLength > existing.contentLength!))
                ? contentLength
                : existing.contentLength,
            mimeType: existing.mimeType ?? mimeType,
          );
  }

  int? _parseContentLength(dynamic headers) {
    if (headers is! Map) return null;
    for (final entry in headers.entries) {
      if (entry.key.toString().toLowerCase() == 'content-length') {
        return int.tryParse(entry.value.toString());
      }
    }
    return null;
  }

  /// The HTTP status of the page's own top-level HTML document (the
  /// first `text/html` response seen), used to distinguish a genuine
  /// `NOT_FOUND` from an SPA shell that always returns 200 regardless of
  /// what it then renders.
  int? _mainDocumentStatus(CdpEvent event) {
    if (event.method != 'Network.responseReceived') return null;
    final response = event.params['response'];
    if (response is! Map) return null;
    final mimeType = response['mimeType'] as String?;
    if (mimeType == null || !mimeType.toLowerCase().startsWith('text/html')) return null;
    return response['status'] as int?;
  }

  Future<MediaExtractionException> _noMediaException(
    DevtoolsSession session,
    Uri sourceUrl,
    HtmlSniffResult? domFallback,
    int? mainDocumentStatus,
  ) async {
    final meta = await _pageMeta(session);
    final finalUrl = Uri.tryParse((meta?['href'] as String?) ?? '') ?? sourceUrl;
    final title = _titleFromMeta(meta) ?? domFallback?.title;
    final signal = PageStatusDetector.detect(finalUrl: finalUrl, title: title, mainDocumentStatusCode: mainDocumentStatus);

    switch (signal) {
      case PageStatusSignal.loginRequired:
        return const MediaExtractionException(
          'LOGIN_REQUIRED',
          'This post needs a signed-in session to view. Browser network '
              'capture cannot log in on your behalf; sign in to this site '
              'in your regular browser and try a different post, or ask '
              'the poster for a direct link.',
        );
      case PageStatusSignal.notFound:
        return const MediaExtractionException(
          'NOT_FOUND',
          'This page returned Not Found. The video may have been removed, '
              'or the URL may be incorrect. Check the link and try again.',
        );
      case null:
        return const MediaExtractionException(
          'NO_MEDIA_FOUND',
          'The headless browser did not observe any media requests while '
              'loading this page. The page may require login, or the '
              'content may be private or removed.',
        );
    }
  }

  Future<void> _waitForLoad(DevtoolsSession session) async {
    final loadCompleter = Completer<void>();
    final loadSub = session.events.listen((event) {
      if (event.method == 'Page.loadEventFired' && !loadCompleter.isCompleted) {
        loadCompleter.complete();
      }
    });
    try {
      await loadCompleter.future.timeout(loadTimeout, onTimeout: () {});
    } finally {
      await loadSub.cancel();
    }
  }

  Future<void> _tryAutoplay(DevtoolsSession session) async {
    try {
      await session.send('Runtime.evaluate', const {
        'expression': "document.querySelector('video') && document.querySelector('video').play()",
      });
    } catch (_) {
      // Best-effort nudge; a page with no <video> element (or one that
      // rejects programmatic play) should not abort the capture.
    }
  }

  static const String _videoElementUrlsExpression = '''
JSON.stringify(
  Array.from(document.querySelectorAll('video')).flatMap(function (v) {
    var urls = [v.currentSrc || v.src || null];
    Array.from(v.querySelectorAll('source')).forEach(function (s) { urls.push(s.src || null); });
    return urls;
  }).filter(function (u) { return u && u.indexOf('blob:') !== 0; })
)
''';

  /// The URLs the live DOM's own `<video>`/`<source>` elements are
  /// actually pointed at right now (`blob:` excluded) - see
  /// [CapturedMediaRanker] for why this outranks a same-shaped but
  /// unrelated network response.
  Future<List<String>> _domVideoElementUrls(DevtoolsSession session) async {
    final raw = await _evalString(session, _videoElementUrlsExpression);
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded.whereType<String>().toList();
    } catch (_) {
      return const [];
    }
  }

  Future<String?> _evalString(DevtoolsSession session, String expression) async {
    try {
      final result = await session.send('Runtime.evaluate', {
        'expression': expression,
        'returnByValue': true,
      });
      final value = (result['result'] as Map?)?['value'];
      return value is String ? value : null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _evalJson(DevtoolsSession session, String jsonExpression) async {
    final raw = await _evalString(session, jsonExpression);
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  static const String _metaExpression = '''
JSON.stringify({
  title: document.title || null,
  ogTitle: (document.querySelector('meta[property="og:title"]') || {}).content || null,
  ogImage: (document.querySelector('meta[property="og:image"]') || {}).content || null,
  href: (typeof location !== 'undefined' && location.href) || null
})
''';

  Future<Map<String, dynamic>?> _pageMeta(DevtoolsSession session) => _evalJson(session, _metaExpression);

  String? _titleFromMeta(Map<String, dynamic>? meta) {
    final ogTitle = meta?['ogTitle'] as String?;
    final rawTitle = meta?['title'] as String?;
    if (ogTitle != null && ogTitle.isNotEmpty) return ogTitle;
    if (rawTitle != null && rawTitle.isNotEmpty) return rawTitle;
    return null;
  }

  String? _thumbnailFromMeta(Map<String, dynamic>? meta) {
    final ogImage = meta?['ogImage'] as String?;
    return (ogImage != null && ogImage.isNotEmpty) ? ogImage : null;
  }

  Future<String> _userAgent(DevtoolsSession session) async {
    try {
      final version = await session.sendBrowserLevel('Browser.getVersion');
      final userAgent = version['userAgent'] as String?;
      if (userAgent != null && userAgent.isNotEmpty) return userAgent;
    } catch (_) {
      // Fall through to the generic desktop UA below.
    }
    return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';
  }

  Future<String> _cookieHeader(DevtoolsSession session, Uri pageUrl, List<CapturedMediaCandidate> candidates) async {
    try {
      final urls = <String>{pageUrl.toString(), for (final c in candidates) c.url}.toList();
      final result = await session.send('Network.getCookies', {'urls': urls});
      final cookies = result['cookies'];
      if (cookies is! List) return '';
      return cookies
          .whereType<Map>()
          .map((c) => '${c['name']}=${c['value']}')
          .where((pair) => pair.isNotEmpty && !pair.startsWith('='))
          .join('; ');
    } catch (_) {
      return '';
    }
  }

  String _idFromUrl(Uri url) => 'browser-capture-${url.toString().hashCode.toUnsigned(31)}';

  String _lastSegmentOrUrl(Uri url) {
    final segments = url.pathSegments.where((s) => s.isNotEmpty).toList();
    return segments.isEmpty ? url.toString() : segments.last;
  }
}
