import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/embeds/kaltura.dart';
import 'package:mida/core/extractors/media_models.dart';

import 'fake_embed_http.dart';

void main() {
  const resolver = KalturaEmbedResolver();
  const apiRoute = 'POST https://cdnapisec.kaltura.com/api_v3/service/multirequest';

  group('KalturaEmbedResolver.matches', () {
    test('kWidget.embed options + embedIframeJs script', () {
      final embed = KalturaEmbedResolver.findEmbed(fixture('kaltura_page.html'))!;
      expect(embed.partnerId, '2054321');
      expect(embed.entryId, '1_ab12cd34');
    });

    test('iframe form: /p/{partner}/... ?entry_id=', () {
      final embed = KalturaEmbedResolver.findEmbed(
        '<iframe src="https://cdnapisec.kaltura.com/p/777/sp/77700/embedIframeJs/uiconf_id/1/partner_id/777'
        '?iframeembed=true&amp;entry_id=0_zz99yy88"></iframe>',
      )!;
      expect(embed.partnerId, '777');
      expect(embed.entryId, '0_zz99yy88');
    });

    test('kWidget options: only top-level fields of the options object count, nested plugin ids never do', () {
      const nestedFirst = '<script>kWidget.embed({wid:"_111",plugins:{related:{entry_id:"1_aaaaaaaa"}},'
          'entry_id:"1_bbbbbbbb"})</script>';
      const nestedLast = '<script>kWidget.embed({entry_id:"1_bbbbbbbb",'
          'plugins:{related:{entry_id:"1_aaaaaaaa",wid:"_999",partner_id:999}},wid:"_111"})</script>';
      for (final html in [nestedFirst, nestedLast]) {
        final embed = KalturaEmbedResolver.findEmbed(html)!;
        expect([embed.partnerId, embed.entryId], ['111', '1_bbbbbbbb'], reason: html);
      }
    });

    test('kWidget options whose only entry id is nested: no embed, no page-wide guess', () {
      const html = '<script>kWidget.embed({wid:"_111",plugins:{related:{entry_id:"1_aaaaaaaa"}}})</script>';
      expect(KalturaEmbedResolver.findEmbed(html), isNull);
    });

    test('two embeds: partner and entry always come from the same embed, never first-of-each', () {
      // A third-party script names partner 333 first in the document; the
      // first player is partner 111 / entry 1_aaaaaaaa, the second 222.
      const html = '<script src="https://cdnapisec.kaltura.com/p/333/sp/33300/embedIframeJs/uiconf_id/9/partner_id/333">'
          '</script><script>'
          "kWidget.embed({'targetId': 'a', 'wid': '_111', 'entry_id': '1_aaaaaaaa'});"
          "kWidget.embed({'targetId': 'b', 'wid': '_222', 'entry_id': '1_bbbbbbbb'});"
          '</script>';
      final embed = KalturaEmbedResolver.findEmbed(html)!;
      expect(embed.partnerId, '111');
      expect(embed.entryId, '1_aaaaaaaa');
    });

    test('entry with no partner in its own embed is never paired with the partner of another embed', () {
      const html = '<script src="https://cdnapisec.kaltura.com/p/333/sp/33300/embedIframeJs/partner_id/333"></script>'
          '<script src="https://cdnapisec.kaltura.com/p/444/sp/44400/embedIframeJs/partner_id/444"></script>'
          "<script>kWidget.embed({'targetId': 'a', 'entry_id': '1_aaaaaaaa'});</script>";
      expect(KalturaEmbedResolver.findEmbed(html), isNull, reason: 'two candidate partners: ambiguous');
    });

    test('player configured in one call and loaded in another pairs only when unambiguous', () {
      const html = "<script>kalturaPlayer.setup({provider: {partnerId: 555}});"
          "player.loadMedia({entryId: '1_cccccccc'});</script>";
      final embed = KalturaEmbedResolver.findEmbed(html)!;
      expect([embed.partnerId, embed.entryId], ['555', '1_cccccccc']);
    });

    test('no kaltura marker, or no well-formed entry id -> no match', () {
      expect(resolver.matches('<script>player({entry_id: "1_ab12cd34", partner_id: 5})</script>'), isFalse);
      expect(resolver.matches('<script>kWidget.embed({wid: "_5", entry_id: "../../x"})</script>'), isFalse);
    });
  });

  group('KalturaEmbedResolver.resolve', () {
    test('anonymous widget session multirequest -> ready clear flavors + HLS playManifest', () async {
      final http = FakeEmbedHttp({apiRoute: ok(fixture('kaltura_multirequest.json'))});
      final info = (await resolver.resolve(requestFor(fixture('kaltura_page.html'), http)))!;

      expect(http.requests, hasLength(1));
      final body = http.requests.single.json as Map;
      expect((body['1'] as Map)['action'], 'startWidgetSession');
      expect((body['1'] as Map)['widgetId'], '_2054321');
      expect((body['2'] as Map)['entryId'], '1_ab12cd34');
      expect((body['3'] as Map)['service'], 'flavorAsset');
      expect((body['3'] as Map)['ks'], '{1:result:ks}');

      expect(info.title, 'Lecture 4: Graphs');
      expect(info.duration, const Duration(seconds: 1834));
      // Not-ready (status 1) and .wvm flavors are dropped; HLS appended last.
      expect(info.formats.map((f) => f.id), ['kaltura-1_src00001', 'kaltura-1_hd000002', 'kaltura-hls']);
      final source = info.formats.first;
      expect(source.url,
          'https://cdnapisec.kaltura.com/p/2054321/sp/205432100/playManifest/entryId/1_ab12cd34'
          '/ks/djJ8MjA1NDMyMXxanonymousWidgetKs%3D%3D/flavorId/1_src00001/format/url/protocol/https/a.mp4');
      expect([source.height, source.bitrate, source.contentLength, source.fps], [1080, 4800000, 1100000 * 1024, 30.0]);
      expect(info.formats.last.container, 'm3u8');
      expect(info.formats.last.url, endsWith('/format/applehttp/protocol/https/a.m3u8'));
    });

    test('only .wvm (Widevine) flavors -> DRM_PROTECTED, no HLS offered', () async {
      final http = FakeEmbedHttp({apiRoute: ok(fixture('kaltura_multirequest_drm.json'))});
      await expectLater(
        resolver.resolve(requestFor(fixture('kaltura_page.html'), http)),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'DRM_PROTECTED')),
      );
    });

    test('KalturaAPIException entries -> null', () async {
      final http = FakeEmbedHttp({apiRoute: ok(fixture('kaltura_multirequest_error.json'))});
      expect(await resolver.resolve(requestFor(fixture('kaltura_page.html'), http)), isNull);
    });

    test('malformed JSON / wrong shapes / HTTP error -> null', () async {
      for (final body in [fixture('malformed.json'), '{}', '[1,2]', '[{}, {}, "x"]', '[{}, {}, [{"id": 5}]]']) {
        final http = FakeEmbedHttp({apiRoute: ok(body)});
        expect(await resolver.resolve(requestFor(fixture('kaltura_page.html'), http)), isNull, reason: body);
      }
      expect(await resolver.resolve(requestFor(fixture('kaltura_page.html'), FakeEmbedHttp({}))), isNull);
    });
  });
}
