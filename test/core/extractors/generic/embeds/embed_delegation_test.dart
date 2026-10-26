import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/embeds/embed_delegation.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/vimeo/vimeo_extractor.dart';
import 'package:mida/core/extractors/youtube/youtube_extractor.dart';

import 'fake_embed_http.dart';

void main() {
  const resolver = DelegatingEmbedResolver();

  test('first player iframe in document order wins; a plain <a> link is ignored', () {
    final delegation = DelegatingEmbedResolver.findDelegation(fixture('delegation_page.html'))!;
    expect(delegation.platform, 'YouTube');
    expect(delegation.target.toString(), 'https://www.youtube.com/watch?v=dQw4w9WgXcQ');
    expect(delegation.status, 'NO_MEDIA_FOUND');
    expect(delegation, isA<MediaExtractionException>());
  });

  test('Vimeo keeps a valid privacy hash; protocol-relative Dailymotion is canonicalized', () {
    final vimeo = DelegatingEmbedResolver.findDelegation(
      '<iframe src="https://player.vimeo.com/video/76979871?h=8272103f6e&amp;badge=0"></iframe>',
    )!;
    expect(vimeo.target.toString(), 'https://player.vimeo.com/video/76979871?h=8272103f6e');

    final noHash = DelegatingEmbedResolver.findDelegation(
      '<iframe src="https://player.vimeo.com/video/76979871?h=not-hex!"></iframe>',
    )!;
    expect(noHash.target.toString(), 'https://player.vimeo.com/video/76979871');

    // `%FF` does not decode as UTF-8: handled locally as "no hash", it
    // must never throw out of matches()/findDelegation.
    final badEncoding = DelegatingEmbedResolver.findDelegation(
      '<iframe src="https://player.vimeo.com/video/76979871?h=%FF"></iframe>',
    )!;
    expect(badEncoding.target.toString(), 'https://player.vimeo.com/video/76979871');
    expect(resolver.matches('<iframe src="//player.vimeo.com/video/1?h=%E0%A4"></iframe>'), isTrue);

    final dm = DelegatingEmbedResolver.findDelegation('<iframe src="//www.dailymotion.com/embed/video/x8abcd1"></iframe>')!;
    expect(dm.target.toString(), 'https://www.dailymotion.com/video/x8abcd1');

    final geo = DelegatingEmbedResolver.findDelegation(
      '<iframe src="https://geo.dailymotion.com/player/xabc1.html?mute=1&amp;video=x9zz8yy"></iframe>',
    )!;
    expect(geo.target.toString(), 'https://www.dailymotion.com/video/x9zz8yy');
  });

  test('canonical targets are accepted by the native extractors they delegate to', () {
    final yt = DelegatingEmbedResolver.findDelegation(fixture('delegation_page.html'))!;
    expect(YoutubeExtractor().canHandle(yt.target), isTrue);
    final vimeo = DelegatingEmbedResolver.findDelegation('<iframe src="https://player.vimeo.com/video/76979871"></iframe>')!;
    expect(VimeoExtractor().canHandle(vimeo.target), isTrue);
  });

  test('look-alike hosts and malformed ids do not delegate', () {
    for (final html in [
      '<iframe src="https://www.youtube.com.evil.example/embed/dQw4w9WgXcQ"></iframe>',
      '<iframe src="https://evil.example/?u=https://www.youtube.com/embed/dQw4w9WgXcQ"></iframe>',
      '<iframe src="https://www.youtube.com/embed/short"></iframe>',
      '<iframe src="https://player.vimeo.com/video/abc"></iframe>',
      '<a href="https://www.youtube.com/embed/dQw4w9WgXcQ">link</a>',
    ]) {
      expect(resolver.matches(html), isFalse, reason: html);
    }
  });

  test('resolve throws the delegation and makes no request', () async {
    final http = FakeEmbedHttp({});
    await expectLater(
      resolver.resolve(requestFor(fixture('delegation_page.html'), http)),
      throwsA(isA<EmbedDelegationException>()),
    );
    expect(http.requests, isEmpty);
  });
}
