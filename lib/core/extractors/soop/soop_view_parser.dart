import 'dart:convert';

import '../media_models.dart';
import '../native_http/native_text.dart';

/// One playable stream of the first part: a URL plus what the API said
/// about it.
class SoopStream {
  final String url;

  /// `m3u8` or `mp4`, from the URL path.
  final String container;
  final int? width;
  final int? height;

  /// Bits per second, or null when the API gave none.
  final int? bitrate;

  const SoopStream({required this.url, required this.container, this.width, this.height, this.bitrate});
}

/// What was read from one `station/video/a/view` answer.
class SoopVod {
  final String id;
  final String title;
  final String? author;
  final String? thumbnailUrl;

  /// Duration of the first part only.
  final Duration? duration;

  /// How many parts (files) the VOD has; only the first is returned.
  final int partCount;

  /// Streams of the first part: per-quality entries, else the part's own
  /// `file`.
  final List<SoopStream> streams;

  const SoopVod({
    required this.id,
    required this.title,
    this.author,
    this.thumbnailUrl,
    this.duration,
    required this.partCount,
    required this.streams,
  });
}

enum _CodeSignal { none, login, gone }

/// Reads the answer of the site's own VOD view call (`POST
/// .../station/video/a/view`).
///
/// Shape as understood from the web player's own request (hand-written in
/// the fixtures, not verified live): `{"result": 1, "data": {"title_no", "title", "writer_nick",
/// "bj_id", "thumb", "total_file_duration", "adult_status", "files": [{
/// "file", "duration", "quality_info": [{"file", "resolution", "bitrate",
/// "name"}]}]}}`.
///
/// Result handling: `result == 1` with a `data` object is success.
/// Everything else is classified from the answer's own signals, because the
/// numeric `result` codes are not documented anywhere stable: `adult_status
/// == notLogin` and a password flag are `LOGIN_REQUIRED`; a message naming
/// a deleted/missing VOD is `NOT_FOUND`; an unrecognized failure is
/// `PARSE_ERROR` (the registry then tries the generic tier). The keyword
/// lists live in [_loginWords] and [_goneWords]. Structured signals are read
/// first, in this order: `adult_status == notLogin`, a password flag, then
/// string-named `code`/`error_code` values ([_codeSignal]); only then wording.
/// Numeric `result`/`code` values other than `result == 1` are not
/// interpreted (no verified table exists).
class SoopViewParser {
  const SoopViewParser();

  static const List<String> _loginWords = [
    'login', 'log in', 'sign in', 'password', 'adult', 'subscribe', 'fan club',
    '로그인', // login
    '성인', // adult
    '비밀번호', // password
    '비밀', // secret
    '연령', // age
    '구독', // subscription
    '팩클럽', // fan club
    '권한', // permission ("권한이 없습니다" = no permission)
  ];

  /// Narrow, explicit deletion phrases only. Broad absence words ("없습니다"
  /// = "there is none", "없는", "삭제" alone) also appear in access messages
  /// such as "로그인하지 않으면 볼 수 없습니다" and must never make a VOD
  /// terminally `NOT_FOUND`; an unrecognized failure stays `PARSE_ERROR`.
  static const List<String> _goneWords = [
    '삭제된 영상', // deleted video
    '삭제된 방송', // deleted broadcast
    '존재하지 않는 영상', // video that does not exist
    'has been deleted',
    'was deleted',
    'video does not exist',
    'video not found',
  ];

  SoopVod parse(String body, {required String titleNo}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const MediaExtractionException('PARSE_ERROR', 'SOOP returned a response MiDa could not read as JSON.');
    }
    final root = NativeText.asMap(decoded);
    if (root == null) {
      throw const MediaExtractionException('PARSE_ERROR', 'SOOP returned JSON that is not a VOD view answer.');
    }

    final data = NativeText.asMap(root['data']);
    _throwForSignals(root, data);
    if (data == null) {
      throw const MediaExtractionException('PARSE_ERROR', 'SOOP returned a VOD view answer without data.');
    }

    final answerId = data['title_no'];
    if (answerId != null && answerId.toString() != titleNo) {
      throw const MediaExtractionException('PARSE_ERROR', 'SOOP answered with a different VOD than the one requested.');
    }

    final files = NativeText.asList(data['files']).map(NativeText.asMap).whereType<Map<String, dynamic>>().toList();
    if (files.isEmpty) {
      throw const MediaExtractionException('NO_MEDIA_FOUND', 'SOOP listed no playable file for this VOD.');
    }
    final first = files.first;
    final streams = _streams(first);
    if (streams.isEmpty) {
      throw const MediaExtractionException('NO_MEDIA_FOUND', 'SOOP listed no playable stream for this VOD.');
    }

