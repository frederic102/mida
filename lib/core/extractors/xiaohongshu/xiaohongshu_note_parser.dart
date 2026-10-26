import '../media_models.dart';
import '../native_http/native_text.dart';

/// One encoded rendition from `note.video.media.stream`.
class XiaohongshuStream {
  /// `h264`, `h265` or `av1` (the key of the array it came from).
  final String codecGroup;
  final String url;
  final int? width;
  final int? height;
  final int? bitrate;
  final int? contentLength;

  /// Milliseconds, as the stream entry reports it.
  final int? durationMs;
  final String? videoCodec;
  final String? audioCodec;

  const XiaohongshuStream({
    required this.codecGroup,
    required this.url,
    this.width,
    this.height,
    this.bitrate,
    this.contentLength,
    this.durationMs,
    this.videoCodec,
    this.audioCodec,
  });
}

/// What was read from one note.
class XiaohongshuNote {
  final String id;
  final String title;
  final String? author;
  final String? thumbnailUrl;
  final Duration? duration;
  final List<XiaohongshuStream> streams;

  /// `https://sns-video-bd.xhscdn.com/<originVideoKey>` when the note has
  /// the key, else null.
  final String? originUrl;

  const XiaohongshuNote({
    required this.id,
    required this.title,
    this.author,
    this.thumbnailUrl,
    this.duration,
    required this.streams,
    this.originUrl,
  });
}

/// Reads `note.noteDetailMap[<id>].note` out of the decoded
/// `__INITIAL_STATE__`. Only the entry whose key is the requested id is
/// looked at, and its `note.noteId` (when present) must agree; fields of
/// other notes in the map (feed recommendations) are never read.
///
/// - Streams: `video.media.stream.{h264,h265,av1}[]` with `masterUrl`,
///   `width`, `height`, `avgBitrate`, `duration` (ms), `size`.
/// - Duration: `video.capa.duration` (seconds), else the first stream's.
/// - Origin file: `video.consumer.originVideoKey` -> `originHost` + key.
/// - No `video` object (an image note) -> `NO_MEDIA_FOUND`.
/// - The entry missing or empty while the map is empty or the entry is an
///   empty shell -> `CHALLENGE_FAILED`: that is what the page serves a
///   client that lacks the share link's `xsec_token` or trips anti-bot, not
///   proof the note needs an account (only an explicit `/login` redirect is
///   `LOGIN_REQUIRED`, decided by the extractor). `CHALLENGE_FAILED` lets
///   the generic and browser tiers try.
class XiaohongshuNoteParser {
  const XiaohongshuNoteParser();

  static const String originHost = 'sns-video-bd.xhscdn.com';
  static const List<String> _codecGroups = ['h264', 'h265', 'av1'];
  static final RegExp _originKey = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_\-./]{2,200}$');

  XiaohongshuNote parse(Map<String, dynamic> state, {required String noteId}) {
    final detailMap = NativeText.asMap(NativeText.asMap(state['note'])?['noteDetailMap']);
    if (detailMap == null) {
      throw const MediaExtractionException('PARSE_ERROR', 'Xiaohongshu page has no note data; trying another method.');
    }
    final entry = NativeText.asMap(detailMap[noteId]);
    final note = NativeText.asMap(entry?['note']);
    if (note == null || note.isEmpty) {
      if (detailMap.isNotEmpty && entry == null) {
        throw const MediaExtractionException('PARSE_ERROR', 'Xiaohongshu page describes a different note than the one requested.');
      }
      throw const MediaExtractionException(
        'CHALLENGE_FAILED',
        'Xiaohongshu served an empty note shell (missing share token or an anti-bot page); trying another method.',
      );
    }

    final answerId = note['noteId'];
    if (answerId != null && answerId.toString() != noteId) {
      throw const MediaExtractionException('PARSE_ERROR', 'Xiaohongshu page describes a different note than the one requested.');
    }

    final video = NativeText.asMap(note['video']);
    if (video == null || video.isEmpty) {
      throw const MediaExtractionException('NO_MEDIA_FOUND', 'This Xiaohongshu note has no video (it is an image note).');
    }

    final streams = _streams(NativeText.asMap(NativeText.asMap(video['media'])?['stream']));
    final originUrl = _originUrl(NativeText.asMap(video['consumer'])?['originVideoKey']);
    if (streams.isEmpty && originUrl == null) {
      throw const MediaExtractionException('NO_MEDIA_FOUND', 'Xiaohongshu listed no playable stream for this note.');
    }

    return XiaohongshuNote(
      id: noteId,
      title: _title(note, noteId),
      author: NativeText.nonEmpty(NativeText.asMap(note['user'])?['nickname']) ??
          NativeText.nonEmpty(NativeText.asMap(note['user'])?['nickName']),
      thumbnailUrl: _thumbnail(note),
      duration: _duration(video, streams),
      streams: streams,
      originUrl: originUrl,
    );
  }

  static List<XiaohongshuStream> _streams(Map<String, dynamic>? stream) {
    if (stream == null) return const [];
    final result = <XiaohongshuStream>[];
    final seen = <String>{};
    for (final group in _codecGroups) {
      for (final item in NativeText.asList(stream[group])) {
        final map = NativeText.asMap(item);
        final url = NativeText.httpsUrl(map?['masterUrl']);
        if (map == null || url == null || !seen.add(url)) continue;
        result.add(XiaohongshuStream(
          codecGroup: group,
          url: url,
          width: NativeText.positiveInt(map['width']),
          height: NativeText.positiveInt(map['height']),
          bitrate: NativeText.positiveInt(map['avgBitrate']),
          contentLength: NativeText.positiveInt(map['size']),
          durationMs: NativeText.positiveInt(map['duration']),
          videoCodec: NativeText.nonEmpty(map['videoCodec']),
          audioCodec: NativeText.nonEmpty(map['audioCodec']),
        ));
      }
    }
    return result;
  }

  static String? _originUrl(Object? key) {
    if (key is! String) return null;
    final trimmed = key.trim();
    if (!_originKey.hasMatch(trimmed) || trimmed.contains('..') || trimmed.contains('//')) return null;
    return 'https://$originHost/$trimmed';
  }

  static Duration? _duration(Map<String, dynamic> video, List<XiaohongshuStream> streams) {
    final seconds = NativeText.positiveInt(NativeText.asMap(video['capa'])?['duration']);
    if (seconds != null) return Duration(seconds: seconds);
    final ms = streams.map((s) => s.durationMs).whereType<int>().firstOrNull;
    return ms == null ? null : Duration(milliseconds: ms);
  }

  static String _title(Map<String, dynamic> note, String noteId) {
    final title = NativeText.nonEmpty(note['title']);
    if (title != null) return title;
    final desc = NativeText.nonEmpty(note['desc']);
    if (desc != null) return NativeText.clip(desc.split(RegExp(r'[\r\n]')).first.trim(), 100);
    return 'Xiaohongshu note $noteId';
  }

  static String? _thumbnail(Map<String, dynamic> note) {
    final first = NativeText.asMap(NativeText.asList(note['imageList']).firstOrNull);
    if (first == null) return null;
    for (final key in ['urlDefault', 'urlPre', 'url']) {
      final url = NativeText.httpsUrl(first[key]);
      if (url != null) return url;
    }
    return null;
  }
}
