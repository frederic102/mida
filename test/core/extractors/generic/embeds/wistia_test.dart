import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/embeds/wistia.dart';
import 'package:mida/core/extractors/media_models.dart';

import 'fake_embed_http.dart';

void main() {
  const resolver = WistiaEmbedResolver();
  const mediaRoute = 'GET https://fast.wistia.net/embed/medias/abc123xyz9.json';

  group('WistiaEmbedResolver.matches', () {
    test('wistia_async_ class, iframe URL, and data-wistia-id', () {
      expect(WistiaEmbedResolver.findMediaId(fixture('wistia_page.html')), 'abc123xyz9');
      expect(
        WistiaEmbedResolver.findMediaId('<iframe src="//fast.wistia.net/embed/iframe/qwertyuio1?videoFoam=true">'),
        'qwertyuio1',
      );
      expect(WistiaEmbedResolver.findMediaId('<div data-wistia-id="zxcvbnm123"></div>'), 'zxcvbnm123');
    });

    test('ids of the wrong length or charset do not match', () {
      expect(resolver.matches('<div class="wistia_async_short"></div>'), isFalse);
      expect(resolver.matches('<div class="wistia_async_abc123xyz9toolong"></div>'), isFalse);
      expect(resolver.matches('<p>wistia</p>'), isFalse);
    });
  });

  group('WistiaEmbedResolver.resolve', () {
    test('media JSON assets -> mp4 ladder, audio, HLS (.bin -> .m3u8), thumbnail', () async {
      final http = FakeEmbedHttp({mediaRoute: ok(fixture('wistia_media.json'))});
      final info = (await resolver.resolve(requestFor(fixture('wistia_page.html'), http)))!;

      expect(info.id, 'wistia-abc123xyz9');
      expect(info.title, 'Onboarding walkthrough');
      expect(info.duration, const Duration(milliseconds: 245320));
      expect(info.thumbnailUrl, 'https://embed-ssl.wistia.com/deliveries/thumb000.bin');
      // Pending (status 1), flash, still, and storyboard assets are dropped.
      expect(info.formats.map((f) => f.container), ['mp4', 'mp4', 'mp4', 'm4a', 'm3u8']);
      expect(info.formats.first.height, 1080);
      expect(info.formats.first.bitrate, 3900000);
      expect(info.formats[3].isAudioOnly, isTrue);
      expect(info.formats.last.url, 'https://embed-ssl.wistia.com/deliveries/hls00000.m3u8');
    });

    test('asset carrying license-server keys only -> DRM_PROTECTED', () async {
      final http = FakeEmbedHttp({mediaRoute: ok(fixture('wistia_media_drm.json'))});
      await expectLater(
        resolver.resolve(requestFor(fixture('wistia_page.html'), http)),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'DRM_PROTECTED')),
      );
    });

    test('password-protected error JSON -> null', () async {
      final http = FakeEmbedHttp({mediaRoute: ok(fixture('wistia_media_error.json'))});
      expect(await resolver.resolve(requestFor(fixture('wistia_page.html'), http)), isNull);
    });

    test('malformed JSON / wrong shapes / 404 -> null', () async {
      for (final body in [fixture('malformed.json'), '[]', '{"media":[]}', '{"media":{"assets":[{"url":5}]}}']) {
        final http = FakeEmbedHttp({mediaRoute: ok(body)});
        expect(await resolver.resolve(requestFor(fixture('wistia_page.html'), http)), isNull, reason: body);
      }
      expect(await resolver.resolve(requestFor(fixture('wistia_page.html'), FakeEmbedHttp({}))), isNull);
    });
  });
}
