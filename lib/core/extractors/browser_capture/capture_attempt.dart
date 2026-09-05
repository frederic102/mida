import '../media_models.dart';

/// One `BrowserCaptureExtractor._attemptCapture` outcome: exactly one of
/// [info]/[error] is set (never both, never neither), plus whether the
/// page itself finished loading during this attempt - see
/// `BrowserCaptureExtractor.extract` for how [loadFired] gates the
/// headed-mode robustness retry. Split into its own file only to keep
/// `browser_capture_extractor.dart` under this project's 400-line cap.
class CaptureAttempt {
  final MediaInfo? info;
  final MediaExtractionException? error;
  final bool loadFired;

  const CaptureAttempt({this.info, this.error, required this.loadFired});
}

/// Whether `BrowserCaptureExtractor.extract` should retry the whole
/// capture once in headless mode after [first] failed to find media - a
/// pure decision matrix, split out so it is unit-testable on its own
/// without a full session/browser flow. Only true when [first] truly
/// found nothing (`info == null`), a real browser is in play (a
/// test-injected session launcher has no headed/headless concept for a
/// retry to differ on at all), and the page itself never finished loading
/// (a page that loaded fine and simply had no media would fail
/// identically in headless too).
bool shouldRetryHeadless(CaptureAttempt first, {required bool hasInjectedSessionLauncher}) {
  return first.info == null && !hasInjectedSessionLauncher && !first.loadFired;
}
