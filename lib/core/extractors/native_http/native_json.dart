import 'dart:convert';

import '../media_models.dart';

/// JSON decoding for API answers, with the failure mapped to the project's
/// extraction status instead of a raw `FormatException`.
class NativeJson {
  const NativeJson._();

  /// Decodes [raw] to any JSON value, or throws `PARSE_ERROR` naming
  /// [service]. Callers that need to tell `false`/`null` apart from an
  /// object (Rumble's "no such video" answer) use this directly.
  static Object? decode(String raw, String service) {
    try {
      return jsonDecode(raw);
    } on FormatException {
      throw MediaExtractionException('PARSE_ERROR', '$service returned a response MiDa could not read as JSON.');
    }
  }

  /// Decodes [raw] as one JSON object, or throws `PARSE_ERROR`.
  static Map<String, dynamic> decodeObject(String raw, String service) {
    final decoded = decode(raw, service);
    if (decoded is! Map<String, dynamic>) {
      throw MediaExtractionException('PARSE_ERROR', '$service returned JSON in a shape MiDa does not recognize.');
    }
    return decoded;
  }
}
