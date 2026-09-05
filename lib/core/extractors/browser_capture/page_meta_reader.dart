import 'dart:convert';

/// Reads a live page's `document.title` / OpenGraph meta / current URL via
/// one `Runtime.evaluate` round trip, and picks the best title/thumbnail
/// out of that result. Split out of `BrowserCaptureExtractor` (which owns
/// the session and event collection) to keep both files under this
/// project's 400-line cap; [evalString] is
/// `BrowserCaptureExtractor._evalString` bound to its live session, so
/// this stays a pure-data helper with no session dependency of its own.
class PageMetaReader {
  const PageMetaReader._();

  static const String metaExpression = '''
JSON.stringify({
  title: document.title || null,
  ogTitle: (document.querySelector('meta[property="og:title"]') || {}).content || null,
  ogImage: (document.querySelector('meta[property="og:image"]') || {}).content || null,
  href: (typeof location !== 'undefined' && location.href) || null
})
''';

  static Future<Map<String, dynamic>?> read(Future<String?> Function(String expression) evalString) async {
    final raw = await evalString(metaExpression);
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  /// Prefers `og:title` (usually cleaner than a `<title>` that carries a
  /// site-name suffix), falling back to the raw document title.
  static String? title(Map<String, dynamic>? meta) {
    final ogTitle = meta?['ogTitle'] as String?;
    final rawTitle = meta?['title'] as String?;
    if (ogTitle != null && ogTitle.isNotEmpty) return ogTitle;
    if (rawTitle != null && rawTitle.isNotEmpty) return rawTitle;
    return null;
  }

  static String? thumbnail(Map<String, dynamic>? meta) {
    final ogImage = meta?['ogImage'] as String?;
    return (ogImage != null && ogImage.isNotEmpty) ? ogImage : null;
  }
}
