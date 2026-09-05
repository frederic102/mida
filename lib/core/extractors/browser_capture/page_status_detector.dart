/// Which non-media reason a browser-capture page most likely fell into
/// when no media was ever observed. Distinguished so
/// `BrowserCaptureExtractor` can report something more specific than a
/// blanket `NO_MEDIA_FOUND` for the most common causes in practice (a
/// login-gated post, one that has been removed/never existed, or a
/// Cloudflare/reCAPTCHA-style bot-check interstitial this app must never
/// try to solve - see `BrowserCaptureExtractor._exceptionForSignal`).
enum PageStatusSignal { loginRequired, notFound, botCheckRequired }

/// Pure classification of "why didn't this page have any media" from a
/// small set of signals gathered during capture: the page's final URL
/// (after any redirect), its title, and the HTTP status of its own main
/// document response. No network/DOM access here - callers gather those
/// signals themselves (from `Runtime.evaluate location.href`/`document
/// .title` and `Network.responseReceived`, respectively) and pass them in.
class PageStatusDetector {
  const PageStatusDetector._();

  static final RegExp _loginPathPattern = RegExp(
    r'(^|/)(accounts/login|login)(/|$|\?)',
    caseSensitive: false,
  );

  static final RegExp _loginTitlePattern = RegExp(r'\b(log ?in|sign ?in)\b', caseSensitive: false);

  /// Titles real anti-bot interstitials actually use (observed live,
  /// docs/plan-phase5-coverage.md 2026-09-05 diagnostic run: Reddit's own
  /// "Reddit - Prove your humanity"; Cloudflare's generic challenge page is
  /// literally titled "Just a moment...", its harder-block variant
  /// "Attention Required!"). Never a page actually *about* passing a
  /// challenge (a game walkthrough, say) matching by accident is an
  /// accepted, narrow risk - these phrases are specific enough in practice
  /// that the false-positive rate observed so far is zero.
  static final RegExp _botCheckTitlePattern = RegExp(
    r'(prove your humanity|verify you are human|just a moment|checking your browser|attention required)',
    caseSensitive: false,
  );

  static PageStatusSignal? detect({
    required Uri finalUrl,
    String? title,
    int? mainDocumentStatusCode,
  }) {
    if (_loginPathPattern.hasMatch(finalUrl.path)) return PageStatusSignal.loginRequired;
    if (title != null && _loginTitlePattern.hasMatch(title)) return PageStatusSignal.loginRequired;
    if (title != null && _botCheckTitlePattern.hasMatch(title)) return PageStatusSignal.botCheckRequired;
    if (mainDocumentStatusCode == 404) return PageStatusSignal.notFound;
    return null;
  }
}
