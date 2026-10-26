import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/embeds/embed_delegation.dart';
import 'package:mida/core/extractors/generic/embeds/embed_resolver.dart';
import 'package:mida/core/extractors/generic/embeds/embed_resolver_chain.dart';
import 'package:mida/core/extractors/media_models.dart';

import 'fake_embed_http.dart';

class _ThrowingResolver implements EmbedResolver {
  @override
  String get platform => 'Broken';
  @override
  bool matches(String html) => true;
  @override
  Future<MediaInfo?> resolve(EmbedRequest request) async => throw StateError('resolver bug');
}

class _ThrowingMatcher implements EmbedResolver {
  @override
  String get platform => 'Broken matcher';
  @override
  bool matches(String html) => throw const FormatException('matcher bug');
  @override
  Future<MediaInfo?> resolve(EmbedRequest request) async => null;
}

const _wistiaRoute = 'GET https://fast.wistia.net/embed/medias/abc123xyz9.json';
const _bcConfig = 'GET https://players.brightcove.net/1234567890/AbCdEf-123_default/config.json';
const _bcPlayback = 'GET https://edge.api.brightcove.com/playback/v1/accounts/1234567890/videos/6301234567001';

void main() {
  test('page with no known embed: null, zero requests', () async {
    final http = FakeEmbedHttp({});
    final chain = EmbedResolverChain(http: http);
    expect(await chain.resolve(pageUrl: hostPage, html: '<html><body><p>hello</p></body></html>'), isNull);
    expect(http.requests, isEmpty);
  });

  test('platform media wins over a YouTube delegation on the same page', () async {
    final http = FakeEmbedHttp({_wistiaRoute: ok(fixture('wistia_media.json'))});
    final html = '${fixture('wistia_page.html')}${fixture('delegation_page.html')}';
    final info = await EmbedResolverChain(http: http).resolve(pageUrl: hostPage, html: html);
    expect(info!.id, 'wistia-abc123xyz9');
  });

  test('delegation beats a DRM-only platform embed', () async {
    final http = FakeEmbedHttp({_wistiaRoute: ok(fixture('wistia_media_drm.json'))});
    final html = '${fixture('wistia_page.html')}${fixture('delegation_page.html')}';
    await expectLater(
      EmbedResolverChain(http: http).resolve(pageUrl: hostPage, html: html),
      throwsA(isA<EmbedDelegationException>()),
    );
  });

  test('DRM-only embed and nothing else: DRM_PROTECTED', () async {
    final http = FakeEmbedHttp({_wistiaRoute: ok(fixture('wistia_media_drm.json'))});
    await expectLater(
      EmbedResolverChain(http: http).resolve(pageUrl: hostPage, html: fixture('wistia_page.html')),
      throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'DRM_PROTECTED')),
    );
  });

  test('a throwing resolver is isolated; the next one still runs', () async {
    final http = FakeEmbedHttp({_wistiaRoute: ok(fixture('wistia_media.json'))});
    final chain = EmbedResolverChain(
      http: http,
      resolvers: [_ThrowingResolver(), ...EmbedResolverChain.defaultResolvers],
    );
    final info = await chain.resolve(pageUrl: hostPage, html: fixture('wistia_page.html'));
    expect(info!.id, 'wistia-abc123xyz9');
  });

  test('shared network budget: a pass never exceeds maxFetches across resolvers', () async {
    final http = FakeEmbedHttp({
      _bcConfig: ok(fixture('brightcove_config.json')),
      _bcPlayback: ok(fixture('brightcove_playback_drm.json')),
      _wistiaRoute: ok(fixture('wistia_media.json')),
    });
    // Brightcove spends 2 (and reports DRM), Wistia would need a 3rd.
    final chain = EmbedResolverChain(http: http, maxFetches: 2);
    final html = '${fixture('brightcove_page_iframe.html')}${fixture('wistia_page.html')}';
    await expectLater(
      chain.resolve(pageUrl: hostPage, html: html),
      throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'DRM_PROTECTED')),
    );
    expect(http.requests, hasLength(2));

    final roomy = FakeEmbedHttp(http.routes);
    final info = await EmbedResolverChain(http: roomy).resolve(pageUrl: hostPage, html: html);
    expect(info!.id, 'wistia-abc123xyz9');
    expect(roomy.requests, hasLength(3));
  });

  test('a throwing matches() is isolated too: the chain keeps going, claims() reads it as no', () async {
    final http = FakeEmbedHttp({_wistiaRoute: ok(fixture('wistia_media.json'))});
    final chain = EmbedResolverChain(http: http, resolvers: [_ThrowingMatcher(), ...EmbedResolverChain.defaultResolvers]);
    final info = await chain.resolve(pageUrl: hostPage, html: fixture('wistia_page.html'));
    expect(info!.id, 'wistia-abc123xyz9');
    expect(EmbedResolverChain(http: http, resolvers: [_ThrowingMatcher()]).claims('<p>x</p>'), isFalse);
  });

  test('malformed Vimeo hash inside the chain: delegation without the hash, no raw FormatException', () async {
    await expectLater(
      EmbedResolverChain(http: FakeEmbedHttp({}))
          .resolve(pageUrl: hostPage, html: '<iframe src="https://player.vimeo.com/video/123?h=%FF"></iframe>'),
      throwsA(isA<EmbedDelegationException>()
          .having((e) => e.target.toString(), 'target', 'https://player.vimeo.com/video/123')),
    );
  });
}
