import 'dart:convert';

import '../media_models.dart';

typedef BilibiliPageInfo = ({
  String bvid,
  int cid,
  String title,
  String? author,
  String? thumbnailUrl,
  Duration? duration,
});

/// Pure HTML -> [BilibiliPageInfo] mapping for a Bilibili watch page
/// (`www.bilibili.com/video/<BV...>`). Kept free of any I/O so it can be
/// exercised entirely against `test/fixtures/bilibili_initial_state.html`.
///
/// Reads the `window.__INITIAL_STATE__ = {...};` blob every Bilibili watch
/// page server-renders, which carries `cid` (the numeric stream id the
/// `playurl` API needs alongside the `bvid` in the URL) plus title/
/// owner/pic/duration.
///
/// Live-verified 2026-09-05 (`docs/plan-phase5-coverage.md` Lane D +
/// follow-up reports) that this page is served two different ways when
/// Bilibili's WAF does not trust the request: sometimes a hard HTTP 412
/// with an `X-BILI-SEC-TOKEN` challenge cookie (caught earlier, at the
/// HTTP-status layer, by `BilibiliExtractor`), and sometimes a soft block
/// - HTTP 200 with a validly-JSON-shaped but intentionally empty
/// `__INITIAL_STATE__` (`"videoData":{"stat":{},"owner":{}}`, no `cid`
/// key at all, alongside an equally-empty `availableVideoList`). Both are
/// anti-bot outcomes indistinguishable, from this response alone, from a
/// genuinely deleted/private video (which likely renders the same empty
/// shell rather than a distinct error shape - not confirmed live, no
/// known-deleted BV id was available to test against). Given that
/// ambiguity, a missing `cid` is deliberately `CHALLENGE_FAILED` (fall-
/// through eligible), not the terminal `NOT_FOUND` an earlier version of
/// this parser used - which was silently blocking
/// `BrowserCaptureExtractor` (a real browser the WAF's soft block does
/// not fingerprint the same way) from ever getting a chance at a video
/// this technique merely failed to read, per the same reasoning
/// `SoundCloudHydrationParser` documents for its own PARSE_ERROR case.
class BilibiliPageParser {
  const BilibiliPageParser();

  static final _initialStatePattern = RegExp(
    r'window\.__INITIAL_STATE__\s*=\s*(\{.*?\});',
    dotAll: true,
  );

  /// Throws [MediaExtractionException] (`PARSE_ERROR`) when the page has
  /// no `__INITIAL_STATE__` blob at all, and (`CHALLENGE_FAILED`) when it
  /// parses but carries no `cid` - see the class doc for why this is
  /// fall-through eligible rather than terminal.
  BilibiliPageInfo parse(String html, {required String bvid}) {
    final match = _initialStatePattern.firstMatch(html);
    if (match == null) {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'MiDa could not find video data on this Bilibili page (it may have '
            'served an anti-bot challenge page instead).',
      );
    }

    final Map<String, dynamic> state;
    try {
      state = jsonDecode(match.group(1)!) as Map<String, dynamic>;
    } on FormatException {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'MiDa could not read this Bilibili page\'s video data.',
      );
    }

    final videoData = state['videoData'];
    final cid = videoData is Map ? videoData['cid'] : null;
    if (cid is! int) {
      throw const MediaExtractionException(
        'CHALLENGE_FAILED',
        'Bilibili did not return playable video data for this page (it may '
            'have served an anti-bot soft block instead).',
      );
    }

    return (
      bvid: bvid,
      cid: cid,
      title: videoData is Map ? (videoData['title'] as String? ?? 'Untitled') : 'Untitled',
      author: videoData is Map ? (videoData['owner']?['name'] as String?) : null,
      thumbnailUrl: videoData is Map ? videoData['pic'] as String? : null,
      duration: videoData is Map ? _durationFromSeconds(videoData['duration']) : null,
    );
  }

  Duration? _durationFromSeconds(dynamic raw) {
    if (raw is int) return Duration(seconds: raw);
    if (raw is num) return Duration(seconds: raw.toInt());
    return null;
  }
}
