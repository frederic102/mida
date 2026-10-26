import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/net/retry_policy.dart';

/// A non-empty format list stand-in: a `MediaInfo` with `formats: []` is
/// *not* success (see the `formats.isEmpty` group below), so every fake
/// extractor here standing in for a real successful one must include this.
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

/// A `RetryPolicy` with an instant `sleeper`: exercises the real
/// `maxAttempts`/backoff-decision logic (unlike stubbing retries out
/// entirely) without any test in this file actually waiting on a real
/// clock. Every registry below that can hit a `RATE_LIMITED`/`NETWORK`
/// platform failure passes this - without it, `ExtractorRegistry`'s real
/// default policy (`RetryPolicy(maxAttempts: 2)`, real `Future.delayed`
/// backoff) would make that test burn a real ~1s sleep.
RetryPolicy _hermeticRetryPolicy({int maxAttempts = 2}) =>
    RetryPolicy(maxAttempts: maxAttempts, sleeper: (_) async {});

/// Covers `ExtractorRegistry.resolveInfo`'s platform-extractor fall-through
/// matrix (TikTok/Instagram/X wiring, Phase 2b/2d) and the
/// empty-formats-is-not-success rule (Gadfly root-cause fix), plus the
/// Phase 4 section 3 `RetryPolicy` wiring layered on top of both: a
/// `RATE_LIMITED`/`NETWORK` platform failure now gets one backed-off retry
/// against the *same* extractor before the fall-through decision is made.
void main() {
  group('ExtractorRegistry.resolveInfo platform-extractor fall-through matrix (TikTok/Instagram/X wiring)', () {
    // Split from a single list (pre-Phase-4 this file had one list and one
    // shared expectation): CHALLENGE_FAILED/PARSE_ERROR are fall-through
    // statuses `RetryPolicy`'s default classification does NOT retry, so
    // the primary extractor still runs exactly once before falling
    // through. RATE_LIMITED/NETWORK ARE retryable, so it runs twice
    // (`ExtractorRegistry`'s internal policy retries once) before falling
    // through.
    const nonRetryableFallThroughStatuses = ['CHALLENGE_FAILED', 'PARSE_ERROR'];
    const retryableFallThroughStatuses = ['RATE_LIMITED', 'NETWORK'];
    // LOGIN_REQUIRED left this list in Phase 7: see the login-wall group below.
    const terminalStatuses = ['PRIVATE', 'NOT_FOUND', 'UNSUPPORTED_MEDIA'];

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
        retryPolicy: _hermeticRetryPolicy(),
      );
    }

    for (final status in nonRetryableFallThroughStatuses) {
      test('$status from a platform extractor falls through to the catch-all extractor without retrying', () async {
        final calls = <String>[];
        final registry = buildRegistry(calls, platformStatus: status);
        final info = await registry.resolveInfo(Uri.parse('https://platform.example/post/1'));
        expect(info.id, 'catchAll');
        expect(calls, ['platform', 'catchAll']);
      });
    }

    // Guard-can-fail: proves the retry actually fires for these two
    // statuses (not just that the end result is the same). If
    // `ExtractorRegistry._attempt` stopped wrapping the initial call in
    // `RetryPolicy` (or `RetryPolicy`'s classification regressed to treat
    // these as non-retryable), `calls` would go back to `['platform',
    // 'catchAll']` and this test would fail.
    for (final status in retryableFallThroughStatuses) {
      test('$status from a platform extractor is retried once (same extractor) before falling through', () async {
        final calls = <String>[];
        final registry = buildRegistry(calls, platformStatus: status);
        final info = await registry.resolveInfo(Uri.parse('https://platform.example/post/1'));
        expect(info.id, 'catchAll');
        expect(calls, ['platform', 'platform', 'catchAll']);
      });
    }

    test('a RATE_LIMITED platform extractor that recovers on its retry never reaches the catch-all extractor', () async {
      final calls = <String>[];
      var platformHits = 0;
      final registry = ExtractorRegistry(
        [
          _FakeExtractor('platform', (u) => u.host == 'platform.example', extractFn: (url) async {
            calls.add('platform');
            platformHits += 1;
            if (platformHits == 1) {
              throw const MediaExtractionException('RATE_LIMITED', 'throttled, try again');
            }
            return MediaInfo(id: 'platform', title: 'recovered', sourceUrl: url, formats: const [_fakeFormat]);
          }),
          _FakeExtractor('catchAll', (u) => true, extractFn: (url) async {
            calls.add('catchAll');
            return MediaInfo(id: 'catchAll', title: 'should not be reached', sourceUrl: url, formats: const [_fakeFormat]);
          }),
        ],
        retryPolicy: _hermeticRetryPolicy(),
      );

      final info = await registry.resolveInfo(Uri.parse('https://platform.example/post/1'));
      expect(info.id, 'platform');
      expect(calls, ['platform', 'platform']);
    });

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
        // observing exactly these tests turn red, then reverting. A
        // terminal status is also never retried (`RetryPolicy`'s default
        // classification rejects it), so this stays a single call, not two.
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
        retryPolicy: _hermeticRetryPolicy(),
      );

      final info = await registry.resolveInfo(Uri.parse('https://platform.example/post/1'));
      expect(info.id, 'browser');
      // 'platform' appears twice (RATE_LIMITED's one retry) before falling
      // through to catchAll (NO_MEDIA_FOUND, not retryable, one call) then
      // browser (succeeds on the first try).
      expect(calls, ['platform', 'platform', 'catchAll', 'browser']);
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
        retryPolicy: _hermeticRetryPolicy(),
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

  group('ExtractorRegistry.resolveInfo: a platform LOGIN_REQUIRED reaches the browser fallback (Phase 7)', () {
    const original = MediaExtractionException('LOGIN_REQUIRED', 'Facebook asks to log in to watch this video.');
    final url = Uri.parse('https://platform.example/video/1');

    /// Platform throws [platformError]; the catch-all and the browser
    /// fallback run [catchAll]/[browser] (null = throw NO_MEDIA_FOUND).
    ExtractorRegistry buildRegistry(
      List<String> calls, {
      MediaExtractionException platformError = original,
      Future<MediaInfo> Function(Uri url)? catchAll,
      Future<MediaInfo> Function(Uri url)? browser,
    }) {
      Future<MediaInfo> noMedia(Uri url) async => throw const MediaExtractionException('NO_MEDIA_FOUND', 'nothing on the page');
      return ExtractorRegistry(
        [
          _FakeExtractor('platform', (u) => u.host == 'platform.example', extractFn: (u) async {
            calls.add('platform');
            throw platformError;
          }),
          _FakeExtractor('catchAll', (u) => true, extractFn: (u) {
            calls.add('catchAll');
            return (catchAll ?? noMedia)(u);
          }),
        ],
        fallbacks: [
          _FakeExtractor('browser', (u) => true, extractFn: (u) {
            calls.add('browser');
            return (browser ?? noMedia)(u);
          }),
        ],
        retryPolicy: _hermeticRetryPolicy(),
        // The browser can carry a signed-in session in this group; the
        // toggle-off case lives in media_extractor_policy_fold_test.dart.
        loginSessionAvailable: true,
      );
    }

    test('falls through the catch-all to the browser fallback, whose success wins', () async {
      final calls = <String>[];
      final registry = buildRegistry(calls, browser: (u) async {
        return MediaInfo(id: 'browser', title: 'signed-in capture', sourceUrl: u, formats: const [_fakeFormat]);
      });
      final info = await registry.resolveInfo(url);
      expect(info.id, 'browser');
      // LOGIN_REQUIRED is not retryable: the platform runs once.
      expect(calls, ['platform', 'catchAll', 'browser']);
    });

    test('a catch-all success also wins (the browser is never launched)', () async {
      final calls = <String>[];
      final registry = buildRegistry(calls, catchAll: (u) async {
        return MediaInfo(id: 'catchAll', title: 'public embed', sourceUrl: u, formats: const [_fakeFormat]);
      });
      expect((await registry.resolveInfo(url)).id, 'catchAll');
      expect(calls, ['platform', 'catchAll']);
    });

    test('if every later attempt fails plainly, the ORIGINAL LOGIN_REQUIRED is rethrown', () async {
      final calls = <String>[];
      final registry = buildRegistry(calls);
      // `same`: the very exception the platform threw, not a folded copy.
      await expectLater(registry.resolveInfo(url), throwsA(same(original)));
      expect(calls, ['platform', 'catchAll', 'browser']);
    });

    // Round 3 (Gadfly C7): a browser that carried the session but was itself
    // refused as a bot surfaces that block (a headed run is the fix).
    test('a browser HEADLESS_BLOCKED outranks the login wall, login reason folded', () async {
      final registry = buildRegistry(<String>[], browser: (u) async {
        throw const MediaExtractionException('HEADLESS_BLOCKED', 'the page looks like a bot-check');
      });
      await expectLater(
        registry.resolveInfo(url),
        throwsA(isA<MediaExtractionException>()
            .having((e) => e.status, 'status', 'HEADLESS_BLOCKED')
            .having((e) => e.reason, 'reason', contains('Facebook asks to log in'))),
      );
    });

    test('a fallback that returns zero formats also ends in the original LOGIN_REQUIRED', () async {
      final calls = <String>[];
      final registry = buildRegistry(calls, browser: (u) async => MediaInfo(id: 'browser', title: 'empty', sourceUrl: u));
      await expectLater(registry.resolveInfo(url), throwsA(same(original)));
      expect(calls, ['platform', 'catchAll', 'browser']);
    });

    test('NOT_FOUND from the same platform still stops the chain', () async {
      final calls = <String>[];
      final registry = buildRegistry(
        calls,
        platformError: const MediaExtractionException('NOT_FOUND', 'This video is not available.'),
      );
      await expectLater(
        registry.resolveInfo(url),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NOT_FOUND')),
      );
      expect(calls, ['platform']);
    });
  });
}
