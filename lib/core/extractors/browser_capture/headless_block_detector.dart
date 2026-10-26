import '../media_models.dart';
import 'challenge_markup.dart';

/// What a forced-headless capture that loaded a page but found zero media
/// most likely ran into. See [HeadlessBlockDetector.classify].
enum HeadlessVerdict {
  /// Independent challenge evidence: report `HEADLESS_BLOCKED`.
  blocked,

  /// The main document answered 429: report `RATE_LIMITED`.
  rateLimited,

  /// The main document answered 5xx: report `NETWORK`.
  serverError,

  /// No evidence of a block: keep the ordinary no-media outcome.
  notBlocked,
}

/// Decides whether a forced-headless capture that loaded a page but found
/// zero media most likely hit an anti-bot challenge (docs/plan-phase7-
/// coverage-agent.md Lane H, Track A contract). Pure classification over
/// signals the caller already gathered; the only session access is the
/// injected `eval` in [verdictFor].
///
/// Honest by design: this only *names* the likely cause so an agent can
/// retry headed. It never tries to get past the block (no stealth patches,
/// no UA spoofing, no automation-flag hiding), and it is only consulted in
/// forced-headless mode, so the headed path's behavior is untouched.
///
/// Evidence ladder (Phase 7 round 2, Gadfly G1 / Bulwark B3 / Plumbline P2):
///  1. A challenge-page title, or challenge-document markup ([_strongSrcHost],
///     [_challengePlatformPage], an exact [_challengeIds] container, or the
///     [_cfChallengeGlobal] assignment; parsed by [ChallengeMarkup]) wins: that is evidence
///     independent of the status code.
///  2. Otherwise a main-document 429 is `RATE_LIMITED` and a 5xx is
///     `NETWORK`, never `HEADLESS_BLOCKED`.
///  3. Weak signals (a thin body, a Turnstile/challenge-platform script that
///     also ships on ordinary pages) count only with a non-2xx status.
/// Never evidence: bare `datadome`/`perimeterx` substrings (their sensor
/// scripts are on every normal page of those sites), a text-light 200 page
/// (a player-only page), or a failed `Runtime.evaluate` (null).
///
/// Limits: markup is only seen when the caller passes the page's
/// `outerHTML`; a challenge served under a localized title with no markup
/// from the lists below and a 2xx status is not detected.
class HeadlessBlockDetector {
  const HeadlessBlockDetector._();

  /// Visible body text under this many characters (trimmed) is "thin".
  static const int emptyShellTextThreshold = 80;

  static final RegExp _challengeTitle = RegExp(
    r'(just a moment|attention required|access denied|checking your browser|'
    r'verify you are human|are you a robot|robot or human|pardon our interruption|'
    r'prove your humanity|security check)',
    caseSensitive: false,
  );

  /// Hosts that only ever serve challenge documents (DataDome's captcha and
  /// interstitial host, PerimeterX's captcha CDN).
  static final RegExp _strongSrcHost = RegExp(
    r'^(?:https?:)?//(?:[a-z0-9-]+\.)*(?:captcha-delivery\.com|captcha\.px-cdn\.net)(?:[/:?#]|$)',
    caseSensitive: false,
  );

  /// Cloudflare's challenge-page orchestrator. The bare
  /// `/cdn-cgi/challenge-platform/scripts/jsd/` bot-management script ships
  /// on ordinary pages too, so only the `orchestrate` path is strong.
  static final RegExp _challengePlatformPage = RegExp(
    r'/cdn-cgi/challenge-platform/(?:h/[a-z]/)?orchestrate/',
    caseSensitive: false,
  );

  /// Turnstile (`challenges.cloudflare.com`) and the generic
  /// challenge-platform path: present on ordinary pages with a login form
  /// or bot management, so only weak evidence.
  static final RegExp _weakSrc = RegExp(
    r'(?:^(?:https?:)?//challenges\.cloudflare\.com(?:[/:?#]|$)|/cdn-cgi/challenge-platform/)',
    caseSensitive: false,
  );

  /// Container ids only challenge documents use, matched as the EXACT `id`
  /// attribute value of one of [_challengeContainerTags] (astra round 2).
  static const Set<String> _challengeIds = {'px-captcha', 'challenge-form', 'cf-challenge-running'};
  static const Set<String> _challengeContainerTags = {'div', 'form', 'section', 'span'};

  /// Cloudflare's challenge bootstrap global, as an assignment in an inline
  /// script (never a mention in text or a comment).
  static final RegExp _cfChallengeGlobal = RegExp(r'(?:^|[^\w$.])(?:window\.)?_cf_chl_opt\s*=');

  static bool _isSuccess(int? status) => status != null && status >= 200 && status < 300;

  static HeadlessVerdict classify({String? title, String? bodyText, String? html, int? mainDocumentStatus}) {
    if (title != null && _challengeTitle.hasMatch(title)) return HeadlessVerdict.blocked;

    final markup = html == null ? null : ChallengeMarkup.parse(html);
    final srcs = markup?.scriptAndFrameSrcs ?? const <String>[];
    if (srcs.any((s) => _strongSrcHost.hasMatch(s) || _challengePlatformPage.hasMatch(s))) {
      return HeadlessVerdict.blocked;
    }
    if (markup != null) {
      final hasChallengeContainer = markup.elementIds
          .any((e) => _challengeContainerTags.contains(e.$1) && _challengeIds.contains(e.$2));
      if (hasChallengeContainer || markup.inlineScripts.any(_cfChallengeGlobal.hasMatch)) {
        return HeadlessVerdict.blocked;
      }
    }

    if (mainDocumentStatus == 429) return HeadlessVerdict.rateLimited;
    if (mainDocumentStatus != null && mainDocumentStatus >= 500 && mainDocumentStatus < 600) {
      return HeadlessVerdict.serverError;
    }

    final nonSuccess = mainDocumentStatus != null && !_isSuccess(mainDocumentStatus);
    if (!nonSuccess) return HeadlessVerdict.notBlocked;
    final thinBody = bodyText != null && bodyText.trim().length < emptyShellTextThreshold;
    final weakMarkup = srcs.any(_weakSrc.hasMatch);
    return thinBody || weakMarkup ? HeadlessVerdict.blocked : HeadlessVerdict.notBlocked;
  }

  /// Reads title and visible body text through [eval] (one
  /// `Runtime.evaluate` each) and classifies together with [html] and
  /// [mainDocumentStatus]. A failed read (null) is absence of a signal,
  /// never evidence of a block.
  static Future<HeadlessVerdict> verdictFor(
    Future<String?> Function(String expression) eval, {
    String? html,
    int? mainDocumentStatus,
  }) async {
    final title = await eval('document.title');
    final bodyText = await eval("document.body ? document.body.innerText : ''");
    return classify(title: title, bodyText: bodyText, html: html, mainDocumentStatus: mainDocumentStatus);
  }

  static MediaExtractionException exception(Uri url) => MediaExtractionException(
        'HEADLESS_BLOCKED',
        '${url.host} did not serve its media to the headless browser: the page loaded but looks like a '
            'bot-check challenge or a blocked empty page. A headed run (without --headless / MIDA_HEADLESS) may work; '
            'this app never tries to evade the check.',
      );
}
