import 'dart:convert';

import '../../services/browser_devtools_session.dart';

/// Clicks an EU-cookie-consent/age-verification dialog's own "accept"
/// button before [PlaybackTrigger] ever runs - see
/// `docs/plan-phase5-coverage.md` Lane A follow-up (2026-09-05 diagnostic
/// run): several sites never mount a `<video>` at all until a consent or
/// age-gate overlay is dismissed, so no amount of clicking play-shaped
/// elements underneath it ever starts playback. Matches by visible text
/// (English/Korean/Chinese "accept"/"agree"/consent phrasing), not by
/// class name or aria-label the way [PlaybackTrigger]'s own play-button
/// selectors do - a consent button's own markup rarely says "play"
/// anywhere, but it almost always says something from this list somewhere
/// in its own text.
///
/// Same fire-and-forget contract as [PlaybackTrigger]: a page with no
/// dialog at all, a selector matching nothing, or a target that has
/// already closed must never abort the capture.
class ConsentDialogDismisser {
  const ConsentDialogDismisser._();

  static const List<String> _matchTexts = [
    'accept all',
    'allow all',
    'i accept',
    'accept',
    'agree',
    'i agree',
    'got it',
    'i am over 18',
    'i am 18',
    'enter',
    '동의',
    '확인',
    '수락',
    '모두 동의',
    '同意',
    '我同意',
    '接受',
    '确定',
  ];

  /// Test-only window onto [_dismissExpression] (which real callers never
  /// need directly - [dismiss] sends it for them).
  static String get debugDismissExpression => _dismissExpression;

  static String get _dismissExpression {
    final needles = jsonEncode(_matchTexts);
    return '''
(function () {
  var needles = $needles;
  var clicked = 0;
  var candidates = document.querySelectorAll(
    'button, a[role="button"], [role="button"], input[type="button"], input[type="submit"]'
  );
  candidates.forEach(function (el) {
    if (clicked >= 5) return;
    var text = (el.innerText || el.value || el.getAttribute('aria-label') || '').trim().toLowerCase();
    if (!text || text.length > 40) return;
    for (var i = 0; i < needles.length; i++) {
      if (text === needles[i] || text.indexOf(needles[i]) !== -1) {
        try { el.click(); clicked++; } catch (e) {}
        return;
      }
    }
  });
  return clicked;
})()
''';
  }

  /// Applies once to the top-level target and once to each currently
  /// attached child (iframe) target - a consent overlay is sometimes
  /// itself served from a cross-origin CMP iframe (e.g. OneTrust,
  /// Cookiebot), matching why [PlaybackTrigger] does the same.
  static Future<void> dismiss(DevtoolsSession session) async {
    await _dismissOn(session, null);
    for (final childSessionId in session.childSessionIds) {
      await _dismissOn(session, childSessionId);
    }
  }

  static Future<void> _dismissOn(DevtoolsSession session, String? childSessionId) async {
    try {
      final params = {'expression': _dismissExpression, 'returnByValue': true};
      if (childSessionId == null) {
        await session.send('Runtime.evaluate', params);
      } else {
        await session.sendToSession(childSessionId, 'Runtime.evaluate', params);
      }
    } catch (_) {
      // Best-effort nudge; see class doc.
    }
  }
}
