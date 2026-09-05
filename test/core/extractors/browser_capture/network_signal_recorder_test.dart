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

    test(
      'a second Range-fragmented response for the same file keeps the larger content-length '
      '(round 6 revert: range=/bytes= is no longer a per-URL segment signal at all - see '
      'CapturedMediaClassifier.isSegmentUrl\'s own doc comment. bbc.co.uk and vk.com both serve a '
      'real, large, single video via repeated ranged GETs of one URL; round 5 briefly rejected this '
      'shape outright and broke both)',
      () {
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
      },
    );

    test(
      'guard can fail: a blob: response with a real video/mp4 mimeType never becomes a candidate '
      '(the nicovideo real-download-gate regression, round 4)',
      () {
        final candidates = <String, CapturedMediaCandidate>{};
        final segmentUrls = <String>{};

        NetworkSignalRecorder.recordResponse(
          {'url': 'blob:https://www.nicovideo.jp/50c9d1fe-abcd-1234-9abc-def012345678', 'mimeType': 'video/mp4'},
          candidates,
          segmentUrls,
        );

        expect(candidates, isEmpty);
      },
    );

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

    test(
      'guard can fail: a manifest URL named only in the request\'s own Referer header is still captured '
      '(round 5 - a segment request whose manifest CDP never separately reported a request for)',
      () {
        final candidates = <String, CapturedMediaCandidate>{};
        final segmentUrls = <String>{};

        NetworkSignalRecorder.recordRequestWillBeSent(
          {
            'url': 'https://cdn.example.com/hls/720p/seg-000.ts',
            'headers': {'Referer': 'https://cdn.example.com/hls/720p/master.m3u8'},
          },
          candidates,
          segmentUrls,
        );

        expect(candidates, hasLength(1));
        expect(candidates.values.single.url, 'https://cdn.example.com/hls/720p/master.m3u8');
        expect(candidates.values.single.container, 'm3u8');
        // The segment's own URL is still tracked as a segment, not lost.
        expect(segmentUrls, contains('https://cdn.example.com/hls/720p/seg-000.ts'));
      },
    );

    test('a request with no Referer header at all is unaffected (no crash, no phantom candidate)', () {
      final candidates = <String, CapturedMediaCandidate>{};
      final segmentUrls = <String>{};

      NetworkSignalRecorder.recordRequestWillBeSent(
        {'url': 'https://cdn.example.com/clip.mp4', 'headers': <String, dynamic>{}},
        candidates,
        segmentUrls,
      );

      expect(candidates, hasLength(1));
      expect(candidates.values.single.url, 'https://cdn.example.com/clip.mp4');
    });
  });

  group('NetworkSignalRecorder.reclassifyFragmentedSiblings', () {
    Map<String, CapturedMediaCandidate> candidatesAt(List<String> urls, {int contentLength = 200 * 1024}) => {
          for (final url in urls) url: CapturedMediaCandidate(url: url, container: 'mp4', contentLength: contentLength),
        };

    test(
      'guard can fail: 3+ small mp4 candidates differing only by a numeric path segment are demoted to segments '
      '(niconico-like shape: no extension, no keyword - only the sibling grouping can catch this)',
      () {
        final candidates = candidatesAt([
          'https://93.184.216.34/dash/fragments/1?sig=abc',
          'https://93.184.216.34/dash/fragments/2?sig=def',
          'https://93.184.216.34/dash/fragments/3?sig=ghi',
        ]);
        final segmentUrls = <String>{};

        NetworkSignalRecorder.reclassifyFragmentedSiblings(candidates, segmentUrls);

        expect(candidates, isEmpty);
        expect(segmentUrls, hasLength(3));
      },
    );

    test('guard can fail: only 2 siblings is not enough - stays a candidate, not demoted', () {
      final candidates = candidatesAt([
        'https://93.184.216.34/dash/fragments/1?sig=abc',
        'https://93.184.216.34/dash/fragments/2?sig=def',
      ]);
      final segmentUrls = <String>{};

      NetworkSignalRecorder.reclassifyFragmentedSiblings(candidates, segmentUrls);

      expect(candidates, hasLength(2));
      expect(segmentUrls, isEmpty);
    });

    test('guard can fail: a candidate at or above the 3MB fragment-size threshold is never demoted, however many '
        'numbered siblings exist (a real quality ladder, not a fragment sequence)', () {
      final candidates = candidatesAt(
        [
          'https://93.184.216.34/dash/fragments/1?sig=abc',
          'https://93.184.216.34/dash/fragments/2?sig=def',
          'https://93.184.216.34/dash/fragments/3?sig=ghi',
        ],
        contentLength: 5 * 1024 * 1024,
      );
      final segmentUrls = <String>{};

      NetworkSignalRecorder.reclassifyFragmentedSiblings(candidates, segmentUrls);

      expect(candidates, hasLength(3));
      expect(segmentUrls, isEmpty);
    });

    test('an m3u8/mpd-container candidate is never touched by this grouping, whatever its size or naming', () {
      final candidates = {
        for (final url in [
          'https://93.184.216.34/dash/1.m3u8',
          'https://93.184.216.34/dash/2.m3u8',
          'https://93.184.216.34/dash/3.m3u8',
        ])
          url: CapturedMediaCandidate(url: url, container: 'm3u8', contentLength: 1024),
      };
      final segmentUrls = <String>{};

      NetworkSignalRecorder.reclassifyFragmentedSiblings(candidates, segmentUrls);

      expect(candidates, hasLength(3));
    });

    test('a candidate with no known content-length is never demoted (cannot confirm the <3MB threshold)', () {
      final candidates = {
        for (final url in [
          'https://93.184.216.34/dash/fragments/1?sig=abc',
          'https://93.184.216.34/dash/fragments/2?sig=def',
          'https://93.184.216.34/dash/fragments/3?sig=ghi',
        ])
          url: CapturedMediaCandidate(url: url, container: 'mp4'),
      };
      final segmentUrls = <String>{};

      NetworkSignalRecorder.reclassifyFragmentedSiblings(candidates, segmentUrls);

      expect(candidates, hasLength(3));
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
