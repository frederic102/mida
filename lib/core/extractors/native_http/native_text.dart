/// Small, dependency-free helpers the phase 7 native extractors share:
/// HTML entity decoding, tag attribute reading, defensive JSON accessors and
/// the one rule for turning a URL found in a response into a download URL.
class NativeText {
  const NativeText._();

  static const Map<String, String> _namedEntities = {
    'amp': '&',
    'lt': '<',
    'gt': '>',
    'quot': '"',
    'apos': "'",
    'nbsp': ' ',
  };

  static final RegExp _entity = RegExp(r'&(#[xX][0-9a-fA-F]{1,6}|#[0-9]{1,7}|[a-zA-Z]{2,6});');

  /// Decodes the entities HTML attributes and meta content actually carry
  /// (`&quot;`, `&amp;`, `&#39;`, `&#x27;`, ...) in a single pass, so
  /// `&amp;quot;` becomes `&quot;` and not `"`. Unknown entities stay as is.
  static String decodeEntities(String text) {
    if (!text.contains('&')) return text;
    return text.replaceAllMapped(_entity, (match) {
      final body = match.group(1)!;
      if (body.startsWith('#')) {
        final isHex = body.length > 1 && (body[1] == 'x' || body[1] == 'X');
        final code = int.tryParse(isHex ? body.substring(2) : body.substring(1), radix: isHex ? 16 : 10);
        if (code == null || code <= 0 || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) return match.group(0)!;
        return String.fromCharCode(code);
      }
      return _namedEntities[body] ?? match.group(0)!;
    });
  }

  static final RegExp _attribute = RegExp(r'''([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)')''');

  /// Attributes of one start tag's text (`<video ...>`), names lowercased,
  /// values entity-decoded. A repeated attribute keeps its first value.
  static Map<String, String> attributes(String startTag) {
    final result = <String, String>{};
    for (final match in _attribute.allMatches(startTag)) {
      final name = match.group(1)!.toLowerCase();
      result.putIfAbsent(name, () => decodeEntities(match.group(2) ?? match.group(3) ?? ''));
    }
    return result;
  }

  /// The URL to use for [value] found in a response, or null. Forced HTTPS
  /// (project policy): a protocol-relative `//host/x` and a plain `http://`
  /// URL are upgraded to `https`; anything that is not an absolute URL with
  /// a host, or has whitespace/control characters, is rejected.
  static String? httpsUrl(Object? value) {
    if (value is! String) return null;
    var text = value.trim();
    if (text.isEmpty || RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(text)) return null;
    if (text.startsWith('//')) text = 'https:$text';
    if (text.startsWith('http://')) text = 'https://${text.substring(7)}';
    final uri = Uri.tryParse(text);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    return text;
  }

  /// A non-empty trimmed string, or null.
  static String? nonEmpty(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// A positive int from a JSON number or a digit string, else null.
  static int? positiveInt(Object? value) {
    final number = switch (value) {
      final int v => v,
      final double v when v.isFinite => v.round(),
      final String v => int.tryParse(v.trim()),
      _ => null,
    };
    return number != null && number > 0 ? number : null;
  }

  /// `value` as a JSON object, else null.
  static Map<String, dynamic>? asMap(Object? value) => value is Map<String, dynamic> ? value : null;

  /// `value` as a JSON array, else an empty list.
  static List<dynamic> asList(Object? value) => value is List<dynamic> ? value : const [];

  /// Cuts [text] to at most [max] characters on a rune boundary.
  static String clip(String text, int max) {
    final runes = text.runes.toList();
    return runes.length <= max ? text : String.fromCharCodes(runes.take(max));
  }
}
