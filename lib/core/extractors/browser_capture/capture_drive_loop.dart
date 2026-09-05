import 'dart:async';

import '../../services/browser_devtools_session.dart';
import 'captured_media_classifier.dart';
import 'consent_dialog_dismisser.dart';
import 'playback_trigger.dart';

/// The wait-and-retry policy `BrowserCaptureExtractor._driveCapture`
/// delegates to, once the page's own `Page.loadEventFired` has already
/// fired - see `docs/plan-phase5-coverage.md` Lane A #1-2. Split out of
/// `BrowserCaptureExtractor` (which owns event collection and format
/// assembly) to keep both files under this project's 400-line cap; this
/// half owns only "when to nudge playback again, and how long to keep
/// waiting for a first candidate" and needs nothing from the extractor
/// beyond the running candidates map it is passed.
class CaptureDriveLoop {
  const CaptureDriveLoop._();

  /// 1. Waits [postLoadDelay], then fires [PlaybackTrigger] once (many
  ///    sites start their own media requests well within this window with
  ///    no nudge needed at all).
  /// 2. If [candidates] is still empty, waits [autoplayRetryDelay] for
  ///    that first nudge to bear fruit.
  /// 3. If still empty, polls every [pollInterval] up to
  ///    [firstCandidateTimeout] total, firing one more [PlaybackTrigger]
  ///    pass at the halfway point (a site whose player only appears after
  ///    an XHR-driven "loading" screen needs a second, later nudge - one
  ///    attempt right after load is not always enough).
  /// 4. Once [candidates] is non-empty (whether from step 1, mid-poll, or
  ///    already before this call even started) *and none of them is
  ///    already a whole manifest* (`m3u8`/`mpd`), waits [variantSettleDelay]
  ///    longer so sibling-quality variants of the same stream - which
  ///    tend to land within a second or two of each other - are not
  ///    missed by returning the instant the very first one appears. A
  ///    manifest candidate already enumerates every variant itself (its
  ///    own fetch-and-parse happens later, in `CapturedFormatBuilder`), so
  ///    there are no siblings left to wait for.
  static Future<void> run(
    DevtoolsSession session,
    Map<String, CapturedMediaCandidate> candidates, {
    required Duration postLoadDelay,
    required Duration autoplayRetryDelay,
    required Duration firstCandidateTimeout,
    required Duration variantSettleDelay,
    required Duration pollInterval,
  }) async {
    await Future<void>.delayed(postLoadDelay);
    // Dismiss a consent/age-gate overlay before ever trying to click a
    // play-shaped element underneath it - see ConsentDialogDismisser's own
    // doc for why this has to run first, not just "also".
    await ConsentDialogDismisser.dismiss(session);
    await PlaybackTrigger.triggerAll(session);

    if (candidates.isEmpty) {
      await Future<void>.delayed(autoplayRetryDelay);
    }

    if (candidates.isEmpty) {
      final halfway = Duration(microseconds: firstCandidateTimeout.inMicroseconds ~/ 2);
      final stopwatch = Stopwatch()..start();
      var retriggered = false;
      while (candidates.isEmpty && stopwatch.elapsed < firstCandidateTimeout) {
        if (!retriggered && stopwatch.elapsed >= halfway) {
          await ConsentDialogDismisser.dismiss(session);
          await PlaybackTrigger.triggerAll(session);
          retriggered = true;
        }
        await Future<void>.delayed(pollInterval);
      }
    }

    final hasManifestCandidate = candidates.values.any((c) => c.container == 'm3u8' || c.container == 'mpd');
    if (candidates.isNotEmpty && !hasManifestCandidate) {
      await Future<void>.delayed(variantSettleDelay);
    }
  }
}
