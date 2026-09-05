import 'dart:convert';
import 'dart:io';

import '../../services/browser_page_fetcher.dart';
import '../media_extractor.dart';
import '../media_models.dart';
import 'generic_http.dart';
import 'hls_playlist_parser.dart';
import '../../net/host_policy.dart';
import 'html_media_sniffer.dart';
import 'iframe_follower.dart';
import 'media_url_probe.dart';

/// Fallback extractor for any http(s) URL that no platform-native
/// extractor recognizes. Detection order (first success wins), per
/// `docs/plan-generic-extractor.md` plus the embedded-player addendum
/// (live Vimeo measurement: the page is a shell with an `<iframe>`, the
/// video is only in the embed document the iframe points at):
///
///   0. Is the URL itself media (extension, then Content-Type)?
///   1. Plain HTML GET, sniff `<video>` / og / JSON-LD / inline-script URLs.
///   1.5. Nothing found -> follow up to 5 `<iframe>`/`<embed>`/
///        `og:video:url` embed pages (one level deep), GET each with
///        `Referer: <page url>`, sniff those. Cheaper than a headless
///        browser, so tried first.
///   2. Still nothing -> render with a headless browser, sniff again.
///   3. Still nothing -> DRM_PROTECTED if DRM markers are present (in the
///      page text, or because every candidate URL found was itself
///      DRM-wrapped), else NO_MEDIA_FOUND.
///
/// Every network request (page GET, embed GET, playlist GET, step-0
/// probe) goes through [HostPolicy.guardedRequest], which refuses
/// loopback/private/link-local hosts, including ones a redirect chain
/// leads to (SSRF guard: a malicious page must not be able to make this
/// app reach the user's local network).
///
/// `canHandle` accepts every http(s) URL, so this must be registered last
/// (Phase 2b) behind every platform-native extractor.
class GenericExtractor implements MediaExtractor {
  final HttpClient Function() _httpClientFactory;
  final MediaUrlProbe _probe;
  final BrowserPageFetcher _browserFetcher;

  /// Test-only escape hatch for [HostPolicy]'s SSRF guard so tests can
  /// point this extractor straight at a local fixture `HttpServer` (a
  /// single hop, no redirect). Any redirect hop encountered mid-flight is
  /// always checked regardless of this flag. Production code must never
  /// set this to true.
  final bool allowPrivateHosts;

