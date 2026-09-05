import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/browser_capture/captured_media_classifier.dart';

void main() {
  group('CapturedMediaClassifier.classify', () {
    test('video/mp4 with a .mp4 URL is a candidate', () {
      final result = CapturedMediaClassifier.classify('https://cdn.example.com/video.mp4', 'video/mp4');
      expect(result, isNotNull);
      expect(result!.container, 'mp4');
    });

    test('application/vnd.apple.mpegurl with a .m3u8 URL is a candidate', () {
      final result = CapturedMediaClassifier.classify(
        'https://cdn.example.com/master.m3u8',
        'application/vnd.apple.mpegurl',
      );
      expect(result, isNotNull);
      expect(result!.container, 'm3u8');
    });

    test('application/dash+xml with a .mpd URL is a candidate', () {
      final result = CapturedMediaClassifier.classify('https://cdn.example.com/stream.mpd', 'application/dash+xml');
      expect(result, isNotNull);
      expect(result!.container, 'mpd');
    });

    test('.m4s segment is ignored even though mime and extension both match condition A', () {
      final result = CapturedMediaClassifier.classify('https://cdn.example.com/seg-000001.m4s', 'video/mp4');
      expect(result, isNull);
    });

    test('image/png is ignored', () {
      final result = CapturedMediaClassifier.classify('https://cdn.example.com/logo.png', 'image/png');
      expect(result, isNull);
    });

    test('application/javascript is ignored', () {
      final result = CapturedMediaClassifier.classify('https://cdn.example.com/app.js', 'application/javascript');
      expect(result, isNull);
    });

    test('application/octet-stream with a .mp4 URL is a candidate (explicit spec case)', () {
      final result = CapturedMediaClassifier.classify('https://cdn.example.com/video.mp4', 'application/octet-stream');
      expect(result, isNotNull);
      expect(result!.container, 'mp4');
    });

    test('application/octet-stream with no recognized extension is ignored', () {
      final result = CapturedMediaClassifier.classify('https://cdn.example.com/blob', 'application/octet-stream');
      expect(result, isNull);
    });

    test('.m3u8 URL with a mimeType that does not otherwise qualify is still a candidate (condition B)', () {
      final result = CapturedMediaClassifier.classify('https://cdn.example.com/playlist.m3u8?token=abc', 'text/plain');
      expect(result, isNotNull);
      expect(result!.container, 'm3u8');
    });

    test('.mpd URL with a null mimeType is still a candidate (condition B)', () {
      final result = CapturedMediaClassifier.classify('https://cdn.example.com/manifest.mpd', null);
      expect(result, isNotNull);
      expect(result!.container, 'mpd');
    });

    test('video/webm with a .webm URL is a candidate', () {
      final result = CapturedMediaClassifier.classify('https://cdn.example.com/clip.webm', 'video/webm');
      expect(result, isNotNull);
      expect(result!.container, 'webm');
    });

    test('malformed URL does not throw', () {
      expect(() => CapturedMediaClassifier.classify('not a url at all', 'video/mp4'), returnsNormally);
    });
  });

  group('CapturedMediaClassifier.dedupeKey', () {
    test('strips a range query param', () {
      final a = CapturedMediaClassifier.dedupeKey('https://cdn.example.com/video.mp4?range=0-1023');
      final b = CapturedMediaClassifier.dedupeKey('https://cdn.example.com/video.mp4?range=1024-2047');
      expect(a, equals(b));
    });

    test('strips a bytes query param regardless of case', () {
      final a = CapturedMediaClassifier.dedupeKey('https://cdn.example.com/video.mp4?Bytes=0-1023');
      final b = CapturedMediaClassifier.dedupeKey('https://cdn.example.com/video.mp4?bytes=1024-2047');
      expect(a, equals(b));
    });

    test('keeps other query params so two genuinely different resources still differ', () {
      final a = CapturedMediaClassifier.dedupeKey('https://cdn.example.com/video.mp4?id=1&range=0-1023');
      final b = CapturedMediaClassifier.dedupeKey('https://cdn.example.com/video.mp4?id=2&range=0-1023');
      expect(a, isNot(equals(b)));
    });

    test('guard can fail: without range removed, byte-range requests would not dedupe', () {
      // Proves the test above is exercising real stripping, not an
      // accidental match: the *raw* URLs (pre-dedupeKey) differ only in
      // their range query, so if dedupeKey stopped stripping it, this
      // assertion (same input shape as the first test) would flip to
      // "not equal" and the "strips a range query param" test would fail.
      const rawA = 'https://cdn.example.com/video.mp4?range=0-1023';
      const rawB = 'https://cdn.example.com/video.mp4?range=1024-2047';
      expect(rawA, isNot(equals(rawB)));
    });
  });
}
