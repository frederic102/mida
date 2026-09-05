import 'dart:convert';
import 'dart:io';

import '../media_extractor.dart';
import '../media_models.dart';
import 'bilibili_buvid_client.dart';
import 'bilibili_page_parser.dart';
import 'bilibili_playurl_parser.dart';
import 'bilibili_wbi_key_client.dart';
import 'bilibili_wbi_signer.dart';

/// Native Bilibili extractor for `bilibili.com/video/<BV...>` URLs.
///
/// Full sequence (live-diagnosed and hardened 2026-09-05,
/// `docs/plan-phase5-coverage.md` Lane D + follow-up report):
/// 1. [BilibiliBuvidClient] - anonymous `buvid3`/`buvid4` cookie bootstrap
///    (`x/frontend/finger/spi`), which answered normally even while the
///    watch page/`x/web-interface/view` were both WAF-blocked from the
///    same network.
/// 2. [BilibiliWbiKeyClient] - `x/web-interface/nav` for the day's WBI
///    mixin-key source pair, sent with the step-1 cookies.
/// 3. The watch page itself, sent with the step-1 cookies, for `cid`
///    ([BilibiliPageParser]).
/// 4. `x/player/wbi/playurl`, its query signed with [BilibiliWbiSigner]
///    using the step-2 keys, sent with the step-1 cookies and a
///    `Referer` (Bilibili's CDN 403s without it - the same `Referer` is
///    threaded into [MediaInfo.requestHeaders] so downloads carry it
///    too).
///
/// This sequence measurably reduces - but per this pass's live testing
/// does not eliminate - the WAF's soft block (HTTP 200 with an
/// intentionally empty `__INITIAL_STATE__`, see [BilibiliPageParser]'s
/// doc): the watch page fetch (step 3) is the one step that pass's
/// re-tests still sometimes got blocked on even with steps 1-2's cookies
/// attached, which is consistent with per-request/IP-reputation scoring
/// rather than a fixed cookie/header check this sequence can
/// deterministically satisfy.
class BilibiliExtractor implements MediaExtractor {
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  static final _bvidPathPattern = RegExp(r'^/video/(BV[0-9A-Za-z]+)');

  final HttpClient Function() _httpClientFactory;
  final BilibiliBuvidClient _buvidClient;
  final BilibiliWbiKeyClient _wbiKeyClient;
  final BilibiliWbiSigner _wbiSigner;
  final BilibiliPageParser _pageParser;
  final BilibiliPlayurlParser _playurlParser;

  /// Rewrites the watch-page URL each request is sent to. Identity by
  /// default; tests point it at a local `HttpServer`.
  final Uri Function(Uri url) _pageRequestUrlBuilder;

  /// Rewrites the `playurl` API URL each request is sent to. Identity by
  /// default; tests point it at a local `HttpServer`.
  final Uri Function(Uri url) _playurlRequestUrlBuilder;

