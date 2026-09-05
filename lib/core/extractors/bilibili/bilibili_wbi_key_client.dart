import 'dart:convert';
import 'dart:io';

import '../media_models.dart';
import 'bilibili_wbi_signer.dart';

/// Fetches the current day's WBI mixin-key source pair
/// (`wbi_img.img_url`/`sub_url`) from `x/web-interface/nav` - the
/// standard, documented source every third-party Bilibili client reads
/// these from, refreshed roughly daily. Works anonymously (no login):
/// verified live 2026-09-05 (`docs/plan-phase5-coverage.md` Lane D
/// follow-up) - the response's own `code: -101` ("account not logged in")
/// does not prevent `data.wbi_img` from being present.
class BilibiliWbiKeyClient {
  final HttpClient Function() _httpClientFactory;

  /// Rewrites the nav endpoint URL. Identity by default; tests point it
  /// at a local `HttpServer`.
  final Uri Function(Uri url) _requestUrlBuilder;

  BilibiliWbiKeyClient({
    HttpClient Function()? httpClientFactory,
    Uri Function(Uri url)? requestUrlBuilder,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _requestUrlBuilder = requestUrlBuilder ?? _identity;

  static Uri _identity(Uri url) => url;

  static const _defaultEndpoint = 'https://api.bilibili.com/x/web-interface/nav';
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  /// Throws [MediaExtractionException] (`PARSE_ERROR`) when the response
  /// has no usable `wbi_img` - fall-through eligible, since a stream this
  /// extractor cannot sign a `playurl` request for is a technique
  /// failure, not "this video has no media".
  Future<({String imgKey, String subKey})> fetchKeys(Map<String, String> cookies) async {
    final httpClient = _httpClientFactory();
    try {
      final request = await httpClient.getUrl(_requestUrlBuilder(Uri.parse(_defaultEndpoint)));
      request.headers.set('User-Agent', _userAgent);
      request.headers.set('Referer', 'https://www.bilibili.com/');
      if (cookies.isNotEmpty) {
        request.headers.set('Cookie', cookies.entries.map((e) => '${e.key}=${e.value}').join('; '));
      }
      final response = await request.close();
      final raw = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw MediaExtractionException(
          'NETWORK',
          'Bilibili returned HTTP ${response.statusCode} while fetching signing keys.',
        );
      }

      final json = jsonDecode(raw);
      final data = json is Map ? json['data'] : null;
      final wbiImg = data is Map ? data['wbi_img'] : null;
      final imgUrl = wbiImg is Map ? wbiImg['img_url'] as String? : null;
      final subUrl = wbiImg is Map ? wbiImg['sub_url'] as String? : null;
      if (imgUrl == null || subUrl == null) {
        throw const MediaExtractionException(
          'PARSE_ERROR',
          'Bilibili did not return signing keys for this request.',
        );
      }
      return (imgKey: BilibiliWbiSigner.keyFromUrl(imgUrl), subKey: BilibiliWbiSigner.keyFromUrl(subUrl));
    } on FormatException {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'Bilibili returned a response MiDa could not read as JSON.',
      );
    } finally {
      httpClient.close(force: true);
    }
  }
}
