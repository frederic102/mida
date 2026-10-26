import 'dart:convert';

import '../media_models.dart';
import '../native_http/native_text.dart';

/// Reads the `window.__INITIAL_STATE__=...` blob a Xiaohongshu page embeds
/// for its own front end.
///
/// The blob is a JavaScript object literal, not JSON: the site serializes
/// it with `undefined` for missing values. [extract] cuts it out of the
/// page, turns every `undefined` that is not inside a string literal into
/// `null`, and decodes the result. A `undefined` inside a string (a note
/// title that says "undefined") is left alone.
class XiaohongshuStateReader {
  const XiaohongshuStateReader._();

  static final RegExp _marker = RegExp(r'window\.__INITIAL_STATE__\s*=\s*');

  /// A double-quoted string literal (matched first, so what is inside is
  /// never rewritten) or a bare `undefined` token.
  static final RegExp _stringOrUndefined = RegExp(r'"[^"\\]*(?:\\.[^"\\]*)*"|\bundefined\b');

  /// The decoded state object, or null when the page has no state blob.
  /// Throws `PARSE_ERROR` when it has one that does not decode.
  static Map<String, dynamic>? extract(String html) {
    final start = _marker.firstMatch(html);
    if (start == null) return null;
    final scriptEnd = html.indexOf('</script>', start.end);
    var literal = html.substring(start.end, scriptEnd < 0 ? html.length : scriptEnd).trim();
    if (literal.endsWith(';')) literal = literal.substring(0, literal.length - 1).trimRight();

    final json = literal.replaceAllMapped(_stringOrUndefined, (m) => m.group(0) == 'undefined' ? 'null' : m.group(0)!);
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'Xiaohongshu page state could not be read; trying another method.',
      );
    }
    final map = NativeText.asMap(decoded);
    if (map == null) {
      throw const MediaExtractionException('PARSE_ERROR', 'Xiaohongshu page state is not an object; trying another method.');
    }
    return map;
  }
}