  GenericExtractor({
    HttpClient Function()? httpClientFactory,
    MediaUrlProbe? probe,
    BrowserPageFetcher? browserFetcher,
    this.allowPrivateHosts = false,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _probe = probe ?? MediaUrlProbe(httpClientFactory: httpClientFactory, allowPrivateHosts: allowPrivateHosts),
        _browserFetcher = browserFetcher ?? BrowserPageFetcher(allowPrivateHosts: allowPrivateHosts);

  static final RegExp _emePattern = RegExp(r'\bEME\b', caseSensitive: false);
  static const List<String> _drmMarkers = [
    'widevine',
    'playready',
    'fairplay',
    'encrypted-media',
    'license_url',
  ];

  @override
  bool canHandle(Uri url) => url.scheme == 'http' || url.scheme == 'https';

  @override
  Future<MediaInfo> extract(Uri url) async {
    if (!allowPrivateHosts && HostPolicy.isDisallowedHost(url)) {
      throw MediaExtractionException(
        'UNSUPPORTED_URL',
        'Refusing to fetch $url: it resolves to a private, loopback, or link-local '
            'network address. This extractor only follows public internet hosts.',
      );
    }

    final extensionContainer = MediaUrlProbe.containerFromExtension(url);
    final directContainer = extensionContainer ?? await _probe.containerFromContentType(url);
    if (directContainer != null) {
      final formats = _orderFormats(await _expandFormats(url.toString(), directContainer));
      return MediaInfo(
        id: _idFromUrl(url),
        title: _lastSegmentOrUrl(url),
        sourceUrl: url,
        formats: formats,
        requestHeaders: const {'User-Agent': genericDesktopUserAgent},
      );
    }

    final html = await _fetchText(url);
    final pageSniffed = HtmlMediaSniffer.sniff(html, url);
    var sniffed = pageSniffed;
    var corpusForDrmCheck = html;
    var anyDrmDropped = pageSniffed.anyDrmCandidatesDropped;
    Map<String, String> requestHeaders = const {'User-Agent': genericDesktopUserAgent};
    Map<String, String>? playlistFetchHeaders;

    if (sniffed.isEmpty) {
      final embedResult = await _followEmbeds(url, html);
      if (embedResult != null) {
        // Embed page's own title/thumbnail win; fall back to the outer
        // page's when the embed page didn't have one.
        sniffed = HtmlSniffResult(
          mediaUrls: embedResult.sniffed.mediaUrls,
          title: embedResult.sniffed.title ?? pageSniffed.title,
          thumbnailUrl: embedResult.sniffed.thumbnailUrl ?? pageSniffed.thumbnailUrl,
          anyDrmCandidatesDropped: embedResult.sniffed.anyDrmCandidatesDropped,
        );
        anyDrmDropped = anyDrmDropped || embedResult.sniffed.anyDrmCandidatesDropped;
        final referer = embedResult.embedUrl.toString();
        requestHeaders = {'User-Agent': genericDesktopUserAgent, 'Referer': referer};
        playlistFetchHeaders = {'Referer': referer};
      }
    }

    if (sniffed.isEmpty) {
      final rendered = await _browserFetcher.fetchDom(url);
      corpusForDrmCheck = '$html\n$rendered';
      sniffed = HtmlMediaSniffer.sniff(rendered, url);
      anyDrmDropped = anyDrmDropped || sniffed.anyDrmCandidatesDropped;
    }

    if (sniffed.isEmpty) {
      throw _noMediaOrDrmException(corpusForDrmCheck, anyDrmCandidatesDropped: anyDrmDropped);
    }

    return _buildMediaInfo(url, sniffed, requestHeaders: requestHeaders, playlistFetchHeaders: playlistFetchHeaders);
  }

  /// The "1.5" step: follows up to [IframeFollower.maxCandidates] embed
  /// pages found in [pageHtml], fetching each with `Referer: <pageUrl>`
  /// and sniffing it independently (one level deep only: an embed page is
  /// never itself scanned for further iframes to follow). Candidates that
  /// fail to fetch, or sniff to nothing, are skipped rather than aborting
  /// the whole step; every embed that does yield media is merged.
  Future<_EmbedFollowResult?> _followEmbeds(Uri pageUrl, String pageHtml) async {
    final candidates = IframeFollower.findEmbedCandidates(pageHtml, pageUrl);
    if (candidates.isEmpty) return null;

    final mergedMedia = <SniffedMedia>[];
    final seenUrls = <String>{};
    String? title;
    String? thumbnailUrl;
    Uri? sourceEmbedUrl;
    var anyDrmDropped = false;

    for (final embedUrl in candidates) {
      String embedHtml;
      try {
        embedHtml = await _fetchText(embedUrl, extraHeaders: {'Referer': pageUrl.toString()});
      } catch (_) {
        continue;
      }

      final embedSniff = HtmlMediaSniffer.sniff(embedHtml, embedUrl);
      anyDrmDropped = anyDrmDropped || embedSniff.anyDrmCandidatesDropped;
      if (embedSniff.isEmpty) continue;

      // Headers are per-MediaInfo, not per-format (see MediaInfo doc), so
      // when multiple embeds contribute we can only carry one Referer:
      // the first embed that actually produced media wins.
      sourceEmbedUrl ??= embedUrl;
      title ??= embedSniff.title;
      thumbnailUrl ??= embedSniff.thumbnailUrl;
      for (final media in embedSniff.mediaUrls) {
        if (seenUrls.add(media.url)) mergedMedia.add(media);
      }
    }

    if (mergedMedia.isEmpty || sourceEmbedUrl == null) {
      // Still surface "found DRM only" even when nothing else contributed,
      // so `extract()` can prefer DRM_PROTECTED over NO_MEDIA_FOUND.
      if (anyDrmDropped) {
        return _EmbedFollowResult(
          sniffed: const HtmlSniffResult(anyDrmCandidatesDropped: true),
          embedUrl: sourceEmbedUrl ?? pageUrl,
        );
      }
      return null;
    }
    return _EmbedFollowResult(
      sniffed: HtmlSniffResult(
        mediaUrls: mergedMedia,
        title: title,
        thumbnailUrl: thumbnailUrl,
        anyDrmCandidatesDropped: anyDrmDropped,
      ),
      embedUrl: sourceEmbedUrl,
    );
  }

  Future<MediaInfo> _buildMediaInfo(
    Uri sourceUrl,
    HtmlSniffResult sniffed, {
    required Map<String, String> requestHeaders,
    Map<String, String>? playlistFetchHeaders,
  }) async {
    final formats = <MediaFormat>[];
    for (final media in sniffed.mediaUrls) {
      formats.addAll(await _expandFormats(media.url, media.container, extraHeaders: playlistFetchHeaders));
    }
    return MediaInfo(
      id: _idFromUrl(sourceUrl),
      title: sniffed.title ?? _lastSegmentOrUrl(sourceUrl),
      thumbnailUrl: sniffed.thumbnailUrl,
      sourceUrl: sourceUrl,
      formats: _orderFormats(formats),
      requestHeaders: requestHeaders,
    );
  }

  /// Orders formats so the ones with the most (and most trustworthy)
  /// metadata come first: an expanded HLS master's per-variant formats
  /// (real height/bitrate from `#EXT-X-STREAM-INF`), then DASH `.mpd`
  /// (single opaque format, variant parsing out of scope), then anything
  /// else (a plain file, or an m3u8 media playlist we could not expand).
  /// Stable within each tier (a plain loop, not `List.sort`, which Dart
  /// does not guarantee is stable) so dedupe/discovery order survives.
  List<MediaFormat> _orderFormats(List<MediaFormat> formats) {
    final hlsWithHeight = <MediaFormat>[];
    final mpd = <MediaFormat>[];
    final rest = <MediaFormat>[];
    for (final format in formats) {
      if (format.container == 'm3u8' && format.height != null) {
        hlsWithHeight.add(format);
      } else if (format.container == 'mpd') {
        mpd.add(format);
      } else {
        rest.add(format);
      }
    }
    return [...hlsWithHeight, ...mpd, ...rest];
  }

  /// Turns one candidate media URL into zero or more [MediaFormat]s. An
  /// `m3u8` URL is fetched and, if it turns out to be a master playlist,
  /// expanded into one format per `#EXT-X-STREAM-INF` variant (per the
  /// plan's format model); a media-playlist `m3u8` (no stream-inf tags,
  /// but a genuine `#EXTM3U` body) is exposed as a single format; DASH
  /// `mpd` (variant parsing out of scope) and any other container is
  /// exposed as a single format unconditionally, with no fetch.
  ///
  /// If the master-playlist fetch itself fails (network error, non-2xx
  /// status, or a body that is not actually an HLS playlist at all, e.g.
  /// an error page returned in place of a DRM-blocked manifest) this
  /// candidate contributes **no** format at all rather than falling back
  /// to a format pointing at a URL already known to be unusable (a live
  /// probe hit exactly this: a placeholder format for an inaccessible
  /// playlist reached ffmpeg and failed with "Invalid data found when
  /// processing input").
  Future<List<MediaFormat>> _expandFormats(String url, String container, {Map<String, String>? extraHeaders}) async {
    if (container != 'm3u8') {
      return [_formatFor(id: url, url: url, container: container)];
    }

    _FetchResult fetch;
    try {
      fetch = await _fetchWithStatus(Uri.parse(url), extraHeaders: extraHeaders);
    } catch (_) {
      return const [];
    }

    final looksLikePlaylist = fetch.body.trimLeft().startsWith('#EXTM3U');
    final isSuccessStatus = fetch.statusCode >= 200 && fetch.statusCode < 300;
    if (!isSuccessStatus || !looksLikePlaylist) {
      return const [];
    }

    final variants = HlsPlaylistParser.parseMasterVariants(fetch.body, Uri.parse(url));
    if (variants.isEmpty) {
      return [_formatFor(id: url, url: url, container: container)];
    }

    return [
      for (var i = 0; i < variants.length; i++)
        _formatFor(
          id: '$url#$i',
          url: variants[i].url,
          container: 'm3u8',
          width: variants[i].width,
          height: variants[i].height,
          bitrate: variants[i].bandwidth,
        ),
    ];
  }

  MediaFormat _formatFor({
    required String id,
    required String url,
    required String container,
    int? width,
    int? height,
    int? bitrate,
  }) {
    final isAudioOnly = container == 'mp3' || container == 'm4a';
    return MediaFormat(
      id: id,
      url: url,
      container: container,
      width: width,
      height: height,
      bitrate: bitrate ?? 0,
      hasVideo: !isAudioOnly,
      hasAudio: true,
    );
  }

  Future<String> _fetchText(Uri url, {Map<String, String>? extraHeaders}) async {
    return (await _fetchWithStatus(url, extraHeaders: extraHeaders)).body;
  }

  Future<_FetchResult> _fetchWithStatus(Uri url, {Map<String, String>? extraHeaders}) async {
    final client = _httpClientFactory();
    try {
      final response = await HostPolicy.guardedRequest(
        client,
        url,
        useHead: false,
        allowPrivateHosts: allowPrivateHosts,
        configureRequest: (request) {
          request.headers.set('User-Agent', genericDesktopUserAgent);
          request.headers.set('Accept-Language', genericAcceptLanguage);
          extraHeaders?.forEach(request.headers.set);
        },
      );
      final bytes = await response.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
      String body;
      try {
        body = utf8.decode(bytes);
      } on FormatException {
        body = latin1.decode(bytes);
      }
      return _FetchResult(statusCode: response.statusCode, body: body);
    } finally {
      client.close(force: true);
    }
  }

  MediaExtractionException _noMediaOrDrmException(String corpus, {bool anyDrmCandidatesDropped = false}) {
    final lower = corpus.toLowerCase();
    final hasDrmMarker =
        anyDrmCandidatesDropped || _drmMarkers.any(lower.contains) || _emePattern.hasMatch(corpus);
    if (hasDrmMarker) {
      return const MediaExtractionException(
        'DRM_PROTECTED',
        'This video is protected by DRM (Widevine, PlayReady, or FairPlay) and cannot be downloaded.',
      );
    }
    return const MediaExtractionException(
      'NO_MEDIA_FOUND',
      'No video found on this page. The site may load video only after '
          'sign-in or interaction. Try the direct video URL if you have it.',
    );
  }

  String _idFromUrl(Uri url) => 'generic-${url.toString().hashCode.toUnsigned(31)}';

  String _lastSegmentOrUrl(Uri url) {
    final segments = url.pathSegments.where((s) => s.isNotEmpty).toList();
    return segments.isEmpty ? url.toString() : segments.last;
  }
}

/// Result of a successful `_followEmbeds` pass: the merged media found
/// across every embed page that yielded any, plus the embed URL to use
/// as the `Referer` for subsequent format/playlist requests.
class _EmbedFollowResult {
  final HtmlSniffResult sniffed;
  final Uri embedUrl;

  const _EmbedFollowResult({required this.sniffed, required this.embedUrl});
}

/// A fetched body plus the HTTP status it came with, so callers that need
/// to distinguish "200 with real content" from "some error page" (the
/// HLS master-playlist expansion path) can.
class _FetchResult {
  final int statusCode;
  final String body;

  const _FetchResult({required this.statusCode, required this.body});
}
