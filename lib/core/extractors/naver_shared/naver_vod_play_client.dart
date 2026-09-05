import 'dart:convert';
import 'dart:io';

import '../media_models.dart';
import 'naver_vod_play_parser.dart';

/// Fetches renditions from Naver's shared VOD playback backend
/// (`apis.naver.com/rmcnmv/rmcnmv/vod/play/v2.0/{videoId}?key={inKey}`)
/// given the `videoId`/`inKey` pair a front-end (Naver TV or CHZZK)
/// resolved for one clip. Unauthenticated, no signing: verified live
/// 2026-09-05 for both platforms (`docs/plan-phase5-coverage.md` Lane C).
/// Mirrors `TwitterExtractor`'s shape (injectable `HttpClient` factory +
/// endpoint builder so tests point this at a local `HttpServer` instead of
/// the real `apis.naver.com`).
class NaverVodPlayClient {
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  final HttpClient Function() _httpClientFactory;
  final NaverVodPlayParser _parser;
  final Uri Function(String videoId, String inKey) _endpointBuilder;

  NaverVodPlayClient({
    HttpClient Function()? httpClientFactory,
    NaverVodPlayParser? parser,
    Uri Function(String videoId, String inKey)? endpointBuilder,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _parser = parser ?? const NaverVodPlayParser(),
        _endpointBuilder = endpointBuilder ?? _defaultEndpoint;

  static Uri _defaultEndpoint(String videoId, String inKey) => Uri.parse(
        'https://apis.naver.com/rmcnmv/rmcnmv/vod/play/v2.0/$videoId?key=$inKey',
      );

  /// Throws [MediaExtractionException] (`NOT_FOUND` for a 404, `NETWORK`
  /// for any other non-200, `PARSE_ERROR` for a non-JSON 200 body) or
  /// returns whatever [NaverVodPlayParser.parseFormats] found (which may be
  /// an empty list - callers treat that as `NO_MEDIA_FOUND` themselves, per
  /// `ExtractorRegistry.resolveInfo`'s shared empty-formats handling).
  Future<List<MediaFormat>> fetchFormats(String videoId, String inKey) async {
    final httpClient = _httpClientFactory();
    try {
      final request = await httpClient.getUrl(_endpointBuilder(videoId, inKey));
      request.headers.set('User-Agent', _userAgent);
      final response = await request.close();
      final raw = await response.transform(utf8.decoder).join();

      if (response.statusCode == 404) {
        throw const MediaExtractionException(
          'NOT_FOUND',
          'This video\'s playback session could not be found. It may have expired or been removed.',
        );
      }
      if (response.statusCode == 429) {
        throw const MediaExtractionException(
          'RATE_LIMITED',
          'Naver is throttling this request. Wait a moment and try again.',
        );
      }
      if (response.statusCode != 200) {
        throw MediaExtractionException(
          'NETWORK',
          'The video playback service returned HTTP ${response.statusCode}.',
        );
      }

      final Map<String, dynamic> json;
      try {
        json = jsonDecode(raw) as Map<String, dynamic>;
      } on FormatException {
        throw const MediaExtractionException(
          'PARSE_ERROR',
          'The video playback service returned a response MiDa could not read as JSON.',
        );
      }

      return _parser.parseFormats(json);
    } finally {
      httpClient.close(force: true);
    }
  }
}
