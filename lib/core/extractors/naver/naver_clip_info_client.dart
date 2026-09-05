import 'dart:convert';
import 'dart:io';

import '../media_models.dart';
import 'naver_api_signer.dart';

/// The subset of `tv.naver.com`'s clip play-info response
/// [NaverClipInfoClient] hands to the extractor: the `videoId`/`inKey` pair
/// needed to call [NaverVodPlayClient] (`../naver_shared/`), plus display
/// metadata. Field mapping verified live 2026-09-05 against
/// `https://apis.naver.com/now_web2/now_web_api/v1/clips/{clipId}/play-info`
/// (`docs/plan-phase5-coverage.md` Lane C): `result.clip.videoId`,
/// `result.play.inKey`, `result.clip.title`, `result.clip.channelName`,
/// `result.clip.thumbnailImageUrl`, `result.clip.playTime` (seconds).
class NaverClipInfo {
  final String videoId;
  final String inKey;
  final String title;
  final String? author;
  final String? thumbnailUrl;
  final Duration? duration;

  const NaverClipInfo({
    required this.videoId,
    required this.inKey,
    required this.title,
    this.author,
    this.thumbnailUrl,
    this.duration,
  });
}

/// Resolves a Naver TV clip number to a [NaverClipInfo] by calling the same
/// signed endpoint (`../v1/clips/{clipId}/play-info`) tv.naver.com's own
/// player calls, via [NaverApiSigner]. Mirrors `TwitterExtractor`'s
/// injectable-`HttpClient`-factory/endpoint-builder shape for hermetic
/// tests.
class NaverClipInfoClient {
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  final HttpClient Function() _httpClientFactory;
  final NaverApiSigner _signer;
  final Uri Function(String clipId) _endpointBuilder;

  /// Test-only override for [NaverApiSigner.sign]'s `nowMillis`: production
  /// leaves this null (real wall clock). Not used to change the signing
  /// key or algorithm, only to make a test's expected signature
  /// reproducible.
  final int? _fixedNowMillis;

  NaverClipInfoClient({
    HttpClient Function()? httpClientFactory,
    NaverApiSigner? signer,
    Uri Function(String clipId)? endpointBuilder,
    int? fixedNowMillis,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _signer = signer ?? const NaverApiSigner(),
        _endpointBuilder = endpointBuilder ?? _defaultEndpoint,
        _fixedNowMillis = fixedNowMillis;

  static Uri _defaultEndpoint(String clipId) => Uri.parse(
        'https://apis.naver.com/now_web2/now_web_api/v1/clips/$clipId/play-info',
      );

  Future<NaverClipInfo> fetch(String clipId) async {
    final httpClient = _httpClientFactory();
    try {
      final signedUrl = _signer.sign(_endpointBuilder(clipId), nowMillis: _fixedNowMillis);
      final request = await httpClient.getUrl(signedUrl);
      request.headers.set('User-Agent', _userAgent);
      request.headers.set('Referer', 'https://tv.naver.com/');
      final response = await request.close();
      final raw = await response.transform(utf8.decoder).join();

      if (response.statusCode == 429) {
        throw const MediaExtractionException(
          'RATE_LIMITED',
          'Naver TV is throttling this request. Wait a moment and try again.',
        );
      }
      if (response.statusCode >= 500) {
        throw MediaExtractionException(
          'NETWORK',
          'Naver TV returned HTTP ${response.statusCode} for this clip.',
        );
      }

      final Map<String, dynamic> json;
      try {
        json = jsonDecode(raw) as Map<String, dynamic>;
      } on FormatException {
        throw const MediaExtractionException(
          'PARSE_ERROR',
          'Naver TV returned a response MiDa could not read as JSON.',
        );
      }

      final statusCode = json['statusCode'] as String?;
      if (statusCode == 'CLIP_NOT_FOUND') {
        throw MediaExtractionException(
          'NOT_FOUND',
          'This Naver TV clip no longer exists or the link is wrong '
              '(clip $clipId).',
        );
      }
      if (statusCode != 'SUCCESS') {
        throw MediaExtractionException(
          'NETWORK',
          'Naver TV returned an unexpected status for this clip: '
              '${json['errorMessage'] ?? statusCode ?? 'unknown'}.',
        );
      }

      final result = json['result'];
      final clip = result is Map ? result['clip'] : null;
      final play = result is Map ? result['play'] : null;
      final videoId = clip is Map ? clip['videoId'] as String? : null;
      final inKey = play is Map ? play['inKey'] as String? : null;
      if (videoId == null || inKey == null) {
        throw const MediaExtractionException(
          'PARSE_ERROR',
          'Naver TV\'s clip response did not include a playable video id.',
        );
      }

      final playable = play is Map ? play['playable'] as String? : null;
      if (playable != null && playable != 'PLAYABLE') {
        final adultGated = clip is Map && clip['adultVideo'] == true;
        throw MediaExtractionException(
          'LOGIN_REQUIRED',
          adultGated
              ? 'This clip is age-restricted. Sign in to a Naver account that has '
                  'passed age verification on tv.naver.com, then try again.'
              : 'This clip needs a signed-in Naver session to play. Sign in on '
                  'tv.naver.com in your browser, then try again.',
        );
      }

      final playTime = clip is Map ? clip['playTime'] : null;
      return NaverClipInfo(
        videoId: videoId,
        inKey: inKey,
        title: (clip is Map ? clip['title'] as String? : null) ?? 'Untitled',
        author: clip is Map ? clip['channelName'] as String? : null,
        thumbnailUrl: clip is Map ? clip['thumbnailImageUrl'] as String? : null,
        duration: playTime is num ? Duration(seconds: playTime.toInt()) : null,
      );
    } finally {
      httpClient.close(force: true);
    }
  }
}
