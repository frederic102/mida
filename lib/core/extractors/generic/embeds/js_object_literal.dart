/// Tiny, quote-aware reader for JavaScript object literals written in host
/// pages (embed options such as `kWidget.embed({...})`). Not a parser: it
/// only finds where an object ends and which scalar fields are written
/// directly in it, so a resolver can attribute ids to the object that owns
/// them instead of to whatever matches first anywhere in the text.
class JsObjectLiteral {
  const JsObjectLiteral._();

  static bool _isWordChar(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5a) || (u >= 0x61 && u <= 0x7a) || c == '_' || c == r'$';
  }

  /// Index just past a `//` or `/* */` comment starting at [i], or null.
  /// Unterminated comments run to [limit].
  static int? _commentEnd(String text, int i, int limit) {
    if (text[i] != '/' || i + 1 >= limit) return null;
    final next = text[i + 1];
    if (next == '/') {
      final end = text.indexOf('\n', i + 2);
      return end < 0 || end >= limit ? limit : end + 1;
    }
    if (next == '*') {
      final end = text.indexOf('*/', i + 2);
      return end < 0 || end + 2 > limit ? limit : end + 2;
    }
    return null;
  }

  /// Index of the quote closing the literal opened at [start], or -1.
  static int _quotedEnd(String text, int start, int limit) {
    final quote = text[start];
    for (var i = start + 1; i < limit; i++) {
      final c = text[i];
      if (c == r'\') {
        i++;
      } else if (c == quote) {
        return i;
      }
    }
    return -1;
  }

  /// The scalar fields written directly in the object literal opening at
  /// [open] (`key: 'v'`, `"key": 12`, `key: _x`): keys quoted or bare,
  /// values quoted strings or bare words/numbers. Anything inside a nested
  /// object or array is skipped, so it can never be mistaken for a field of
  /// this object; comments never count. First occurrence of a key wins.
  /// Bounded by [maxLength].
  static Map<String, String> topLevelFields(String text, int open, {int maxLength = 8000}) {
    final fields = <String, String>{};
    final limit = text.length < open + maxLength ? text.length : open + maxLength;
    var depth = 0;
    String? key;
    String? lastToken;
    var i = open;
    while (i < limit) {
      final c = text[i];
      final skip = _commentEnd(text, i, limit);
      if (skip != null) {
        i = skip;
        continue;
      }
      if (c == '"' || c == "'") {
        final end = _quotedEnd(text, i, limit);
        if (end < 0) break;
        if (depth == 1) {
          final literal = text.substring(i + 1, end);
          if (key != null) {
            fields.putIfAbsent(key, () => literal);
            key = null;
          } else {
            lastToken = literal;
          }
        }
        i = end + 1;
        continue;
      }
      if (c == '{' || c == '[') {
        depth++;
        if (depth > 1) key = null;
      } else if (c == '}' || c == ']') {
        depth--;
        if (depth == 0) break;
      } else if (depth == 1) {
        if (c == ':') {
          key = lastToken;
          lastToken = null;
        } else if (c == ',') {
          key = null;
          lastToken = null;
        } else if (_isWordChar(c)) {
          var end = i;
          while (end < limit && _isWordChar(text[end])) {
            end++;
          }
          final word = text.substring(i, end);
          if (key != null) {
            fields.putIfAbsent(key, () => word);
            key = null;
          } else {
            lastToken = word;
          }
          i = end;
          continue;
        }
      }
      i++;
    }
    return fields;
  }

  /// Index just past the `}` closing the object that opens at [open]
  /// (quote- and comment-aware, bounded by [maxLength]).
  static int end(String text, int open, {int maxLength = 8000}) {
    final limit = text.length < open + maxLength ? text.length : open + maxLength;
    var depth = 0;
    String? quote;
    for (var i = open; i < limit; i++) {
      final c = text[i];
      if (quote != null) {
        if (c == r'\') {
          i++;
        } else if (c == quote) {
          quote = null;
        }
        continue;
      }
      final skip = _commentEnd(text, i, limit);
      if (skip != null) {
        i = skip - 1;
        continue;
      }
      if (c == '"' || c == "'") {
        quote = c;
      } else if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) return i + 1;
      }
    }
    return limit;
  }
}
