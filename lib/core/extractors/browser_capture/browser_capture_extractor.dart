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
import 'capture_attempt.dart';
import 'capture_drive_loop.dart';
import 'main_document_status_tracker.dart';
import 'network_signal_recorder.dart';
import 'page_load_waiter.dart';
import 'page_meta_reader.dart';
import 'page_status_detector.dart';
import 'page_status_exceptions.dart';
import 'private_destination_guard.dart';
import 'segment_manifest_prober.dart';
import 'session_request_context.dart';

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
  final SegmentManifestProber _segmentProber;
  final Duration connectTimeout;
  final Duration loadTimeout;

  /// How long to wait after `Page.loadEventFired` before the first
  /// [PlaybackTrigger] attempt - many sites already start playback on
  /// their own well within this window.
  final Duration postLoadDelay;

  /// How long to wait, after the first [PlaybackTrigger] attempt, before
  /// checking whether it produced a candidate and (if not) moving on to
  /// [_driveCapture]'s bounded poll - see [CaptureDriveLoop.run].
  final Duration autoplayRetryDelay;

  /// Max total time to poll for a first media candidate after
  /// [postLoadDelay] (docs/plan-phase5-coverage.md Lane A #2: "0개면
  /// 최대 25초까지 폴링"). A second [PlaybackTrigger] attempt fires at the
  /// halfway point of this window - see [_driveCapture].
  final Duration firstCandidateTimeout;

  /// Once a first candidate exists, how much longer to keep collecting
  /// (sibling-quality variants of the same stream usually arrive within a
  /// second or two of each other).
  final Duration variantSettleDelay;

  /// How often [_driveCapture]'s poll loop re-checks for a first
  /// candidate while waiting up to [firstCandidateTimeout].
  final Duration pollInterval;

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
    this.firstCandidateTimeout = const Duration(seconds: 25),
    this.variantSettleDelay = const Duration(seconds: 3),
    this.pollInterval = const Duration(seconds: 1),
    this.useBrowserLoginSession = false,
  })  : _sessionLauncher = sessionLauncher,
        _formatBuilder = CapturedFormatBuilder(httpClientFactory: httpClientFactory),
        _segmentProber = SegmentManifestProber(httpClientFactory: httpClientFactory);

  @override
  bool canHandle(Uri url) => url.scheme == 'http' || url.scheme == 'https';

  /// Production default (no [_sessionLauncher] injected) launches directly
  /// with [useBrowserLoginSession] and [preferHeaded] threaded through,
  /// rather than closing over them in a stored function literal (a
  /// function literal cannot itself declare an optional parameter's
  /// default value in Dart, which the `{Duration connectTimeout}` shape
  /// here would otherwise need). A test-injected [_sessionLauncher] never
  /// sees [preferHeaded] at all - it has no headed/headless concept, and
  /// [_attemptCapture]'s retry decision does not depend on it knowing.
  Future<DevtoolsSession> _launchSession({required Duration connectTimeout, required bool preferHeaded}) {
    final launcher = _sessionLauncher;
    if (launcher != null) return launcher(connectTimeout: connectTimeout);
    return BrowserDevtoolsSession.launch(
      connectTimeout: connectTimeout,
      useBrowserLoginSession: useBrowserLoginSession,
      preferHeaded: preferHeaded,
    );
  }

  @override
  Future<MediaInfo> extract(Uri url) async {
    HostPolicy.assertAllowedHost(url, context: 'this page');
    final first = await _attemptCapture(url, preferHeaded: true);
    if (first.info != null) return first.info!;

    if (shouldRetryHeadless(first, hasInjectedSessionLauncher: _sessionLauncher != null)) {
      final retry = await _attemptCapture(url, preferHeaded: false);
      if (retry.info != null) return retry.info!;
      throw retry.error!;
    }
    throw first.error!;
  }

  Future<CaptureAttempt> _attemptCapture(Uri url, {required bool preferHeaded}) async {
    final session = await _launchSession(connectTimeout: connectTimeout, preferHeaded: preferHeaded);
    var loadFired = false;
    try {
      final info = await _captureWith(session, url, onLoadFired: (fired) => loadFired = fired);
      return CaptureAttempt(info: info, loadFired: loadFired);
    } on MediaExtractionException catch (e) {
      return CaptureAttempt(error: e, loadFired: loadFired);
    } finally {
      await session.close();
    }
  }

  Future<MediaInfo> _captureWith(DevtoolsSession session, Uri url, {required void Function(bool) onLoadFired}) async {
    final candidates = <String, CapturedMediaCandidate>{};
    final segmentUrls = <String>{};
    final mainDocStatus = MainDocumentStatusTracker();

    final subscription = session.events.listen((event) {
      _observe(event, candidates, segmentUrls);
      mainDocStatus.observe(
        event,
        navigatedUrl: url,
        isTopLevelSession: !session.childSessionIds.contains(event.sessionId),
      );
      // Independent of the classification above: adjudicated (and, off
      // this event stream, replied to) on its own regardless of whether
      // this event also happened to be media - see PrivateDestinationGuard.
      unawaited(PrivateDestinationGuard.handle(session, event));
    });
    try {
      await session.send('Page.navigate', {'url': url.toString()});
      onLoadFired(await _waitForLoad(session, candidates));

      // Fail fast on a login wall, a bot-verification interstitial (never
      // solved - see PageStatusDetector), or a 404: none of these three
      // ever start producing media no matter how long _driveCapture waits
      // or how many playback/consent-dialog nudges it fires, so there is
      // nothing to gain by running that whole budget first (diagnostic
      // run, docs/plan-phase5-coverage.md: Reddit alone burned 40s on a
      // "Prove your humanity" page this way before this check existed).
      final earlySignal = await _pageStatusSignal(session, url, mainDocStatus.status);
      if (earlySignal != null) throw PageStatusExceptions.forSignal(earlySignal);

      await _driveCapture(session, candidates);

      final domVideoUrls = await _domVideoElementUrls(session);
      await _backfillFromPerformanceEntries(session, candidates, segmentUrls);
      // Round 5 (real-download-gate regression): a post-hoc pass over the
      // *complete* set of network-observed candidates - only a group of
      // 3+ can distinguish a fragment sequence from a few coincidentally
      // numbered whole files, so this cannot run per-event. See
      // NetworkSignalRecorder.reclassifyFragmentedSiblings's own doc
      // comment.
      NetworkSignalRecorder.reclassifyFragmentedSiblings(candidates, segmentUrls);
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

      final userAgent = await SessionRequestContext.userAgent(session);

      // Lane A #4: nothing whole was ever classified, but the page did
      // request HLS/DASH fragments directly - recover the manifest those
      // fragments belong to by guessing at its directory's conventional
      // filenames, rather than giving up with those fragments' own CDN
      // traffic sitting right there unused.
      if (finalCandidates.isEmpty && segmentUrls.isNotEmpty) {
        final recovered = await _segmentProber.recoverFirst(segmentUrls, {
          'User-Agent': userAgent,
          'Referer': url.toString(),
        });
        if (recovered != null) finalCandidates = [recovered];
      }

      if (finalCandidates.isEmpty) {
        throw await _noMediaException(session, url, domFallback, mainDocStatus.status);
      }

      // Reject before doing anything further with these URLs (our own
      // m3u8 GET below, or handing them back to the caller at all): a
      // page could otherwise get a capture pass to "discover" (and this
      // app to later fetch) an internal/private network address. This
      // applies uniformly regardless of which of the paths above
      // produced [finalCandidates] (network-observed, DOM fallback, or
      // segment-manifest recovery) - none of them is exempt.
      for (final candidate in finalCandidates) {
        final candidateUrl = Uri.tryParse(candidate.url);
        if (candidateUrl != null) HostPolicy.assertAllowedHost(candidateUrl, context: 'a captured media URL');
      }

      final meta = await PageMetaReader.read((expression) => _evalString(session, expression));
      final title = PageMetaReader.title(meta) ?? domFallback?.title;
      final thumbnailUrl = PageMetaReader.thumbnail(meta) ?? domFallback?.thumbnailUrl;
      final cookiesByDomain = await SessionRequestContext.cookiesByDomain(session, url, finalCandidates);

      // UA/Referer only - never a blanket `Cookie` here (see
      // `MediaInfo.cookiesByDomain`'s own doc): the master-playlist fetch
      // just below still needs a cookie when the site gates it behind
      // one, so it is scoped per candidate's own host instead.
      final requestHeaders = <String, String>{
        'User-Agent': userAgent,
        'Referer': url.toString(),
      };

      final formats = <MediaFormat>[];
      for (final candidate in finalCandidates) {
        final scoped = SessionRequestContext.scopedHeaders(candidate, requestHeaders, cookiesByDomain);
        formats.addAll(await _formatBuilder.expandFormats(candidate, scoped));
      }

      return MediaInfo(
        id: _idFromUrl(url),
        title: title ?? _lastSegmentOrUrl(url),
        thumbnailUrl: thumbnailUrl,
        sourceUrl: url,
        formats: formats,
        requestHeaders: requestHeaders,
        cookiesByDomain: cookiesByDomain,
      );
    } finally {
      await subscription.cancel();
    }
  }

  /// Dispatches one CDP event to [NetworkSignalRecorder] - see that class
  /// for the actual classification (this method's only job is picking
  /// `event.params`'s right sub-object apart per method name).
  void _observe(CdpEvent event, Map<String, CapturedMediaCandidate> candidates, Set<String> segmentUrls) {
    switch (event.method) {
      case 'Network.responseReceived':
        final response = event.params['response'];
        if (response is Map) {
          NetworkSignalRecorder.recordResponse(response.cast<String, dynamic>(), candidates, segmentUrls);
        }
        return;
      case 'Network.requestWillBeSent':
        final request = event.params['request'];
        if (request is Map) {
          NetworkSignalRecorder.recordRequestWillBeSent(request.cast<String, dynamic>(), candidates, segmentUrls);
        }
        return;
    }
  }

  Future<MediaExtractionException> _noMediaException(
    DevtoolsSession session,
    Uri sourceUrl,
    HtmlSniffResult? domFallback,
    int? mainDocumentStatus,
  ) async {
    final signal = await _pageStatusSignal(session, sourceUrl, mainDocumentStatus, domFallback: domFallback);
    return PageStatusExceptions.forSignal(signal);
  }

  /// Shared by the fast early-exit in [_captureWith] and [_noMediaException]
  /// (the late, "nothing was ever found" path) - one page-status read, one
  /// classification, so the two call sites can never disagree about what a
  /// given page's own title/URL/status code mean.
  Future<PageStatusSignal?> _pageStatusSignal(
    DevtoolsSession session,
    Uri sourceUrl,
    int? mainDocumentStatus, {
    HtmlSniffResult? domFallback,
  }) async {
    final meta = await PageMetaReader.read((expression) => _evalString(session, expression));
    final finalUrl = Uri.tryParse((meta?['href'] as String?) ?? '') ?? sourceUrl;
    final title = PageMetaReader.title(meta) ?? domFallback?.title;
    return PageStatusDetector.detect(finalUrl: finalUrl, title: title, mainDocumentStatusCode: mainDocumentStatus);
  }

  /// Whether `Page.loadEventFired` was actually observed within
  /// See [PageLoadWaiter.wait]. Used by [_attemptCapture]/[extract] to
  /// decide whether a media-less result is worth retrying headless (a page
  /// that never finished loading at all is a much stronger "this
  /// session's render may itself be the problem" signal than one that
  /// loaded fine and simply had no media).
  Future<bool> _waitForLoad(DevtoolsSession session, Map<String, CapturedMediaCandidate> candidates) =>
      PageLoadWaiter.wait(session, candidates, loadTimeout: loadTimeout);

  /// Delegates to [CaptureDriveLoop.run] - see that class for the actual
  /// wait/retry/poll policy (kept out of this file to stay under the
  /// project's 400-line cap).
  Future<void> _driveCapture(DevtoolsSession session, Map<String, CapturedMediaCandidate> candidates) => CaptureDriveLoop.run(
        session,
        candidates,
        postLoadDelay: postLoadDelay,
        autoplayRetryDelay: autoplayRetryDelay,
        firstCandidateTimeout: firstCandidateTimeout,
        variantSettleDelay: variantSettleDelay,
        pollInterval: pollInterval,
      );

  /// See [NetworkSignalRecorder.backfillFromPerformanceEntries].
  Future<void> _backfillFromPerformanceEntries(
    DevtoolsSession session,
    Map<String, CapturedMediaCandidate> candidates,
    Set<String> segmentUrls,
  ) =>
      NetworkSignalRecorder.backfillFromPerformanceEntries(
        (expression) => _evalString(session, expression),
        candidates,
        segmentUrls,
      );

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

  String _idFromUrl(Uri url) => 'browser-capture-${url.toString().hashCode.toUnsigned(31)}';

  String _lastSegmentOrUrl(Uri url) {
    final segments = url.pathSegments.where((s) => s.isNotEmpty).toList();
    return segments.isEmpty ? url.toString() : segments.last;
  }
}
