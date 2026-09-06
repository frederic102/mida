import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';

class _FakeExtractor implements MediaExtractor {
  final Future<MediaInfo> Function(Uri url) extractFn;
  const _FakeExtractor(this.extractFn);

  @override
  bool canHandle(Uri url) => true;

  @override
  Future<MediaInfo> extract(Uri url) => extractFn(url);
}

const _cookie = CookieEntry(
  domain: 'delivery.domand.nicovideo.jp',
  path: '/',
  secure: true,
  name: 'domand_bid',
  value: 'abc123',
);

/// Guards `docs/plan-phase6-av-pairing.md` Lane N (N1):
/// `ExtractorRegistry._normalizeProtocols` used to rebuild `MediaInfo` from
/// scratch to stamp the derived `protocol` onto each format, and its
/// constructor call listed every field except `cookiesByDomain` - so any
/// extractor whose formats needed a protocol stamp (every `m3u8`/`mpd`
/// producer) silently lost its cookies on the way out of
/// `ExtractorRegistry.resolveInfo`, even though the extractor itself (e.g.
/// `BrowserCaptureExtractor`, `NiconicoExtractor`) built them correctly.
/// A downstream ffmpeg fetch of a cookie-gated media playlist then 403s
/// with no cookie ever having been dropped anywhere visible.
void main() {
  group('ExtractorRegistry.resolveInfo preserves cookiesByDomain', () {
    test('guard: an m3u8 format (forces protocol normalization to rebuild MediaInfo) '
        'keeps cookiesByDomain intact', () async {
      final registry = ExtractorRegistry([
        _FakeExtractor((url) async => MediaInfo(
              id: 'a',
              title: 'fake',
              sourceUrl: url,
              formats: const [
                MediaFormat(
                  id: 'f1',
                  url: 'https://delivery.domand.nicovideo.jp/hlsbid/master.m3u8',
                  container: 'm3u8',
                  hasVideo: true,
                  hasAudio: true,
                ),
              ],
              cookiesByDomain: const {
                'delivery.domand.nicovideo.jp': [_cookie],
              },
            )),
      ]);

      final info = await registry.resolveInfo(Uri.parse('https://a.example/video'));

      // Sanity: this format did in fact need normalizing (protocol
      // stamped hls), i.e. the MediaInfo-rebuild branch actually ran -
      // otherwise this test would pass vacuously via the unchanged-info
      // early return and prove nothing about the bug.
      expect(info.formats.single.protocol, 'hls');
      expect(info.cookiesByDomain, isNotEmpty);
      expect(info.cookiesByDomain['delivery.domand.nicovideo.jp'], hasLength(1));
      expect(info.cookiesByDomain['delivery.domand.nicovideo.jp']!.single.name, 'domand_bid');
      expect(info.cookiesByDomain['delivery.domand.nicovideo.jp']!.single.value, 'abc123');
    });

    test('an mp4-only format (no normalization needed) also keeps cookiesByDomain', () async {
      final registry = ExtractorRegistry([
        _FakeExtractor((url) async => MediaInfo(
              id: 'a',
              title: 'fake',
              sourceUrl: url,
              formats: const [
                MediaFormat(
                  id: 'f1',
                  url: 'https://example.invalid/video.mp4',
                  container: 'mp4',
                  hasVideo: true,
                  hasAudio: true,
                ),
              ],
              cookiesByDomain: const {
                'example.invalid': [_cookie],
              },
            )),
      ]);

      final info = await registry.resolveInfo(Uri.parse('https://a.example/video'));

      expect(info.cookiesByDomain, isNotEmpty);
      expect(info.cookiesByDomain['example.invalid'], hasLength(1));
    });
  });
}
