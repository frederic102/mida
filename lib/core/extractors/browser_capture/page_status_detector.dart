/// Which non-media reason a browser-capture page most likely fell into
/// when no media was ever observed. Distinguished so
/// `BrowserCaptureExtractor` can report something more specific than a
/// blanket `NO_MEDIA_FOUND` for the two most common causes in practice
/// (a login-gated post, or one that has been removed/never existed).
enum PageStatusSignal { loginRequired, notFound }

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

  static PageStatusSignal? detect({
    required Uri finalUrl,
    String? title,
    int? mainDocumentStatusCode,
  }) {
    if (_loginPathPattern.hasMatch(finalUrl.path)) return PageStatusSignal.loginRequired;
    if (title != null && _loginTitlePattern.hasMatch(title)) return PageStatusSignal.loginRequired;
    if (mainDocumentStatusCode == 404) return PageStatusSignal.notFound;
    return null;
  }
}
