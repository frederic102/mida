import 'dart:convert';

import '../../services/browser_devtools_session.dart';

/// Best-effort playback nudges applied to the top-level page and every
/// auto-attached child (iframe) target - see
/// `docs/plan-phase5-coverage.md` Lane A #1 and #5. A great many
/// arbitrary video sites never fire a single media request until
/// *something* (a click, a scroll, an explicit muted `.play()`) actually
/// starts playback, and the real player just as often lives inside a
/// cross-origin iframe rather than the top-level document (Vimeo's does;
/// see `BrowserDevtoolsSession`'s own child-session-tracking comment).
///
/// Every step here is fire-and-forget best-effort, matching the contract
/// `BrowserCaptureExtractor._tryAutoplay` already had before this file
/// existed: a selector matching nothing, a `play()` rejected by the
/// browser's autoplay policy, or a child session that has already closed
/// must never abort the capture.
class PlaybackTrigger {
  const PlaybackTrigger._();

  /// Common "play" affordances across arbitrary sites: aria-label/title
  /// text (English "play" and Korean "재생"), test-id hooks, and a few
  /// well-known player frameworks' own button classes.
  static const List<String> _playButtonSelectors = [
    'button[aria-label*="play" i]',
    'button[title*="play" i]',
    '[data-testid*="play" i]',
    '[class*="play-button" i]',
    '[class*="playbutton" i]',
    '.ytp-large-play-button',
    '.vjs-big-play-button',
    'button[aria-label*="재생"]',
    'button[title*="재생"]',
  ];

  static String get _clickButtonsExpression {
    final selectorList = jsonEncode(_playButtonSelectors);
    return '''
(function () {
  var selectors = $selectorList;
  var seen = [];
  selectors.forEach(function (sel) {
    try {
      document.querySelectorAll(sel).forEach(function (el) {
        if (seen.indexOf(el) !== -1) return;
        seen.push(el);
        el.click();
      });
    } catch (e) {}
  });
  return true;
})()
''';
  }

  static const String _mutedPlayExpression = '''
(function () {
  document.querySelectorAll('video').forEach(function (v) {
    try {
      v.muted = true;
      var p = v.play();
      if (p && p.catch) p.catch(function () {});
    } catch (e) {}
  });
  return true;
})()
''';

  static const String _scrollExpression = '''
(function () {
  try {
    window.scrollBy(0, Math.round(window.innerHeight * 0.5));
  } catch (e) {}
  return true;
})()
''';

  /// A visible player-shaped element's center, in the target's own
  /// viewport coordinates, for [Input.dispatchMouseEvent] to click - a
  /// synthetic `Runtime.evaluate .click()` call never satisfies a site's
  /// own "was this a real user gesture" check, which is exactly the
  /// class of site this coordinate-based click exists for. Falls back to
  /// the viewport's own center when nothing player-shaped is found
  /// (still a harmless no-op click on a page with no player at all).
  static const String _playerCenterExpression = '''
(function () {
  var el = document.querySelector('video') ||
    document.querySelector('[class*="player" i]') ||
    document.querySelector('[id*="player" i]');
  var rect = el ? el.getBoundingClientRect() : null;
  if (rect && rect.width > 0 && rect.height > 0) {
    return JSON.stringify({x: rect.left + rect.width / 2, y: rect.top + rect.height / 2});
  }
  return JSON.stringify({x: window.innerWidth / 2, y: window.innerHeight / 2});
})()
''';

  /// Applies every trigger once to the top-level target and once to each
  /// currently attached child (iframe) target.
  static Future<void> triggerAll(DevtoolsSession session) async {
    await _triggerOn(session, null);
    for (final childSessionId in session.childSessionIds) {
      await _triggerOn(session, childSessionId);
    }
  }

  static Future<void> _triggerOn(DevtoolsSession session, String? childSessionId) async {
    await _evaluate(session, childSessionId, _clickButtonsExpression);
    await _dispatchCenterClick(session, childSessionId);
    await _evaluate(session, childSessionId, _mutedPlayExpression);
    await _evaluate(session, childSessionId, _scrollExpression);
  }

  static Future<void> _dispatchCenterClick(DevtoolsSession session, String? childSessionId) async {
    final raw = await _evaluate(session, childSessionId, _playerCenterExpression);
    if (raw == null) return;
    double? x, y;
    try {
      final decoded = jsonDecode(raw) as Map;
      x = (decoded['x'] as num?)?.toDouble();
      y = (decoded['y'] as num?)?.toDouble();
    } catch (_) {
      return;
    }
    if (x == null || y == null) return;

    try {
      await _send(session, childSessionId, 'Input.dispatchMouseEvent', {
        'type': 'mousePressed',
        'x': x,
        'y': y,
        'button': 'left',
        'clickCount': 1,
      });
      await _send(session, childSessionId, 'Input.dispatchMouseEvent', {
        'type': 'mouseReleased',
        'x': x,
        'y': y,
        'button': 'left',
        'clickCount': 1,
      });
    } catch (_) {
      // Best-effort synthetic click; a target that rejects Input.* (or
      // has closed in the meantime) is not a capture failure on its own.
    }
  }

  static Future<String?> _evaluate(DevtoolsSession session, String? childSessionId, String expression) async {
    try {
      final result = await _send(session, childSessionId, 'Runtime.evaluate', {
        'expression': expression,
        'returnByValue': true,
      });
      final value = (result['result'] as Map?)?['value'];
      return value is String ? value : null;
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>> _send(
    DevtoolsSession session,
    String? childSessionId,
    String method,
    Map<String, dynamic> params,
  ) {
    return childSessionId == null ? session.send(method, params) : session.sendToSession(childSessionId, method, params);
  }
}
