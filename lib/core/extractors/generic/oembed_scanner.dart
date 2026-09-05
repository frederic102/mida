import 'dart:convert';

/// Pure (no network) helpers for the oEmbed fallback (plan Lane B item 3):
/// a page can advertise its player via
/// `<link type="application/json+oembed" href="...">` instead of embedding
/// an `<iframe>` directly. `GenericExtractor` fetches [findOembedUrl]'s
/// result, then hands the JSON body to [findIframeSrcInOembedJson] to pull
/// the iframe out of the response's `html` field, and finally follows that
/// iframe exactly like any other embed candidate (same host policy, same
/// `Referer`, same one-level-deep limit as `IframeFollower`).
class OembedScanner {
  const OembedScanner._();

  static final RegExp _oembedLinkPattern = RegExp(
    '<link\\b[^>]*\\btype\\s*=\\s*(?:"application/json\\+oembed"|' r"'application/json\+oembed')" '[^>]*>',
    caseSensitive: false,
  );

  static final RegExp _hrefPattern = RegExp(
    '''href\\s*=\\s*"([^"]+)"|href\\s*=\\s*''' r"'([^']+)'",
    caseSensitive: false,
  );

  static final RegExp _iframeSrcPattern = RegExp(
    '<iframe\\b[^>]*\\bsrc\\s*=\\s*(?:"([^"]+)"|' r"'([^']+)')",
    caseSensitive: false,
  );

  /// Finds the oEmbed discovery link's `href`, resolved against [pageUrl].
  /// Null when the page has no such link, the link has no `href`, or the
  /// `href` does not resolve to an http(s) URL.
  static Uri? findOembedUrl(String html, Uri pageUrl) {
    final linkMatch = _oembedLinkPattern.firstMatch(html);
    if (linkMatch == null) return null;
    final tag = linkMatch.group(0)!;
    final hrefMatch = _hrefPattern.firstMatch(tag);
    if (hrefMatch == null) return null;
    final raw = hrefMatch.group(1) ?? hrefMatch.group(2);
    return _resolveHttpUrl(raw, pageUrl);
  }

  /// Extracts the first `<iframe src>` found in the oEmbed response's
  /// `html` field, resolved against [oembedUrl] (the response may return a
  /// protocol-relative or path-relative iframe src). Null on malformed
  /// JSON, a non-string/missing `html` field, no iframe inside it, or a
  /// non-http(s) result.
  static Uri? findIframeSrcInOembedJson(String rawJson, Uri oembedUrl) {
    dynamic decoded;
    try {
      decoded = jsonDecode(rawJson);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final htmlField = decoded['html'];
    if (htmlField is! String) return null;
    final match = _iframeSrcPattern.firstMatch(htmlField);
    if (match == null) return null;
    final raw = match.group(1) ?? match.group(2);
    return _resolveHttpUrl(raw, oembedUrl);
  }

  static Uri? _resolveHttpUrl(String? raw, Uri base) {
    if (raw == null || raw.isEmpty) return null;
    Uri resolved;
    try {
      resolved = base.resolve(_decodeEntities(raw));
    } catch (_) {
      return null;
    }
    if (resolved.scheme != 'http' && resolved.scheme != 'https') return null;
    return resolved;
  }

  static String _decodeEntities(String text) => text.replaceAll('&amp;', '&');
}
