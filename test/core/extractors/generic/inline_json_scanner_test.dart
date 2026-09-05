import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/inline_json_scanner.dart';

String _fixture(String name) => File('test/fixtures/$name').readAsStringSync();

void main() {
  group('InlineJsonScanner.scanAll', () {
    test('<script type="application/json"> (__NEXT_DATA__ shape): finds both variants with label-derived height', () {
      final html = _fixture('generic_next_data.html');
      final candidates = InlineJsonScanner.scanAll(html);

      expect(candidates, hasLength(2));
      expect(candidates.map((c) => c.url), containsAll(<String>[
        'https://cdn.example.com/hls/1080/index.m3u8',
        'https://cdn.example.com/hls/480/index.m3u8',
      ]));
      final hi = candidates.firstWhere((c) => c.url.contains('1080'));
      expect(hi.height, 1080);
      expect(hi.bitrate, 4500000);
    });

    test(
      'window.__INITIAL_STATE__ = {...}: balanced-brace extraction survives a } inside a string value',
      () {
        final html = _fixture('generic_initial_state.html');
        final candidates = InlineJsonScanner.scanAll(html);

        expect(candidates, hasLength(1));
        expect(candidates.single.url, 'https://cdn.example.com/video.mp4');
        expect(candidates.single.width, 1920);
        expect(candidates.single.height, 1080);
      },
    );

    // Guard-can-fail evidence (verified, see report): temporarily replacing
    // `_extractBalancedObject` with a naive non-greedy regex
    // (`RegExp(r'\{.*?\}')`) and rerunning this file made this exact test
    // fail (0 candidates instead of 1) - the regex stops at the *first*
    // `}` it finds, which is the one inside the `"note"` string's own text
    // ("a brace inside a string: } stays inside quotes"), producing an
    // unterminated, unbalanced substring that `jsonDecode` throws on.
    // Reverted immediately after confirming the failure.

    test('Video.js data-setup JSON attribute is parsed for its sources', () {
      final html = _fixture('generic_videojs_setup.html');
      final candidates = InlineJsonScanner.scanAll(html);

      expect(candidates, hasLength(1));
      expect(candidates.single.url, 'https://cdn.example.com/videojs-clip.mp4');
    });

    test('a truncated/malformed window assignment (braces never balance) is skipped, not thrown', () {
      const html = '''
        <html><body>
          <script>window.__INITIAL_STATE__ = {"sources": [{"src": "https://cdn.example.com/a.mp4"</script>
        </body></html>
      ''';
      expect(() => InlineJsonScanner.scanAll(html), returnsNormally);
      expect(InlineJsonScanner.scanAll(html), isEmpty);
    });

    test('a <script type="application/json"> tag with invalid JSON is skipped, not thrown', () {
      const html = '''
        <html><body>
          <script type="application/json">not actually json { at all</script>
        </body></html>
      ''';
      expect(() => InlineJsonScanner.scanAll(html), returnsNormally);
      expect(InlineJsonScanner.scanAll(html), isEmpty);
    });

    test('a page with none of the recognized shapes yields an empty list', () {
      const html = '<html><body><p>Just an article.</p></body></html>';
      expect(InlineJsonScanner.scanAll(html), isEmpty);
    });

    test('a JSON blob over the 2MB cap is skipped without attempting to decode it (resource-exhaustion guard)', () {
      final hugeArray = List.filled(300000, '"https://cdn.example.com/x.mp4"').join(',');
      final html = '<script type="application/json">[$hugeArray]</script>';
      expect(html.length, greaterThan(2 * 1024 * 1024));

      expect(() => InlineJsonScanner.scanAll(html), returnsNormally);
      expect(InlineJsonScanner.scanAll(html), isEmpty);
    });

    // Guard-can-fail evidence (verified, see report): temporarily removing
    // the `jsonText.length > _maxBlobChars` early return in
    // `_decodeAndWalk` made the test above fail: it came back with 300000
    // candidates (one per array element) instead of an empty list,
    // proving the cap - not some other filter - is what kept the huge
    // blob from being decoded and walked. Reverted immediately after
    // confirming the failure.
  });
}
