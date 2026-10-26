import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/bounded_body.dart';

/// The one bounded body reader shared by `GenericExtractor`,
/// `GuardedEmbedHttp` and `FacebookPageFetcher`.
void main() {
  test('stops at the cap, reports truncation, cancels the rest of the stream', () async {
    var cancelled = false;
    final controller = StreamController<List<int>>(onCancel: () => cancelled = true);
    for (var i = 0; i < 5; i++) {
      controller.add(List<int>.filled(100, 0x61));
    }
    final body = await readBoundedBytes(controller.stream, 250);
    expect(body.bytes.length, 250);
    expect(body.truncated, isTrue);
    expect(cancelled, isTrue, reason: 'leaving early must cancel the subscription');
  });

  test('a short body is complete and not truncated; text falls back to Latin-1', () async {
    final ok = await readBoundedBytes(Stream.value(utf8.encode('héllo')), 1000);
    expect(ok.truncated, isFalse);
    expect(ok.text, 'héllo');
    final latin = await readBoundedBytes(Stream.value(latin1.encode('café')), 1000);
    expect(latin.text, 'café');
  });

  test('every caller goes through the shared reader (no private copy of the loop left)', () {
    for (final path in [
      'lib/core/extractors/generic/generic_extractor.dart',
      'lib/core/extractors/generic/embeds/embed_http.dart',
      'lib/core/extractors/facebook/facebook_page_fetcher.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('await for (final chunk in response)')), reason: path);
      expect(source, isNot(contains('bytes.addAll(chunk)')), reason: path);
      expect(source, isNot(contains('response.listen(')), reason: path);
    }
  });
}
