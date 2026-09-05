import '../media_models.dart';

/// Pure JSON -> [MediaInfo] mapping for a YouTube `/youtubei/v1/player`
/// response. Kept free of any I/O so it can be exercised entirely against
/// fixtures in tests.
class PlayerResponseParser {
  const PlayerResponseParser();

  /// Throws [MediaExtractionException] when `playabilityStatus.status` is
  /// not `OK` (LOGIN_REQUIRED, UNPLAYABLE, ERROR, etc), or when the
  /// response is OK but too malformed to extract anything useful from
  /// (status `PARSE_ERROR`) rather than letting a raw [TypeError] escape.
  MediaInfo parse(Map<String, dynamic> json, {required Uri sourceUrl, required Map<String, String> requestHeaders}) {
    try {
      final playability = json['playabilityStatus'] as Map<String, dynamic>?;
      final status = playability?['status'] as String? ?? 'UNKNOWN';
      if (status != 'OK') {
        throw MediaExtractionException(status, playability?['reason'] as String?);
      }

      final videoDetails = json['videoDetails'] as Map<String, dynamic>? ?? const {};
      final streamingData = json['streamingData'] as Map<String, dynamic>? ?? const {};

      final formats = <MediaFormat>[
        ..._parseFormatList(streamingData['formats']),
        ..._parseFormatList(streamingData['adaptiveFormats']),
      ];

      return MediaInfo(
        id: videoDetails['videoId'] as String? ?? '',
        title: videoDetails['title'] as String? ?? 'Untitled',
        author: videoDetails['author'] as String?,
        thumbnailUrl: _bestThumbnail(videoDetails['thumbnail']),
        duration: _durationFromSeconds(videoDetails['lengthSeconds']),
        formats: formats,
        captions: _parseCaptions(json['captions']),
        translatableLanguageCodes: _parseTranslationLanguages(json['captions']),
        sourceUrl: sourceUrl,
        requestHeaders: requestHeaders,
      );
    } on MediaExtractionException {
      rethrow;
    } catch (e) {
      throw MediaExtractionException('PARSE_ERROR', 'Failed to parse player response: $e');
    }
  }

  List<MediaFormat> _parseFormatList(dynamic rawList) {
    if (rawList is! List) return const [];
    final result = <MediaFormat>[];
    for (final entry in rawList) {
      if (entry is! Map) continue;
      final url = entry['url'] as String?;
      if (url == null) continue; // no direct URL (e.g. cipher-only): skip, don't crash

      final mimeType = entry['mimeType'] as String? ?? '';
      final container = _containerFromMime(mimeType);
      final codecs = _codecsFromMime(mimeType);
      final videoCodec = _findCodec(codecs, _videoCodecPrefixes);
      final audioCodec = _findCodec(codecs, _audioCodecPrefixes);
      final height = _asInt(entry['height']);

      result.add(MediaFormat(
        id: '${entry['itag'] ?? ''}',
        url: url,
        container: container,
        videoCodec: videoCodec,
        audioCodec: audioCodec,
        width: _asInt(entry['width']),
        height: height,
        fps: (entry['fps'] as num?)?.toDouble(),
        bitrate: _asInt(entry['averageBitrate']) ?? _asInt(entry['bitrate']) ?? 0,
        contentLength: _asInt(entry['contentLength']),
        hasVideo: videoCodec != null || height != null,
        hasAudio: audioCodec != null || mimeType.startsWith('audio/'),
      ));
    }
    return result;
  }

  List<CaptionTrack> _parseCaptions(dynamic rawCaptions) {
    if (rawCaptions is! Map) return const [];
    final renderer = rawCaptions['playerCaptionsTracklistRenderer'];
    if (renderer is! Map) return const [];
    final tracks = renderer['captionTracks'];
    if (tracks is! List) return const [];

    final result = <CaptionTrack>[];
    for (final entry in tracks) {
      if (entry is! Map) continue;
      final baseUrl = entry['baseUrl'] as String?;
      final languageCode = entry['languageCode'] as String?;
      if (baseUrl == null || languageCode == null) continue;
      result.add(CaptionTrack(
        languageCode: languageCode,
        url: baseUrl,
        isAuto: entry['kind'] == 'asr',
      ));
    }
    return result;
  }

  /// Language codes YouTube offers as auto-translation targets for the
  /// tracks in [_parseCaptions], separate from the tracks that natively
  /// exist. Used so caption selection only attempts `&tlang=` for a
  /// language YouTube actually supports translating into.
  List<String> _parseTranslationLanguages(dynamic rawCaptions) {
    if (rawCaptions is! Map) return const [];
    final renderer = rawCaptions['playerCaptionsTracklistRenderer'];
    if (renderer is! Map) return const [];
    final list = renderer['translationLanguages'];
    if (list is! List) return const [];

    final result = <String>[];
    for (final entry in list) {
      if (entry is! Map) continue;
      final code = entry['languageCode'] as String?;
      if (code != null) result.add(code);
    }
    return result;
  }

  String? _bestThumbnail(dynamic rawThumbnail) {
    if (rawThumbnail is! Map) return null;
    final thumbnails = rawThumbnail['thumbnails'];
    if (thumbnails is! List || thumbnails.isEmpty) return null;

    Map? best;
    var bestArea = -1;
    for (final entry in thumbnails) {
      if (entry is! Map) continue;
      final area = (_asInt(entry['width']) ?? 0) * (_asInt(entry['height']) ?? 0);
      if (area >= bestArea) {
        best = entry;
        bestArea = area;
      }
    }
    return best?['url'] as String?;
  }

  Duration? _durationFromSeconds(dynamic raw) {
    final seconds = _asInt(raw);
    return seconds == null ? null : Duration(seconds: seconds);
  }

  static const _videoCodecPrefixes = ['avc1', 'av01', 'vp9', 'vp09', 'hvc1', 'mp4v'];
  static const _audioCodecPrefixes = ['mp4a', 'opus', 'vorbis', 'ac-3', 'ec-3'];

  String? _findCodec(List<String> codecs, List<String> prefixes) {
    for (final codec in codecs) {
      for (final prefix in prefixes) {
        if (codec.startsWith(prefix)) return codec;
      }
    }
    return null;
  }

  String _containerFromMime(String mimeType) {
    final slash = mimeType.indexOf('/');
    if (slash < 0) return '';
    final semicolon = mimeType.indexOf(';');
    final end = semicolon < 0 ? mimeType.length : semicolon;
    return mimeType.substring(slash + 1, end).trim();
  }

  List<String> _codecsFromMime(String mimeType) {
    final match = RegExp(r'codecs="([^"]*)"').firstMatch(mimeType);
    if (match == null) return const [];
    return match.group(1)!.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  }

  int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
