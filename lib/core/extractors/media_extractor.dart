import '../net/retry_policy.dart';
import 'media_models.dart';

/// Contract every platform-native extractor implements. `canHandle` must be
/// cheap (no network) so [ExtractorRegistry] can probe every extractor per
/// URL without cost.
abstract class MediaExtractor {
  bool canHandle(Uri url);
  Future<MediaInfo> extract(Uri url);
}

/// Looks up the extractor registered for a given URL and resolves it into a
/// [MediaInfo], applying the two cross-cutting rules every extractor shares
/// so individual extractors do not each reimplement them:
///
///  1. Protocol normalization ([_normalizeProtocols]): a format's
///     `container` implies how it must be downloaded (`m3u8` needs ffmpeg,
///     not a ranged GET); every extractor leaves `MediaFormat.protocol` at
///     its default (`'https'`) and this is the one place that derives the
///     real value.
///  2. The fallback chain ([_resolveAfterFailure]): a platform extractor's
///     `canHandle` matching does not guarantee its *technique* worked.
///     - The catch-all extractor (`GenericExtractor`, always last in
///       [_extractors] per `extractor_registry_builder.dart`) reporting
///       `NO_MEDIA_FOUND` tries each of [fallbacks]
///       (`BrowserCaptureExtractor`) in order (Phase 2d).
///     - Any other (platform) extractor reporting one of
///       [_platformFallThroughStatuses] - a technique failure, not "there is
///       genuinely nothing here" - falls through to the catch-all extractor
///       and then [fallbacks], for the same URL (e.g. TikTok's WAF
///       intermittently escalates past what the page-fetch technique can
///       solve; the browser path was measured to succeed there).
///     Terminal statuses (`PRIVATE`, `NOT_FOUND`, `UNSUPPORTED_MEDIA`,
///     `LOGIN_REQUIRED`, ...) are not in [_platformFallThroughStatuses]:
///     the source explicitly said there is nothing to get, so trying a
///     different technique would not help and only wastes time (Generic's
///     HTML GET, or a whole headless browser launch).
///     This chain intentionally lives here rather than in the registry
///     builder, per `docs/plan-phase2b-wiring.md`: the builder only
///     decides ordering, this method decides what to do when the ordering
///     alone was not enough.
class ExtractorRegistry {
  final List<MediaExtractor> _extractors;

  /// Tried, in order, once the fallback chain (see class doc) decides the
  /// URL needs a browser. Not part of the `canHandle` scan itself:
  /// `BrowserCaptureExtractor.canHandle` also accepts every http(s) URL, so
  /// if it were mixed into `_extractors` it would sit unreachable behind
  /// `GenericExtractor` (which accepts the same URLs) rather than acting
  /// as a real fallback.
  final List<MediaExtractor> fallbacks;

  /// Platform-extractor failure codes that mean "this technique did not
  /// work this time", not "this URL genuinely has no media" - worth
  /// retrying against the catch-all extractor and then [fallbacks].
  /// `NO_MEDIA_FOUND` is deliberately not here: it is the catch-all
  /// extractor's own terminal code, handled separately in
  /// [_resolveAfterFailure].
  static const _platformFallThroughStatuses = {
    'CHALLENGE_FAILED',
    'RATE_LIMITED',
    'PARSE_ERROR',
    'NETWORK',
  };

  /// Backs off and retries a single extractor attempt once
  /// (`RetryPolicy(maxAttempts: 2)`) when it fails `RATE_LIMITED`/`NETWORK`
  /// - before this class decides whether to fall through to the next
  /// technique at all (`docs/plan-phase4-cookies-resilience.md` section 3).
  /// Deliberately just one retry, not the full 4-attempt policy default: a
  /// platform extractor that keeps failing has a whole fall-through chain
  /// (catch-all, then [fallbacks]) to try next, so exhausting 4 attempts
  /// per technique here would compound into a very long wait before ever
  /// reaching the technique (browser capture) that was actually measured
  /// to get past a WAF escalation. `null` (the default via the constructor)
  /// lazily uses [_defaultRetryPolicy] rather than being a `const`
  /// constructor default itself, so `const ExtractorRegistry(...)` (used by
  /// tests with no failure paths to retry) keeps working.
  final RetryPolicy? _retryPolicy;

  static final RetryPolicy _defaultRetryPolicy = RetryPolicy(maxAttempts: 2);

  const ExtractorRegistry(this._extractors, {this.fallbacks = const [], RetryPolicy? retryPolicy})
      : _retryPolicy = retryPolicy;

  MediaExtractor? find(Uri url) {
    for (final extractor in _extractors) {
      if (extractor.canHandle(url)) return extractor;
    }
    return null;
  }

