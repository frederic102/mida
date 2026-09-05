import '../media_models.dart';

/// Pure JSON -> [MediaFormat] mapping for a Bilibili `playurl` API
/// response (`api.bilibili.com/x/player/playurl?bvid=...&cid=...&fnval=16`,
/// DASH mode). Kept free of any I/O so it can be exercised entirely
/// against `test/fixtures/bilibili_playurl.json`. See
/// `BilibiliPageParser`'s doc for this API's live-verification status.
class BilibiliPlayurlParser {
  const BilibiliPlayurlParser();

  /// Throws [MediaExtractionException]: `LOGIN_REQUIRED` for the API's
  /// own `-403`/`-404` codes that mean "log in to watch this" (age-gated
  /// or member-only content), and `UNSUPPORTED_MEDIA` when the response
  /// is `code: 0` (success) but neither `data.dash` nor `data.durl` has
  /// anything - a shape this parser does not recognize, or a live stream.
  List<MediaFormat> parse(Map<String, dynamic> json) {
    final code = json['code'];
    if (code == -403 || code == -404) {
      throw const MediaExtractionException(
        'LOGIN_REQUIRED',
        'This Bilibili video requires logging in (or is age-restricted).',
      );
    }
    if (code != 0 && code != null) {
      throw MediaExtractionException(
        'UNSUPPORTED_MEDIA',
        json['message'] as String? ?? 'Bilibili refused to return this video.',
      );
    }

    final data = json['data'];
    if (data is! Map) {
      throw const MediaExtractionException(
        'UNSUPPORTED_MEDIA',
        'Bilibili returned no playback data for this video.',
      );
    }

    final dash = data['dash'];
    if (dash is Map) {
      final formats = <MediaFormat>[
        ..._parseDashTrackList(dash['video'], isVideo: true),
        ..._parseDashTrackList(dash['audio'], isVideo: false),
      ];
      if (formats.isNotEmpty) return formats;
    }

    final durl = data['durl'];
    if (durl is List && durl.isNotEmpty) {
      return _parseDurl(durl);
    }

    throw const MediaExtractionException(
      'UNSUPPORTED_MEDIA',
      'Bilibili returned no playable renditions for this video (it may be '
          'a live broadcast, not a VOD).',
    );
  }

  List<MediaFormat> _parseDashTrackList(dynamic rawList, {required bool isVideo}) {
    if (rawList is! List) return const [];
    final formats = <MediaFormat>[];
    for (final entry in rawList) {
      if (entry is! Map) continue;
      final url = entry['baseUrl'] as String? ?? entry['base_url'] as String?;
      if (url == null) continue;

      final codecs = entry['codecs'] as String?;
      formats.add(MediaFormat(
        id: '${entry['id'] ?? formats.length}',
        url: url,
        // v.redd.it-style fragmented mp4 (`.m4s`) segments: a plain
        // ranged GET works the same as a regular mp4 (see
        // `NaverVodPlayParser`'s doc for the same reasoning applied to a
        // different CDN), so this is deliberately `mp4`, not a manifest
        // container - there is no separate manifest to fetch.
        container: 'mp4',
        videoCodec: isVideo ? codecs : null,
        audioCodec: isVideo ? null : codecs,
        width: isVideo ? _asInt(entry['width']) : null,
        height: isVideo ? _asInt(entry['height']) : null,
        fps: isVideo ? double.tryParse('${entry['frameRate'] ?? ''}') : null,
        bitrate: _asInt(entry['bandwidth']) ?? 0,
        hasVideo: isVideo,
        hasAudio: !isVideo,
      ));
    }
    return formats;
  }

  List<MediaFormat> _parseDurl(List<dynamic> durl) {
    final formats = <MediaFormat>[];
    for (final entry in durl) {
      if (entry is! Map) continue;
      final url = entry['url'] as String?;
      if (url == null) continue;
      formats.add(MediaFormat(
        id: '${entry['order'] ?? formats.length}',
        url: url,
        container: 'mp4',
        bitrate: _asInt(entry['bandwidth']) ?? 0,
        contentLength: _asInt(entry['size']),
        // `durl` is Bilibili's legacy progressive (already-muxed) delivery,
        // used when DASH is unavailable for this video.
        hasVideo: true,
        hasAudio: true,
      ));
    }
    return formats;
  }

  int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
