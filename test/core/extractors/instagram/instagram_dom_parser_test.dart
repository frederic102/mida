import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/instagram/instagram_dom_parser.dart';
import 'package:mida/core/extractors/media_models.dart';

void main() {
  const parser = InstagramDomParser();

  group('InstagramDomParser against a live DOM excerpt', () {
    // Captured 2026-09-05 via `--dump-dom` against
    // https://www.instagram.com/reel/Chunk8-jurw/ (see the fixture file's
    // own header comment and `docs/plan-phase2-extractors.md`).
    final html = File('test/fixtures/instagram_dom_excerpt.html').readAsStringSync();
    final sourceUrl = Uri.parse('https://www.instagram.com/reel/Chunk8-jurw/');

    test('title is "@author - first 60 chars of caption", not the raw caption', () {
      final info = parser.parse(html, sourceUrl: sourceUrl);
      expect(info.title, startsWith('@instagram - '));
      expect(info.title, contains('Gingerton'));
      // The real caption runs past 150 chars including embedded mentions
      // and emoji; a raw-caption title (the bug this replaced) would fail
      // this length check.
      expect(info.title.length, lessThanOrEqualTo('@instagram - '.length + 60));
      expect(info.author, 'instagram');
      expect(info.id, 'Chunk8-jurw');
    });

    test('decodes the JSON \\/ escapes inside the mp4 urls (no literal backslashes left)', () {
      final info = parser.parse(html, sourceUrl: sourceUrl);
      expect(info.formats, isNotEmpty);
      for (final format in info.formats) {
        expect(format.url, isNot(contains(r'\/')));
        expect(format.url, startsWith('https://'));
        expect(format.container, 'mp4');
      }
    });

    test('every format is video-only: this real post has no audio anywhere (has_audio: false)', () {
      // Verified live (byte-level `ffprobe`, both against a `video_versions`
      // URL and a DASH `Representation` BaseURL for this exact post): this
      // specific reel genuinely has no audio track at all
      // (`if_not_gated_logged_out.has_audio == false` in the raw capture).
      // So unlike the earlier assumption ("video_versions/DASH always has
      // an audio-only companion"), the honest assertion for *this* fixture
      // is zero audio-only formats - the audio-only DASH branch itself is
      // covered separately below with a synthetic manifest that actually
      // has one, since this real capture cannot exercise it.
      final info = parser.parse(html, sourceUrl: sourceUrl);
      expect(info.formats, isNotEmpty);
      expect(info.formats.every((f) => f.isVideoOnly), isTrue);
      expect(info.formats.any((f) => f.isAudioOnly), isFalse);
    });

    test('the best (highest-bandwidth) video-only format is the DASH manifest\'s 720x1280 rendition', () {
      final info = parser.parse(html, sourceUrl: sourceUrl);
      final best = info.formats.reduce((a, b) => a.bitrate > b.bitrate ? a : b);
      expect(best.bitrate, 3140618);
      expect(best.width, 720);
      expect(best.height, 1280);
      expect(best.videoCodec, 'avc1.64001F');
    });

    test('video_versions entries are included as extra video-only candidates, not muxed', () {
      final info = parser.parse(html, sourceUrl: sourceUrl);
      // 6 DASH Representations + 3 video_versions entries.
      expect(info.formats.length, 9);
      expect(info.formats.every((f) => f.hasVideo && !f.hasAudio), isTrue);
    });

    test('parses the thumbnail from image_versions2.candidates[0].url', () {
      final info = parser.parse(html, sourceUrl: sourceUrl);
      expect(info.thumbnailUrl, isNotNull);
      expect(info.thumbnailUrl, startsWith('https://'));
    });

    test('falls back to the DASH manifest duration when video_duration is absent', () {
      final info = parser.parse(html, sourceUrl: sourceUrl);
      // The real capture has no top-level `video_duration` field; the
      // manifest's `mediaPresentationDuration="PT0H0M4.967S"` is the only
      // source, so this also proves the fallback path actually ran (not
      // just that duration happens to be non-null for some other reason).
      expect(info.duration, const Duration(milliseconds: 4967));
    });

    test('does not pick up an unrelated recommended post with a different code', () {
      // The same DOM embeds several other reels (Instagram's "up next"
      // rail) with their own `code`/`caption`/`video_versions`. Regression
      // guard: none of those captions should leak into this result.
      final info = parser.parse(html, sourceUrl: sourceUrl);
      expect(info.title, isNot(contains("that’s his spa now")));
    });
  });

  group('InstagramDomParser edge cases (synthetic)', () {
    final sourceUrl = Uri.parse('https://www.instagram.com/p/ImageOnly123/');

    test('an image-only post (no video_versions anywhere) surfaces as UNSUPPORTED_MEDIA', () {
      final html = '<script type="application/json">${jsonEncode({
        'code': 'ImageOnly123',
        'caption': {'text': 'just a photo'},
        'user': {'username': 'photographer'},
        'image_versions2': {
          'candidates': [
            {'url': 'https://example.com/photo.jpg'},
          ],
        },
      })}</script>';
      expect(
        () => parser.parse(html, sourceUrl: sourceUrl),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_MEDIA')),
      );
    });

    test('a page with no matching JSON at all surfaces as PARSE_ERROR', () {
      expect(
        () => parser.parse('<html><body>blocked / login wall</body></html>', sourceUrl: sourceUrl),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR')),
      );
    });

    test('a carousel exposes only the first video it finds', () {
      final html = '<script type="application/json">${jsonEncode({
        'code': 'ImageOnly123',
        'caption': {'text': 'carousel post'},
        'user': {'username': 'carouseluser'},
        'carousel_media': [
          {
            'image_versions2': {
              'candidates': [
                {'url': 'https://example.com/slide1.jpg'},
              ],
            },
          },
          {
            'video_versions': [
              {'type': 101, 'url': 'https://example.com/slide2.mp4'},
            ],
          },
          {
            'video_versions': [
              {'type': 101, 'url': 'https://example.com/slide3.mp4'},
            ],
          },
        ],
      })}</script>';
      final info = parser.parse(html, sourceUrl: sourceUrl);
      expect(info.formats.single.url, 'https://example.com/slide2.mp4');
    });

    test('a manifest with a separate audio/mp4 AdaptationSet produces an audio-only format', () {
      // Synthetic (this real fixture's own post has no audio anywhere, see
      // the live group above) but modeled on the real manifest's exact
      // attribute shape, just with an added audio AdaptationSet - proves
      // the `mimeType="audio/mp4"` branch of `_parseDashManifest` actually
      // works when the source does have one.
      const manifest = '<MPD><Period>'
          '<AdaptationSet mimeType="video/mp4"><Representation id="v1" mimeType="video/mp4" '
          'codecs="avc1.64001F" width="720" height="1280" bandwidth="3140618">'
          '<BaseURL>https://example.com/video.mp4?a=1&amp;b=2</BaseURL></Representation></AdaptationSet>'
          '<AdaptationSet mimeType="audio/mp4"><Representation id="a1" codecs="mp4a.40.2" bandwidth="128000">'
          '<BaseURL>https://example.com/audio.mp4?a=1&amp;b=2</BaseURL></Representation></AdaptationSet>'
          '</Period></MPD>';
      final html = '<script type="application/json">${jsonEncode({
        'code': 'ImageOnly123',
        'caption': {'text': 'has real audio'},
        'user': {'username': 'someone'},
        'video_dash_manifest': manifest,
      })}</script>';

      final info = parser.parse(html, sourceUrl: sourceUrl);
      final audioOnly = info.formats.where((f) => f.isAudioOnly).toList();
      final videoOnly = info.formats.where((f) => f.isVideoOnly).toList();
      expect(audioOnly, hasLength(1));
      expect(audioOnly.single.url, 'https://example.com/audio.mp4?a=1&b=2', reason: '&amp; must decode to &');
      expect(audioOnly.single.audioCodec, 'mp4a.40.2');
      expect(videoOnly, hasLength(1));
      expect(videoOnly.single.width, 720);
      expect(videoOnly.single.height, 1280);
    });
  });

  group('InstagramDomParser.buildSocialTitle', () {
    test('truncates a long caption to 60 chars and prefixes the author', () {
      final title = InstagramDomParser.buildSocialTitle(
        author: 'someuser',
        caption: 'a' * 200,
        postId: '1',
      );
      expect(title, '@someuser - ${'a' * 60}');
    });

    test('falls back to the post id when the caption is empty', () {
      final title = InstagramDomParser.buildSocialTitle(author: 'someuser', caption: '', postId: 'Abc123');
      expect(title, '@someuser - Abc123');
    });

    test('strips URLs and line breaks before truncating', () {
      final title = InstagramDomParser.buildSocialTitle(
        author: 'someuser',
        caption: 'check this out\nhttps://example.com/very/long/link?x=1\nso cool',
        postId: '1',
      );
      expect(title, '@someuser - check this out so cool');
    });
  });
}
