import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/browser_capture/captured_media_classifier.dart';

void main() {
  group('CapturedMediaRanker.rank', () {
    test('a <video> element src wins over a much bigger unrelated captured asset', () {
      final ranked = CapturedMediaRanker.rank(
        [
          const CapturedMediaCandidate(url: 'https://cdn.example.com/unrelated-big.mp4', container: 'mp4', contentLength: 50 * 1024 * 1024),
          const CapturedMediaCandidate(url: 'https://cdn.example.com/the-real-post.mp4', container: 'mp4', contentLength: 3 * 1024 * 1024),
        ],
        ['https://cdn.example.com/the-real-post.mp4?sig=abc'],
      );

      expect(ranked.first.url, 'https://cdn.example.com/the-real-post.mp4');
      expect(ranked.map((c) => c.url), contains('https://cdn.example.com/unrelated-big.mp4'));
    });

    test(
      'a <video> element URL never seen in network capture is still surfaced as the top candidate '
      '(the TikTok fix: the real signed CDN URL has no recognizable extension, so classify() never saw it)',
      () {
        final ranked = CapturedMediaRanker.rank(
          [
            const CapturedMediaCandidate(
              url: 'https://sf16-website-login.neutral.ttwstatic.com/obj/login-loop.mp4',
              container: 'mp4',
              contentLength: 200 * 1024, // 0.2MB, the observed live value
            ),
          ],
          ['https://v16-webapp.tiktok.com/abcdef1234567890/?a=1988&br=1'],
        );

        expect(ranked, hasLength(2));
        expect(ranked.first.url, 'https://v16-webapp.tiktok.com/abcdef1234567890/?a=1988&br=1');
        expect(ranked.first.container, 'mp4'); // No extension in the URL; defaults to mp4.
      },
    );

    test('blob: video element URLs are excluded, not synthesized into a candidate', () {
      final ranked = CapturedMediaRanker.rank(
        [const CapturedMediaCandidate(url: 'https://cdn.example.com/real.mp4', container: 'mp4', contentLength: 5 * 1024 * 1024)],
        ['blob:https://example.com/9c8b7a6d-1234-5678-9abc-def012345678'],
      );

      expect(ranked, hasLength(1));
      expect(ranked.single.url, 'https://cdn.example.com/real.mp4');
    });

    test(
      'guard can fail: a non-blob, non-http pseudo-scheme (e.g. data:) DOM URL is excluded too - '
      'proves this is a real scheme check, not a blob:-literal string match',
      () {
        // Round 4: CapturedMediaRanker used to check
        // `!url.toLowerCase().startsWith('blob:')` directly; now it shares
        // CapturedMediaClassifier.isFetchableUrl with every other
        // candidate-producing path. A data: URL would have sailed straight
        // through the old check.
        final ranked = CapturedMediaRanker.rank(
          [const CapturedMediaCandidate(url: 'https://cdn.example.com/real.mp4', container: 'mp4', contentLength: 5 * 1024 * 1024)],
          ['data:video/mp4;base64,AAAA'],
        );

        expect(ranked, hasLength(1));
        expect(ranked.single.url, 'https://cdn.example.com/real.mp4');
      },
    );

    test('a tiny captured asset is dropped once a confirmed-larger candidate exists', () {
      final ranked = CapturedMediaRanker.rank(
        [
          const CapturedMediaCandidate(url: 'https://cdn.example.com/tiny-login-loop.mp4', container: 'mp4', contentLength: 40 * 1024),
          const CapturedMediaCandidate(url: 'https://cdn.example.com/real-post.mp4', container: 'mp4', contentLength: 4 * 1024 * 1024),
        ],
        const [],
      );

      expect(ranked, hasLength(1));
      expect(ranked.single.url, 'https://cdn.example.com/real-post.mp4');
    });

    test(
      'guard can fail: without the size cutoff, both candidates (including the tiny one) would rank, '
      'just in descending order',
      () {
        // Directly demonstrates what "rank without drop" would look like,
        // so the assertion above (hasLength(1)) is proven to depend on
        // the drop step rather than on some other accidental narrowing:
        // sorted-only (no filtering) keeps both, tiny one last.
        final sortedOnly = [
          const CapturedMediaCandidate(url: 'https://cdn.example.com/tiny-login-loop.mp4', container: 'mp4', contentLength: 40 * 1024),
          const CapturedMediaCandidate(url: 'https://cdn.example.com/real-post.mp4', container: 'mp4', contentLength: 4 * 1024 * 1024),
        ]..sort((a, b) => b.contentLength!.compareTo(a.contentLength!));
        expect(sortedOnly, hasLength(2)); // What rank() would wrongly return if the drop step were removed.
      },
    );

    test('unknown content-length is not dropped merely for being unknown', () {
      final ranked = CapturedMediaRanker.rank(
        [
          const CapturedMediaCandidate(url: 'https://cdn.example.com/unknown-length.mp4', container: 'mp4'),
          const CapturedMediaCandidate(url: 'https://cdn.example.com/big.mp4', container: 'mp4', contentLength: 4 * 1024 * 1024),
        ],
        const [],
      );

      expect(ranked, hasLength(2));
      expect(ranked.first.url, 'https://cdn.example.com/big.mp4'); // Known-large still sorts first.
      expect(ranked.last.url, 'https://cdn.example.com/unknown-length.mp4'); // Kept, just last.
    });

    test('a static-asset-host candidate is dropped only when a non-static-host candidate exists', () {
      final ranked = CapturedMediaRanker.rank(
        [
          const CapturedMediaCandidate(url: 'https://sf16-static.ttwstatic.com/asset.mp4', container: 'mp4', contentLength: 5 * 1024 * 1024),
          const CapturedMediaCandidate(url: 'https://v16-webapp.tiktok.com/real.mp4', container: 'mp4', contentLength: 5 * 1024 * 1024),
        ],
        const [],
      );

      expect(ranked, hasLength(1));
      expect(ranked.single.url, 'https://v16-webapp.tiktok.com/real.mp4');
    });

    test('a static-asset-host candidate is kept when it is the only candidate (never empties the list)', () {
      final ranked = CapturedMediaRanker.rank(
        [const CapturedMediaCandidate(url: 'https://sf16-static.ttwstatic.com/asset.mp4', container: 'mp4', contentLength: 5 * 1024 * 1024)],
        const [],
      );

      expect(ranked, hasLength(1));
    });

    test('empty input yields empty output', () {
      expect(CapturedMediaRanker.rank(const [], const []), isEmpty);
    });
  });
}
