import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';

/// A non-empty format list stand-in used throughout this file: a
/// `MediaInfo` with `formats: []` is *not* success (see the
/// `formats.isEmpty` group below), so every fake extractor here that is
/// meant to represent a real success must include this (or its own
/// formats) rather than relying on the `MediaInfo` constructor's default.
const _fakeFormat = MediaFormat(
  id: 'f',
  url: 'https://example.invalid/video.mp4',
  container: 'mp4',
  hasVideo: true,
  hasAudio: true,
);

class _FakeExtractor implements MediaExtractor {
  final String label;
  final bool Function(Uri) canHandleFn;
  final Future<MediaInfo> Function(Uri url)? extractFn;
  const _FakeExtractor(this.label, this.canHandleFn, {this.extractFn});

  @override
  bool canHandle(Uri url) => canHandleFn(url);

  @override
  Future<MediaInfo> extract(Uri url) {
    if (extractFn != null) return extractFn!(url);
    return Future.value(MediaInfo(id: label, title: 'fake', sourceUrl: url, formats: const [_fakeFormat]));
  }
}

void main() {
  group('ExtractorRegistry', () {
    test('returns the first extractor whose canHandle matches', () {
      final registry = ExtractorRegistry([
        _FakeExtractor('a', (u) => u.host == 'a.example'),
        _FakeExtractor('b', (u) => u.host == 'b.example'),
      ]);

      final found = registry.find(Uri.parse('https://b.example/video'));
      expect(found, isNotNull);
    });

    test('returns null when no extractor handles the URL', () {
      final registry = ExtractorRegistry([
        _FakeExtractor('a', (u) => u.host == 'a.example'),
      ]);

      final found = registry.find(Uri.parse('https://unhandled.example/video'));
      expect(found, isNull);
    });

    test('when two extractors both match the same URL, the first registered wins', () {
      final registry = ExtractorRegistry([
        _FakeExtractor('first', (u) => true),
        _FakeExtractor('second', (u) => true),
      ]);

      final found = registry.find(Uri.parse('https://either.example/video'));
      expect(found, isNotNull);
      expect((found as _FakeExtractor).label, 'first');
    });
  });

  group('ExtractorRegistry.resolveInfo protocol normalization', () {
    test('an m3u8 format is stamped protocol hls', () async {
      final registry = ExtractorRegistry([
        _FakeExtractor(
          'a',
          (u) => true,
          extractFn: (url) async => MediaInfo(
            id: 'a',
            title: 'fake',
            sourceUrl: url,
            formats: const [
              MediaFormat(id: 'f1', url: 'https://example.invalid/master.m3u8', container: 'm3u8', hasVideo: true, hasAudio: true),
            ],
          ),
        ),
      ]);

      final info = await registry.resolveInfo(Uri.parse('https://a.example/video'));
      expect(info.formats.single.protocol, 'hls');
    });

    test('an mpd format is stamped protocol dash', () async {
      final registry = ExtractorRegistry([
        _FakeExtractor(
          'a',
          (u) => true,
          extractFn: (url) async => MediaInfo(
            id: 'a',
            title: 'fake',
            sourceUrl: url,
            formats: const [
              MediaFormat(id: 'f1', url: 'https://example.invalid/manifest.mpd', container: 'mpd', hasVideo: true, hasAudio: true),
            ],
          ),
        ),
      ]);

      final info = await registry.resolveInfo(Uri.parse('https://a.example/video'));
      expect(info.formats.single.protocol, 'dash');
    });

    test('an mp4 format keeps the default https protocol', () async {
      final registry = ExtractorRegistry([
        _FakeExtractor(
          'a',
          (u) => true,
          extractFn: (url) async => MediaInfo(
            id: 'a',
            title: 'fake',
            sourceUrl: url,
            formats: const [
              MediaFormat(id: 'f1', url: 'https://example.invalid/video.mp4', container: 'mp4', hasVideo: true, hasAudio: true),
            ],
          ),
        ),
      ]);

      final info = await registry.resolveInfo(Uri.parse('https://a.example/video'));
      expect(info.formats.single.protocol, 'https');
    });
  });

  group('ExtractorRegistry.resolveInfo fallback chain (Phase 2d wiring)', () {
    test('NO_MEDIA_FOUND from the primary extractor is retried against fallbacks in order', () async {
      final calls = <String>[];
      final registry = ExtractorRegistry(
        [
          _FakeExtractor('primary', (u) => true, extractFn: (url) async {
            calls.add('primary');
            throw const MediaExtractionException('NO_MEDIA_FOUND', 'nothing here');
          }),
        ],
        fallbacks: [
          _FakeExtractor('fallback1', (u) => true, extractFn: (url) async {
            calls.add('fallback1');
            throw const MediaExtractionException('NO_MEDIA_FOUND', 'nothing here either');
          }),
          _FakeExtractor('fallback2', (u) => true, extractFn: (url) async {
            calls.add('fallback2');
            return MediaInfo(id: 'fallback2', title: 'found it', sourceUrl: url, formats: const [_fakeFormat]);
          }),
        ],
      );

      final info = await registry.resolveInfo(Uri.parse('https://a.example/video'));
      expect(info.id, 'fallback2');
      expect(calls, ['primary', 'fallback1', 'fallback2']);
    });

    test('a non-NO_MEDIA_FOUND failure is not retried against fallbacks', () async {
      final fallbackCalled = <String>[];
      final registry = ExtractorRegistry(
        [
          _FakeExtractor('primary', (u) => true, extractFn: (url) async {
            throw const MediaExtractionException('DRM_PROTECTED', 'drm');
          }),
        ],
        fallbacks: [
          _FakeExtractor('fallback', (u) => true, extractFn: (url) async {
            fallbackCalled.add('fallback');
            return MediaInfo(id: 'fallback', title: 'found it', sourceUrl: url, formats: const [_fakeFormat]);
          }),
        ],
      );

      await expectLater(
        registry.resolveInfo(Uri.parse('https://a.example/video')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'DRM_PROTECTED')),
      );
      expect(fallbackCalled, isEmpty);
    });

    test('when every fallback also fails, the FIRST status code is kept and both reasons are folded in', () async {
      final registry = ExtractorRegistry(
        [
          _FakeExtractor('primary', (u) => true, extractFn: (url) async {
            throw const MediaExtractionException('NO_MEDIA_FOUND', 'primary reason');
          }),
        ],
        fallbacks: [
          _FakeExtractor('fallback', (u) => true, extractFn: (url) async {
            throw const MediaExtractionException('NO_MEDIA_FOUND', 'fallback reason too');
          }),
        ],
      );

      await expectLater(
        registry.resolveInfo(Uri.parse('https://a.example/video')),
        throwsA(isA<MediaExtractionException>()
            .having((e) => e.status, 'status', 'NO_MEDIA_FOUND')
            .having((e) => e.reason, 'reason', allOf(contains('primary reason'), contains('fallback reason too')))),
      );
    });

    test('no matching extractor at all throws UNSUPPORTED_URL', () async {
      const registry = ExtractorRegistry([]);
      await expectLater(
        registry.resolveInfo(Uri.parse('https://a.example/video')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL')),
      );
    });
  });

  group('ExtractorRegistry.resolveInfo platform-extractor fall-through matrix (TikTok/Instagram/X wiring)', () {
    const fallThroughStatuses = ['CHALLENGE_FAILED', 'RATE_LIMITED', 'PARSE_ERROR', 'NETWORK'];
    const terminalStatuses = ['PRIVATE', 'NOT_FOUND', 'UNSUPPORTED_MEDIA', 'LOGIN_REQUIRED'];

    /// [platform] (matches only `platform.example`) is registered ahead of
    /// [catchAll] (matches every URL, standing in for `GenericExtractor`),
    /// with one fallback (standing in for `BrowserCaptureExtractor`).
    /// [calls] records the order extractors actually ran in.
    ExtractorRegistry buildRegistry(List<String> calls, {required String platformStatus}) {
      return ExtractorRegistry(
        [
          _FakeExtractor('platform', (u) => u.host == 'platform.example', extractFn: (url) async {
            calls.add('platform');
            throw MediaExtractionException(platformStatus, 'platform failure: $platformStatus');
          }),
          _FakeExtractor('catchAll', (u) => true, extractFn: (url) async {
            calls.add('catchAll');
            return MediaInfo(id: 'catchAll', title: 'found by catchAll', sourceUrl: url, formats: const [_fakeFormat]);
          }),
        ],
        fallbacks: [
          _FakeExtractor('browser', (u) => true, extractFn: (url) async {
            calls.add('browser');
            return MediaInfo(id: 'browser', title: 'found by browser', sourceUrl: url, formats: const [_fakeFormat]);
          }),
        ],
      );
    }

    for (final status in fallThroughStatuses) {
      test('$status from a platform extractor falls through to the catch-all extractor', () async {
        final calls = <String>[];
        final registry = buildRegistry(calls, platformStatus: status);
        final info = await registry.resolveInfo(Uri.parse('https://platform.example/post/1'));
        expect(info.id, 'catchAll');
        expect(calls, ['platform', 'catchAll']);
      });
    }

    for (final status in terminalStatuses) {
      test('$status from a platform extractor is terminal (never reaches the catch-all extractor)', () async {
        final calls = <String>[];
        final registry = buildRegistry(calls, platformStatus: status);
        await expectLater(
          registry.resolveInfo(Uri.parse('https://platform.example/post/1')),
          throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', status)),
        );
        // The guard: if the status-code check in `_resolveAfterFailure`
        // were ever removed (e.g. replaced with an unconditional `true`),
        // this would become `['platform', 'catchAll']` and the test above
        // would fail - verified live by temporarily neutering that check,
        // observing exactly these tests turn red, then reverting.
        expect(calls, ['platform']);
      });
    }

    test('if the catch-all extractor also fails, the fallback (BrowserCaptureExtractor-shaped) is tried next', () async {
      final calls = <String>[];
      final registry = ExtractorRegistry(
        [
          _FakeExtractor('platform', (u) => u.host == 'platform.example', extractFn: (url) async {
            calls.add('platform');
            throw const MediaExtractionException('RATE_LIMITED', 'throttled');
          }),
          _FakeExtractor('catchAll', (u) => true, extractFn: (url) async {
            calls.add('catchAll');
            throw const MediaExtractionException('NO_MEDIA_FOUND', 'nothing found either');
          }),
        ],
        fallbacks: [
          _FakeExtractor('browser', (u) => true, extractFn: (url) async {
            calls.add('browser');
            return MediaInfo(id: 'browser', title: 'found by browser', sourceUrl: url, formats: const [_fakeFormat]);
          }),
        ],
      );

      final info = await registry.resolveInfo(Uri.parse('https://platform.example/post/1'));
      expect(info.id, 'browser');
      expect(calls, ['platform', 'catchAll', 'browser']);
    });

    test('when the whole chain fails, the FIRST (platform) status code surfaces with the last reason appended', () async {
      final registry = ExtractorRegistry(
        [
          _FakeExtractor('platform', (u) => u.host == 'platform.example', extractFn: (url) async {
            throw const MediaExtractionException('RATE_LIMITED', 'X is throttling this request.');
          }),
          _FakeExtractor('catchAll', (u) => true, extractFn: (url) async {
            throw const MediaExtractionException('NO_MEDIA_FOUND', 'No video found on this page.');
          }),
        ],
        fallbacks: [
          _FakeExtractor('browser', (u) => true, extractFn: (url) async {
            throw const MediaExtractionException('NO_MEDIA_FOUND', 'Headless browser found nothing either.');
          }),
        ],
      );

      await expectLater(
        registry.resolveInfo(Uri.parse('https://platform.example/post/1')),
        throwsA(isA<MediaExtractionException>()
            // Keeps the FIRST (platform) extractor's status code, not the
            // catch-all's or the last fallback's.
            .having((e) => e.status, 'status', 'RATE_LIMITED')
            .having(
              (e) => e.reason,
              'reason',
              allOf(
                contains('X is throttling this request.'),
                contains('Headless browser found nothing either.'),
              ),
            )),
      );
    });
  });

  group('ExtractorRegistry.resolveInfo: empty formats is not success (Gadfly root-cause fix)', () {
    test('a catch-all extractor returning zero formats is NOT success and continues to BrowserCapture', () async {
      final calls = <String>[];
      final registry = ExtractorRegistry(
        [
          _FakeExtractor('generic', (u) => true, extractFn: (url) async {
            calls.add('generic');
            // "Success" with nothing to download - e.g. GenericExtractor
            // sniffed the page and, for whatever reason, built an empty
            // format list instead of throwing NO_MEDIA_FOUND outright.
            return MediaInfo(id: 'generic', title: 'empty page', sourceUrl: url);
          }),
        ],
        fallbacks: [
          _FakeExtractor('browserCapture', (u) => true, extractFn: (url) async {
            calls.add('browserCapture');
            return MediaInfo(id: 'browserCapture', title: 'found by browser', sourceUrl: url, formats: const [_fakeFormat]);
          }),
        ],
      );

      final info = await registry.resolveInfo(Uri.parse('https://a.example/video'));
      expect(info.id, 'browserCapture');
      expect(calls, ['generic', 'browserCapture']);
    });

    test('a platform extractor returning zero formats also continues the fall-through chain '
        '(not just extractors that throw NO_MEDIA_FOUND)', () async {
      final calls = <String>[];
      final registry = ExtractorRegistry(
        [
          _FakeExtractor('platform', (u) => u.host == 'platform.example', extractFn: (url) async {
            calls.add('platform');
            return MediaInfo(id: 'platform', title: 'empty', sourceUrl: url); // success, but nothing to download
          }),
          _FakeExtractor('catchAll', (u) => true, extractFn: (url) async {
            calls.add('catchAll');
            return MediaInfo(id: 'catchAll', title: 'found by catchAll', sourceUrl: url, formats: const [_fakeFormat]);
          }),
        ],
      );

      final info = await registry.resolveInfo(Uri.parse('https://platform.example/post/1'));
      expect(info.id, 'catchAll');
      expect(calls, ['platform', 'catchAll']);
    });

    test('if every attempt in the chain returns empty formats, the final error is NO_MEDIA_FOUND', () async {
      final registry = ExtractorRegistry(
        [
          _FakeExtractor('generic', (u) => true, extractFn: (url) async => MediaInfo(id: 'generic', title: 'x', sourceUrl: url)),
        ],
        fallbacks: [
          _FakeExtractor('browserCapture', (u) => true, extractFn: (url) async => MediaInfo(id: 'bc', title: 'x', sourceUrl: url)),
        ],
      );

      await expectLater(
        registry.resolveInfo(Uri.parse('https://a.example/video')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NO_MEDIA_FOUND')),
      );
    });

  });
}
