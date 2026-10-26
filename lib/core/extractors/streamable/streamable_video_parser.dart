import '../media_models.dart';
import '../native_http/native_text.dart';

/// What `https://api.streamable.com/videos/<code>` described.
class StreamableVideo {
  final String? title;
  final String? thumbnailUrl;
  final Duration? duration;
  final List<MediaFormat> formats;

  const StreamableVideo({this.title, this.thumbnailUrl, this.duration, this.formats = const []});
}

/// Reads the JSON the Streamable web player loads for a video.
///
/// Shape: `{status, title, thumbnail_url, files:{mp4:{status,url,width,
/// height,bitrate,size,framerate,duration}, "mp4-mobile":{...}}}`. `status`
/// is `2` once encoding finished; anything else means the files are not
/// ready (`0` queued, `1` processing, `3` failed) and is `PARSE_ERROR`
/// (a technique failure the registry may retry with another tier, and which
/// the user can simply retry later) saying so.
class StreamableVideoParser {
  const StreamableVideoParser();

  static const int _ready = 2;

  StreamableVideo parse(Map<String, dynamic> json) {
    final status = json['status'];
    if (status is! int) {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'Streamable returned a video description MiDa does not recognize; trying another method.',
      );
    }
    if (status != _ready) {
      throw MediaExtractionException(
        'PARSE_ERROR',
        'This Streamable video is still processing (or failed to process, status $status). Try again in a minute.',
      );
    }

    final files = NativeText.asMap(json['files']);
    final formats = <MediaFormat>[];
    Duration? duration;
    if (files != null) {
      for (final entry in files.entries) {
        final file = NativeText.asMap(entry.value);
        if (file == null) continue;
        final fileStatus = file['status'];
        if (fileStatus is int && fileStatus != _ready) continue;
        final container = _containerFor(entry.key);
        final url = NativeText.httpsUrl(file['url']);
        if (container == null || url == null) continue;

        final seconds = file['duration'];
        if (duration == null && seconds is num && seconds.isFinite && seconds > 0) {
          duration = Duration(milliseconds: (seconds * 1000).round());
        }
        final fps = file['framerate'];
        formats.add(MediaFormat(
          id: entry.key,
          url: url,
          container: container,
          width: NativeText.positiveInt(file['width']),
          height: NativeText.positiveInt(file['height']),
          fps: fps is num && fps.isFinite && fps > 0 ? fps.toDouble() : null,
          bitrate: NativeText.positiveInt(file['bitrate']) ?? 0,
          contentLength: NativeText.positiveInt(file['size']),
          hasVideo: true,
          hasAudio: true,
          capabilitiesUnknown: true,
        ));
      }
    }

    return StreamableVideo(
      title: NativeText.nonEmpty(json['title']),
      thumbnailUrl: NativeText.httpsUrl(json['thumbnail_url']),
      duration: duration,
      formats: formats,
    );
  }

  /// `mp4`, `mp4-mobile` -> mp4; `webm*` -> webm; any other key is skipped.
  static String? _containerFor(String key) {
    final lower = key.toLowerCase();
    if (lower == 'mp4' || lower.startsWith('mp4-')) return 'mp4';
    if (lower == 'webm' || lower.startsWith('webm-')) return 'webm';
    return null;
  }
}
