import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/browser_capture/captured_media_classifier.dart';
import 'package:mida/core/extractors/browser_capture/network_signal_recorder.dart';

void main() {
  group('NetworkSignalRecorder.recordResponse', () {
    test('a classified video/mp4 response becomes a candidate keyed by its dedupe key', () {
      final candidates = <String, CapturedMediaCandidate>{};
      final segmentUrls = <String>{};

      NetworkSignalRecorder.recordResponse(
        {'url': 'https://cdn.example.com/clip.mp4', 'mimeType': 'video/mp4'},
        candidates,
        segmentUrls,
      );

      expect(candidates, hasLength(1));
      expect(candidates.values.single.container, 'mp4');
      expect(segmentUrls, isEmpty);
    });

    test('a .ts segment response is tracked as a segment URL, never as its own candidate', () {
      final candidates = <String, CapturedMediaCandidate>{};
      final segmentUrls = <String>{};

      NetworkSignalRecorder.recordResponse(
        {'url': 'https://cdn.example.com/hls/seg-001.ts', 'mimeType': 'video/mp2t'},
        candidates,
        segmentUrls,
      );

      expect(candidates, isEmpty);
      expect(segmentUrls, {'https://cdn.example.com/hls/seg-001.ts'});
    });

    test('a second Range-fragmented response for the same file keeps the larger content-length', () {
      final candidates = <String, CapturedMediaCandidate>{};
      final segmentUrls = <String>{};

      NetworkSignalRecorder.recordResponse(
        {
          'url': 'https://cdn.example.com/video.mp4?range=0-1023',
          'mimeType': 'video/mp4',
          'headers': {'content-length': '1024'},
        },
        candidates,
        segmentUrls,
      );
      NetworkSignalRecorder.recordResponse(
        {
          'url': 'https://cdn.example.com/video.mp4?range=1024-4194303',
          'mimeType': 'video/mp4',
          'headers': {'content-length': '4193280'},
        },
        candidates,
        segmentUrls,
      );

      expect(candidates, hasLength(1));
      expect(candidates.values.single.contentLength, 4193280);
    });

    test('a non-Map response value is ignored rather than thrown', () {
      final candidates = <String, CapturedMediaCandidate>{};
      final segmentUrls = <String>{};

      // recordResponse's caller (`BrowserCaptureExtractor._observe`) already
      // guards `response is Map` before calling in, but recordResponse
      // itself must still be safe to call with a response missing a `url`
      // key entirely (a malformed/partial CDP event).
      NetworkSignalRecorder.recordResponse({'mimeType': 'video/mp4'}, candidates, segmentUrls);

      expect(candidates, isEmpty);
    });
  });

  group('NetworkSignalRecorder.recordRequestWillBeSent', () {
    test('a bare .mp4 URL with no mimeType at all still becomes a candidate', () {
      final candidates = <String, CapturedMediaCandidate>{};
      final segmentUrls = <String>{};

      NetworkSignalRecorder.recordRequestWillBeSent(
        {'url': 'https://cdn.example.com/clip.mp4'},
        candidates,
        segmentUrls,
      );

      expect(candidates, hasLength(1));
    });

    test('a request for an unrelated asset (no recognized extension) is ignored', () {
      final candidates = <String, CapturedMediaCandidate>{};
      final segmentUrls = <String>{};

      NetworkSignalRecorder.recordRequestWillBeSent(
        {'url': 'https://cdn.example.com/app.js'},
        candidates,
        segmentUrls,
      );

      expect(candidates, isEmpty);
      expect(segmentUrls, isEmpty);
    });
  });

  group('NetworkSignalRecorder.parsePerformanceEntries', () {
    test('decodes a JSON array of resource URL strings', () {
      final parsed = NetworkSignalRecorder.parsePerformanceEntries(
        '["https://cdn.example.com/a.mp4","https://cdn.example.com/b.js"]',
      );
      expect(parsed, ['https://cdn.example.com/a.mp4', 'https://cdn.example.com/b.js']);
    });

    test('a JSON object (not an array) is treated as a miss, not a crash', () {
      expect(NetworkSignalRecorder.parsePerformanceEntries('{"not":"a list"}'), isNull);
    });

    test('invalid JSON is treated as a miss, not a crash', () {
      expect(NetworkSignalRecorder.parsePerformanceEntries('not json at all'), isNull);
    });
  });

  group('NetworkSignalRecorder.backfillFromPerformanceEntries', () {
    test('every recognized resource URL from the eval result is folded into candidates/segmentUrls', () async {
      final candidates = <String, CapturedMediaCandidate>{};
      final segmentUrls = <String>{};

      await NetworkSignalRecorder.backfillFromPerformanceEntries(
        (expression) async => '["https://cdn.example.com/movie.mp4","https://cdn.example.com/hls/seg-1.ts"]',
        candidates,
        segmentUrls,
      );

      expect(candidates, hasLength(1));
      expect(candidates.values.single.url, 'https://cdn.example.com/movie.mp4');
      expect(segmentUrls, {'https://cdn.example.com/hls/seg-1.ts'});
    });

    test('a null eval result (page threw, or performance was redefined) is a no-op', () async {
      final candidates = <String, CapturedMediaCandidate>{};
      final segmentUrls = <String>{};

      await NetworkSignalRecorder.backfillFromPerformanceEntries(
        (expression) async => null,
        candidates,
        segmentUrls,
      );

      expect(candidates, isEmpty);
      expect(segmentUrls, isEmpty);
    });
  });
}