  BilibiliExtractor({
    HttpClient Function()? httpClientFactory,
    BilibiliBuvidClient? buvidClient,
    BilibiliWbiKeyClient? wbiKeyClient,
    BilibiliWbiSigner? wbiSigner,
    BilibiliPageParser? pageParser,
    BilibiliPlayurlParser? playurlParser,
    Uri Function(Uri url)? pageRequestUrlBuilder,
    Uri Function(Uri url)? playurlRequestUrlBuilder,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _buvidClient = buvidClient ?? BilibiliBuvidClient(httpClientFactory: httpClientFactory),
        _wbiKeyClient = wbiKeyClient ?? BilibiliWbiKeyClient(httpClientFactory: httpClientFactory),
        _wbiSigner = wbiSigner ?? const BilibiliWbiSigner(),
        _pageParser = pageParser ?? const BilibiliPageParser(),
        _playurlParser = playurlParser ?? const BilibiliPlayurlParser(),
        _pageRequestUrlBuilder = pageRequestUrlBuilder ?? _identity,
        _playurlRequestUrlBuilder = playurlRequestUrlBuilder ?? _identity;

  static Uri _identity(Uri url) => url;

  static bool _hostMatches(String host, String domain) => host == domain || host.endsWith('.$domain');

  String? _bvidFor(Uri url) {
    if (!_hostMatches(url.host.toLowerCase(), 'bilibili.com')) return null;
    return _bvidPathPattern.firstMatch(url.path)?.group(1);
  }

  @override
  bool canHandle(Uri url) => _bvidFor(url) != null;

  @override
  Future<MediaInfo> extract(Uri url) async {
    final bvid = _bvidFor(url);
    if (bvid == null) {
      throw MediaExtractionException('UNSUPPORTED_URL', 'Not a recognizable Bilibili video URL: $url');
    }

    final cookies = await _buvidClient.fetchCookies();
    final wbiKeys = await _wbiKeyClient.fetchKeys(cookies);
    final pageInfo = await _fetchPageInfo(url, bvid, cookies);

    final signedParams = _wbiSigner.sign(
      {'bvid': bvid, 'cid': '${pageInfo.cid}', 'qn': '120', 'fnval': '16', 'fourk': '1'},
      wbiKeys.imgKey,
      wbiKeys.subKey,
    );
    final playurlUrl = Uri.parse('https://api.bilibili.com/x/player/wbi/playurl').replace(
      queryParameters: signedParams,
    );
    final playurlJson = await _fetchPlayurlJson(playurlUrl, cookies);
    final formats = _playurlParser.parse(playurlJson);

    final referer = 'https://www.bilibili.com/video/$bvid/';
    return MediaInfo(
      id: bvid,
      title: pageInfo.title,
      author: pageInfo.author,
      thumbnailUrl: pageInfo.thumbnailUrl,
      duration: pageInfo.duration,
      formats: formats,
      sourceUrl: url,
      requestHeaders: {'User-Agent': _userAgent, 'Referer': referer},
    );
  }

  Future<BilibiliPageInfo> _fetchPageInfo(Uri sourceUrl, String bvid, Map<String, String> cookies) async {
    final httpClient = _httpClientFactory();
    try {
      final request = await httpClient.getUrl(_pageRequestUrlBuilder(sourceUrl));
      request.headers.set('User-Agent', _userAgent);
      request.headers.set('Accept-Language', 'zh-CN,zh;q=0.9,en;q=0.8');
      if (cookies.isNotEmpty) request.headers.set('Cookie', _cookieHeader(cookies));
      final response = await request.close();
      final html = await response.transform(utf8.decoder).join();

      // No dedicated 404 -> NOT_FOUND branch: live-checked 2026-09-06
      // (`docs/plan-phase5-coverage.md` Lane D review round 2) that
      // Bilibili's watch page answers HTTP 200 even for a nonexistent
      // BV id (its own soft-block/empty-state shape - see
      // BilibiliPageParser's doc). A 404 here would only come from an
      // intermediary synthesizing one, not Bilibili itself, so it is
      // folded into the same CHALLENGE_FAILED-or-NETWORK handling below
      // rather than trusted as authoritative; BilibiliPageParser's own
      // body-shape check (missing `cid`) is the real "not found vs
      // anti-bot" signal, and it is deliberately CHALLENGE_FAILED, not
      // NOT_FOUND, for the same reason.
      if (response.statusCode == 412 || response.statusCode == 403) {
        throw const MediaExtractionException(
          'CHALLENGE_FAILED',
          'Bilibili blocked this request with an anti-bot challenge.',
        );
      }
      if (response.statusCode != 200) {
        throw MediaExtractionException(
          'NETWORK',
          'Bilibili returned HTTP ${response.statusCode} for this page.',
        );
      }
      return _pageParser.parse(html, bvid: bvid);
    } finally {
      httpClient.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _fetchPlayurlJson(Uri playurlUrl, Map<String, String> cookies) async {
    final httpClient = _httpClientFactory();
    try {
      final request = await httpClient.getUrl(_playurlRequestUrlBuilder(playurlUrl));
      request.headers.set('User-Agent', _userAgent);
      request.headers.set('Referer', 'https://www.bilibili.com/');
      if (cookies.isNotEmpty) request.headers.set('Cookie', _cookieHeader(cookies));
      final response = await request.close();
      final raw = await response.transform(utf8.decoder).join();

      if (response.statusCode == 412 || response.statusCode == 403) {
        throw const MediaExtractionException(
          'CHALLENGE_FAILED',
          'Bilibili blocked this request with an anti-bot challenge.',
        );
      }
      if (response.statusCode != 200) {
        throw MediaExtractionException(
          'NETWORK',
          'Bilibili returned HTTP ${response.statusCode} for this video\'s stream list.',
        );
      }
      try {
        return jsonDecode(raw) as Map<String, dynamic>;
      } on FormatException {
        throw const MediaExtractionException(
          'PARSE_ERROR',
          'Bilibili returned a response MiDa could not read as JSON.',
        );
      }
    } finally {
      httpClient.close(force: true);
    }
  }

  String _cookieHeader(Map<String, String> cookies) =>
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
}
