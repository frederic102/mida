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

/// Covers `find`, protocol normalization, and the Phase 2d NO_MEDIA_FOUND
/// fallback chain. The platform-extractor fall-through matrix (including
/// the `RetryPolicy` wiring added in Phase 4 section 3) and the
/// empty-formats-is-not-success group live in
/// `media_extractor_fallthrough_test.dart` instead - split out (Phase 4)
/// once this file was about to cross the 400-line hard cap.
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
}
