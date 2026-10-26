import 'dart:convert';

import '../generic/format_expander.dart';
import '../media_extractor.dart';
import '../media_models.dart';
import '../native_http/native_host_list.dart';
import '../native_http/native_http_client.dart';
import '../native_http/native_json.dart';
import '../native_http/native_text.dart';
import 'bluesky_post_parser.dart';
import 'bluesky_url_matcher.dart';

/// Native Bluesky extractor for
/// `bsky.app/profile/<handle-or-did>/post/<rkey>` (see [BlueskyUrlMatcher]).
///
/// Technique, per `docs/supported-sites.md` Policy: the unauthenticated
/// AppView calls the public web app itself makes on `public.api.bsky.app`:
/// `com.atproto.identity.resolveHandle` (only when the URL names a handle,
/// not a DID), then `app.bsky.feed.getPostThread` for the post's `at://` URI
/// with `depth=0`. The post's video embed carries an HLS master playlist,
/// which is expanded (and DRM-scanned) through `FormatExpander`. No account,
/// no token, no cookies.
///
/// Outcomes:
/// - video found -> [MediaInfo] (one format per HLS variant).
/// - an unresolvable handle, a `notFoundPost`, or HTTP 400/404/410 ->
///   `NOT_FOUND`. A `blockedPost` or a `!no-unauthenticated` account is `LOGIN_REQUIRED`.
/// - an account that hides itself from signed-out viewers
///   (`!no-unauthenticated` label) -> `LOGIN_REQUIRED`.
/// - a post with no video embed (text, images, link card, quoted video) ->
///   `NO_MEDIA_FOUND`.
/// - DRM-flagged playlist only -> `DRM_PROTECTED`.
/// - HTTP 429 -> `RATE_LIMITED`; 401/403 -> `CHALLENGE_FAILED`; unrecognized
///   or mismatched answer, or an unreadable playlist -> `PARSE_ERROR`.
class BlueskyExtractor implements MediaExtractor {
  /// Bluesky video lives on `video.bsky.app` / `video.cdn.bsky.app`. A
  /// playlist URL (or redirect) elsewhere is never requested.
  static const NativeHostList _mediaHosts = NativeHostList(['bsky.app']);

  static const String _apiHost = 'public.api.bsky.app';
  static const Map<String, String> _downloadHeaders = {'User-Agent': NativeHttpClient.userAgent};

  final NativeHttpClient _http;
  final BlueskyPostParser _parser;
  final FormatExpander _expander;

  BlueskyExtractor({NativeHttpClient? httpClient, BlueskyPostParser? parser})
      : this._((httpClient ?? NativeHttpClient(service: 'Bluesky')).withMediaHosts(_mediaHosts), parser);

  BlueskyExtractor._(this._http, BlueskyPostParser? parser)
      : _parser = parser ?? const BlueskyPostParser(),
        _expander = FormatExpander(fetchText: _http.fetchText);

  @override
  bool canHandle(Uri url) => BlueskyUrlMatcher.match(url) != null;

  @override
  Future<MediaInfo> extract(Uri url) async {
    final ref = BlueskyUrlMatcher.match(url);
    if (ref == null) {
      throw const MediaExtractionException('UNSUPPORTED_URL', 'Not a recognizable Bluesky post URL.');
    }

    final did = ref.actorIsDid ? ref.actor : await _resolveHandle(ref.actor);
    final atUri = ref.atUri(did);
    final thread = await _getJson(
      Uri.https(_apiHost, '/xrpc/app.bsky.feed.getPostThread', {'uri': atUri, 'depth': '0'}),
      badRequest: const MediaExtractionException('NOT_FOUND', 'Bluesky does not know this post.'),
    );
    final post = _parser.parse(thread, expectedUri: atUri);

    final video = post.video;
    if (video == null) {
      throw const MediaExtractionException('NO_MEDIA_FOUND', 'This Bluesky post has no video.');
    }

    final raw = await _expander.expandFormats(video.playlistUrl, 'm3u8', extraHeaders: _downloadHeaders);
    final expanded = ExpandedFormats(formats: _http.filterAllowedFormats(raw.formats), drmDetected: raw.drmDetected);
    if (expanded.formats.isEmpty) {
      if (expanded.drmDetected) {
        throw const MediaExtractionException(
          'DRM_PROTECTED',
          'This Bluesky video is DRM protected. MiDa does not bypass DRM.',
        );
      }
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'MiDa could not read this Bluesky video playlist; trying another method.',
      );
    }

    final text = post.text == null ? null : NativeText.clip(post.text!.split(RegExp(r'\r?\n')).first.trim(), 100);
    return MediaInfo(
      id: ref.rkey,
      title: text == null || text.isEmpty ? 'Bluesky video by @${post.handle}' : text,
      author: post.author ?? post.handle,
      thumbnailUrl: video.thumbnailUrl != null && _http.mediaUrlAllowed(video.thumbnailUrl!) ? video.thumbnailUrl : null,
      formats: expanded.formats,
      sourceUrl: url,
      requestHeaders: _downloadHeaders,
    );
  }

  Future<String> _resolveHandle(String handle) async {
    final json = await _getJson(
      Uri.https(_apiHost, '/xrpc/com.atproto.identity.resolveHandle', {'handle': handle}),
      badRequest: const MediaExtractionException('NOT_FOUND', 'This Bluesky handle does not resolve to an account.'),
    );
    final did = json['did'];
    if (did is! String || !BlueskyUrlMatcher.didPattern.hasMatch(did)) {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'Bluesky answered the handle lookup with something MiDa does not recognize; trying another method.',
      );
    }
    return did;
  }

  /// GETs [url] as JSON. HTTP 400 with XRPC error `NotFound` becomes [badRequest]; every other non-200 status maps as in
  /// `NativeHttpClient.throwForStatus`.
  Future<Map<String, dynamic>> _getJson(Uri url, {required MediaExtractionException badRequest}) async {
    final response = await _http.get(
      url,
      kind: NativeBodyKind.api,
      headers: const {'Accept': 'application/json'},
      acceptHop: (hop) => hop.host.toLowerCase() == _apiHost,
    );
    if (response.statusCode == 400) {
      // Only the XRPC `NotFound` error is a removal statement; InvalidRequest
      // and anything unreadable stay non-terminal so other tiers get a turn.
      final error = _xrpcError(response.body);
      throw error == 'NotFound'
          ? badRequest
          : const MediaExtractionException(
              'PARSE_ERROR',
              'Bluesky rejected the request without saying the item is gone; trying another method.',
            );
    }
    NativeHttpClient.throwForStatus(response.statusCode, 'Bluesky');
    return NativeJson.decodeObject(response.body, 'Bluesky');
  }

  static String? _xrpcError(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> && decoded['error'] is String ? decoded['error'] as String : null;
    } on FormatException {
      return null;
    }
  }
}