    final baseTitle = NativeText.nonEmpty(data['title']) ?? 'SOOP VOD $titleNo';
    final durationMs = NativeText.positiveInt(first['duration']) ??
        (files.length == 1 ? NativeText.positiveInt(data['total_file_duration']) : null);
    return SoopVod(
      id: titleNo,
      title: files.length > 1 ? '$baseTitle (part 1 of ${files.length})' : baseTitle,
      author: NativeText.nonEmpty(data['writer_nick']) ?? NativeText.nonEmpty(data['bj_nick']) ?? NativeText.nonEmpty(data['bj_id']),
      thumbnailUrl: NativeText.httpsUrl(data['thumb']) ?? NativeText.httpsUrl(data['thumbnail']),
      duration: durationMs == null ? null : Duration(milliseconds: durationMs),
      partCount: files.length,
      streams: streams,
    );
  }

  void _throwForSignals(Map<String, dynamic> root, Map<String, dynamic>? data) {
    final adult = data?['adult_status']?.toString().toLowerCase();
    if (adult == 'notlogin') throw _loginRequired;
    if (_truthy(data?['is_password']) || _truthy(data?['password'])) throw _loginRequired;

    final result = root['result'];
    final ok = result == 1 || result == '1' || result == true;
    if (ok && data != null) return;

    // A structured code name beats wording: it is language independent.
    final signal = _codeSignal([root['code'], root['error_code'], data?['code'], data?['error_code']]);
    if (signal == _CodeSignal.login) throw _loginRequired;
    if (signal == _CodeSignal.gone) {
      throw const MediaExtractionException('NOT_FOUND', 'This SOOP VOD was deleted or does not exist.');
    }

    final message = '${root['message'] ?? ''} ${root['msg'] ?? ''} ${data?['message'] ?? ''} ${data?['msg'] ?? ''}'.toLowerCase();
    // Access restrictions first: a message that names both a login and an
    // absence is an access message.
    if (_loginWords.any(message.contains)) throw _loginRequired;
    if (_gone(message)) {
      throw const MediaExtractionException('NOT_FOUND', 'This SOOP VOD was deleted or does not exist.');
    }
    if (!ok) {
      throw MediaExtractionException('PARSE_ERROR', 'SOOP answered with result code ${result is num ? result : 'none'} that MiDa does not recognize; trying another method.');
    }
  }

  /// Reads `code`/`error_code` values that are *names* (strings). Numeric
  /// codes are deliberately not interpreted: no numeric `result`/`code`
  /// table is verified, and guessing one would make a wrong terminal status.
  /// Relied on: a string containing `login`, `password`, `adult` or `auth`
  /// (-> login), or `delete`, `removed`, `not_found`/`notfound` (-> gone).
  /// Login wins when both appear.
  static _CodeSignal _codeSignal(Iterable<Object?> codes) {
    var gone = false;
    for (final code in codes) {
      if (code is! String) continue;
      final lower = code.toLowerCase();
      if (['login', 'password', 'adult', 'auth'].any(lower.contains)) return _CodeSignal.login;
      if (['delete', 'removed', 'not_found', 'notfound'].any(lower.contains)) gone = true;
    }
    return gone ? _CodeSignal.gone : _CodeSignal.none;
  }

  static bool _gone(String message) => _goneWords.any(message.contains);

  static bool _truthy(Object? value) =>
      value == true || value == 1 || (value is String && {'y', 'yes', 'true', '1'}.contains(value.toLowerCase()));

  static const MediaExtractionException _loginRequired = MediaExtractionException(
    'LOGIN_REQUIRED',
    'This SOOP VOD needs a signed-in session (adult, password, or members-only).',
  );

  static List<SoopStream> _streams(Map<String, dynamic> file) {
    final result = <SoopStream>[];
    final seen = <String>{};
    void add(SoopStream? stream) {
      if (stream != null && seen.add(stream.url)) result.add(stream);
    }

    for (final quality in NativeText.asList(file['quality_info'])) {
      final map = NativeText.asMap(quality);
      if (map != null) add(_stream(map['file'] ?? map['url'], map));
    }
    // The part's own playlist is the fallback when no per-quality entry
    // gave a usable URL; with qualities present it would only duplicate one.
    if (result.isEmpty) add(_stream(file['file'], file));
    return result;
  }

  static SoopStream? _stream(Object? rawUrl, Map<String, dynamic> info) {
    final url = NativeText.httpsUrl(rawUrl);
    if (url == null) return null;
    final path = Uri.parse(url).path.toLowerCase();
    final container = path.endsWith('.m3u8')
        ? 'm3u8'
        : path.endsWith('.mp4')
            ? 'mp4'
            : null;
    if (container == null) return null;

    int? width = NativeText.positiveInt(info['width']);
    int? height = NativeText.positiveInt(info['height']);
    final resolution = RegExp(r'^(\d{2,5})\s*[xX*]\s*(\d{2,5})$').firstMatch('${info['resolution'] ?? ''}'.trim());
    if (resolution != null) {
      width ??= int.parse(resolution.group(1)!);
      height ??= int.parse(resolution.group(2)!);
    }
    // The API's `bitrate` is in kbit/s; a value this large is already bit/s.
    final rawBitrate = NativeText.positiveInt(info['bitrate']);
    final bitrate = rawBitrate == null ? null : (rawBitrate < 100000 ? rawBitrate * 1000 : rawBitrate);
    return SoopStream(url: url, container: container, width: width, height: height, bitrate: bitrate);
  }
}
