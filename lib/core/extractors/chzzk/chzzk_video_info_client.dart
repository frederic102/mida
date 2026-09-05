import 'dart:convert';
import 'dart:io';

import '../media_models.dart';

/// The subset of CHZZK's video-info response [ChzzkVideoInfoClient] hands
/// to the extractor: the `videoId`/`inKey` pair needed to call
/// `NaverVodPlayClient` (`../naver_shared/` - CHZZK VOD hands off to the
/// same underlying Naver VOD playback backend Naver TV uses, verified live
/// 2026-09-05, `docs/plan-phase5-coverage.md` Lane C), plus display
/// metadata.
class ChzzkVideoInfo {
  final String videoId;
  final String inKey;
  final String title;
  final String? author;
  final String? thumbnailUrl;
  final Duration? duration;

  const ChzzkVideoInfo({
    required this.videoId,
    required this.inKey,
    required this.title,
    this.author,
    this.thumbnailUrl,
    this.duration,
  });
}

/// Resolves a CHZZK VOD number to a [ChzzkVideoInfo] by calling CHZZK's own
/// public video-info API (`api.chzzk.naver.com/service/v3/videos/{videoNo}`)
/// - unauthenticated, unsigned (unlike Naver TV's equivalent call), verified
/// live 2026-09-05. Mirrors `TwitterExtractor`'s injectable-`HttpClient`-
/// factory/endpoint-builder shape for hermetic tests.
class ChzzkVideoInfoClient {
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  final HttpClient Function() _httpClientFactory;
  final Uri Function(String videoNo) _endpointBuilder;

  ChzzkVideoInfoClient({
    HttpClient Function()? httpClientFactory,
    Uri Function(String videoNo)? endpointBuilder,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _endpointBuilder = endpointBuilder ?? _defaultEndpoint;

  static Uri _defaultEndpoint(String videoNo) =>
      Uri.parse('https://api.chzzk.naver.com/service/v3/videos/$videoNo');

  Future<ChzzkVideoInfo> fetch(String videoNo) async {
    final httpClient = _httpClientFactory();
    try {
      final request = await httpClient.getUrl(_endpointBuilder(videoNo));
      request.headers.set('User-Agent', _userAgent);
      final response = await request.close();
      final raw = await response.transform(utf8.decoder).join();

      if (response.statusCode == 429) {
        throw const MediaExtractionException(
          'RATE_LIMITED',
          'CHZZK is throttling this request. Wait a moment and try again.',
        );
      }
      if (response.statusCode >= 500) {
        throw MediaExtractionException(
          'NETWORK',
          'CHZZK returned HTTP ${response.statusCode} for this video.',
        );
      }

      final Map<String, dynamic> json;
      try {
        json = jsonDecode(raw) as Map<String, dynamic>;
      } on FormatException {
        throw const MediaExtractionException(
          'PARSE_ERROR',
          'CHZZK returned a response MiDa could not read as JSON.',
        );
      }

      // CHZZK's own API reports its result status in a `code` field in the
      // JSON body, not (only) the HTTP status - the not-found case above
      // was observed live returning HTTP 404 *and* `code: 404` together,
      // but every field here is read from the body to stay correct even if
      // that ever diverges.
      final code = json['code'];
      if (code == 404) {
        throw MediaExtractionException(
          'NOT_FOUND',
          'This CHZZK video no longer exists or the link is wrong '
              '(video $videoNo). ${json['message'] ?? ''}'.trim(),
        );
      }
      if (code != 200) {
        throw MediaExtractionException(
          'NETWORK',
          'CHZZK returned an unexpected response for this video: ${json['message'] ?? code}.',
        );
      }

      final content = json['content'];
      if (content is! Map) {
        throw const MediaExtractionException(
          'PARSE_ERROR',
          'CHZZK\'s video response did not include a content payload.',
        );
      }

      final videoId = content['videoId'] as String?;
      final inKey = content['inKey'] as String?;
      if (videoId == null || inKey == null) {
        throw const MediaExtractionException(
          'PARSE_ERROR',
          'CHZZK\'s video response did not include a playable video id.',
        );
      }

      // CHZZK's API does not expose a separate "is this playable right
      // now" field the way Naver TV's does; `adult` is the one gating
      // signal it does expose, and CHZZK's own player requires a signed-in,
      // age-verified session before it will play an adult-flagged video -
      // inferred from that field's name and CHZZK's known age-gate UX
      // (not separately live-verified against an actual adult video, since
      // finding one was out of scope for this pass).
      if (content['adult'] == true) {
        throw const MediaExtractionException(
          'LOGIN_REQUIRED',
          'This video is age-restricted. Sign in to a Naver account that has '
              'passed age verification on chzzk.naver.com, then try again.',
        );
      }

      final channel = content['channel'];
      final durationSeconds = content['duration'];
      return ChzzkVideoInfo(
        videoId: videoId,
        inKey: inKey,
        title: content['videoTitle'] as String? ?? 'Untitled',
        author: channel is Map ? channel['channelName'] as String? : null,
        thumbnailUrl: content['thumbnailImageUrl'] as String?,
        duration: durationSeconds is num ? Duration(seconds: durationSeconds.toInt()) : null,
      );
    } finally {
      httpClient.close(force: true);
    }
  }
}
