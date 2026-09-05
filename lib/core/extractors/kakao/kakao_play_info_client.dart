import 'dart:convert';
import 'dart:io';

import '../media_models.dart';

/// Calls KakaoTV's legacy playback gateway
/// (`tv.kakao.com/katz/v3/ft/cliplink/{clipId}/readyNplay`) - the same
/// route name KakaoTV's own web player used for years before the service
/// was discontinued.
///
/// **Verified live 2026-09-05 that KakaoTV itself is shut down**
/// (`docs/plan-phase5-coverage.md` Lane C), independently two ways:
/// `tv.kakao.com`'s own homepage now serves a dedicated notice page
/// ("카카오TV 서비스가 종료되었습니다" - "KakaoTV service has ended"), and this
/// `readyNplay` call returns HTTP 422 with a structured
/// `{"code":"ServiceEnded",...}` body for *every* clip id tried, not just
/// one deleted video (the request shape itself is accepted by the server -
/// it is a real, still-listening route - it is the underlying content that
/// is gone for the whole platform). Every clip link this extractor is
/// asked to resolve will therefore hit [_serviceEndedMessage] in practice.
///
/// The success-path parsing below (`videoLocation`/`videoOutputList`
/// shape) is reconstructed from this endpoint's historically documented
/// field names, not from a live 200 response - none could be produced to
/// verify against, since there is no still-live clip left to ask. It is
/// kept deliberately conservative: if a future revival of the service
/// returns something this parser does not recognize, it throws
/// `NO_MEDIA_FOUND` (which falls through to Generic/BrowserCapture, per
/// `ExtractorRegistry`) rather than guessing at a shape.
class KakaoPlayInfoClient {
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  static const _serviceEndedMessage =
      'KakaoTV\'s public video service has been discontinued (verified live: '
      'tv.kakao.com now shows its own "service ended" notice, and this link\'s '
      'playback request was rejected with the same status). This clip can no '
      'longer be played from here.';

  final HttpClient Function() _httpClientFactory;
  final Uri Function(String clipId) _endpointBuilder;

  KakaoPlayInfoClient({
    HttpClient Function()? httpClientFactory,
    Uri Function(String clipId)? endpointBuilder,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _endpointBuilder = endpointBuilder ?? _defaultEndpoint;

  static Uri _defaultEndpoint(String clipId) => Uri.parse(
        'https://tv.kakao.com/katz/v3/ft/cliplink/$clipId/readyNplay'
        '?player=monet_html5&dteType=PC&fields=seekUrl,abrVideoLocationList,tid',
      );

  Future<List<MediaFormat>> fetchFormats(String clipId) async {
    final httpClient = _httpClientFactory();
    try {
      final request = await httpClient.getUrl(_endpointBuilder(clipId));
      request.headers.set('User-Agent', _userAgent);
      request.headers.set('Referer', 'https://tv.kakao.com/');
      final response = await request.close();
      final raw = await response.transform(utf8.decoder).join();

      Map<String, dynamic>? json;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) json = decoded;
      } on FormatException {
        json = null;
      }

      if (response.statusCode != 200) {
        final code = json?['code'];
        if (code == 'ServiceEnded' || code == 'NotFound' || code == 'InvalidParameter') {
          throw const MediaExtractionException('NOT_FOUND', _serviceEndedMessage);
        }
        if (response.statusCode == 429) {
          throw const MediaExtractionException(
            'RATE_LIMITED',
            'KakaoTV is throttling this request. Wait a moment and try again.',
          );
        }
        throw MediaExtractionException(
          'NETWORK',
          'KakaoTV returned HTTP ${response.statusCode} for this clip.',
        );
      }

      if (json == null) {
        throw const MediaExtractionException(
          'PARSE_ERROR',
          'KakaoTV returned a response MiDa could not read as JSON.',
        );
      }

      final formats = _parseRenditions(json);
      if (formats.isEmpty) {
        throw const MediaExtractionException(
          'NO_MEDIA_FOUND',
          'KakaoTV returned a successful response MiDa did not recognize the shape of.',
        );
      }
      return formats;
    } finally {
      httpClient.close(force: true);
    }
  }

  /// Best-effort read of KakaoTV's historically documented rendition list
  /// (`videoLocation`/`videoOutputList`, an array of `{url, width, height,
  /// bitRate}`-shaped entries) - see the class doc for why this cannot be
  /// live-verified. Any shape it does not recognize yields an empty list.
  List<MediaFormat> _parseRenditions(Map<String, dynamic> json) {
    final list = json['videoLocation'] ?? json['videoOutputList'] ?? json['abrVideoLocationList'];
    if (list is! List) return const [];

    final formats = <MediaFormat>[];
    for (final entry in list) {
      if (entry is! Map) continue;
      final url = entry['url'] as String? ?? entry['videoUrl'] as String?;
      if (url == null || url.isEmpty) continue;
      formats.add(MediaFormat(
        id: '${entry['width'] ?? formats.length}p',
        url: url,
        container: 'mp4',
        width: _asInt(entry['width']),
        height: _asInt(entry['height']),
        bitrate: _asInt(entry['bitRate']) ?? 0,
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
