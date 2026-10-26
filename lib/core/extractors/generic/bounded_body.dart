import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// At most `maxBytes` of one response body, and whether the cap cut it
/// short (true as soon as the cap is reached, even if the body happened to
/// end exactly there).
class BoundedBody {
  final Uint8List bytes;
  final bool truncated;

  const BoundedBody(this.bytes, {required this.truncated});

  /// UTF-8, falling back to Latin-1 for a body that is not valid UTF-8.
  String get text {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }
}

/// The single bounded body reader of the generic extractor family (page
/// GET, embed GET/POST, manifests, Facebook pages). Reads at most
/// [maxBytes] and stops there: leaving the `await for` early cancels the
/// subscription, which for an `HttpClientResponse` abandons the rest of the
/// body instead of downloading it. Time is the caller's to bound (see
/// `runBounded` in `stage_deadline.dart`): this only bounds bytes.
Future<BoundedBody> readBoundedBytes(Stream<List<int>> body, int maxBytes) async {
  final builder = BytesBuilder();
  var truncated = false;
  await for (final chunk in body) {
    final room = maxBytes - builder.length;
    if (chunk.length >= room) {
      builder.add(chunk.length == room ? chunk : chunk.sublist(0, room < 0 ? 0 : room));
      truncated = true;
      break;
    }
    builder.add(chunk);
  }
  return BoundedBody(builder.takeBytes(), truncated: truncated);
}

/// [readBoundedBytes], decoded with [BoundedBody.text].
Future<String> readBoundedBody(Stream<List<int>> body, int maxBytes) async =>
    (await readBoundedBytes(body, maxBytes)).text;

/// Drops [response]'s body without reading or waiting for it: cancelling
/// the subscription closes the connection's remaining body (an error or
/// throttle page that never finishes can therefore not hold the caller).
/// The cancel itself is bounded too, and the caller still force-closes its
/// client afterwards.
Future<void> discardBody(HttpClientResponse response) async {
  final subscription = response.listen(null, onError: (Object _) {}, cancelOnError: true);
  await subscription.cancel().timeout(const Duration(seconds: 1), onTimeout: () {});
}
