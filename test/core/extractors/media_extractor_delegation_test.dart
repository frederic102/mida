import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/embeds/embed_delegation.dart';
import 'package:mida/core/extractors/media_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/net/retry_policy.dart';

const _fakeFormat = MediaFormat(
  id: 'f',
  url: 'https://example.invalid/video.mp4',
  container: 'mp4',
  hasVideo: true,
  hasAudio: true,
);

typedef _Extract = Future<MediaInfo> Function(Uri url);

/// Records `'<label> <url>'` into [calls] on every `extract`, then runs
/// [extractFn] (default: success with one format).
class _FakeExtractor implements MediaExtractor {
  final String label;
  final bool Function(Uri) canHandleFn;
  final List<String> calls;
  final _Extract? extractFn;
  const _FakeExtractor(this.label, this.canHandleFn, this.calls, {this.extractFn});

  @override
  bool canHandle(Uri url) => canHandleFn(url);

  @override
  Future<MediaInfo> extract(Uri url) {
    calls.add('$label $url');
    if (extractFn != null) return extractFn!(url);
    return Future.value(MediaInfo(id: label, title: 'fake', sourceUrl: url, formats: const [_fakeFormat]));
  }
}

RetryPolicy _hermeticRetryPolicy() => RetryPolicy(maxAttempts: 2, sleeper: (_) async {});

Future<MediaInfo> _noMedia(Uri url) async => throw const MediaExtractionException('NO_MEDIA_FOUND', 'nothing here');

final _page = Uri.parse('https://news.example/article/1');
final _platformPage = Uri.parse('https://platform.example/post/1');
final _youtube = Uri.https('www.youtube.com', '/watch', {'v': 'dQw4w9WgXcQ'});
final _vimeo = Uri.https('player.vimeo.com', '/video/76979871');

