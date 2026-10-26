import 'dart:convert';

import '../../media_models.dart';
import '../generic_http.dart';
import 'embed_http.dart';

/// Everything one [EmbedResolver.resolve] call gets: the host page it is
/// looking at and the only network surface it may use.
class EmbedRequest {
  final Uri pageUrl;
  final String html;
  final EmbedHttp http;

  const EmbedRequest({required this.pageUrl, required this.html, required this.http});

  /// `scheme://host[:port]` of the host page. Sent as `Origin`, and (with
  /// a trailing slash) as `Referer`, on platform API calls and recorded as
  /// the media `Referer`: what a browser's default
  /// `strict-origin-when-cross-origin` policy sends from an embedding page
  /// to a different origin, so no more of the page URL leaks than the
  /// site's own player would leak.
  String get pageOrigin => pageUrl.origin;
}

/// One embed-platform family (Brightcove, Kaltura, ...). [matches] must be
/// cheap and network-free; [resolve] calls the platform's own public player
/// API exactly as its web player does and returns null when this page's
/// embed turns out to have nothing usable (unknown id, API error, empty
/// source list). It throws `MediaExtractionException('DRM_PROTECTED')`
/// when the platform itself reports only DRM-protected renditions, and
/// `EmbedDelegationException` (see `embed_delegation.dart`) when the media
/// belongs to a platform a native extractor already covers.
abstract class EmbedResolver {
  String get platform;
  bool matches(String html);
  Future<MediaInfo?> resolve(EmbedRequest request);
}

/// Shared policy and parsing helpers for every embed resolver.
class EmbedSupport {
  const EmbedSupport._();

  static MediaExtractionException drmException(String platform) => MediaExtractionException(
        'DRM_PROTECTED',
        'This $platform video is protected by DRM (Widevine, PlayReady, or FairPlay) and cannot be downloaded.',
      );

  /// Headers for a platform API call made on the host page's behalf.
  static Map<String, String> apiHeaders(EmbedRequest request, {String accept = 'application/json'}) => {
        'Accept': accept,
        'Origin': request.pageOrigin,
        'Referer': '${request.pageOrigin}/',
      };

  /// `MediaInfo.requestHeaders` for formats found via an embed.
  static Map<String, String> mediaHeaders(EmbedRequest request) => {
        'User-Agent': genericDesktopUserAgent,
        'Referer': '${request.pageOrigin}/',
      };

  /// Decodes [body] as JSON, or null when it is not valid JSON.
  static Object? tryDecodeJson(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }

  static String? asString(Object? value) => value is String && value.isNotEmpty ? value : null;

  static int? asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  /// Only absolute http(s) URLs with a host; anything else (relative,
  /// `data:`, `javascript:`, hostless) is dropped rather than guessed at.
  static String? httpUrl(Object? value) {
    final raw = asString(value);
    if (raw == null) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'https' && uri.scheme != 'http') return null;
    return raw;
  }

  /// Defensive, platform-neutral DRM marker on one source/asset object:
  /// any of the keys platforms use to attach license-server info.
  static bool hasDrmKeys(Map<dynamic, dynamic> source) {
    for (final key in const ['key_systems', 'keySystems', 'drm']) {
      final value = source[key];
      if (value == null || value == false) continue;
      if (value is Map && value.isEmpty) continue;
      if (value is List && value.isEmpty) continue;
      return true;
    }
    return false;
  }

  /// Minimal HTML entity decoding for attribute values and inline URLs
  /// (`&amp;` is by far the common case in `src="...?a=1&amp;b=2"`).
  static String unescapeHtml(String value) => value
      .replaceAll('&amp;', '&')
      .replaceAll('&#38;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#34;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll(r'\/', '/')
      // JSON-escaped ampersand (backslash, u0026) in inline script data;
      // spelled as two adjacent literals so no tool rewrites the escape.
      .replaceAll(r'\' 'u0026', '&');

  static final RegExp _attributePattern = RegExp(
    r'''([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))''',
  );

  /// Attributes of one opening tag's source text (`<video a="1" b='2'>`),
  /// lower-cased names, entity-decoded values.
  static Map<String, String> attributesOf(String tagText) {
    final attributes = <String, String>{};
    for (final match in _attributePattern.allMatches(tagText)) {
      final name = match.group(1)!.toLowerCase();
      final value = match.group(2) ?? match.group(3) ?? match.group(4) ?? '';
      attributes.putIfAbsent(name, () => unescapeHtml(value));
    }
    return attributes;
  }

  /// Source text of every opening tag named one of [tagNames] in [html],
  /// capped at [limit] tags so a pathological page stays cheap.
  static Iterable<String> openingTags(String html, List<String> tagNames, {int limit = 200}) sync* {
    final pattern = RegExp('<(?:${tagNames.join('|')})(?![-a-zA-Z0-9])[^>]*>', caseSensitive: false);
    var count = 0;
    for (final match in pattern.allMatches(html)) {
      if (count++ >= limit) return;
      yield match.group(0)!;
    }
  }

  /// `src`/`data-src` of every `<iframe>` in [html], entity-decoded.
  static Iterable<String> iframeSources(String html) sync* {
    for (final tag in openingTags(html, const ['iframe'])) {
      final attributes = attributesOf(tag);
      final src = attributes['src'];
      if (src != null && src.isNotEmpty) yield src;
      final lazy = attributes['data-src'];
      if (lazy != null && lazy.isNotEmpty) yield lazy;
    }
  }
}
