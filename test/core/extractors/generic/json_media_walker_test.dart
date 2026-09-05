import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/json_media_walker.dart';

void main() {
  group('JsonMediaWalker.walk', () {
    test('a source object carrying url + width + height + bitrate keeps all four', () {
      final decoded = {
        'sources': [
          {'file': 'https://cdn.example.com/hls/index.m3u8', 'width': 1280, 'height': 720, 'bitrate': 2500000},
        ],
      };
      final candidates = JsonMediaWalker.walk(decoded);

      expect(candidates, hasLength(1));
      expect(candidates.single.url, 'https://cdn.example.com/hls/index.m3u8');
      expect(candidates.single.width, 1280);
      expect(candidates.single.height, 720);
      expect(candidates.single.bitrate, 2500000);
    });

    test('a "label" like "720p" is parsed into height when no numeric height sibling exists', () {
      final decoded = {
        'file': 'https://cdn.example.com/video-720.mp4',
        'label': '720p',
      };
      final candidates = JsonMediaWalker.walk(decoded);

      expect(candidates.single.height, 720);
      expect(candidates.single.width, isNull);
    });

    test('a numeric height sibling wins over a quality label when both are present', () {
      final decoded = {
        'file': 'https://cdn.example.com/video.mp4',
        'height': 1080,
        'label': '720p',
      };
      final candidates = JsonMediaWalker.walk(decoded);

      expect(candidates.single.height, 1080);
    });

    test('nested arrays and maps (Next.js props.pageProps shape) are all walked', () {
      final decoded = {
        'props': {
          'pageProps': {
            'video': {
              'renditions': [
                {'src': 'https://cdn.example.com/low.mp4', 'height': 360},
                {'src': 'https://cdn.example.com/high.mp4', 'height': 1080},
              ],
            },
          },
        },
      };
      final candidates = JsonMediaWalker.walk(decoded);

      expect(candidates, hasLength(2));
      expect(candidates.map((c) => c.height), containsAll(<int?>[360, 1080]));
    });

    test('a bare media-shaped string with no surrounding metadata is still found without metadata', () {
      final decoded = ['https://cdn.example.com/clip.m3u8'];
      final candidates = JsonMediaWalker.walk(decoded);

      expect(candidates, hasLength(1));
      expect(candidates.single.url, 'https://cdn.example.com/clip.m3u8');
      expect(candidates.single.width, isNull);
    });

    test('non-media strings (thumbnails, ids, unrelated JSON) are never candidates', () {
      final decoded = {
        'thumbnailUrl': 'https://cdn.example.com/thumb.jpg',
        'id': 'abc123',
        'description': 'A video about mp4 files, not a url',
      };
      final candidates = JsonMediaWalker.walk(decoded);

      expect(candidates, isEmpty);
    });

    // Guard-can-fail evidence (verified, see report): temporarily making
    // `JsonMediaWalker._looksLikeMediaUrl` `return true` unconditionally
    // (simulating "the extension allowlist is disabled") and rerunning this
    // file made 3 of the 7 tests above fail: "non-media strings" went from
    // an empty list to 3 fake candidates (the .jpg thumbnail, the bare id
    // "abc123", and the description sentence), and the two quality-label
    // tests broke with "Bad state: Too many elements" because every string
    // in their JSON (including "720p" itself) became a spurious extra
    // candidate. Reverted immediately after confirming the failure.

    test('query string after the extension is ignored (still recognized)', () {
      final decoded = {'src': 'https://cdn.example.com/clip.mp4?token=abc&exp=1'};
      final candidates = JsonMediaWalker.walk(decoded);

      expect(candidates, hasLength(1));
    });

    group('contextBacked false-positive guard', () {
      test('a bare "url" key with no metadata siblings and no player-container ancestor is found but not '
          'context-backed (the ad/tracker shape: a generic id next to a URL, nothing player-shaped around it)', () {
        final decoded = {
          'creative': {'url': 'https://ads.example.com/spot.mp4', 'id': 'abc123'},
        };
        final candidates = JsonMediaWalker.walk(decoded);

        expect(candidates, hasLength(1));
        expect(candidates.single.contextBacked, isFalse);
      });

      test('the same shape but with a width/height sibling is marked context-backed', () {
        final decoded = {
          'creative': {'url': 'https://ads.example.com/spot.mp4', 'width': 640, 'height': 360},
        };
        final candidates = JsonMediaWalker.walk(decoded);

        expect(candidates.single.contextBacked, isTrue);
      });

      test('a URL nested inside a "sources" container is context-backed even with no numeric metadata', () {
        final decoded = {
          'player': {
            'sources': [
              {'file': 'https://cdn.example.com/clip.mp4'},
            ],
          },
        };
        final candidates = JsonMediaWalker.walk(decoded);

        expect(candidates.single.contextBacked, isTrue);
      });

      // Guard-can-fail evidence (verified, see report): temporarily making
      // `_visitOne` always pass `contextBacked: true` for the direct-URL
      // case (as if the false-positive guard did not exist) made the
      // first test above fail: `contextBacked` came back `true` instead of
      // `false` for the bare ad-shaped candidate. Reverted immediately
      // after confirming the failure.
    });

    group('resource-exhaustion guards', () {
      test('a 10,000-deep nested array does not stack overflow, and the buried candidate is never reached '
          '(past the depth cap)', () {
        dynamic node = 'https://cdn.example.com/deep.mp4';
        for (var i = 0; i < 10000; i++) {
          node = [node];
        }
        expect(() => JsonMediaWalker.walk(node), returnsNormally);
        expect(JsonMediaWalker.walk(node), isEmpty);
      });

      test('candidate count is capped at 200 even when the JSON contains far more matching strings', () {
        final node = [for (var i = 0; i < 1000; i++) 'https://cdn.example.com/clip$i.mp4'];
        final candidates = JsonMediaWalker.walk(node);

        expect(candidates.length, lessThanOrEqualTo(200));
      });

      // Guard-can-fail evidence (verified, see report): temporarily
      // removing the `results.length >= _maxCandidates` check from
      // `walk`'s loop condition made the test above fail: `candidates`
      // came back with all 1000 entries instead of being capped at 200.
      // Reverted immediately after confirming the failure.
    });
  });
}
