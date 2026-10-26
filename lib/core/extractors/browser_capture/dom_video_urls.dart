import 'dart:convert';

/// Reads the URLs the live DOM's own `<video>`/`<source>` elements point at
/// (`blob:` excluded) - see `CapturedMediaRanker` for why this outranks a
/// same-shaped but unrelated network response. Split out of
/// `BrowserCaptureExtractor` to keep that file under the 400-line cap;
/// [eval] is its `_evalString` bound to the live session.
class DomVideoUrls {
  const DomVideoUrls._();

  static const String expression = '''
JSON.stringify(
  Array.from(document.querySelectorAll('video')).flatMap(function (v) {
    var urls = [v.currentSrc || v.src || null];
    Array.from(v.querySelectorAll('source')).forEach(function (s) { urls.push(s.src || null); });
    return urls;
  }).filter(function (u) { return u && u.indexOf('blob:') !== 0; })
)
''';

  static Future<List<String>> read(Future<String?> Function(String expression) eval) async {
    final raw = await eval(expression);
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded.whereType<String>().toList();
    } catch (_) {
      return const [];
    }
  }
}
