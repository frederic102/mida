import '../media_models.dart';
import '../native_http/native_text.dart';

/// One progressive (single-file) rendition from the embedJS answer.
class RumbleFile {
  final String id;
  final String url;
  final String container;
  final int? width;
  final int? height;

  /// Bits per second (Rumble reports kilobits per second).
  final int bitrate;
  final int? size;
  final double? fps;

  const RumbleFile({
    required this.id,
    required this.url,
    required this.container,
    this.width,
    this.height,
    this.bitrate = 0,
    this.size,
    this.fps,
  });
}

/// The fields read from one embedJS answer. Everything belongs to the one
/// video object the request asked for.
class RumbleVideo {
  final String? title;
  final String? author;
  final String? thumbnailUrl;
  final Duration? duration;
  final bool isLive;
  final List<RumbleFile> files;

  /// HLS master playlist URLs, to be expanded by the caller.
  final List<String> hlsUrls;

  const RumbleVideo({
    this.title,
    this.author,
    this.thumbnailUrl,
    this.duration,
    this.isLive = false,
    this.files = const [],
    this.hlsUrls = const [],
  });
}

/// Reads the JSON from `https://rumble.com/embedJS/u3/?request=video&ver=2&v=<id>`,
/// the call Rumble's own embed player makes.
///
/// Shape (the player's own): `ua` maps container -> rendition key -> `{url,
/// meta:{bitrate,size,w,h}}` (`ua.mp4["720"]`, `ua.hls.auto`); `u` is the
/// older container -> `{url, meta}` map and is only used when `ua` yields
/// nothing. `i` is the thumbnail, `author.name` the channel.
class RumbleVideoParser {
  const RumbleVideoParser();

  static const Set<String> _progressive = {'mp4', 'webm'};

  /// [json] is the decoded embedJS object. Throws `NOT_FOUND`/
  /// `LOGIN_REQUIRED` for Rumble's own error answers and `PARSE_ERROR` when
  /// the shape is not one this parser knows.
  RumbleVideo parse(Map<String, dynamic> json) {
    final error = json['error'];
    if (error is String) _throwForError(error);

    if (json['ua'] == null && json['u'] == null && json['title'] == null) {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'Rumble returned a player answer MiDa does not recognize; trying another method.',
      );
    }

    final isLive = json['live'] == 1 || json['live'] == true;
    final files = <RumbleFile>[];
    final hls = <String>[];
    _collect(NativeText.asMap(json['ua']), isLive, json, files, hls, keyedByRendition: true);
    if (files.isEmpty && hls.isEmpty) {
      _collect(NativeText.asMap(json['u']), isLive, json, files, hls, keyedByRendition: false);
    }

    final seconds = json['duration'];
    final duration = seconds is num && seconds.isFinite && seconds > 0 ? Duration(seconds: seconds.round()) : null;
    return RumbleVideo(
      title: NativeText.nonEmpty(json['title']),
      author: NativeText.nonEmpty(NativeText.asMap(json['author'])?['name']),
      thumbnailUrl: NativeText.httpsUrl(json['i']),
      duration: duration,
      isLive: isLive,
      files: files,
      hlsUrls: hls,
    );
  }

  static void _collect(
    Map<String, dynamic>? containers,
    bool isLive,
    Map<String, dynamic> root,
    List<RumbleFile> files,
    List<String> hls, {
    required bool keyedByRendition,
  }) {
    if (containers == null) return;
    final seenUrls = <String>{};
    for (final entry in containers.entries) {
      final container = entry.key.toLowerCase();
      final renditions = NativeText.asMap(entry.value);
      if (renditions == null) continue;
      // `ua` nests one more level (rendition key); `u` holds the rendition directly.
      final items = keyedByRendition ? renditions.entries : [MapEntry(container, renditions)];
      for (final item in items) {
        final data = NativeText.asMap(item.value);
        final url = data == null ? null : NativeText.httpsUrl(data['url']);
        if (data == null || url == null || !seenUrls.add(url)) continue;
        final meta = NativeText.asMap(data['meta']) ?? const <String, dynamic>{};
        if (container == 'hls') {
          if (isLive && meta['live'] == true) continue;
          hls.add(url);
        } else if (_progressive.contains(container)) {
          final key = keyedByRendition ? item.key : '';
          final height = NativeText.positiveInt(meta['h']) ?? NativeText.positiveInt(key);
          final kbps = NativeText.positiveInt(meta['bitrate']);
          files.add(RumbleFile(
            id: height == null ? container : '$container-${height}p',
            url: url,
            container: container,
            width: NativeText.positiveInt(meta['w']),
            height: height,
            bitrate: kbps == null ? 0 : kbps * 1000,
            size: NativeText.positiveInt(meta['size']),
            fps: NativeText.positiveInt(root['fps'])?.toDouble(),
          ));
        }
      }
    }
  }

  static void _throwForError(String error) {
    final lower = error.toLowerCase();
    // Access wording first: a message that names both a removal word and a
    // guest/login gate is an access restriction, never terminal.
    if (RegExp(r'log ?in|sign ?in|guest|subscri|premium|\bage\b|members').hasMatch(lower)) {
      throw const MediaExtractionException(
        'LOGIN_REQUIRED',
        'This Rumble video needs an account, a subscription or an age check.',
      );
    }
    // Terminal only on an explicit removal statement (the embedJS `false`
    // answer and HTTP 404 are handled by the extractor).
    if (RegExp(r'not found|removed|deleted|does not exist').hasMatch(lower)) {
      throw const MediaExtractionException('NOT_FOUND', 'This Rumble video is not available. It may have been removed.');
    }
    // Plain "unavailable" / region wording is not proof the video is gone: let
    // the generic and browser tiers try.
    if (RegExp(r'unavailable|region|country|geo|blocked|restrict').hasMatch(lower)) {
      throw const MediaExtractionException(
        'CHALLENGE_FAILED',
        'Rumble says this video is unavailable here (restricted or region limited); trying another method.',
      );
    }
    throw const MediaExtractionException(
      'PARSE_ERROR',
      'Rumble answered with an error MiDa does not recognize; trying another method.',
    );
  }
}
