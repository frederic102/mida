import 'dart:convert';

import '../media_models.dart';
import '../native_http/native_text.dart';

/// One entry of a pin's `video_list` (`V_720P`, `V_HLSV4`, ...).
class PinterestVideoEntry {
  /// The `video_list` key, e.g. `V_720P` or `V_HLSV4`.
  final String key;
  final String url;
  final int? width;
  final int? height;
  final int? durationMs;

  const PinterestVideoEntry({required this.key, required this.url, this.width, this.height, this.durationMs});
}

/// What was read from one pin object. Every field comes from the single
/// `data` object whose id matched the requested pin.
class PinterestPin {
  final String id;
  final String title;
  final String? author;
  final String? thumbnailUrl;

  /// The chosen `video_list`'s entries in the order the API listed them.
  final List<PinterestVideoEntry> videos;

  /// True when [videos] came from a story pin block rather than `videos`.
  final bool fromStoryPin;

  const PinterestPin({
    required this.id,
    required this.title,
    this.author,
    this.thumbnailUrl,
    required this.videos,
    this.fromStoryPin = false,
  });
}

/// Reads `resource/PinResource/get/` answers.
///
/// Answer shape (`unauth_react_main_pin`): `{"resource_response": {"status":
/// "success"|"failure", "data": {pin} | null, "error": null | {...}}}`. The
/// pin holds `title`, `grid_title`, `description`, `pinner`, `images`,
/// `videos.video_list` and, for story pins, `story_pin_data.pages[].blocks[]
/// .video.video_list`. A pin without any `video_list` is `NO_MEDIA_FOUND`.
///
/// Story pins have several pages; only the first page block that carries a
/// video is used, as a whole (its formats are never mixed with another
/// block's). A pin whose `data.id` differs from the requested id is refused.
class PinterestPinParser {
  const PinterestPinParser();

  static const List<String> _thumbnailKeys = ['orig', '736x', '564x', '474x', '236x', '170x'];

  PinterestPin parse(String body, {required String pinId}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const MediaExtractionException('PARSE_ERROR', 'Pinterest returned a response MiDa could not read as JSON.');
    }
    final response = NativeText.asMap(NativeText.asMap(decoded)?['resource_response']);
    if (response == null) {
      throw const MediaExtractionException('PARSE_ERROR', 'Pinterest returned JSON that is not a pin resource answer.');
    }

    final data = NativeText.asMap(response['data']);
    final error = response['error'];
    if (response['status'] == 'failure' || error != null) {
      throw _failureFor(NativeText.asMap(error));
    }
    if (data == null || data.isEmpty) {
      // An envelope with neither data nor an error is not evidence that the
      // pin was removed; only an explicit error object is.
      throw const MediaExtractionException('PARSE_ERROR', 'Pinterest returned an incomplete pin answer; trying another method.');
    }

    final dataId = data['id'];
    if (dataId != null && dataId.toString() != pinId) {
      throw const MediaExtractionException('PARSE_ERROR', 'Pinterest answered with a different pin than the one requested.');
    }

    var fromStory = false;
    var videos = _entries(NativeText.asMap(NativeText.asMap(data['videos'])?['video_list']));
    if (videos.isEmpty) {
      videos = _storyPinVideos(data);
      fromStory = videos.isNotEmpty;
    }
    if (videos.isEmpty) {
      throw const MediaExtractionException('NO_MEDIA_FOUND', 'This Pinterest pin has no video (it is an image pin).');
    }

    final pinner = NativeText.asMap(data['pinner']);
    return PinterestPin(
      id: pinId,
      title: _title(data, pinId),
      author: NativeText.nonEmpty(pinner?['full_name']) ?? NativeText.nonEmpty(pinner?['username']),
      thumbnailUrl: _thumbnail(data),
      videos: videos,
      fromStoryPin: fromStory,
    );
  }

  /// Order matters: the structured `http_status` is read first (an access
  /// restriction wins over any wording, so a 403 whose message says "not
  /// found" stays `LOGIN_REQUIRED`); the terminal `NOT_FOUND` needs an
  /// explicit 404/410; free text alone can only ever say "needs login", and
  /// anything else is `PARSE_ERROR` (never terminal).
  static MediaExtractionException _failureFor(Map<String, dynamic>? error) {
    final httpStatus = NativeText.positiveInt(error?['http_status']);
    final text = '${error?['message'] ?? ''} ${error?['message_detail'] ?? ''}'.toLowerCase();
    final saysLogin = text.contains('log in') || text.contains('login') || text.contains('private');
    if (httpStatus == 401 || httpStatus == 403) {
      // Same as the transport: a bare 401/403 is a refusal of this client
      // (CHALLENGE_FAILED); only an explicit login/private message is an
      // account restriction.
      return saysLogin
          ? _loginRequired
          : const MediaExtractionException('CHALLENGE_FAILED', 'Pinterest refused the pin request; trying another method.');
    }
    if (httpStatus == 404 || httpStatus == 410) {
      return const MediaExtractionException('NOT_FOUND', 'This Pinterest pin does not exist or was removed.');
    }
    if (saysLogin) return _loginRequired;
    return const MediaExtractionException('PARSE_ERROR', 'Pinterest reported an error MiDa does not recognize; trying another method.');
  }

  static const MediaExtractionException _loginRequired =
      MediaExtractionException('LOGIN_REQUIRED', 'This Pinterest pin is private or needs a signed-in session.');

  static List<PinterestVideoEntry> _entries(Map<String, dynamic>? videoList) {
    if (videoList == null) return const [];
    final result = <PinterestVideoEntry>[];
    for (final entry in videoList.entries) {
      final value = NativeText.asMap(entry.value);
      final url = NativeText.httpsUrl(value?['url']);
      if (value == null || url == null) continue;
      result.add(PinterestVideoEntry(
        key: entry.key,
        url: url,
        width: NativeText.positiveInt(value['width']),
        height: NativeText.positiveInt(value['height']),
        durationMs: NativeText.positiveInt(value['duration']),
      ));
    }
    return result;
  }

  static List<PinterestVideoEntry> _storyPinVideos(Map<String, dynamic> data) {
    final pages = NativeText.asList(NativeText.asMap(data['story_pin_data'])?['pages']);
    for (final page in pages) {
      for (final block in NativeText.asList(NativeText.asMap(page)?['blocks'])) {
        final entries = _entries(NativeText.asMap(NativeText.asMap(NativeText.asMap(block)?['video'])?['video_list']));
        if (entries.isNotEmpty) return entries;
      }
    }
    return const [];
  }

  static String _title(Map<String, dynamic> data, String pinId) {
    final direct = NativeText.nonEmpty(data['title']) ?? NativeText.nonEmpty(data['grid_title']);
    if (direct != null) return direct;
    final description = NativeText.nonEmpty(data['description']) ?? NativeText.nonEmpty(data['seo_description']);
    if (description != null) return NativeText.clip(description.split(RegExp(r'[\r\n]')).first.trim(), 100);
    return 'Pinterest pin $pinId';
  }

  static String? _thumbnail(Map<String, dynamic> data) {
    final images = NativeText.asMap(data['images']);
    if (images == null) return null;
    for (final key in _thumbnailKeys) {
      final url = NativeText.httpsUrl(NativeText.asMap(images[key])?['url']);
      if (url != null) return url;
    }
    for (final value in images.values) {
      final url = NativeText.httpsUrl(NativeText.asMap(value)?['url']);
      if (url != null) return url;
    }
    return null;
  }
}
