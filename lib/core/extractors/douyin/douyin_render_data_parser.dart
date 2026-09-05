import '../media_models.dart';

/// Pure JSON -> [MediaInfo] mapping for the decoded `RENDER_DATA` payload
/// on a Douyin video page (`<script id="RENDER_DATA"
/// type="application/json">` - URI-encoded JSON; decoding it is the
/// caller's job, this class only reads the resulting tree). Kept free of
/// any I/O so it can be exercised entirely against
/// `test/fixtures/douyin_render_data.json`.
///
/// `RENDER_DATA` is keyed by opaque numeric strings that change between
/// page loads, so this walks every top-level value looking for the one
/// shaped like `{"aweme":{"detail": {...}}}` rather than assuming a fixed
/// key - the long-documented technique every third-party Douyin
/// downloader uses. Not live-verified end to end
/// (`docs/plan-phase5-coverage.md` Lane D report): every request this
/// pass made to `www.douyin.com` returned Douyin's JS-VM anti-bot
/// interstitial (a custom bytecode challenge, not solvable without
/// executing real JS) instead of a rendered page, so `RENDER_DATA` was
/// never actually observed live this pass - this is the documented shape
/// used broadly by other public tools, not a captured fixture.
class DouyinRenderDataParser {
  const DouyinRenderDataParser();

  /// Throws [MediaExtractionException] (`PARSE_ERROR`) when no
  /// `aweme.detail` node is found anywhere in the tree, and
  /// (`UNSUPPORTED_MEDIA`) when it is found but has no usable play
  /// address at all.
  ///
  /// `PARSE_ERROR`, not the terminal `NOT_FOUND` an earlier version of
  /// this parser used: a `RENDER_DATA` tag with no `aweme.detail` anywhere
  /// in it was not live-observed this pass (every live request hit the
  /// JS-VM shell first, caught separately in `DouyinExtractor` before
  /// this parser ever runs), so there is no live evidence distinguishing
  /// "genuinely wrong/deleted id" from "an anti-bot decoy payload that
  /// still parses as valid JSON" - per the same reasoning
  /// `BilibiliPageParser` documents for its analogous case, the safer
  /// default is fall-through eligible, not terminal.
  MediaInfo parse(Map<String, dynamic> renderData, {required Uri sourceUrl, required Map<String, String> requestHeaders}) {
    final detail = _findAwemeDetail(renderData);
    if (detail == null) {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'MiDa could not find video data in this Douyin page\'s render data.',
      );
    }

    final formats = _parseFormats(detail);
    if (formats.isEmpty) {
      throw const MediaExtractionException(
        'UNSUPPORTED_MEDIA',
        'Douyin returned no playable renditions for this video.',
      );
    }

    final author = detail['author'];
    final video = detail['video'];
    return MediaInfo(
      id: '${detail['aweme_id'] ?? ''}',
      title: detail['desc'] as String? ?? 'Untitled',
      author: author is Map ? author['nickname'] as String? : null,
      thumbnailUrl: _firstUrl(video is Map ? video['cover'] : null),
      duration: _durationFromMillis(video is Map ? video['duration'] : null),
      formats: formats,
      sourceUrl: sourceUrl,
      requestHeaders: requestHeaders,
    );
  }

  Map<String, dynamic>? _findAwemeDetail(dynamic node, {int depth = 0}) {
    if (depth > 6 || node == null) return null;
    if (node is Map) {
      final aweme = node['aweme'];
      if (aweme is Map && aweme['detail'] is Map) {
        return (aweme['detail'] as Map).cast<String, dynamic>();
      }
      for (final value in node.values) {
        final found = _findAwemeDetail(value, depth: depth + 1);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final value in node) {
        final found = _findAwemeDetail(value, depth: depth + 1);
        if (found != null) return found;
      }
    }
    return null;
  }

  List<MediaFormat> _parseFormats(Map<String, dynamic> detail) {
    final video = detail['video'];
    if (video is! Map) return const [];

    final formats = <MediaFormat>[];

    // Per-bitrate renditions, when present, are the highest quality and
    // (unlike `play_addr`) not watermarked.
    final bitRateList = video['bit_rate'];
    if (bitRateList is List) {
      for (final entry in bitRateList) {
        if (entry is! Map) continue;
        final url = _firstUrl(entry['play_addr']);
        if (url == null) continue;
        formats.add(MediaFormat(
          id: '${entry['gear_name'] ?? entry['bit_rate'] ?? formats.length}',
          url: url,
          container: 'mp4',
          bitrate: _asInt(entry['bit_rate']) ?? 0,
          width: _asInt(entry['play_addr']?['width']),
          height: _asInt(entry['play_addr']?['height']),
          hasVideo: true,
          hasAudio: true,
        ));
      }
    }

    if (formats.isEmpty) {
      final fallbackUrl = _firstUrl(video['play_addr']);
      if (fallbackUrl != null) {
        formats.add(MediaFormat(
          id: 'default',
          url: fallbackUrl,
          container: 'mp4',
          width: _asInt(video['width']),
          height: _asInt(video['height']),
          hasVideo: true,
          hasAudio: true,
        ));
      }
    }

    return formats;
  }

  String? _firstUrl(dynamic node) {
    if (node is! Map) return null;
    final list = node['url_list'];
    if (list is! List || list.isEmpty) return null;
    // Prefer an `https://` entry (Douyin sometimes lists a `http://`
    // mirror first); fall back to whatever is first if none match.
    for (final entry in list) {
      if (entry is String && entry.startsWith('https://')) return entry;
    }
    return list.first as String?;
  }

  Duration? _durationFromMillis(dynamic raw) {
    if (raw is int) return Duration(milliseconds: raw);
    if (raw is num) return Duration(milliseconds: raw.toInt());
    return null;
  }

  int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
