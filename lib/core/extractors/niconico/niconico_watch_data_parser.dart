import 'dart:convert';

import '../media_models.dart';

typedef NiconicoWatchData = ({
  String id,
  String title,
  String? author,
  String? thumbnailUrl,
  Duration? duration,
  Map<String, dynamic> sessionApi,
});

/// Pure HTML -> [NiconicoWatchData] mapping for a Niconico watch page's
/// legacy `<div id="js-initial-watch-data" data-api-data="...">`
/// attribute (HTML-entity-encoded JSON carrying the video's metadata plus
/// `media.delivery.movie.session.videos`/`audios`/`session_api` -
/// everything [NiconicoDmcSessionClient] needs to start a DMS/DMC
/// playback session). Kept free of any I/O so it can be exercised
/// entirely against `test/fixtures/niconico_watch_data.html`.
///
/// Not live-verified against the current site
/// (`docs/plan-phase5-coverage.md` Lane D report): fetching
/// `nicovideo.jp/watch/sm9` live 2026-09-05 returned a React-Router-based
/// SPA shell with no `js-initial-watch-data` (or any other embedded JSON)
/// at all - the site has migrated to loading watch data client-side via
/// `nvapi.nicovideo.jp` behind an auth check this pass could not clear
/// (`UNAUTHORIZED` with a session cookie and matching `Referer`, tried
/// within budget). This parser implements the long-documented legacy
/// shape (still the one most third-party Niconico tools reference); when
/// the current page does not have it, [NiconicoExtractor] throws
/// `PARSE_ERROR` so `ExtractorRegistry` falls through to
/// `BrowserCaptureExtractor`.
class NiconicoWatchDataParser {
  const NiconicoWatchDataParser();

  static final _dataAttrPattern = RegExp(
    r'id="js-initial-watch-data"[^>]*data-api-data="([^"]*)"',
  );

  /// Returns `null` (rather than throwing) when the attribute is not
  /// present at all - the caller decides what that means (currently
  /// always "fall through to a different technique").
  NiconicoWatchData? tryParse(String html) {
    final match = _dataAttrPattern.firstMatch(html);
    if (match == null) return null;

    final decoded = _unescapeHtml(match.group(1)!);
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(decoded) as Map<String, dynamic>;
    } on FormatException {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'MiDa could not read this Niconico page\'s video data.',
      );
    }

    final video = data['video'];
    if (video is! Map) {
      // PARSE_ERROR (fall-through eligible), not the terminal NOT_FOUND
      // an earlier version of this parser used: the attribute decoded as
      // valid JSON but without a `video` object is not live-confirmed to
      // mean "this id does not exist" specifically, versus some other
      // anti-bot/degraded-response shape this pass never observed (the
      // current site does not serve this attribute at all - see the
      // class doc); per the same reasoning `BilibiliPageParser` and
      // `DouyinRenderDataParser` document for their analogous cases, the
      // safer default is fall-through eligible.
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'MiDa could not find video data in this Niconico page\'s watch data.',
      );
    }

    final media = video['dmcInfo'] ?? data['media'];
    final delivery = media is Map ? media['delivery'] : null;
    final movie = delivery is Map ? delivery['movie'] : null;
    final deliverySession = movie is Map ? movie['session'] : null;
    final sessionApi = deliverySession ?? (media is Map ? media['session_api'] : null);
    if (sessionApi is! Map) {
      throw const MediaExtractionException(
        'UNSUPPORTED_MEDIA',
        'This Niconico video has no DMC/DMS session data (it may need a '
            'premium account, or be region/age restricted).',
      );
    }

    final owner = video['owner'] ?? data['owner'];
    return (
      id: video['id'] as String? ?? '',
      title: video['title'] as String? ?? 'Untitled',
      author: owner is Map ? owner['nickname'] as String? : null,
      thumbnailUrl: _thumbnailUrl(video['thumbnail']),
      duration: _durationFromSeconds(video['duration']),
      sessionApi: sessionApi.cast<String, dynamic>(),
    );
  }

  String? _thumbnailUrl(dynamic thumbnail) {
    if (thumbnail is String) return thumbnail;
    if (thumbnail is Map) return thumbnail['url'] as String? ?? thumbnail['largeUrl'] as String?;
    return null;
  }

  Duration? _durationFromSeconds(dynamic raw) {
    if (raw is int) return Duration(seconds: raw);
    if (raw is num) return Duration(seconds: raw.toInt());
    return null;
  }

  String _unescapeHtml(String value) => value
      .replaceAll('&quot;', '"')
      .replaceAll('&amp;', '&')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
}
