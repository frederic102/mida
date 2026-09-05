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
            // request that dedupes to this same key, and keep whichever
            // mimeType we saw first (a Range-fragmented request's own
            // Content-Length is only that fragment's size, not the whole
            // file's - round 6: `range=`/`bytes=` is deliberately *not* a
            // per-URL segment signal at all, see
            // `CapturedMediaClassifier.isSegmentUrl`'s own doc comment;
            // only `NetworkSignalRecorder.reclassifyFragmentedSiblings`'s
            // group-of-3+-small-siblings pass can still demote this
            // shape, and only as part of a real group).
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

    // Round 5 (real-download-gate regression): a fragment request's own
    // `Referer` header is very often the manifest URL the player is
    // actually working from, even when CDP never separately reports a
    // request for that manifest itself (e.g. resolved from a cached
    // service worker response, or fetched from inside a Worklet CDP
    // cannot see into at all) - one more source for the same
    // `.m3u8`/`.mpd`-in-the-URL condition B that [classifyByUrlOnly]
    // already accepts regardless of mimeType, so no new acceptance rule
    // is needed here, only one more place a URL can come from.
    final headers = request['headers'];
    if (headers is Map) {
      final referer = _headerValue(headers, 'referer');
      if (referer != null) recordUrlOnly(referer, candidates, segmentUrls);
    }
  }

  static String? _headerValue(Map<dynamic, dynamic> headers, String name) {
    for (final entry in headers.entries) {
      if (entry.key.toString().toLowerCase() == name) {
        final value = entry.value;
        return value is String ? value : null;
      }
    }
    return null;
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

  /// Below this size, a single `mp4`/`m4a` response is small enough to
  /// plausibly be one fragment of a longer stream rather than a whole
  /// video/audio file in its own right - only relevant when paired with
  /// [_minSiblingsForFragmentGroup] in [reclassifyFragmentedSiblings]
  /// below, never on its own (a short but complete clip is exactly this
  /// small too).
  static const int _fragmentSizeThreshold = 3 * 1024 * 1024;

  /// How many same-shaped, differently-numbered candidates must exist
  /// before [reclassifyFragmentedSiblings] treats the group as a
  /// fragment sequence rather than a coincidence (e.g. three genuinely
  /// distinct quality renditions that happen to be numbered).
  static const int _minSiblingsForFragmentGroup = 3;

  /// Round 5 (real-download-gate regression): catches a fragment shape
  /// [CapturedMediaClassifier.isSegmentUrl]'s per-URL patterns miss
  /// entirely - a purely numeric path *segment* (not a filename suffix)
  /// distinguishing otherwise-identical sibling URLs, e.g.
  /// `.../dash/fragments/5?sig=...`, `.../dash/fragments/6?sig=...` - each
  /// individually looks like an ordinary small `mp4` response with no
  /// segment-shaped substring anywhere in it at all. Only a *group* of
  /// these (this method's own job, called once after a capture's network
  /// observation is complete, never per-event) can tell a fragment
  /// sequence apart from three legitimately distinct small files. A
  /// candidate already classified elsewhere (`m3u8`/`mpd`/`webm`/anything
  /// not `mp4`/`m4a`) is left untouched regardless of grouping - this is
  /// deliberately narrow to the exact shape the coordinator's report
  /// named (bare CMAF-family fragments), not a general size-based prune.
  static void reclassifyFragmentedSiblings(
    Map<String, CapturedMediaCandidate> candidates,
    Set<String> segmentUrls,
  ) {
    final groupedKeys = <String, List<String>>{};
    candidates.forEach((key, candidate) {
      if (candidate.container != 'mp4' && candidate.container != 'm4a') return;
      final length = candidate.contentLength;
      if (length == null || length >= _fragmentSizeThreshold) return;
      final signature = _fragmentGroupSignature(candidate.url);
      if (signature == null) return;
      groupedKeys.putIfAbsent(signature, () => []).add(key);
    });

    for (final keys in groupedKeys.values) {
      if (keys.length < _minSiblingsForFragmentGroup) continue;
      for (final key in keys) {
        final removed = candidates.remove(key);
        if (removed != null) segmentUrls.add(removed.url);
      }
    }
  }

  /// Groups by directory + last path segment with its final run of
  /// digits replaced by a placeholder (query string ignored entirely - a
  /// signed per-segment token there would otherwise make every sibling
  /// its own unique group of one). Null (excluded from grouping) for a
  /// last path segment with no digit run at all - a plain, unnumbered
  /// filename has nothing for this heuristic to key on.
  static String? _fragmentGroupSignature(String url) {
    Uri uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {
      return null;
    }
    if (uri.pathSegments.isEmpty) return null;
    final last = uri.pathSegments.last;
    final digitRun = RegExp(r'\d+').firstMatch(last);
    if (digitRun == null) return null;
    final placeholder = last.replaceRange(digitRun.start, digitRun.end, '#');
    final directorySegments = uri.pathSegments.sublist(0, uri.pathSegments.length - 1);
    return Uri(scheme: uri.scheme, host: uri.host, pathSegments: [...directorySegments, placeholder]).toString();
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
