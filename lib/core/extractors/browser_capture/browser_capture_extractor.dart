import 'dart:async';
import 'dart:io';

import '../../services/browser_devtools_session.dart';
import '../../services/cdp_client.dart';
import '../../services/interactive_session_detector.dart';
import '../generic/html_media_sniffer.dart';
import '../media_extractor.dart';
import '../media_models.dart';
import 'captured_format_builder.dart';
import 'dom_video_urls.dart';
import 'headless_block_detector.dart';
import 'captured_media_classifier.dart';
import '../../net/host_policy.dart';
import 'capture_attempt.dart';
import 'capture_drive_loop.dart';
import 'main_document_status_tracker.dart';
import 'network_signal_recorder.dart';
import 'no_media_diagnosis.dart';
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
  /// Test-only override of the whole launch. Null in production, where
  /// [_launchSession] calls [BrowserDevtoolsSession.launch] directly.
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

  /// Phase 7 agent/CLI mode: never open a headed window. One headless
  /// attempt (no headed-first, no retry); a loaded page with zero media that
  /// looks like a challenge/empty shell throws `HEADLESS_BLOCKED`
  /// ([HeadlessBlockDetector]). Also on when `MIDA_HEADLESS=1` is set in
  /// the environment (injectable for tests).
  final bool forceHeadless;
  final Map<String, String>? _environment;

  /// Test-only: called with each launch's `preferHeaded` just before
  /// [_launchSession] runs (the injected launcher shape cannot carry it).
  final void Function({required bool preferHeaded})? launchObserver;

  bool get _headless => forceHeadless || InteractiveSessionDetector.isHeadlessForced(environment: _environment);

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
    this.forceHeadless = false,
    Map<String, String>? environment,
    this.launchObserver,
  })  : _sessionLauncher = sessionLauncher,
        _environment = environment,
        _formatBuilder = CapturedFormatBuilder(httpClientFactory: httpClientFactory),
        _segmentProber = SegmentManifestProber(httpClientFactory: httpClientFactory);

  @override
  bool canHandle(Uri url) => url.scheme == 'http' || url.scheme == 'https';

  /// Production default (no [_sessionLauncher] injected) launches directly
  /// with [useBrowserLoginSession] and [preferHeaded] threaded through. A
  /// test-injected [_sessionLauncher] never sees [preferHeaded] (it has no
  /// headed/headless concept); tests observe it via [launchObserver].
  Future<DevtoolsSession> _launchSession({required Duration connectTimeout, required bool preferHeaded}) {
    launchObserver?.call(preferHeaded: preferHeaded);
    final launcher = _sessionLauncher;
    if (launcher != null) return launcher(connectTimeout: connectTimeout);
    return BrowserDevtoolsSession.launch(
      connectTimeout: connectTimeout,
      useBrowserLoginSession: useBrowserLoginSession,
      preferHeaded: preferHeaded,
      environment: _environment,
    );
  }

  @override
  Future<MediaInfo> extract(Uri url) async {
    HostPolicy.assertAllowedHost(url, context: 'this page');
    // Forced headless: one headless attempt, no headed-first and no retry.
    final first = await _attemptCapture(url, preferHeaded: !_headless);
    if (first.info != null) return first.info!;

    if (!_headless && shouldRetryHeadless(first, hasInjectedSessionLauncher: _sessionLauncher != null)) {
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
      final loaded = await _waitForLoad(session, candidates);
      onLoadFired(loaded);

      // Fail fast on a login wall, a bot-verification interstitial (never
      // solved - see PageStatusDetector), or a 404: none of these three
      // ever start producing media no matter how long _driveCapture waits
      // or how many playback/consent-dialog nudges it fires, so there is
      // nothing to gain by running that whole budget first (diagnostic
      // run, docs/plan-phase5-coverage.md: Reddit alone burned 40s on a
      // "Prove your humanity" page this way before this check existed).
      final earlySignal =
          await NoMediaDiagnosis.pageStatusSignal((e) => _evalString(session, e), url, mainDocStatus.status);
      if (earlySignal != null) {
        // Headless: a bot-check page is a headless-specific block (a headed
        // run may pass it), so say so instead of the generic BOT_CHECK.
        throw _headless && earlySignal == PageStatusSignal.botCheckRequired
            ? HeadlessBlockDetector.exception(url)
            : PageStatusExceptions.forSignal(earlySignal);
      }

      await _driveCapture(session, candidates);

      final domVideoUrls = await DomVideoUrls.read((e) => _evalString(session, e));
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
      String? outerHtml;
      if (finalCandidates.isEmpty) {
        outerHtml = await _evalString(session, 'document.documentElement.outerHTML');
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
        // Login wall / 404 / bot-check / 429 / 5xx / headless block / none:
        // see NoMediaDiagnosis.exceptionFor for the order.
        throw await NoMediaDiagnosis.exceptionFor(
          (e) => _evalString(session, e),
          url,
          domFallback,
          mainDocStatus.status,
          headlessBlockCheck: _headless && loaded,
          html: outerHtml,
        );
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

  /// See [PageLoadWaiter.wait]; the result feeds [shouldRetryHeadless] and
  /// the forced-headless block check (a page that never loaded is a
  /// different signal than one that loaded with no media).
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
