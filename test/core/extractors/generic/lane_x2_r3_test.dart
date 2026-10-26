import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/facebook/facebook_video_json_parser.dart';
import 'package:mida/core/extractors/generic/embeds/kaltura.dart';
import 'package:mida/core/extractors/generic/generic_extractor.dart';
import 'package:mida/core/extractors/generic/media_url_probe.dart';
import 'package:mida/core/extractors/generic/stage_deadline.dart';

import 'generic_test_support.dart';

/// A bare-candidate probe that never answers (and no step-0 network).
class _StallingProbe extends MediaUrlProbe {
  _StallingProbe() : super(allowPrivateHosts: true);

  @override
  Future<String?> containerFromContentType(Uri url, {StageDeadline? deadline}) async => null;

  @override
  Future<bool> isPlausibleMediaCandidate(Uri url, {StageDeadline? deadline}) => Completer<bool>().future;
}

/// astra round 3 (Lane X2): attribution and ordering edge cases.
void main() {
  const parser = FacebookVideoJsonParser();

  test('raw: a conflicted progressive_urls entry credits nothing to its owner', () {
    const html = '<script>v({"video_id":"3","progressive_urls":[{"progressive_url":"https://cdn.example/a.mp4",'
        '"progressive_url":"https://cdn.example/b.mp4"}]})</script>';
    expect(parser.parse(html, videoId: '3').video, isNull);
  });

  test('kaltura: commented-out fields and braces never count', () {
    for (final html in [
      '<script>kWidget.embed({wid:"_111", /* old entry_id:"1_wrong123" */ entry_id:"1_right123"});</script>',
      '<script>kWidget.embed({wid:"_111", // entry_id:"1_wrong123"\n entry_id:"1_right123"});</script>',
      '<script>kWidget.embed({wid:"_111", /* } */ entry_id:"1_right123"});</script>',
    ]) {
      final embed = KalturaEmbedResolver.findEmbed(html)!;
      expect([embed.partnerId, embed.entryId], ['111', '1_right123'], reason: html);
    }
  });

  test('facebook: every spelling of type=application/json reaches the JSON walker', () {
    const body = '{"v":{"id":"7","title":"T7","d":{"playable_url":"https://v.fbcdn.net/7.mp4"}}}';
    for (final open in [
      "<script type='application/json'>",
      '<script type = "application/json">',
      '<script type=application/json>',
    ]) {
      final data = parser.parse('$open$body</script>', videoId: '7');
      // Only the JSON walker inherits id 7 into the delivery map and reads T7.
      expect(data.video?.id, '7', reason: open);
      expect(data.meta.title, 'T7', reason: open);
    }
  });

  test('a stalling bare-URL probe cannot starve a working <video src> mp4', () async {
    final server = await FakePageServer.start();
    addTearDown(server.close);
    server.body = '<html><body><video src="/media/real.mp4"></video>'
        '<script>var beacon = "https://ads.example/creative.mp4";</script></body></html>';
    final extractor = GenericExtractor(
      allowPrivateHosts: true,
      probe: _StallingProbe(),
      staticStageDeadlineForTesting: const Duration(seconds: 2),
    );
    final info = await extractor.extract(server.urlFor('/post'));
    expect(info.formats.single.url, server.urlFor('/media/real.mp4').toString());
  });
}
