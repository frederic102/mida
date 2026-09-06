/// Small, dependency-free XML text helpers `ManifestReferenceWalker`'s DASH
/// parsing needs (attribute reads, entity decoding, ISO-8601 duration
/// parsing) - split out purely to keep that file under this project's
/// 400-line cap. Not a general XML parser and not trying to be one.
class ManifestXmlUtils {
  const ManifestXmlUtils._();

  /// Reads one XML attribute out of an already-matched start tag.
  /// Phase 6 B-R3-4: XML permits either quote character, and attribute
  /// values are entity-encoded (an `&amp;` in a DASH URL template is a
  /// literal `&`), so both are handled here. Unquoted attribute values
  /// (invalid XML) and values containing a literal `>` stay out of scope.
  static String? attributeOf(String tag, String name) {
    final match = _attributePattern(name).firstMatch(tag);
    if (match == null) return null;
    return decodeEntities(match.group(1) ?? match.group(2) ?? '');
  }

  static final Map<String, RegExp> _attributePatterns = {};

  static RegExp _attributePattern(String name) => _attributePatterns.putIfAbsent(
        name,
        () => RegExp('\\b$name\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\')', caseSensitive: false),
      );

  static final _entityPattern = RegExp(r'&(amp|lt|gt|quot|apos|#\d+|#[xX][0-9a-fA-F]+);');

  /// The five predefined XML entities plus numeric character references.
  /// Anything else is left exactly as written rather than guessed at.
  static String decodeEntities(String value) => value.replaceAllMapped(_entityPattern, (match) {
        final body = match.group(1)!;
        switch (body) {
          case 'amp':
            return '&';
          case 'lt':
            return '<';
          case 'gt':
            return '>';
          case 'quot':
            return '"';
          case 'apos':
            return "'";
        }
        final code = body.startsWith('#x') || body.startsWith('#X')
            ? int.tryParse(body.substring(2), radix: 16)
            : int.tryParse(body.substring(1));
        return code == null ? match.group(0)! : String.fromCharCode(code);
      });

  static final _iso8601DurationPattern = RegExp(
    r'^P(?:(\d+(?:\.\d+)?)Y)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)W)?(?:(\d+(?:\.\d+)?)D)?'
    r'(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?$',
    caseSensitive: false,
  );

  /// Parses the ISO-8601 duration DASH's `mediaPresentationDuration`/
  /// `<Period duration=...>` uses (`PT1H2M3.5S`). Years and months are
  /// nominal (365 / 30 days): a media presentation of that length does not
  /// exist, and the value is only ever used as an expected-length
  /// comparison. Returns null for anything unparseable or non-positive
  /// rather than a wrong Duration, since the caller reads null as
  /// "unknown" but would treat a wrong answer as truth.
  static Duration? parseIso8601Duration(String? value) {
    if (value == null) return null;
    final match = _iso8601DurationPattern.firstMatch(value.trim());
    if (match == null) return null;
    double part(int group) => double.tryParse(match.group(group) ?? '') ?? 0;
    final seconds = part(1) * 365 * 86400 +
        part(2) * 30 * 86400 +
        part(3) * 7 * 86400 +
        part(4) * 86400 +
        part(5) * 3600 +
        part(6) * 60 +
        part(7);
    if (seconds <= 0) return null;
    return Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round());
  }
}
