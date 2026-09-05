import 'dart:convert';

import '../media_models.dart';

/// Pure JSON -> [MediaInfo] mapping for a TikTok video-detail page (the
/// `__UNIVERSAL_DATA_FOR_REHYDRATION__` script tag TikTok's second response
/// carries once the wafchallenge is solved). Kept free of any I/O so it can
/// be exercised entirely against `test/fixtures/tiktok_universal_data.json`.
///
/// Field mapping verified live 2026-09-05 against
/// `https://www.tiktok.com/@hankgreen1/video/7047596209028074758`
/// (`docs/plan-phase2-extractors.md` TikTok section):
/// `__DEFAULT_SCOPE__["webapp.video-detail"]`: `statusCode` (0 = ok),
/// `itemInfo.itemStruct`: `desc` (title), `video.duration` (seconds),
/// `video.cover` (thumbnail), `video.bitrateInfo[]` (`Bitrate`,
/// `PlayAddr`{`UrlList[]`, `Width`, `Height`, `UrlKey`, `DataSize`}), with a
/// `video.playAddr` string fallback for the (rare) shape that has no
/// `bitrateInfo` at all. A live byte-level `ffprobe` of a real
/// `bitrateInfo` progressive URL came back muxed h264+aac, so renditions
/// are muxed mp4 when [_parseFormats]'s `hasAudioSignal` heuristic
/// (`item.music` presence, see its call site) says so - see that method's
/// doc for why there is no cleaner per-rendition signal to use instead.
class TikTokPageParser {
  const TikTokPageParser();

  static final RegExp _universalDataPattern = RegExp(
    r'<script[^>]+\bid="__UNIVERSAL_DATA_FOR_REHYDRATION__"[^>]*>(.*?)</script>',
    dotAll: true,
  );

  /// True when [html] carries the rehydration payload at all, without
  /// paying for a full [parse]. Callers use this to decide whether a
  /// wafchallenge still needs solving.
  static bool hasUniversalData(String html) => _universalDataPattern.hasMatch(html);

  /// Throws [MediaExtractionException]:
  /// - `PARSE_ERROR` when [html] does not carry the rehydration payload, or
  ///   it is not valid/expected JSON.
  /// - `PRIVATE` for `statusCode` 10216/10222 (video set to private/friends).
  /// - `RATE_LIMITED` for `statusCode` 10204 (TikTok blocking this IP).
  /// - `NOT_FOUND` for any other non-zero `statusCode`, or a missing
  ///   `itemStruct`.
  /// - `UNSUPPORTED_MEDIA` when the post has no playable video rendition at
  ///   all (TikTok photo posts have no `bitrateInfo`/`playAddr`).
  MediaInfo parse(
    String html, {
    required Uri sourceUrl,
    required Map<String, String> requestHeaders,
  }) {
    final match = _universalDataPattern.firstMatch(html);
    if (match == null) {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'TikTok returned a page MiDa could not read the video data from.',
      );
    }

