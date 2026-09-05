import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/html_media_sniffer.dart';

String _fixture(String name) => File('test/fixtures/$name').readAsStringSync();

void main() {
  group('HtmlMediaSniffer.sniff', () {
    test('video src: resolves a relative src against the page URL', () {
      final html = _fixture('generic_video_src_relative.html');
      final result = HtmlMediaSniffer.sniff(html, Uri.parse('https://example.com/posts/1'));

      expect(result.mediaUrls, hasLength(1));
      expect(result.mediaUrls.single.url, 'https://example.com/media/clip.mp4');
      expect(result.mediaUrls.single.container, 'mp4');
      expect(result.title, 'Relative Video Demo');
    });

    test(
      'og:video: reads secure_url/twitter:player:stream, og:title, og:image, and '
      'width/height from og:video:width/height (regression: streamable.com and archive.org '
      'both carry exactly this tag pair and previously came back with height null)',
      () {
        final html = _fixture('generic_og_video.html');
        final result = HtmlMediaSniffer.sniff(html, Uri.parse('https://example.com/post/2'));

        expect(result.mediaUrls.map((m) => m.url), contains('https://cdn.example.com/videos/post-720.mp4'));
        // og:video:secure_url and twitter:player:stream point at the same
        // file here; dedup must collapse them to one candidate.
        expect(result.mediaUrls, hasLength(1));
        expect(result.mediaUrls.single.width, 1280);
        expect(result.mediaUrls.single.height, 720);
        expect(result.title, 'A Public Post');
        expect(result.thumbnailUrl, 'https://cdn.example.com/thumb.jpg');
      },
    );

    test('JSON-LD array: finds VideoObject.contentUrl nested in a top-level array, ignores embedUrl', () {
      final html = _fixture('generic_jsonld_array.html');
      final result = HtmlMediaSniffer.sniff(html, Uri.parse('https://example.com/post/3'));

      expect(result.mediaUrls, hasLength(1));
      expect(result.mediaUrls.single.url, 'https://cdn.example.com/videos/array-item.mp4');
      expect(result.mediaUrls.any((m) => m.url.contains('embed')), isFalse);
    });

    test('inline script: recovers a JSON-escaped m3u8 URL with query string', () {
      final html = _fixture('generic_script_escaped_m3u8.html');
      final result = HtmlMediaSniffer.sniff(html, Uri.parse('https://example.com/watch/4'));

      expect(result.mediaUrls, hasLength(1));
      expect(result.mediaUrls.single.url, 'https://cdn.example.com/hls/index.m3u8?token=abc&exp=1');
      expect(result.mediaUrls.single.container, 'm3u8');
    });

    test('no media: an ordinary article page yields no candidates', () {
      final html = _fixture('generic_no_media.html');
      final result = HtmlMediaSniffer.sniff(html, Uri.parse('https://example.com/article/5'));

      expect(result.isEmpty, isTrue);
      expect(result.title, 'Just An Article');
    });

    test('DRM fixture: sniffer itself still returns no candidates (DRM decision is the caller\'s job)', () {
      final html = _fixture('generic_drm.html');
      final result = HtmlMediaSniffer.sniff(html, Uri.parse('https://example.com/movie/6'));

      expect(result.isEmpty, isTrue);
    });

    test(
      'DRM URL filter: a DRM-marked URL (/drm/, cbcs) next to a clear one keeps only the clear one '
      '(regression for a live ffmpeg failure: "Invalid data found when processing input" against a '
      "Vimeo /playlist/drm/cbcs,... master that a naive sniff would have kept)",
      () {
        final html = _fixture('generic_drm_and_clear_side_by_side.html');
        final result = HtmlMediaSniffer.sniff(html, Uri.parse('https://vimeo.com/76979871'));

        expect(result.mediaUrls, hasLength(1));
        expect(result.mediaUrls.single.url, endsWith('clear.m3u8'));
        expect(result.anyDrmCandidatesDropped, isTrue);
      },
    );

    test('DRM URL filter: when every candidate is DRM-marked, mediaUrls is empty but anyDrmCandidatesDropped is true',
        () {
      final html = _fixture('generic_all_drm.html');
      final result = HtmlMediaSniffer.sniff(html, Uri.parse('https://vimeo.com/76979871'));

      expect(result.mediaUrls, isEmpty);
      expect(result.anyDrmCandidatesDropped, isTrue);
    });

    // Guard-can-fail evidence (see report): temporarily making
    // `HtmlMediaSniffer._looksLikeDrmUrl` always return `false` (i.e. the
    // DRM filter is disabled) made both tests above fail: the first one
    // now finds 2 mediaUrls instead of 1 (the DRM one leaks through), and
    // the second finds 2 mediaUrls with `anyDrmCandidatesDropped == false`
    // instead of an empty list with the flag true.

    test(
      'Instagram-style \\uXXXX escape: the extracted URL is fully decoded, not truncated at the escape '
      '(regression for a live 403: a truncated signed query string still parses as a URL but the CDN '
      'rejects it)',
      () {
        final html = _fixture('generic_instagram_escaped_url.html');
        final result = HtmlMediaSniffer.sniff(html, Uri.parse('https://www.instagram.com/reel/example/'));

        expect(result.mediaUrls, hasLength(1));
        expect(
          result.mediaUrls.single.url,
          'https://scontent-lax3-1.cdninstagram.com/v/t50.2886-16/12345_video.mp4'
          '?_nc_ht=scontent-lax3-1.cdninstagram.com&_nc_cat=100&vs=abcdef&oh=signature123&oe=deadbeef',
        );
      },
    );

    test('dedupe: the same URL reached via a \\uXXXX escape and via a plain <video src> collapses to one candidate',
        () {
      const html = '''
        <html><body>
          <video src="https://cdn.example.com/clip.mp4?a=1&b=2"></video>
          <script>
            var again = "https:\\/\\/cdn.example.com\\/clip.mp4?a=1\\u0026b=2";
          </script>
        </body></html>
      ''';
      final result = HtmlMediaSniffer.sniff(html, Uri.parse('https://example.com/post/7'));

      expect(result.mediaUrls, hasLength(1));
      expect(result.mediaUrls.single.url, 'https://cdn.example.com/clip.mp4?a=1&b=2');
    });

    test(
      'data-* attributes: data-video-src and data-hls are found; data-src on an image (.jpg) is rejected '
      'by the same extension gate as every other source',
      () {
        final html = _fixture('generic_data_attrs.html');
        final result = HtmlMediaSniffer.sniff(html, Uri.parse('https://example.com/post/8'));

        expect(result.mediaUrls.map((m) => m.url), containsAll(<String>[
          'https://example.com/media/data-video.mp4',
          'https://cdn.example.com/data-attr/index.m3u8',
        ]));
        expect(result.mediaUrls, hasLength(2));
        expect(result.mediaUrls.any((m) => m.url.contains('thumb.jpg')), isFalse);
      },
    );

    test('inline __NEXT_DATA__ JSON: both variants are found with height/bitrate populated from the JSON', () {
      final html = _fixture('generic_next_data.html');
      final result = HtmlMediaSniffer.sniff(html, Uri.parse('https://example.com/post/9'));

      expect(result.mediaUrls, hasLength(2));
      final hi = result.mediaUrls.firstWhere((m) => m.url.contains('1080'));
      expect(hi.height, 1080);
      expect(hi.bitrate, 4500000);
      expect(hi.container, 'm3u8');
    });

    test(
      'metadata upgrade-in-place: a URL found first via a plain <video src> (no metadata) is later enriched '
      'with width/height/bitrate when an inline-JSON blob describes the same URL',
      () {
        const html = '''
          <html><head><title>Enriched</title></head>
          <body>
            <video src="https://cdn.example.com/clip.mp4"></video>
            <script type="application/json">{"src": "https://cdn.example.com/clip.mp4", "width": 1280, "height": 720, "bitrate": 900000}</script>
          </body></html>
        ''';
        final result = HtmlMediaSniffer.sniff(html, Uri.parse('https://example.com/post/10'));

        expect(result.mediaUrls, hasLength(1));
        expect(result.mediaUrls.single.url, 'https://cdn.example.com/clip.mp4');
        expect(result.mediaUrls.single.width, 1280);
        expect(result.mediaUrls.single.height, 720);
        expect(result.mediaUrls.single.bitrate, 900000);
      },
    );

    // Guard-can-fail evidence (verified, see report): temporarily making
    // `addCandidate`'s already-seen branch return immediately (skipping the
    // "upgrade in place" merge, i.e. `if (!seenUrls.add(...)) return;` with
    // no metadata fill-in at all - the pre-Lane-B behavior) made the test
    // above fail: `result.mediaUrls.single.height` came back `null` instead
    // of `720`, because the <video src> match (with no metadata) claimed
    // the URL first and the later JSON candidate's metadata was discarded
    // instead of merged. Reverted immediately after confirming the failure.

    group('contextBacked false-positive guard', () {
      test('a <video src> match is context-backed', () {
        final html = _fixture('generic_video_src_relative.html');
        final result = HtmlMediaSniffer.sniff(html, Uri.parse('https://example.com/posts/1'));

        expect(result.mediaUrls.single.contextBacked, isTrue);
      });

      test('og:video meta candidates are context-backed', () {
        final html = _fixture('generic_og_video.html');
        final result = HtmlMediaSniffer.sniff(html, Uri.parse('https://example.com/post/2'));

        expect(result.mediaUrls.single.contextBacked, isTrue);
      });

      test(
        'a bare .mp4 URL found only via the raw-text catch-all (no video/source/og/JSON-LD/player-shaped-JSON '
        'around it - the ad-creative/tracker-beacon shape) is NOT context-backed',
        () {
          const html = '''
            <html><body>
              <script>var trackerBeacon = "https://ads.example.com/creative.mp4";</script>
            </body></html>
          ''';
          final result = HtmlMediaSniffer.sniff(html, Uri.parse('https://example.com/tracked'));

          expect(result.mediaUrls, hasLength(1));
          expect(result.mediaUrls.single.contextBacked, isFalse);
        },
      );

      // Guard-can-fail evidence (verified, see report): temporarily making
      // the raw-text catch-all's `addCandidate` call pass
      // `contextBacked: true` (as if this source were trusted like every
      // other one) made the test above fail: `contextBacked` came back
      // `true` instead of `false` for the ad/tracker URL. Reverted
      // immediately after confirming the failure.

      test('the candidate count is capped at 200 distinct URLs per sniff pass (resource-exhaustion guard)', () {
        final buffer = StringBuffer('<html><body>');
        for (var i = 0; i < 500; i++) {
          buffer.write('<script>var u$i = "https://cdn.example.com/clip$i.mp4";</script>');
        }
        buffer.write('</body></html>');

        final result = HtmlMediaSniffer.sniff(buffer.toString(), Uri.parse('https://example.com/many'));

        expect(result.mediaUrls.length, lessThanOrEqualTo(200));
      });

      // Guard-can-fail evidence (verified, see report): temporarily
      // removing the `candidatesByUrl.length >= _maxCandidates` check from
      // `addCandidate` made the test above fail: `mediaUrls` came back
      // with all 500 entries instead of being capped at 200. Reverted
      // immediately after confirming the failure.
    });

    group('guard: extension allowlist rejects non-media URLs', () {
      test('tracker/analytics/ad/embed URLs without a recognized extension are never candidates', () {
        final html = _fixture('generic_tracker_urls.html');
        final result = HtmlMediaSniffer.sniff(html, Uri.parse('https://example.com/tracked'));

        // The fixture has an og:video meta tag (a detector this sniffer
        // does look at) pointing to a no-extension tracker/embed URL, plus
        // "theme", "scheme", "extreme" text near an EME false-positive
        // trap, and a real m3u8 URL. Only the m3u8 URL should survive:
        // this is the specific bug an over-broad allowlist (or a denylist
        // approach) would let through.
        expect(result.mediaUrls, hasLength(1));
        expect(result.mediaUrls.single.url, 'https://cdn.example.com/hls/index.m3u8');
        for (final media in result.mediaUrls) {
          expect(media.url, isNot(contains('tracker.example.com')));
          expect(media.url, isNot(contains('google-analytics.com')));
        }
      });

      // Guard-can-fail evidence (see report): temporarily making
      // `HtmlMediaSniffer._classify` skip the
      // `MediaUrlProbe.containerFromExtension` gate (defaulting an
      // unrecognized extension to 'mp4' instead of returning null) made
      // this test fail (`result.mediaUrls` grew to 2, including
      // `https://tracker.example.com/embed/player` from the og:video meta
      // tag), proving the extension gate above is load-bearing rather
      // than decorative.
    });
  });
}
