import 'dart:convert';

import 'captured_media_classifier.dart';
import 'segment_manifest_prober.dart';

/// Turns raw CDP/DOM signals into entries in `BrowserCaptureExtractor`'s
/// two running sets: classified media candidates and segment-looking URLs
/// (`.m4s`/`.ts`/`seg-*.mp4`, tracked even though they never become their
/// own candidate - see [SegmentManifestProber]). Split out of
/// `BrowserCaptureExtractor` to keep both files under this project's
/// 400-line cap, and because none of this needs a live `DevtoolsSession`
/// at all: every method here is a pure function over already-decoded CDP
/// params or already-fetched strings, exactly what
/// `docs/plan-phase5-coverage.md` Lane A #3 (also collect
/// `Network.requestWillBeSent`, and backfill from
/// `performance.getEntriesByType('resource')`) needs classified.
class NetworkSignalRecorder {
  const NetworkSignalRecorder._();

  /// A `Network.responseReceived` event's own `response` object: the one
  /// observation with both a URL and a real `Content-Type`, so it goes
  /// through [CapturedMediaClassifier.classify] (the stricter of the two
  /// classifiers) exactly as before this recorder existed.
  static void recordResponse(
    Map<String, dynamic> response,
    Map<String, CapturedMediaCandidate> candidates,
    Set<String> segmentUrls,
  ) {
    final responseUrl = response['url'];
    if (responseUrl is! String) return;
    if (SegmentManifestProber.looksLikeSegmentUrl(responseUrl)) segmentUrls.add(responseUrl);

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
            // Content-Length is only that fragment's size, not the
            // whole file's), and keep whichever mimeType we saw first.
            contentLength: (contentLength != null && (existing.contentLength == null || contentLength > existing.contentLength!))
                ? contentLength
                : existing.contentLength,
            mimeType: existing.mimeType ?? mimeType,
          );
  }

  /// A `Network.requestWillBeSent` event's own `request` object: fires
  /// before any response exists, so it has no mimeType at all - routed
  /// through [CapturedMediaClassifier.classifyByUrlOnly] instead, which
  /// exists for exactly this (and the [recordUrlOnly] performance-entries
  /// path below).
  static void recordRequestWillBeSent(
    Map<String, dynamic> request,
    Map<String, CapturedMediaCandidate> candidates,
    Set<String> segmentUrls,
  ) {
    final requestUrl = request['url'];
    if (requestUrl is! String) return;
    recordUrlOnly(requestUrl, candidates, segmentUrls);
  }

  /// Shared by [recordRequestWillBeSent] and the
  /// `performance.getEntriesByType('resource')` backfill in
  /// `BrowserCaptureExtractor`: a bare URL with no mimeType signal at
  /// all.
  static void recordUrlOnly(
    String url,
    Map<String, CapturedMediaCandidate> candidates,
    Set<String> segmentUrls,
  ) {
    if (SegmentManifestProber.looksLikeSegmentUrl(url)) segmentUrls.add(url);
    final classified = CapturedMediaClassifier.classifyByUrlOnly(url);
    if (classified == null) return;
    final key = CapturedMediaClassifier.dedupeKey(classified.url);
    candidates.putIfAbsent(key, () => classified);
  }

  /// Decodes `performance.getEntriesByType('resource')`'s
  /// `JSON.stringify`d result (a plain array of URL strings) back into
  /// the list it started as - null (rather than throwing) for anything
  /// that is not that shape, since a page that redefines `performance`
  /// or throws inside the eval is a best-effort miss, not a capture
  /// failure.
  static List<String>? parsePerformanceEntries(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      return decoded.whereType<String>().toList(growable: false);
    } catch (_) {
      return null;
    }
  }

  /// Lane A #3: backfills any media URL CDP's own `Network.*` events
  /// missed, from the live page's own record of every resource it
  /// fetched - `performance.getEntriesByType('resource')` - regardless of
  /// which internal API (Worklet, service worker) asked for it. [evalString]
  /// is `BrowserCaptureExtractor._evalString` bound to its live session;
  /// kept as a plain callback here (rather than taking a `DevtoolsSession`
  /// directly) so this stays a pure-data helper with no session dependency
  /// of its own, matching every other method in this class.
  static Future<void> backfillFromPerformanceEntries(
    Future<String?> Function(String expression) evalString,
    Map<String, CapturedMediaCandidate> candidates,
    Set<String> segmentUrls,
  ) async {
    const expression = "JSON.stringify(performance.getEntriesByType('resource').map(function (e) { return e.name; }))";
    final raw = await evalString(expression);
    final urls = raw == null ? null : parsePerformanceEntries(raw);
    if (urls == null) return;
    for (final entryUrl in urls) {
      recordUrlOnly(entryUrl, candidates, segmentUrls);
    }
  }

  static int? _parseContentLength(dynamic headers) {
    if (headers is! Map) return null;
    for (final entry in headers.entries) {
      if (entry.key.toString().toLowerCase() == 'content-length') {
        return int.tryParse(entry.value.toString());
      }
    }
    return null;
  }
}
