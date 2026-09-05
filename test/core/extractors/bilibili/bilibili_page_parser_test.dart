import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/bilibili/bilibili_page_parser.dart';
import 'package:mida/core/extractors/media_models.dart';

void main() {
  group('BilibiliPageParser.parse against a fixture matching __INITIAL_STATE__\'s shape', () {
    test('reads cid/title/author/thumbnail/duration', () async {
      final html = await File('test/fixtures/bilibili_initial_state.html').readAsString();
      final info = const BilibiliPageParser().parse(html, bvid: 'BV1GJ411x7h7');

      expect(info.bvid, 'BV1GJ411x7h7');
      expect(info.cid, 66279060);
      expect(info.title, 'Example Video Title');
      expect(info.author, 'ExampleUploader');
      expect(info.duration, const Duration(seconds: 245));
    });

    test('throws PARSE_ERROR when the page has no __INITIAL_STATE__ blob', () {
      expect(
        () => const BilibiliPageParser().parse('<html><body>challenge page</body></html>', bvid: 'BV1'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR')),
      );
    });

    test('throws CHALLENGE_FAILED (fall-through eligible) when videoData has no cid', () {
      // Matches the real WAF soft-block shape observed live: HTTP 200
      // with a validly-shaped but empty videoData - see the class doc
      // for why this must not be the terminal NOT_FOUND.
      expect(
        () => const BilibiliPageParser().parse(
          'window.__INITIAL_STATE__={"videoData":{"stat":{},"owner":{}}};',
          bvid: 'BV1',
        ),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'CHALLENGE_FAILED')),
      );
    });
  });
}
