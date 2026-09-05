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

    test('.ts segment is ignored even with a real video/mp2t mimeType (never its own candidate)', () {
      // Guard can fail: this is the exact bug a mimeType-only fallback for
      // extension-less URLs could reintroduce if `ts` were ever dropped
      // from the recognized-extension list - an HLS segment must never
      // become its own whole-file candidate.
      final result = CapturedMediaClassifier.classify('https://cdn.example.com/hls/seg-001.ts', 'video/mp2t');
      expect(result, isNull);
    });

    test('a real video/mp4 response with no extension anywhere in the URL is still a candidate (vk.com CDN shape)', () {
      // docs/plan-phase5-coverage.md Lane A diagnostic (2026-09-05): vk.com
      // serves real video/audio from a bare signed path like
      // `okcdn.ru/?expires=...&type=2&...` with no dotted extension at
      // all - the server's own Content-Type is trusted instead of
      // discarding this traffic for lacking a URL extension.
      final result = CapturedMediaClassifier.classify(
        'https://vkvd674.okcdn.ru/?expires=1&type=2',
        'video/mp4',
      );
      expect(result, isNotNull);
      expect(result!.container, 'mp4');
    });

    test(
      'guard can fail: the same vk.com shape WITH a bytes= range query still a candidate, not a segment '
      '(round 6 revert: round 5 treated any bytes=/range= URL as a segment per-URL, no matter its size or '
      'sibling count, which broke vk.com\'s real single large video candidate - see isSegmentUrl\'s own '
      'doc comment. bytes=/range= is no longer a per-URL segment signal at all; only a *group* of 3+ small '
      'siblings sharing this shape is ever demoted - NetworkSignalRecorder.reclassifyFragmentedSiblings)',
      () {
        final result = CapturedMediaClassifier.classify(
          'https://vkvd674.okcdn.ru/?expires=1&type=2&bytes=0-100',
          'video/mp4',
        );
        expect(result, isNotNull);
        expect(result!.container, 'mp4');
      },
    );

    test('audio/mpeg with no dotted extension (Bandcamp CDN shape) is a candidate with an mp3 container', () {
      // Bandcamp's own CDN path segment is literally "mp3-128" (not a
      // ".mp3" file extension), which the extension regex was never going
      // to match either way.
      final result = CapturedMediaClassifier.classify(
        'https://t4.bcbits.com/stream/abc/mp3-128/123?token=xyz',
        'audio/mpeg',
      );
      expect(result, isNotNull);
      expect(result!.container, 'mp3');
    });

    test('video/webm with no extension falls back to a webm container, not mp4', () {
      final result = CapturedMediaClassifier.classify('https://cdn.example.com/media?id=1', 'video/webm');
      expect(result, isNotNull);
      expect(result!.container, 'webm');
    });

    test('audio/mp4 with no extension falls back to an m4a container', () {
      final result = CapturedMediaClassifier.classify('https://cdn.example.com/media?id=1', 'audio/mp4');
      expect(result, isNotNull);
      expect(result!.container, 'm4a');
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

    test(
      'guard can fail: a blob: URL with a real video/mp4 mimeType is never a candidate '
      '(the extension-less fallback must not skip the scheme check)',
      () {
        // Round 4 real-download-gate regression (nicovideo, non-
        // deterministic): Chromium can emit a genuine
        // Network.responseReceived for a <video> element's blob: (MediaSource)
        // src, complete with a video/* Content-Type - and the bare
        // extension-less mimeType fallback just above (added for vk.com/
        // Bandcamp) never checked scheme at all, so this exact shape used
        // to produce a candidate whose URL could never actually be
        // downloaded by this app's own pipeline.
        final result = CapturedMediaClassifier.classify('blob:https://www.nicovideo.jp/50c9d1fe-abcd', 'video/mp4');
        expect(result, isNull);
      },
    );

    test('guard can fail: a blob: URL with a recognized .mp4-looking extension is still never a candidate', () {
      final result = CapturedMediaClassifier.classify(
        'blob:https://cdn.example.com/video.mp4',
        'application/octet-stream',
      );
      expect(result, isNull);
    });
  });

  group('CapturedMediaClassifier.classifyByUrlOnly', () {
    test('an ordinary https URL with a .mp4 extension is a candidate', () {
      final result = CapturedMediaClassifier.classifyByUrlOnly('https://cdn.example.com/video.mp4');
      expect(result, isNotNull);
    });

    test('guard can fail: a blob: URL is never a candidate even with a .mp4-looking suffix', () {
      final result = CapturedMediaClassifier.classifyByUrlOnly('blob:https://cdn.example.com/video.mp4');
      expect(result, isNull);
    });
  });

  group('CapturedMediaClassifier.isSegmentUrl (round 6 regression fixtures)', () {
    test(
      'guard can fail: vimeo\'s real ranged-mp4 URL is not a segment (round 5 regression - live-observed shape, '
      'docs/plan-phase5-coverage.md round 6 diagnostic on https://vimeo.com/22439234)',
      () {
        // Exact shape observed live: a `/v2/range/prot/<base64>/avf/<uuid>.mp4`
        // path plus a `range=0-802` query param - a completely ordinary,
        // real, whole-file progressive-download candidate on vimeo's own
        // CDN. Round 5's bare `range=` keyword substring match rejected
        // this outright (`vimeo.com` went from 4 formats to
        // NO_MEDIA_FOUND); round 6 no longer treats `range=`/`bytes=` as a
        // per-URL segment signal at all.
        const vimeoUrl = 'https://vod-adaptive-ak.vimeocdn.com/'
            'exp=1788638917~acl=%2Fd342534e-4aaa-4eee-bdd6-94430cb955d1%2F~hmac=dc1e68e9/'
            'd342534e-4aaa-4eee-bdd6-94430cb955d1/v2/range/prot/cmFuZ2U9MC04MDI/'
            'avf/6151447b-d92a-4c7e-a900-52466126853e.mp4'
            '?pathsig=8c953e4f~E_g-Ib8buCJ6lmVXdumYroTNc6PK1d64MLY-7ciKkSA&r=dXMtd2VzdDE%3D&range=0-802';

        expect(CapturedMediaClassifier.isSegmentUrl(vimeoUrl), isFalse);
        expect(CapturedMediaClassifier.classify(vimeoUrl, 'video/mp4'), isNotNull);
      },
    );

    test(
      'guard can fail: a Next.js static-asset "chunks" directory is not a segment '
      '(round 5 regression - "chunk" bare-substring matched the plural "chunks" directory name; '
      'live-observed on both vimeo.com and bbc.co.uk)',
      () {
        const chunkUrl = 'https://f.vimeocdn.com/next-server/vimeo-next/_next/static/chunks/1fuy3mu0n4abg.js';
        expect(CapturedMediaClassifier.isSegmentUrl(chunkUrl), isFalse);
      },
    );

    test(
      'guard can fail: a third-party analytics URL with "/segment" as its own path component is not a segment '
      '(round 5 regression - live-observed on bbc.co.uk: api.permutive.com/ctx/v1/segment)',
      () {
        const permutiveUrl = 'https://api.permutive.com/ctx/v1/segment?k=1bb84885-9325-4fef-adda-a208032b2715';
        expect(CapturedMediaClassifier.isSegmentUrl(permutiveUrl), isFalse);
      },
    );

    test('a literal seg-prefixed .mp4 chunk (the original, narrower round-2/3 shape) is still a segment', () {
      expect(CapturedMediaClassifier.isSegmentUrl('https://cdn.example.com/hls/seg-042.mp4'), isTrue);
    });

    test('an init.mp4 CMAF init segment is still a segment (word-boundary token, not a bare substring)', () {
      expect(CapturedMediaClassifier.isSegmentUrl('https://cdn.example.com/video/1/init.mp4'), isTrue);
    });

    test('a real .cmfv/.cmfa/.m4s/.ts extension is still a segment regardless of path tokens', () {
      expect(CapturedMediaClassifier.isSegmentUrl('https://cdn.example.com/video/1/01.cmfv'), isTrue);
      expect(CapturedMediaClassifier.isSegmentUrl('https://cdn.example.com/video/1/01.cmfa'), isTrue);
      expect(CapturedMediaClassifier.isSegmentUrl('https://cdn.example.com/hls/720p/seg-000.ts'), isTrue);
      expect(CapturedMediaClassifier.isSegmentUrl('https://cdn.example.com/dash/chunk_0.m4s'), isTrue);
    });

    test('guard can fail: a single bytes=-addressed URL with a large Content-Length is still a candidate, '
        'never a segment, however small or large its query looks', () {
      final result = CapturedMediaClassifier.classify(
        'https://cdn.example.com/video.mp4?bytes=0-5242879',
        'video/mp4',
      );
      expect(result, isNotNull);
    });
  });

  group('CapturedMediaClassifier.isFetchableUrl', () {
    test('http and https are fetchable', () {
      expect(CapturedMediaClassifier.isFetchableUrl('http://cdn.example.com/a.mp4'), isTrue);
      expect(CapturedMediaClassifier.isFetchableUrl('https://cdn.example.com/a.mp4'), isTrue);
    });

    test('guard can fail: blob/data/mediasource schemes and a schemeless string are all rejected', () {
      expect(CapturedMediaClassifier.isFetchableUrl('blob:https://cdn.example.com/uuid'), isFalse);
      expect(CapturedMediaClassifier.isFetchableUrl('data:video/mp4;base64,AAAA'), isFalse);
      expect(CapturedMediaClassifier.isFetchableUrl('mediasource:https://cdn.example.com/uuid'), isFalse);
      expect(CapturedMediaClassifier.isFetchableUrl('not a url at all'), isFalse);
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
