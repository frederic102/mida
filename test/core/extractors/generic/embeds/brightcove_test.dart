import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/embeds/brightcove.dart';
import 'package:mida/core/extractors/media_models.dart';

import 'fake_embed_http.dart';

void main() {
  const resolver = BrightcoveEmbedResolver();
  const configUrl = 'GET https://players.brightcove.net/1234567890/AbCdEf-123_default/config.json';
  const playbackUrl = 'GET https://edge.api.brightcove.com/playback/v1/accounts/1234567890/videos/6301234567001';

  group('BrightcoveEmbedResolver.matches', () {
    test('iframe embed with &amp;-escaped query', () {
      final embed = BrightcoveEmbedResolver.findEmbed(fixture('brightcove_page_iframe.html'))!;
      expect(embed.accountId, '1234567890');
      expect(embed.playerId, 'AbCdEf-123');
      expect(embed.embedId, 'default');
      expect(embed.videoId, '6301234567001');
    });

    test('in-page <video-js data-*> embed with a ref: id', () {
      final embed = BrightcoveEmbedResolver.findEmbed(fixture('brightcove_page_video_tag.html'))!;
      expect(embed.videoId, 'ref:launch_2026');
      expect(embed.playerId, 'AbCdEf-123');
    });

    test('rejects ids that could steer the URL (path traversal, non-numeric account)', () {
      expect(resolver.matches('<video data-account="12/../evil" data-player="p" data-video-id="1">'), isFalse);
      expect(resolver.matches('<video data-account="123" data-player="p/../x" data-video-id="1">'), isFalse);
      expect(resolver.matches('<video data-account="123" data-player="p" data-video-id="1?x=y">'), isFalse);
      expect(resolver.matches('<html><body>no player</body></html>'), isFalse);
    });
  });

  group('BrightcoveEmbedResolver.resolve', () {
    test('config.json policy key -> Playback API -> HLS + MP4 ladder + audio', () async {
      final http = FakeEmbedHttp({
        configUrl: ok(fixture('brightcove_config.json')),
        playbackUrl: ok(fixture('brightcove_playback.json')),
      });
      final info = (await resolver.resolve(requestFor(fixture('brightcove_page_iframe.html'), http)))!;

      expect(http.requests, hasLength(2));
      final playbackCall = http.requests[1];
      expect(playbackCall.headers['Accept'], 'application/json;pk=BCpkADawqM1fakePolicyKey_abc-123');
      expect(playbackCall.headers['Origin'], 'https://www.example.org');
      expect(playbackCall.headers.keys.map((k) => k.toLowerCase()), isNot(contains('cookie')));

      expect(info.title, 'Product tour 2026');
      expect(info.duration, const Duration(milliseconds: 93120));
      expect(info.sourceUrl, hostPage);
      expect(info.requestHeaders['Referer'], 'https://www.example.org/');
      // Duplicate HLS src collapsed, RTMP skipped.
      expect(info.formats.map((f) => f.container), ['m3u8', 'mp4', 'mp4', 'm4a']);
      final high = info.formats[1];
      expect([high.width, high.height, high.bitrate, high.contentLength], [1280, 720, 2500000, 29100000]);
      expect(high.isMuxed, isTrue);
      expect(info.formats.last.isAudioOnly, isTrue);
    });

    test('every source carries key_systems -> DRM_PROTECTED', () async {
      final http = FakeEmbedHttp({
        configUrl: ok(fixture('brightcove_config.json')),
        playbackUrl: ok(fixture('brightcove_playback_drm.json')),
      });
      await expectLater(
        resolver.resolve(requestFor(fixture('brightcove_page_iframe.html'), http)),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'DRM_PROTECTED')),
      );
    });

    test('malformed config JSON -> null, Playback API never called', () async {
      final http = FakeEmbedHttp({configUrl: ok(fixture('malformed.json'))});
      expect(await resolver.resolve(requestFor(fixture('brightcove_page_iframe.html'), http)), isNull);
      expect(http.requests, hasLength(1));
    });

    test('policy key with header-smuggling characters is refused', () async {
      final http = FakeEmbedHttp({
        configUrl: ok('{"video_cloud":{"policy_key":"abc;pk=other, text/html"}}'),
        playbackUrl: ok(fixture('brightcove_playback.json')),
      });
      expect(await resolver.resolve(requestFor(fixture('brightcove_page_iframe.html'), http)), isNull);
      expect(http.requests, hasLength(1));
    });

    test('malformed playback JSON / wrong shapes / API 403 -> null', () async {
      for (final body in [fixture('malformed.json'), '[]', '{"sources":"nope"}', '{"sources":[1,"x",null]}']) {
        final http = FakeEmbedHttp({configUrl: ok(fixture('brightcove_config.json')), playbackUrl: ok(body)});
        expect(await resolver.resolve(requestFor(fixture('brightcove_page_iframe.html'), http)), isNull, reason: body);
      }
      final denied = FakeEmbedHttp({configUrl: ok(fixture('brightcove_config.json'))});
      expect(await resolver.resolve(requestFor(fixture('brightcove_page_iframe.html'), denied)), isNull);
    });
  });
}
