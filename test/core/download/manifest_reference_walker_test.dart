import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/manifest_reference_walker.dart';

/// Covers the pure text-parsing pieces of `ManifestReferenceWalker` added
/// or tightened in phase 6 round 4: the shape check no longer accepting a
/// lookalike body (B-R4-4), two more LL-HLS/DASH URI-bearing tags
/// (B-R4-5), and DASH duration scoped to `<Period>` rather than always the
/// MPD-wide figure (B-R4-7).
void main() {
  group('B-R4-4: the shape check requires the root element itself, not a substring anywhere in the body', () {
    test('guard can fail: an HLS lookalike tag that merely starts with #EXTM3U is rejected', () {
      // Not a real playlist: `#EXTM3U` must be the exact, whole first
      // line. The old `startsWith('#EXTM3U')` check accepted this.
      expect(ManifestReferenceWalker.looksLikeManifest('#EXTM3UEXTRA\n#EXTINF:10,\nseg.ts\n'), isFalse);
      // Guard can fail (see report): reverting `looksLikeManifest` to
      // `head.startsWith('#EXTM3U')` makes this assertion fail - the
      // lookalike tag passes the shape check again.
    });

    test('a genuine HLS playlist (#EXTM3U alone on the first line) still passes', () {
      expect(ManifestReferenceWalker.looksLikeManifest('#EXTM3U\n#EXTINF:10,\nseg.ts\n'), isTrue);
    });

    test('guard can fail: an HTML error page that merely mentions "<MPD" in its body text is rejected', () {
      const htmlLookalike = '<html><head><title>Sign in</title></head>'
          '<body>Your session expired. <MPD>not a real element</MPD></body></html>';
      expect(ManifestReferenceWalker.looksLikeManifest(htmlLookalike), isFalse);
      // Guard can fail (see report): the old `RegExp('<MPD\\b').hasMatch`
      // scanned the WHOLE body for that substring, so this login-wall
      // page - which never has DASH XML as its root element - passed the
      // shape check and was handed to `_parseDash` as if it were real.
    });

    test('a genuine DASH manifest, with an XML declaration and a comment before <MPD, still passes', () {
      const dash = '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<!-- generated -->\n'
          '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011"><Period/></MPD>';
      expect(ManifestReferenceWalker.looksLikeManifest(dash), isTrue);
    });

    test('a DASH doctype declaration before <MPD is also skipped correctly', () {
      const dash = '<!DOCTYPE mpd><MPD><Period/></MPD>';
      expect(ManifestReferenceWalker.looksLikeManifest(dash), isTrue);
    });

    test('a BOM before either root element does not defeat the check', () {
      expect(ManifestReferenceWalker.looksLikeManifest('﻿#EXTM3U\n#EXTINF:10,\nseg.ts\n'), isTrue);
      expect(ManifestReferenceWalker.looksLikeManifest('﻿<?xml version="1.0"?><MPD/>'), isTrue);
    });
  });

  group('B-R4-5: LL-HLS PART/PRELOAD-HINT and DASH Initialization are walked as references', () {
    test('#EXT-X-PART URIs are collected as leaf references', () {
      final parsed = ManifestReferenceWalker.parse(
        '#EXTM3U\n'
        '#EXT-X-PART:DURATION=1.0,URI="https://cdn.example.invalid/part1.mp4"\n'
        '#EXTINF:6,\nhttps://cdn.example.invalid/seg1.ts\n',
        Uri.parse('https://cdn.example.invalid/media.m3u8'),
      );
      expect(
        parsed.references.map((r) => r.uri),
        containsAll([
          Uri.parse('https://cdn.example.invalid/part1.mp4'),
          Uri.parse('https://cdn.example.invalid/seg1.ts'),
        ]),
      );
    });

    test('#EXT-X-PRELOAD-HINT URIs are collected as leaf references', () {
      final parsed = ManifestReferenceWalker.parse(
        '#EXTM3U\n'
        '#EXT-X-PRELOAD-HINT:TYPE=PART,URI="https://cdn.example.invalid/part2.mp4"\n'
        '#EXTINF:6,\nhttps://cdn.example.invalid/seg1.ts\n',
        Uri.parse('https://cdn.example.invalid/media.m3u8'),
      );
      expect(parsed.references.map((r) => r.uri), contains(Uri.parse('https://cdn.example.invalid/part2.mp4')));
    });

    test('guard can fail: a standalone DASH <Initialization sourceURL> is collected and forces fMP4 framing', () {
      final parsed = ManifestReferenceWalker.parse(
        '<?xml version="1.0"?><MPD><Period><AdaptationSet><Representation>'
        '<SegmentBase><Initialization sourceURL="init.mp4"/></SegmentBase>'
        '</Representation></AdaptationSet></Period></MPD>',
        Uri.parse('https://cdn.example.invalid/manifest.mpd'),
      );
      expect(parsed.references.map((r) => r.uri), contains(Uri.parse('https://cdn.example.invalid/init.mp4')));
      expect(parsed.framing, SegmentFraming.fragmentedMp4);
      // Guard can fail (see report): dropping the `<Initialization>` loop
      // from `_parseDash` makes this init segment invisible to the
      // scanner - a host-check bypass, since nothing would ever verify
      // where it points - and drops the framing signal.
    });
  });

  group('B-R4-5b: a DASH <Location> relocation is host-checked as a leaf, never walked', () {
    test('guard can fail: <Location> (with an &amp; entity) is collected as a leaf reference', () {
      final parsed = ManifestReferenceWalker.parse(
        '<?xml version="1.0"?><MPD><Location>https://relocated.example.invalid/live.mpd?a=1&amp;b=2</Location>'
        '<Period><AdaptationSet><Representation><BaseURL>seg/</BaseURL></Representation>'
        '</AdaptationSet></Period></MPD>',
        Uri.parse('https://cdn.example.invalid/manifest.mpd'),
      );
      expect(
        parsed.references.map((r) => r.uri),
        contains(Uri.parse('https://relocated.example.invalid/live.mpd?a=1&b=2')),
        reason: 'guard can fail (Bulwark round 4 #1): drop the <Location> branch from _parseDash and the '
            'relocated manifest ffmpeg would follow is never host-checked at all',
      );
      final relocation = parsed.references
          .firstWhere((r) => r.uri == Uri.parse('https://relocated.example.invalid/live.mpd?a=1&b=2'));
      expect(relocation.kind, ManifestReferenceKind.leaf,
          reason: 'a relocation is the same MPD elsewhere: walking it as a playlist would let a <Location> '
              'loop drive the scanner in circles, so it is host-checked as a leaf');
    });
  });

  group('B-R4-7: DASH declared duration is scoped to what a Period actually declares', () {
    test('guard can fail: two periods that each declare a duration are summed rather than only the MPD-wide '
        'figure being trusted', () {
      final parsed = ManifestReferenceWalker.parse(
        '<?xml version="1.0"?><MPD mediaPresentationDuration="PT999S">'
        '<Period duration="PT30S"/><Period duration="PT45S"/>'
        '</MPD>',
        Uri.parse('https://cdn.example.invalid/manifest.mpd'),
      );
      expect(parsed.declaredDuration, const Duration(seconds: 75));
      // Guard can fail (see report): always returning the MPD-level
      // `mediaPresentationDuration` (PT999S here) instead of summing the
      // Periods' own durations makes this assertion fail.
    });

    test('a period missing its own duration falls back to the MPD-wide mediaPresentationDuration', () {
      final parsed = ManifestReferenceWalker.parse(
        '<?xml version="1.0"?><MPD mediaPresentationDuration="PT120S">'
        '<Period duration="PT30S"/><Period/>'
        '</MPD>',
        Uri.parse('https://cdn.example.invalid/manifest.mpd'),
      );
      expect(parsed.declaredDuration, const Duration(seconds: 120));
    });

    test('no Period elements at all falls back to the MPD-wide duration', () {
      final parsed = ManifestReferenceWalker.parse(
        '<?xml version="1.0"?><MPD mediaPresentationDuration="PT10S"></MPD>',
        Uri.parse('https://cdn.example.invalid/manifest.mpd'),
      );
      expect(parsed.declaredDuration, const Duration(seconds: 10));
    });
  });
}