/// Covers `ExtractorRegistry`'s handling of [EmbedDelegationException]:
/// one native re-resolve of the delegation target, depth 1, and the
/// original page URL's browser fallback whenever that re-resolve fails.
void main() {
  group('ExtractorRegistry: embed delegation', () {
    /// Registry order mirrors production: native extractors, then the
    /// catch-all (`generic`, accepts every URL unless [genericHandles] is
    /// given), plus one `browser` fallback.
    ExtractorRegistry build(
      List<String> calls, {
      _Extract? platform,
      _Extract? youtube,
      _Extract? vimeo,
      required _Extract generic,
      _Extract? browser,
      bool includeYoutube = true,
      bool Function(Uri)? genericHandles,
      bool withFallback = true,
      bool loginSessionAvailable = false,
    }) {
      return ExtractorRegistry(
        [
          _FakeExtractor('platform', (u) => u.host == 'platform.example', calls,
              extractFn: platform ?? (u) async => throw const MediaExtractionException('CHALLENGE_FAILED', 'waf')),
          if (includeYoutube) _FakeExtractor('youtube', (u) => u.host == 'www.youtube.com', calls, extractFn: youtube),
          _FakeExtractor('vimeo', (u) => u.host == 'player.vimeo.com', calls, extractFn: vimeo),
          _FakeExtractor('generic', genericHandles ?? (u) => true, calls, extractFn: generic),
        ],
        fallbacks: [
          if (withFallback) _FakeExtractor('browser', (u) => true, calls, extractFn: browser),
        ],
        retryPolicy: _hermeticRetryPolicy(),
        loginSessionAvailable: loginSessionAvailable,
      );
    }

    Future<MediaInfo> delegateToYoutube(Uri url) async => throw EmbedDelegationException(_youtube, platform: 'YouTube');

    test('Generic delegating to a YouTube URL runs the YouTube extractor on that URL and returns its result', () async {
      final calls = <String>[];
      final registry = build(calls, generic: delegateToYoutube);
      final info = await registry.resolveInfo(_page);
      expect(info.id, 'youtube');
      expect(info.sourceUrl, _youtube);
      expect(calls, ['generic $_page', 'youtube $_youtube']);
    });

    test('the delegated result goes through protocol normalization too', () async {
      final calls = <String>[];
      final registry = build(calls, generic: delegateToYoutube, youtube: (u) async {
        return MediaInfo(id: 'yt', title: 'hls', sourceUrl: u, formats: const [
          MediaFormat(id: 'h', url: 'https://example.invalid/a.m3u8', container: 'm3u8', hasVideo: true, hasAudio: true),
        ]);
      });
      final info = await registry.resolveInfo(_page);
      expect(info.formats.single.protocol, 'hls');
    });

    test('a target no extractor recognizes falls back to the browser for the ORIGINAL page URL', () async {
      final calls = <String>[];
      final registry = build(calls,
          generic: delegateToYoutube, includeYoutube: false, genericHandles: (u) => u.host == 'news.example');
      final info = await registry.resolveInfo(_page);
      expect(info.id, 'browser');
      expect(calls, ['generic $_page', 'browser $_page']);
    });

    test('a target only the catch-all accepts is never delegated back to it', () async {
      final calls = <String>[];
      final registry = build(calls, generic: delegateToYoutube, includeYoutube: false);
      final info = await registry.resolveInfo(_page);
      expect(info.id, 'browser');
      expect(calls, ['generic $_page', 'browser $_page']);
    });

    test('a native target that throws falls back to the browser for the original URL', () async {
      final calls = <String>[];
      final registry = build(calls,
          generic: delegateToYoutube,
          youtube: (u) async => throw const MediaExtractionException('PRIVATE', 'This video is private.'));
      final info = await registry.resolveInfo(_page);
      expect(info.id, 'browser');
      expect(info.sourceUrl, _page);
      expect(calls, ['generic $_page', 'youtube $_youtube', 'browser $_page']);
    });

    test('a native target returning zero formats also falls back for the original URL', () async {
      final calls = <String>[];
      final registry = build(calls,
          generic: delegateToYoutube, youtube: (u) async => MediaInfo(id: 'yt', title: 'empty', sourceUrl: u));
      expect((await registry.resolveInfo(_page)).id, 'browser');
      expect(calls, ['generic $_page', 'youtube $_youtube', 'browser $_page']);
    });

    test('a nested delegation from the native target is NOT followed (depth 1) and falls back', () async {
      final calls = <String>[];
      final registry = build(calls,
          generic: delegateToYoutube,
          youtube: (u) async => throw EmbedDelegationException(_vimeo, platform: 'Vimeo'));
      final info = await registry.resolveInfo(_page);
      expect(info.id, 'browser');
      expect(calls, ['generic $_page', 'youtube $_youtube', 'browser $_page']);
      expect(calls.any((c) => c.startsWith('vimeo')), isFalse);
    });

    // Phase 7 round 2 (Vigil H1): the browser's HEADLESS_BLOCKED is a
    // policy status, so it now wins the status code over Generic's
    // NO_MEDIA_FOUND; the folded reason still leads with the delegation.
    test('when everything fails, the browser policy status surfaces with the delegation reason first', () async {
      final calls = <String>[];
      final registry = build(calls,
          generic: delegateToYoutube,
          youtube: (u) async => throw const MediaExtractionException('PRIVATE', 'private'),
          browser: (u) async => throw const MediaExtractionException('HEADLESS_BLOCKED', 'bot check'));
      await expectLater(
        registry.resolveInfo(_page),
        throwsA(isA<MediaExtractionException>()
            .having((e) => e.status, 'status', 'HEADLESS_BLOCKED')
            .having((e) => e.reason, 'reason', allOf(contains('$_youtube'), contains('bot check')))),
      );
      expect(calls, ['generic $_page', 'youtube $_youtube', 'browser $_page']);
    });

    test('with no fallbacks configured, a failed delegation rethrows the delegation itself', () async {
      final calls = <String>[];
      final delegation = EmbedDelegationException(_youtube, platform: 'YouTube');
      final registry = build(calls,
          generic: (u) async => throw delegation,
          youtube: (u) async => throw const MediaExtractionException('PARSE_ERROR', 'bad json'),
          withFallback: false);
      await expectLater(registry.resolveInfo(_page), throwsA(same(delegation)));
      expect(calls, ['generic $_page', 'youtube $_youtube']);
    });

    // astra round 2: a delegated policy status (here PRIVATE) is the
    // authoritative diagnosis, so it now wins even with no fallbacks.
    test('with no fallbacks configured, a delegated PRIVATE surfaces with the delegation reason folded', () async {
      final calls = <String>[];
      final registry = build(calls,
          generic: (u) async => throw EmbedDelegationException(_youtube, platform: 'YouTube'),
          youtube: (u) async => throw const MediaExtractionException('PRIVATE', 'private video'),
          withFallback: false);
      await expectLater(
        registry.resolveInfo(_page),
        throwsA(isA<MediaExtractionException>()
            .having((e) => e.status, 'status', 'PRIVATE')
            .having((e) => e.reason, 'reason', contains('private video'))),
      );
    });

    test('a plain NO_MEDIA_FOUND from Generic still goes straight to the browser (no delegation)', () async {
      final calls = <String>[];
      final registry = build(calls, generic: _noMedia);
      expect((await registry.resolveInfo(_page)).id, 'browser');
      expect(calls, ['generic $_page', 'browser $_page']);
    });

    group('after a platform extractor fell through to Generic', () {
      test('the delegation is honored', () async {
        final calls = <String>[];
        final registry = build(calls, generic: delegateToYoutube);
        final info = await registry.resolveInfo(_platformPage);
        expect(info.id, 'youtube');
        expect(calls, ['platform $_platformPage', 'generic $_platformPage', 'youtube $_youtube']);
      });

      test('a failed delegation continues to the browser for the original URL', () async {
        final calls = <String>[];
        final registry = build(calls,
            generic: delegateToYoutube,
            youtube: (u) async => throw const MediaExtractionException('PARSE_ERROR', 'player changed'));
        final info = await registry.resolveInfo(_platformPage);
        expect(info.id, 'browser');
        expect(calls,
            ['platform $_platformPage', 'generic $_platformPage', 'youtube $_youtube', 'browser $_platformPage']);
      });

      test('a nested delegation is not followed there either', () async {
        final calls = <String>[];
        final registry = build(calls,
            generic: delegateToYoutube,
            youtube: (u) async => throw EmbedDelegationException(_vimeo, platform: 'Vimeo'));
        expect((await registry.resolveInfo(_platformPage)).id, 'browser');
        expect(calls.any((c) => c.startsWith('vimeo')), isFalse);
      });

      test('a platform LOGIN_REQUIRED still wins when the delegation and the browser both fail', () async {
        final calls = <String>[];
        const login = MediaExtractionException('LOGIN_REQUIRED', 'log in to watch');
        final registry = build(calls,
            platform: (u) async => throw login,
            generic: delegateToYoutube,
            youtube: (u) async => throw const MediaExtractionException('PRIVATE', 'private'),
            browser: _noMedia,
            loginSessionAvailable: true);
        await expectLater(registry.resolveInfo(_platformPage), throwsA(same(login)));
        expect(calls,
            ['platform $_platformPage', 'generic $_platformPage', 'youtube $_youtube', 'browser $_platformPage']);
      });
    });
  });
}
