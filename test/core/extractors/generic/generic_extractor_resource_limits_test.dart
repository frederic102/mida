import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/generic_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';

import 'generic_test_support.dart';

/// Resource-exhaustion guards (security follow-up), split out to keep
/// `generic_extractor_test.dart` under the 400-line cap: (1) a page body
/// is truncated at 5MB rather than buffered in full, (2) the whole
/// static-analysis stage has an overall wall-clock deadline so a
/// pathological/hanging server cannot hang `extract()` forever.
void main() {
  group('GenericExtractor: resource-exhaustion guards', () {
    late FakePageServer server;

    setUp(() async {
      server = await FakePageServer.start();
    });

    tearDown(() async {
      await server.close();
    });

    test(
      'a page body is truncated at 5MB: a <video src> placed past that point is never seen, even though '
      'the exact same tag placed before it would be found',
      () async {
        // Padding well past the 5MB cap, followed by the only media tag on
        // the page: if the body were buffered in full this would resolve
        // normally; because it is truncated at 5MB, the tag is never
        // reached and the page looks empty.
        final padding = 'x' * (6 * 1024 * 1024);
        server.body = '<html><body><!-- $padding --><video src="/media/late.mp4"></video></body></html>';

        final extractor = GenericExtractor(allowPrivateHosts: true);
        await expectLater(
          extractor.extract(server.urlFor('/huge-late-tag')),
          throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NO_MEDIA_FOUND')),
        );
      },
    );

    test('the same <video src> placed before the 5MB mark is still found normally (control case)', () async {
      final padding = 'x' * (1024 * 1024); // 1MB: well under the cap
      server.body = '<html><body><video src="/media/early.mp4"></video><!-- $padding --></body></html>';

      final extractor = GenericExtractor(allowPrivateHosts: true);
      final info = await extractor.extract(server.urlFor('/huge-early-tag'));

      expect(info.formats, hasLength(1));
      expect(info.formats.single.url, server.urlFor('/media/early.mp4').toString());
    });

    // Guard-can-fail evidence (verified, see report): temporarily raising
    // `_maxBodyBytes` to 100MB made the "past that point" test above fail
    // (it resolved normally instead of throwing NO_MEDIA_FOUND, because
    // the late tag was no longer truncated away). Reverted immediately
    // after confirming the failure.

    test(
      'the whole static-analysis stage has a wall-clock deadline: a server that never responds at all '
      'raises NO_MEDIA_FOUND once the (test-shortened) deadline elapses, instead of hanging forever',
      () async {
        final hangingServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => hangingServer.close(force: true));
        hangingServer.listen((request) {
          // Deliberately never responds.
        });

        final extractor = GenericExtractor(
          allowPrivateHosts: true,
          staticStageDeadlineForTesting: const Duration(milliseconds: 300),
        );

        await expectLater(
          extractor.extract(Uri.parse('http://127.0.0.1:${hangingServer.port}/slow')),
          throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NO_MEDIA_FOUND')),
        );
      },
    );

    // Guard-can-fail evidence (verified, see report): temporarily removing
    // the `.timeout(_effectiveStaticStageDeadline)` call in `extract()`
    // made the test above hang indefinitely (the test runner eventually
    // times the whole test out as a failure) instead of completing
    // quickly with NO_MEDIA_FOUND. Reverted immediately after confirming
    // the failure.
  });
}