  /// Runs a single [extractor]'s `extract(url)` through [_retryPolicy] (or
  /// [_defaultRetryPolicy]): a `RATE_LIMITED`/`NETWORK` failure gets one
  /// backed-off retry against the *same* extractor before either
  /// [resolveInfo] or [_resolveAfterFailure] decides whether to fall
  /// through to a different technique. Every other status (including the
  /// other fall-through statuses, `CHALLENGE_FAILED`/`PARSE_ERROR`, and
  /// every terminal status) is not retryable per `RetryPolicy`'s default
  /// classification, so it is rethrown immediately, unchanged - identical
  /// to calling `extractor.extract(url)` directly.
  Future<MediaInfo> _attempt(MediaExtractor extractor, Uri url) {
    final policy = _retryPolicy ?? _defaultRetryPolicy;
    return policy.run(() => extractor.extract(url));
  }

  Future<MediaInfo> resolveInfo(Uri url) async {
    final extractor = find(url);
    if (extractor == null) {
      throw const MediaExtractionException(
        'UNSUPPORTED_URL',
        'No extractor recognizes this URL.',
      );
    }

    try {
      final info = _normalizeProtocols(await _attempt(extractor, url));
      if (info.formats.isEmpty) {
        // A successful extract with zero formats is not success: there is
        // nothing to download. Treated exactly like the catch-all
        // extractor's own `NO_MEDIA_FOUND` and always continues the
        // fall-through chain (Generic -> BrowserCapture), regardless of
        // which extractor produced it - `forceFallThrough` bypasses the
        // "only the catch-all's NO_MEDIA_FOUND falls through" gate below,
        // which exists for extractors that *threw* NO_MEDIA_FOUND
        // (currently only the catch-all ever does), not for this
        // "reported success but found nothing" case.
        return _resolveAfterFailure(
          url,
          extractor,
          const MediaExtractionException(
            'NO_MEDIA_FOUND',
            'The extractor found this item but it has no downloadable formats.',
          ),
          forceFallThrough: true,
        );
      }
      return info;
    } on MediaExtractionException catch (e) {
      return _resolveAfterFailure(url, extractor, e);
    }
  }

  /// [firstFailure] is what [failedExtractor] (the one [find] picked)
  /// threw (or, for an empty-formats "success", the synthetic
  /// `NO_MEDIA_FOUND` [resolveInfo] built for it - see [forceFallThrough]).
  /// Decides whether that is worth retrying at all, and if so, builds the
  /// ordered list of remaining attempts (see class doc) and runs them in
  /// order, returning the first success or re-throwing the most recent
  /// failure if every attempt fails.
  Future<MediaInfo> _resolveAfterFailure(
    Uri url,
    MediaExtractor failedExtractor,
    MediaExtractionException firstFailure, {
    bool forceFallThrough = false,
  }) async {
    final catchAll = _extractors.last;
    final failedWasCatchAll = identical(failedExtractor, catchAll);

    final shouldFallThrough = forceFallThrough ||
        (failedWasCatchAll
            ? firstFailure.status == 'NO_MEDIA_FOUND'
            : _platformFallThroughStatuses.contains(firstFailure.status));
    if (!shouldFallThrough) throw firstFailure;

    final remainingAttempts = <MediaExtractor>[
      if (!failedWasCatchAll) catchAll,
      ...fallbacks,
    ];
    if (remainingAttempts.isEmpty) throw firstFailure;

    var lastFailure = firstFailure;
    for (final attempt in remainingAttempts) {
      try {
        final info = _normalizeProtocols(await _attempt(attempt, url));
        if (info.formats.isEmpty) {
          // Same rule as the top-level check in resolveInfo: an empty
          // format list is not success, even from a fallback - keep going
          // rather than handing the caller a MediaInfo with nothing to
          // download.
          lastFailure = const MediaExtractionException(
            'NO_MEDIA_FOUND',
            'The extractor found this item but it has no downloadable formats.',
          );
          continue;
        }
        return info;
      } on MediaExtractionException catch (e) {
        lastFailure = e;
      }
    }

    // Every attempt failed: keep the FIRST extractor's status code (it is
    // the one that actually matches this platform/URL) but fold the last
    // attempt's reason in too, so the user sees both "what the real
    // extractor said" and "what the fallback chain ended up with"
    // instead of losing the more specific original diagnosis.
    throw MediaExtractionException(
      firstFailure.status,
      '${firstFailure.reason ?? firstFailure.status}. Also tried the fallback extractors '
          '(Generic/BrowserCapture): ${lastFailure.reason ?? lastFailure.status}',
    );
  }

  static MediaInfo _normalizeProtocols(MediaInfo info) {
    final needsChange = info.formats.any((f) => f.protocol != _protocolFor(f.container));
    if (!needsChange) return info;
    return MediaInfo(
      id: info.id,
      title: info.title,
      author: info.author,
      thumbnailUrl: info.thumbnailUrl,
      duration: info.duration,
      formats: [for (final f in info.formats) f.withProtocol(_protocolFor(f.container))],
      captions: info.captions,
      translatableLanguageCodes: info.translatableLanguageCodes,
      sourceUrl: info.sourceUrl,
      requestHeaders: info.requestHeaders,
    );
  }

  static String _protocolFor(String container) {
    switch (container) {
      case 'm3u8':
        return 'hls';
      case 'mpd':
        return 'dash';
      default:
        return 'https';
    }
  }
}
