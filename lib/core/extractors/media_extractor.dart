import '../net/retry_policy.dart';
import 'fallback_failure.dart';
import 'generic/embeds/embed_delegation.dart';
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
///     - A platform extractor reporting `LOGIN_REQUIRED`
///       ([_platformLoginWallStatus]) also falls through to the catch-all
///       and then [fallbacks]: platform extractors never send cookies, but
///       `BrowserCaptureExtractor` can carry the user's signed-in browser
///       session ("Use browser login session"). [fallbacks] are only tried
///       for it when [loginSessionAvailable] is true: without a session the
///       browser would hit the same wall after a slow launch, so only the
///       catch-all is tried (Gadfly G2). If every later attempt
///       fails too, the ORIGINAL `LOGIN_REQUIRED` exception is rethrown
///       unchanged (not the fallbacks' `NO_MEDIA_FOUND`/`HEADLESS_BLOCKED`),
///       so the user sees the honest reason and the GUI's "enable login
///       session and retry" action still keys off it.
///     Terminal statuses (`PRIVATE`, `NOT_FOUND`, `UNSUPPORTED_MEDIA`, ...)
///     are in neither set: the source explicitly said there is nothing to
///     get, so trying a different technique would not help and only wastes
///     time (Generic's HTML GET, or a whole headless browser launch). The
///     catch-all's own `LOGIN_REQUIRED` stays terminal too (only its
///     `NO_MEDIA_FOUND` continues the chain).
///     When the chain fails, a fallback's policy or rate-limit status
///     ([fallbackSurfacedStatuses], e.g. `HEADLESS_BLOCKED`) is surfaced
///     over the first status, and a fallback throwing a non-extraction
///     [Exception] is folded in via [asFallbackFailure] rather than escaping.
///  3. Embed delegation ([_tryDelegation]): the catch-all may throw an
///     [EmbedDelegationException] (a `NO_MEDIA_FOUND` subtype) meaning "this
///     page embeds a YouTube/Vimeo/Dailymotion player; the video is at
///     `target`". That is honored whether the catch-all ran first or was
///     reached by a platform fall-through: [find] picks the native extractor
///     for `target` and it gets exactly ONE attempt (never the catch-all
///     itself, and depth 1: a second delegation thrown by that attempt is
///     not followed). If that attempt fails or finds no formats, the chain
///     carries on for the ORIGINAL page URL ([fallbacks], i.e. browser
///     capture) with the delegation as the failure, exactly as an ordinary
///     catch-all `NO_MEDIA_FOUND` would. `MediaInfo.sourceUrl` is whatever
///     the native extractor set (the canonical `target`).
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

  /// A platform extractor's login wall: falls through like
  /// [_platformFallThroughStatuses] (the browser fallback may hold a signed-in
  /// session), but when the whole chain fails this exact exception is
  /// rethrown as-is instead of the folded "also tried" message.
  static const _platformLoginWallStatus = 'LOGIN_REQUIRED';

  /// The catch-all's own failures that continue to [fallbacks]: nothing found,
  /// or a parse failure (wrapped parser bugs included; Gadfly r3 / astra r3).
  /// A non-offline NETWORK (TLS refusal, reset) continues too, see [_resolveAfterFailure].
  static const _catchAllFallThroughStatuses = {'NO_MEDIA_FOUND', 'PARSE_ERROR'};

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

  /// True when the browser fallback can carry the user's signed-in session
  /// (Settings: "Use browser login session"). Gates only the
  /// `LOGIN_REQUIRED` fall-through into [fallbacks]; every other chain is
  /// unaffected. Default false: without a session a browser launch cannot
  /// get past a login wall, it only costs time and a window.
  final bool loginSessionAvailable;

  const ExtractorRegistry(
    this._extractors, {
    this.fallbacks = const [],
    RetryPolicy? retryPolicy,
    this.loginSessionAvailable = false,
  }) : _retryPolicy = retryPolicy;

  /// The first extractor whose `canHandle` accepts [url]. A `canHandle`
  /// that throws (a bug in one extractor's URL matcher) counts as "does not
  /// handle" instead of crashing resolution for every URL (Bulwark round 2).
  MediaExtractor? find(Uri url) {
    for (final extractor in _extractors) {
      bool handles;
      try {
        handles = extractor.canHandle(url);
      } catch (_) {
        handles = false;
      }
      if (handles) return extractor;
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

  /// Anything other than a [MediaExtractionException] a primary extractor
  /// throws, an [Error] included (a parser bug: `TypeError`,
  /// `FormatException`, `StateError`), becomes a fixed-text failure via
  /// [asFallbackFailure] (usually `PARSE_ERROR`) and so falls through like a
  /// technique failure instead of crashing the caller (Vigil N2). The
  /// fall-through itself runs OUTSIDE the `try`, so its own final failure is
  /// never caught and re-run here.
  Future<MediaInfo> resolveInfo(Uri url) async {
    final extractor = find(url);
    if (extractor == null) {
      throw const MediaExtractionException(
        'UNSUPPORTED_URL',
        'No extractor recognizes this URL.',
      );
    }

    MediaExtractionException failure;
    var forceFallThrough = false;
    try {
      final info = _normalizeProtocols(await _attempt(extractor, url));
      if (info.formats.isNotEmpty) return info;
      // A successful extract with zero formats is not success: there is
      // nothing to download. Treated exactly like the catch-all
      // extractor's own `NO_MEDIA_FOUND` and always continues the
      // fall-through chain (Generic -> BrowserCapture), regardless of
      // which extractor produced it - `forceFallThrough` bypasses the
      // "only the catch-all's NO_MEDIA_FOUND falls through" gate, which
      // exists for extractors that *threw* NO_MEDIA_FOUND (currently only
      // the catch-all ever does), not for this "reported success but found
      // nothing" case.
      failure = const MediaExtractionException(
        'NO_MEDIA_FOUND',
        'The extractor found this item but it has no downloadable formats.',
      );
      forceFallThrough = true;
    } catch (error) {
      failure = asFallbackFailure(error);
    }

    if (failure is EmbedDelegationException) {
      final delegated = await _tryDelegation(failure);
      final delegatedInfo = delegated.info;
      if (delegatedInfo != null) return delegatedInfo;
      // Depth 1: the original-URL fallback path must not act on a second
      // delegation, so it runs with delegation handling switched off. The
      // native target's own failure is kept for the final status choice.
      return _resolveAfterFailure(url, extractor, failure, allowDelegation: false, priorFailure: delegated.failure);
    }
    return _resolveAfterFailure(url, extractor, failure, forceFallThrough: forceFallThrough);
  }

  /// One native re-resolve of [delegation]'s `target` (class doc, rule 3).
  /// Never throws. `info` is null when there is no native extractor for the
  /// target, the only match is the catch-all (delegating back to it would
  /// just repeat the page fetch), the attempt throws (including a nested
  /// [EmbedDelegationException], which is deliberately not followed), or it
  /// finds no formats: the caller then continues the original page URL's
  /// fallback chain. `failure` is what the native attempt threw (anything,
  /// via [asFallbackFailure]) so a delegated `DRM_PROTECTED` or `PRIVATE`
  /// can still decide the final status (astra round 2).
  Future<({MediaInfo? info, MediaExtractionException? failure})> _tryDelegation(
    EmbedDelegationException delegation,
  ) async {
    final target = find(delegation.target);
    if (target == null || identical(target, _extractors.last)) return (info: null, failure: null);
    try {
      final info = _normalizeProtocols(await _attempt(target, delegation.target));
      return (info: info.formats.isEmpty ? null : info, failure: null);
    } catch (error) {
      return (info: null, failure: asFallbackFailure(error));
    }
  }

  static MediaExtractionException? _surfaced(MediaExtractionException? failure) =>
      failure != null && fallbackSurfacedStatuses.contains(failure.status) ? failure : null;

  /// Browser statuses that, on a platform login wall, outrank the original
  /// `LOGIN_REQUIRED`: the session got the browser to the page, but the
  /// page itself refused the (headless) browser, so the next step is a
  /// headed run, not "enable the login session" (Gadfly round 2 C7).
  static const _browserBlockStatuses = {'HEADLESS_BLOCKED', 'BOT_CHECK_REQUIRED'};

  /// Whether the catch-all's [failure] (after a platform fall-through) ends
  /// the chain before any browser launch (Vigil N4): `NETWORK` (offline, the
  /// browser would fail the same way after a slow launch) or a policy /
  /// rate-limit status. A catch-all `LOGIN_REQUIRED` still continues when the
  /// browser can carry the user's session.
  bool _catchAllEndsChain(MediaExtractionException failure, MediaExtractionException firstFailure) {
    // Only a proven offline/DNS failure, after a native NETWORK too, ends it (Gadfly r3, Vigil r3 M1):
    // a TLS refusal or reset from Generic can be a WAF that the real browser gets past.
    if (failure.status == 'NETWORK') return failure is OfflineNetworkException && firstFailure.status == 'NETWORK';
    if (failure.status == _platformLoginWallStatus && loginSessionAvailable) return false;
    return fallbackSurfacedStatuses.contains(failure.status);
  }

  /// [firstFailure] is what [failedExtractor] (the one [find] picked)
  /// threw (or, for an empty-formats "success", the synthetic
  /// `NO_MEDIA_FOUND` [resolveInfo] built for it - see [forceFallThrough]).
  /// Decides whether that is worth retrying at all, and if so, builds the
  /// ordered list of remaining attempts (see class doc) and runs them in
  /// order, returning the first success or re-throwing the most recent
  /// failure if every attempt fails. [allowDelegation] (default true) lets a
  /// catch-all attempt's [EmbedDelegationException] be re-resolved once via
  /// [_tryDelegation]; [resolveInfo] passes false on its own delegation
  /// path so a delegation is never followed twice.
  Future<MediaInfo> _resolveAfterFailure(
    Uri url,
    MediaExtractor failedExtractor,
    MediaExtractionException firstFailure, {
    bool forceFallThrough = false,
    bool allowDelegation = true,
    MediaExtractionException? priorFailure,
  }) async {
    final catchAll = _extractors.last;
    final failedWasCatchAll = identical(failedExtractor, catchAll);

    final shouldFallThrough = forceFallThrough ||
        (failedWasCatchAll
            ? _catchAllFallThroughStatuses.contains(firstFailure.status) ||
                (firstFailure.status == 'NETWORK' && firstFailure is! OfflineNetworkException)
            : _platformFallThroughStatuses.contains(firstFailure.status) ||
                firstFailure.status == _platformLoginWallStatus);
    if (!shouldFallThrough) throw firstFailure;

    final isLoginWall = !failedWasCatchAll && firstFailure.status == _platformLoginWallStatus;
    final remainingAttempts = <MediaExtractor>[
      if (!failedWasCatchAll) catchAll,
      if (!isLoginWall || loginSessionAvailable) ...fallbacks,
    ];
    // [priorFailure] (a delegated native target's failure) takes part in
    // the final status choice like any fallback failure.
    var surfacedFailure = _surfaced(priorFailure);
    if (remainingAttempts.isEmpty && surfacedFailure == null) throw firstFailure;

    var lastFailure = firstFailure;
    MediaExtractionException? browserBlock;
    for (final attempt in remainingAttempts) {
      final isCatchAllAttempt = identical(attempt, catchAll);
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
      } catch (error) {
        final e = asFallbackFailure(error);
        if (allowDelegation && e is EmbedDelegationException && isCatchAllAttempt) {
          // A platform extractor fell through to the catch-all, which found
          // a native-platform embed: one native attempt, then (on failure)
          // the remaining fallbacks for the original URL, as usual.
          final delegated = await _tryDelegation(e);
          final delegatedInfo = delegated.info;
          if (delegatedInfo != null) return delegatedInfo;
          surfacedFailure = _surfaced(delegated.failure) ?? surfacedFailure;
        }
        lastFailure = e;
        surfacedFailure = _surfaced(e) ?? surfacedFailure;
        if (!isCatchAllAttempt && _browserBlockStatuses.contains(e.status)) browserBlock = e;
        if (isCatchAllAttempt && _catchAllEndsChain(e, firstFailure)) break;
      }
    }

    if (isLoginWall) {
      // C7: the browser carried the session but was itself refused as a
      // bot: say so (a headed run is the fix), keeping the login reason.
      final block = browserBlock;
      if (block != null) {
        throw MediaExtractionException(
          block.status,
          '${firstFailure.reason ?? firstFailure.status}. Also tried the fallback extractors '
              '(Generic/BrowserCapture): ${block.reason ?? block.status}',
        );
      }
      // A login wall that no later technique got past: the original
      // LOGIN_REQUIRED is the honest diagnosis (and what the GUI's "enable
      // login session and retry" action matches on), so rethrow it untouched.
      throw firstFailure;
    }

    // Every attempt failed: keep the FIRST extractor's status code (it is
    // the one that actually matches this platform/URL) but fold the last
    // attempt's reason in too, so the user sees both "what the real
    // extractor said" and "what the fallback chain ended up with"
    // instead of losing the more specific original diagnosis. Exception:
    // a fallback that named a policy wall or a rate limit
    // ([fallbackSurfacedStatuses]) wins the status code (and the folded
    // reason), since that is what the user or agent can act on.
    final folded = surfacedFailure ?? lastFailure;
    throw MediaExtractionException(
      surfacedFailure?.status ?? firstFailure.status,
      '${firstFailure.reason ?? firstFailure.status}. Also tried the fallback extractors '
          '(Generic/BrowserCapture): ${folded.reason ?? folded.status}',
    );
  }

  // Round 2 (`docs/plan-phase6-av-pairing.md`, P-R9): rebuilds via
  // `MediaInfo.copyWith` rather than a hand-spelled field list - that
  // hand-rolled version is exactly what dropped `cookiesByDomain` in round
  // 1 (docs' own C1/N1 finding), and a field added to `MediaInfo` later can
  // never be silently missed here again.
  static MediaInfo _normalizeProtocols(MediaInfo info) {
    final needsChange = info.formats.any((f) => f.protocol != _protocolFor(f.container));
    if (!needsChange) return info;
    return info.copyWith(formats: [for (final f in info.formats) f.withProtocol(_protocolFor(f.container))]);
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
