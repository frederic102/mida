import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/youtube/youtube_extractor.dart';

void main() {
  group('YoutubeExtractor.attemptWithFallback', () {
    final extractor = YoutubeExtractor();
    final fakeInfo = MediaInfo(id: 'ok', title: 'ok', sourceUrl: Uri.parse('https://example.invalid'));

    test('a SocketException on the first attempt falls through to the second', () async {
      var calls = 0;
      final result = await extractor.attemptWithFallback([
        () async {
          calls++;
          throw const SocketException('connection refused');
        },
        () async {
          calls++;
          return fakeInfo;
        },
      ]);

      expect(result, same(fakeInfo));
      expect(calls, 2);
    });

    test('a TimeoutException falls through, same as SocketException', () async {
      final result = await extractor.attemptWithFallback([
        () async => throw TimeoutException('took too long'),
        () async => fakeInfo,
      ]);
      expect(result, same(fakeInfo));
    });

    test('a FormatException (bad JSON body) falls through instead of aborting', () async {
      final result = await extractor.attemptWithFallback([
        () async => throw const FormatException('Unexpected character'),
        () async => fakeInfo,
      ]);
      expect(result, same(fakeInfo));
    });

    test('a TypeError (unexpected response shape) falls through instead of aborting', () async {
      final result = await extractor.attemptWithFallback([
        () async {
          const dynamic notAMap = 'oops';
          notAMap as Map; // throws TypeError before ever reaching a return
          return fakeInfo;
        },
        () async => fakeInfo,
      ]);
      expect(result, same(fakeInfo));
    });

    test('a MediaExtractionException falls through too (existing behavior preserved)', () async {
      final result = await extractor.attemptWithFallback([
        () async => throw const MediaExtractionException('LOGIN_REQUIRED', 'bot check'),
        () async => fakeInfo,
      ]);
      expect(result, same(fakeInfo));
    });

    test('when every attempt fails, the last failure reason is what surfaces', () async {
      await expectLater(
        extractor.attemptWithFallback([
          () async => throw const MediaExtractionException('LOGIN_REQUIRED', 'first'),
          () async => throw const MediaExtractionException('UNPLAYABLE', 'second'),
        ]),
        throwsA(isA<MediaExtractionException>().having((e) => e.reason, 'reason', 'second')),
      );
    });

    test('an empty attempts list throws UNKNOWN rather than hanging or crashing', () async {
      await expectLater(
        extractor.attemptWithFallback(const []),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNKNOWN')),
      );
    });

    test('when every attempt fails with a network error (Socket or Timeout), the final status is '
        'NETWORK (aligned with ExtractorRegistry._platformFallThroughStatuses, not the old '
        'NETWORK_ERROR/TIMEOUT), so a YouTube network failure falls through to Generic/BrowserCapture', () async {
      await expectLater(
        extractor.attemptWithFallback([
          () async => throw const SocketException('connection refused'),
        ]),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NETWORK')),
      );

      await expectLater(
        extractor.attemptWithFallback([
          () async => throw TimeoutException('took too long'),
        ]),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NETWORK')),
      );
    });
  });
}
