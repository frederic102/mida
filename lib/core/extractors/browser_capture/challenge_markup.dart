/// What a page's markup actually *declares*, as opposed to text that merely
/// mentions it (astra round 2, `HeadlessBlockDetector` evidence). Built by a
/// small tag/attribute scanner, not by substring search, so these are never
/// evidence:
///  - HTML comments (`<!-- <div id="px-captcha"> -->`),
///  - text or escaped markup in a code sample (`&lt;div id="px-captcha"&gt;`,
///    anything inside `<pre>`, `<code>`, `<textarea>`, `<template>`, ...),
///  - markup quoted inside an attribute value or a script string,
///  - look-alike attributes (`data-id="px-captcha"`) or values
///    (`id="px-captcha-demo"`).
///
/// Limits: a regex scanner, not an HTML5 parser. A `>` inside an unquoted
/// attribute value, or a `</script>` inside a script string, can end a tag
/// or script early; both only lose evidence, they cannot invent a match
/// that is not a real `id`/`src` attribute of a real tag.
class ChallengeMarkup {
  /// `src` values of real `<script>` and `<iframe>` tags.
  final List<String> scriptAndFrameSrcs;

  /// `(lower-case tag name, exact id value)` of every real tag with an `id`.
  final List<(String, String)> elementIds;

  /// Bodies of inline (no `src`) `<script>` elements, JS comments removed.
  final List<String> inlineScripts;

  const ChallengeMarkup._(this.scriptAndFrameSrcs, this.elementIds, this.inlineScripts);

  static final RegExp _comment = RegExp(r'<!--[\s\S]*?(?:-->|$)');
  static final RegExp _script = RegExp(r'<script\b([^>]*)>([\s\S]*?)(?:</script\s*>|$)', caseSensitive: false);
  static final RegExp _rawText = RegExp(
    r'<(style|textarea|pre|code|xmp|template|title|noscript)\b[^>]*>[\s\S]*?(?:</\1\s*>|$)',
    caseSensitive: false,
  );

  /// One whole tag, attribute values included, so markup quoted inside a
  /// value is consumed as part of the outer tag and never matched itself.
  static final RegExp _tag = RegExp(
    r'''<([a-zA-Z][a-zA-Z0-9-]*)((?:\s+[^\s"'=<>/`]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*)\s*/?>''',
  );
  static final RegExp _attribute = RegExp(
    r'''([^\s"'=<>/`]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?''',
  );
  static final RegExp _quotedValue = RegExp('"[^"]*"|' "'[^']*'");
  static final RegExp _jsBlockComment = RegExp(r'/\*[\s\S]*?\*/');
  static final RegExp _jsLineComment = RegExp(r'(^|[^:"\x27\\])//[^\n]*');

  static Map<String, String> _attributes(String raw) => {
        for (final m in _attribute.allMatches(raw))
          m.group(1)!.toLowerCase(): m.group(2) ?? m.group(3) ?? m.group(4) ?? '',
      };

  static ChallengeMarkup parse(String html) {
    final srcs = <String>[];
    final ids = <(String, String)>[];
    final inline = <String>[];

    // Dead context goes BEFORE anything is collected (astra round 3): comments, then markup
    // quoted inside attribute values, then template/noscript/pre/code/... contents.
    var rest = html.replaceAll(_comment, '');
    rest = rest.replaceAllMapped(_tag, (m) => m.group(0)!.replaceAllMapped(_quotedValue, (q) => q.group(0)!.contains('<') ? '""' : q.group(0)!));
    rest = rest.replaceAll(_rawText, ' ');
    rest = rest.replaceAllMapped(_script, (m) {
      final attrs = _attributes(m.group(1)!);
      final src = attrs['src'];
      if (src != null && src.isNotEmpty) {
        srcs.add(src);
      } else {
        inline.add(m.group(2)!.replaceAll(_jsBlockComment, '').replaceAllMapped(_jsLineComment, (c) => c.group(1)!));
      }
      final id = attrs['id'];
      if (id != null) ids.add(('script', id));
      return ' ';
    });

    for (final m in _tag.allMatches(rest)) {
      final tag = m.group(1)!.toLowerCase();
      final attrs = _attributes(m.group(2) ?? '');
      final id = attrs['id'];
      if (id != null) ids.add((tag, id));
      final src = attrs['src'];
      if (tag == 'iframe' && src != null && src.isNotEmpty) srcs.add(src);
    }
    return ChallengeMarkup._(srcs, ids, inline);
  }
}