    final Map<String, dynamic> data;
    try {
      data = jsonDecode(match.group(1)!) as Map<String, dynamic>;
    } on FormatException {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        "TikTok's page data was not valid JSON.",
      );
    }

    final scope = data['__DEFAULT_SCOPE__'];
    final detail = scope is Map ? scope['webapp.video-detail'] : null;
    if (detail is! Map) {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        "TikTok's page did not include video-detail data.",
      );
    }

    _checkStatusCode(_asInt(detail['statusCode']) ?? 0);

    final itemInfo = detail['itemInfo'];
    final item = itemInfo is Map ? itemInfo['itemStruct'] : null;
    if (item is! Map) {
      throw const MediaExtractionException(
        'NOT_FOUND',
        'This TikTok video no longer exists or the link is wrong.',
      );
    }

    final video = item['video'];
    // TikTok's itemStruct has no explicit per-rendition "this file has an
    // audio track" boolean: `bitrateInfo[].CodecType` is the *video* codec
    // (verified live: "h264"/"h265_hvc1" values, never an audio codec), not
    // an audio signal. `item.music` (present for virtually every post - even
    // "original sound" gets one) is the closest real proxy available, and
    // matches a live byte-level `ffprobe` of a real `bitrateInfo` progressive
    // URL coming back muxed h264+aac when `music` was present. This is a
    // heuristic, not a guarantee: the download pipeline's own ffprobe check
    // on the fetched file is the actual safety net for the rare post where
    // it is wrong.
    final hasAudioSignal = item['music'] != null;
    final formats = video is Map ? _parseFormats(video, hasAudioSignal: hasAudioSignal) : const <MediaFormat>[];
    if (formats.isEmpty) {
      throw const MediaExtractionException(
        'UNSUPPORTED_MEDIA',
        'This TikTok post has no playable video (likely a photo post), '
            'which MiDa does not support yet.',
      );
    }

    final desc = item['desc'] as String?;
    final durationSeconds = video is Map ? _asInt(video['duration']) : null;
    final author = item['author'];
    final authorName = author is Map ? author['uniqueId'] as String? : null;
    final postId = (item['id'] as String?) ?? _lastPathSegment(sourceUrl) ?? '';

    return MediaInfo(
      id: postId,
      title: buildSocialTitle(author: authorName, caption: desc, postId: postId),
      author: authorName,
      thumbnailUrl: video is Map ? video['cover'] as String? : null,
      duration: durationSeconds == null ? null : Duration(seconds: durationSeconds),
      formats: formats,
      sourceUrl: sourceUrl,
      requestHeaders: requestHeaders,
    );
  }

  /// Builds the display title: `@<author> - <first 60 chars of the
  /// caption/desc, URLs and line breaks stripped>`, or `@<author> - <post
  /// id>` when nothing usable is left after that cleanup. A raw TikTok
  /// `desc` can be empty entirely (real example: the `hankgreen1` fixture
  /// video has no caption at all), and the page's own `<title>` ("TikTok의
  /// Hank Green" for that same video) is not a usable filename either - so
  /// this is deliberately never "fall back to some other page string".
  /// Shared verbatim (small enough that a cross-platform import would be
  /// more awkward than the duplication) with
  /// `InstagramDomParser.buildSocialTitle`.
  static String buildSocialTitle({
    required String? author,
    required String? caption,
    required String postId,
  }) {
    final authorPart = '@${(author != null && author.isNotEmpty) ? author : 'unknown'}';
    final cleaned = _cleanCaptionForTitle(caption);
    return '$authorPart - ${cleaned.isNotEmpty ? cleaned : postId}';
  }

  static String _cleanCaptionForTitle(String? caption) {
    if (caption == null) return '';
    final noUrls = caption.replaceAll(RegExp(r'https?://\S+'), '');
    final noLineBreaks = noUrls.replaceAll(RegExp(r'[\r\n]+'), ' ');
    final collapsed = noLineBreaks.replaceAll(RegExp(r'\s+'), ' ').trim();
    return _truncateSafely(collapsed, 60);
  }

  /// Truncates to [maxLen] UTF-16 code units without splitting a surrogate
  /// pair (astral-plane emoji are two code units; a naive `substring` can
  /// cut one in half and leave an unpaired surrogate in the result).
  static String _truncateSafely(String value, int maxLen) {
    if (value.length <= maxLen) return value;
    var end = maxLen;
    if (end > 0 && value.codeUnitAt(end - 1) >= 0xD800 && value.codeUnitAt(end - 1) <= 0xDBFF) {
      end -= 1;
    }
    return value.substring(0, end).trim();
  }

  void _checkStatusCode(int statusCode) {
    if (statusCode == 0) return;
    if (statusCode == 10216 || statusCode == 10222) {
      throw const MediaExtractionException(
        'PRIVATE',
        'This TikTok video is private or not visible to the public.',
      );
    }
    if (statusCode == 10204) {
      throw const MediaExtractionException(
        'RATE_LIMITED',
        'TikTok is temporarily blocking requests from this network. Wait a '
            'moment and try again.',
      );
    }
    throw const MediaExtractionException(
      'NOT_FOUND',
      'This TikTok video no longer exists or the link is wrong.',
    );
  }

  List<MediaFormat> _parseFormats(Map video, {required bool hasAudioSignal}) {
    final result = <MediaFormat>[];
    final bitrateInfo = video['bitrateInfo'];
    if (bitrateInfo is List) {
      for (final entry in bitrateInfo) {
        if (entry is! Map) continue;
        final playAddr = entry['PlayAddr'];
        if (playAddr is! Map) continue;
        final urlList = playAddr['UrlList'];
        final url = (urlList is List && urlList.isNotEmpty) ? urlList.first as String? : null;
        if (url == null || url.isEmpty) continue;
        result.add(MediaFormat(
          id: (playAddr['UrlKey'] as String?) ?? '${entry['Bitrate']}',
          url: url,
          container: 'mp4',
          videoCodec: entry['CodecType'] as String?,
          width: _asInt(playAddr['Width']),
          height: _asInt(playAddr['Height']),
          bitrate: _asInt(entry['Bitrate']) ?? 0,
          contentLength: _asInt(playAddr['DataSize']),
          hasVideo: true,
          hasAudio: hasAudioSignal,
        ));
      }
    }

    if (result.isEmpty) {
      final playAddr = video['playAddr'];
      if (playAddr is String && playAddr.isNotEmpty) {
        result.add(MediaFormat(
          id: 'default',
          url: playAddr,
          container: 'mp4',
          videoCodec: video['codecType'] as String?,
          width: _asInt(video['width']),
          height: _asInt(video['height']),
          bitrate: _asInt(video['bitrate']) ?? 0,
          hasVideo: true,
          hasAudio: hasAudioSignal,
        ));
      }
    }
    return result;
  }

  int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  String? _lastPathSegment(Uri url) {
    final segments = url.pathSegments.where((s) => s.isNotEmpty).toList();
    return segments.isEmpty ? null : segments.last;
  }
}
