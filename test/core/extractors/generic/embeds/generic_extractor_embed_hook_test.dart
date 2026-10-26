import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/embeds/embed_delegation.dart';
import 'package:mida/core/extractors/generic/embeds/embed_resolver_chain.dart';
import 'package:mida/core/extractors/generic/generic_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';

import '../generic_test_support.dart';
import 'fake_embed_http.dart';

/// The page itself comes from a loopback fixture server (hop-0 exemption);
/// every platform API call goes to [FakeEmbedHttp], so nothing leaves the
/// machine.
void main() {
  late FakePageServer server;

  setUp(() async => server = await FakePageServer.start());
  tearDown(() => server.close());

  GenericExtractor extractorWith(FakeEmbedHttp http) => GenericExtractor(
        allowPrivateHosts: true,
        embedResolverChain: EmbedResolverChain(http: http),
      );

  test('page with only a Wistia async embed resolves through the media JSON', () async {
    server.body = fixture('wistia_page.html');
    final http = FakeEmbedHttp({'GET https://fast.wistia.net/embed/medias/abc123xyz9.json': ok(fixture('wistia_media.json'))});
    final info = await extractorWith(http).extract(server.urlFor('/watch'));
    expect(info.id, 'wistia-abc123xyz9');
    expect(info.formats, isNotEmpty);
    expect(http.requests.single.headers['Origin'], 'http://127.0.0.1:${server.server.port}');
  });

  test('page whose own HTML already has media never reaches the chain', () async {
    server.body = '<html><body><video src="https://cdn.example.org/clip.mp4"></video>'
        '<div class="wistia_async_abc123xyz9"></div></body></html>';
    final http = FakeEmbedHttp({});
    final info = await extractorWith(http).extract(server.urlFor('/watch'));
    expect(info.formats.single.url, 'https://cdn.example.org/clip.mp4');
    expect(http.requests, isEmpty);
  });

  test('lazy YouTube iframe surfaces as a delegation that still reads as NO_MEDIA_FOUND', () async {
    server.body = '<html><body><iframe data-src="https://www.youtube.com/embed/dQw4w9WgXcQ"></iframe></body></html>';
    await expectLater(
      extractorWith(FakeEmbedHttp({})).extract(server.urlFor('/watch')),
      throwsA(isA<EmbedDelegationException>()
          .having((e) => e.status, 'status', 'NO_MEDIA_FOUND')
          .having((e) => e.target.toString(), 'target', 'https://www.youtube.com/watch?v=dQw4w9WgXcQ')),
    );
  });

  test('DRM-only Brightcove embed surfaces DRM_PROTECTED, not NO_MEDIA_FOUND', () async {
    server.body = '<html><body><video-js data-account="1234567890" data-player="AbCdEf-123" '
        'data-embed="default" data-video-id="6301234567001"></video-js></body></html>';
    final http = FakeEmbedHttp({
      'GET https://players.brightcove.net/1234567890/AbCdEf-123_default/config.json': ok(fixture('brightcove_config.json')),
      'GET https://edge.api.brightcove.com/playback/v1/accounts/1234567890/videos/6301234567001':
          ok(fixture('brightcove_playback_drm.json')),
    });
    await expectLater(
      extractorWith(http).extract(server.urlFor('/watch')),
      throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'DRM_PROTECTED')),
    );
  });

  test('no embed at all keeps the original NO_MEDIA_FOUND, zero platform calls', () async {
    server.body = '<html><body><p>just text</p></body></html>';
    final http = FakeEmbedHttp({});
    await expectLater(
      extractorWith(http).extract(server.urlFor('/watch')),
      throwsA(isA<MediaExtractionException>()
          .having((e) => e.status, 'status', 'NO_MEDIA_FOUND')
          .having((e) => e is EmbedDelegationException, 'is delegation', isFalse)),
    );
    expect(http.requests, isEmpty);
  });
}
