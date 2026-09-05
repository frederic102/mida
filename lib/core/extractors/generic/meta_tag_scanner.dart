/// Shared, minimal `<meta>` tag reader used by both `HtmlMediaSniffer` and
/// `IframeFollower`. No HTML-parsing package is added for this (project
/// convention: no new pub deps); a small pair of attribute regexes reads
/// `property`/`content` (also accepting the `name=` form some sites use for
/// twitter/og tags) regardless of attribute order.
class MetaTagScanner {
  const MetaTagScanner._();

  static final RegExp _metaTagPattern = RegExp(r'<meta\b([^>]*)>', caseSensitive: false);

  static final RegExp _propertyPattern = RegExp(
    '(?:property|name)\\s*=\\s*"([^"]*)"|(?:property|name)\\s*=\\s*' r"'([^']*)'",
    caseSensitive: false,
  );

  static final RegExp _contentPattern = RegExp(
    'content\\s*=\\s*"([^"]*)"|content\\s*=\\s*' r"'([^']*)'",
    caseSensitive: false,
  );

  /// Yields a (lowercased property/name, content) pair for every `<meta>`
  /// tag in [html] that carries both attributes.
  static Iterable<MapEntry<String, String>> scan(String html) sync* {
    for (final metaMatch in _metaTagPattern.allMatches(html)) {
      final attrs = metaMatch.group(1) ?? '';
      final propertyMatch = _propertyPattern.firstMatch(attrs);
      final contentMatch = _contentPattern.firstMatch(attrs);
      if (propertyMatch == null || contentMatch == null) continue;
      final property = (propertyMatch.group(1) ?? propertyMatch.group(2) ?? '').toLowerCase();
      final content = contentMatch.group(1) ?? contentMatch.group(2) ?? '';
      yield MapEntry(property, content);
    }
  }
}
