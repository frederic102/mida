import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/facebook/facebook_raw_literal_scanner.dart';
import 'package:mida/core/extractors/facebook/facebook_video_json_parser.dart';

import 'facebook_fake_server.dart';

/// Shape D (inline JS object literals): object-level attribution only.
void main() {
  const parser = FacebookVideoJsonParser();

  test('canonical URL names 111, inline JS only describes recommendation 222: no video', () {
    const html = '<html><head><link rel="canonical" href="https://www.facebook.com/reel/111"></head><body>'
        '<script>rec.init({"video_id":"222","playable_url":"https:\\/\\/video.xx.fbcdn.net\\/222_sd.mp4",'
        '"playable_url_quality_hd":"https:\\/\\/video.xx.fbcdn.net\\/222_hd.mp4"});</script></body></html>';
    expect(parser.parse(html, videoId: '111').video, isNull, reason: '222 media must never be returned as 111');
    expect(parser.parse(html, videoId: '222').video!.hdUrl, 'https://video.xx.fbcdn.net/222_hd.mp4');
  });

  test('HD and SD in separate id-less objects are ambiguous: never merged into one node', () {
    const html = '<a href="/reel/111">x</a><script>'
        'a({"playable_url_quality_hd":"https:\\/\\/v.fbcdn.net\\/hd.mp4"});'
        'b({"playable_url":"https:\\/\\/v.fbcdn.net\\/sd.mp4"});</script>';
    expect(parser.parse(html, videoId: '111').video, isNull);
    expect(parser.parse(html).video, isNull, reason: 'no id and two candidates: ambiguous');
  });

  test('HD of the requested object is never paired with SD of another object', () {
    const html = '<script>'
        'p({"video_id":"111","playable_url_quality_hd":"https:\\/\\/v.fbcdn.net\\/111_hd.mp4"});'
        'p({"video_id":"222","playable_url":"https:\\/\\/v.fbcdn.net\\/222_sd.mp4"});</script>';
    final node = parser.parse(html, videoId: '111').video!;
    expect(node.id, '111');
    expect(node.hdUrl, 'https://v.fbcdn.net/111_hd.mp4');
    expect(node.sdUrl, isNull);
  });

  test('fields of a nested object stay with that object, not its parent', () {
    const html = '<script>x({"video_id":"111","related":{"video_id":"222",'
        '"playable_url":"https:\\/\\/v.fbcdn.net\\/222.mp4"},"title":"t"});</script>';
    expect(parser.parse(html, videoId: '111').video, isNull);
    final nodes = FacebookRawLiteralScanner.scan(html);
    expect(nodes.single.id, '222');
  });

  test('numeric (unquoted) id is attributed too', () {
    const html = '<script>p({id:1, "id":111,"browser_native_sd_url":"https:\\/\\/v.fbcdn.net\\/a.mp4"})</script>';
    expect(parser.parse(html, videoId: '111').video!.sdUrl, 'https://v.fbcdn.net/a.mp4');
  });

  test('Shape B in raw JS: progressive_urls with quality, dash_manifests, credited to the owning object', () {
    const html = '<script>d.load({"video_id":"333","progressive_urls":['
        '{"progressive_url":"https:\\/\\/v.fbcdn.net\\/333_sd.mp4","metadata":{"quality":"SD"}},'
        '{"progressive_url":"https:\\/\\/v.fbcdn.net\\/333_hd.mp4","metadata":{"quality":"HD"}}],'
        '"dash_manifests":[{"manifest_xml":"<MPD><\\/MPD>"}]});</script>';
    final node = parser.parse(html, videoId: '333').video!;
    expect(node.hdUrl, 'https://v.fbcdn.net/333_hd.mp4');
    expect(node.sdUrl, 'https://v.fbcdn.net/333_sd.mp4');
    expect(node.dashXml, '<MPD></MPD>');
  });

  test('an apostrophe in a JS comment does not derail the scan', () {
    const html = "<script>// don't break\nv({\"video_id\":\"4\",\"playable_url\":\"https:\\/\\/v.fbcdn.net\\/4.mp4\"})</script>";
    expect(parser.parse(html, videoId: '4').video!.sdUrl, 'https://v.fbcdn.net/4.mp4');
  });

  test('existing reel fixture (single object with both qualities) still resolves', () {
    final node = parser.parse(fixture('facebook_reel_inline_js.html'), videoId: '3333333333333').video!;
    expect(node.hdUrl, contains('reel_hd.mp4'));
    expect(node.sdUrl, contains('reel_sd.mp4'));
  });
}
