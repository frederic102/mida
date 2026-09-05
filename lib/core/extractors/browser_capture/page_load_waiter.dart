import 'dart:async';

import '../../services/browser_devtools_session.dart';
import 'captured_media_classifier.dart';

/// Waits for `Page.loadEventFired`, bounded by [loadTimeout] - split out of
/// `BrowserCaptureExtractor` to keep that file under this project's
/// 400-line cap.
class PageLoadWaiter {
  const PageLoadWaiter._();

  /// Returns whether `Page.loadEventFired` was actually observed. Also
  /// returns early (`true`... no - see below) as soon as [candidates] is
  /// non-empty, even if the load event never arrives at all - a heavy page
  /// (docs/plan-phase5-coverage.md: Bilibili's own DASH player starts real
  /// media requests within ~5s while the rest of the page, ads/comments/
  /// recommendation widgets included, keeps loading for much longer) can
  /// already have the media this whole capture exists to find long before
  /// its own `load` event fires; there is nothing left to wait for once
  /// that is true. The return value still reflects only whether the load
  /// event itself fired (used by `BrowserCaptureExtractor` to decide
  /// whether a later media-less result is worth a headless retry) -
  /// exiting early for [candidates] rather than the load event is not the
  /// same as the load event having fired.
  static Future<bool> wait(
    DevtoolsSession session,
    Map<String, CapturedMediaCandidate> candidates, {
    required Duration loadTimeout,
  }) async {
    final loadCompleter = Completer<void>();
    final loadSub = session.events.listen((event) {
      if (event.method == 'Page.loadEventFired' && !loadCompleter.isCompleted) {
        loadCompleter.complete();
      }
    });
    try {
      final stopwatch = Stopwatch()..start();
      while (!loadCompleter.isCompleted && candidates.isEmpty && stopwatch.elapsed < loadTimeout) {
        await Future.any<void>([
          loadCompleter.future,
          Future<void>.delayed(const Duration(milliseconds: 200)),
        ]);
      }
      return loadCompleter.isCompleted;
    } finally {
      await loadSub.cancel();
    }
  }
}
