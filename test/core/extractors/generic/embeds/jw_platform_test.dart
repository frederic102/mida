import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/embeds/jw_platform.dart';
import 'package:mida/core/extractors/media_models.dart';

import 'fake_embed_http.dart';

void main() {
  const resolver = JwPlatformEmbedResolver();
  const mediaRoute = 'GET https://cdn.jwplayer.com/v2/media/Ab12Cd34';

  group('JwPlatformEmbedResolver.matches', () {
    test('content.jwplatform.com player script, cdn.jwplayer.com player, data-video-jw-id', () {
      expect(JwPlatformEmbedResolver.findMediaId(fixture('jw_page.html')), 'Ab12Cd34');
      expect(JwPlatformEmbedResolver.findMediaId('<iframe src="https://cdn.jwplayer.com/players/Zz11Yy22-Pp33Qq44.html">'),
          'Zz11Yy22');
      expect(JwPlatformEmbedResolver.findMediaId('<div data-video-jw-id="Mm55Nn66"></div>'), 'Mm55Nn66');
    });

    test('nine-character ids and unrelated pages do not match', () {
      expect(resolver.matches('<script src="https://cdn.jwplayer.com/players/Ab12Cd349.js"></script>'), isFalse);
      expect(resolver.matches('<script src="https://cdn.jwplayer.com/libraries/abc.js"></script>'), isFalse);
    });
  });

  group('JwPlatformEmbedResolver.resolve', () {
    test('Delivery API playlist[0].sources -> HLS, MP4 ladder, audio; javascript: URL dropped', () async {
      final http = FakeEmbedHttp({mediaRoute: ok(fixture('jw_media.json'))});
      final info = (await resolver.resolve(requestFor(fixture('jw_page.html'), http)))!;

      expect(http.requests.single.url.toString(), 'https://cdn.jwplayer.com/v2/media/Ab12Cd34');
      expect(info.title, 'Keynote highlights');
      expect(info.duration, const Duration(seconds: 312));
      expect(info.thumbnailUrl, startsWith('https://cdn.jwplayer.com/v2/media/Ab12Cd34/poster.jpg'));
      expect(info.formats.map((f) => f.container), ['m3u8', 'mp4', 'mp4', 'm4a']);
      final hd = info.formats[1];
      expect([hd.width, hd.height, hd.bitrate, hd.contentLength, hd.fps], [1280, 720, 2100000, 82000000, 29.97]);
      expect(info.formats.last.isAudioOnly, isTrue);
      expect(info.formats.any((f) => f.url.startsWith('javascript')), isFalse);
    });

    test('every source carries a drm block -> DRM_PROTECTED', () async {
      final http = FakeEmbedHttp({mediaRoute: ok(fixture('jw_media_drm.json'))});
      await expectLater(
        resolver.resolve(requestFor(fixture('jw_page.html'), http)),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'DRM_PROTECTED')),
      );
    });

    test('malformed JSON / wrong shapes / 404 -> null', () async {
      for (final body in [
        fixture('malformed.json'),
        '[]',
        '{"playlist":[]}',
        '{"playlist":["x"]}',
        '{"playlist":[{"sources":{"file":"x"}}]}',
      ]) {
        final http = FakeEmbedHttp({mediaRoute: ok(body)});
        expect(await resolver.resolve(requestFor(fixture('jw_page.html'), http)), isNull, reason: body);
      }
      expect(await resolver.resolve(requestFor(fixture('jw_page.html'), FakeEmbedHttp({}))), isNull);
    });
  });
}
