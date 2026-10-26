import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/facebook/facebook_video_json_parser.dart';

/// Round-2 attribution rules: id-less JSON maps never merge, comments and
/// template literals never count, a JSON recommendation never blocks the
/// raw-literal target.
void main() {
  const parser = FacebookVideoJsonParser();

  group('JSON blocks: id-less maps keep their identity', () {
    test('two id-less objects carrying different videos are rejected, never merged', () {
      const html = '<a href="/reel/55">x</a><script type="application/json">{'
          '"a":{"playable_url_quality_hd":"https://v.fbcdn.net/x_hd.mp4"},'
          '"b":{"playable_url":"https://v.fbcdn.net/y_sd.mp4"}}</script>';
      expect(parser.parse(html, videoId: '55').video, isNull);
      expect(parser.parse(html).video, isNull, reason: 'no id and two id-less videos: ambiguous');
    });

    test('a single id-less JSON object is still accepted when the page mentions the id', () {
      const html = '<a href="/reel/56">x</a><script type="application/json">{'
          '"a":{"playable_url_quality_hd":"https://v.fbcdn.net/x_hd.mp4","playable_url":"https://v.fbcdn.net/x_sd.mp4"}}'
          '</script>';
      final node = parser.parse(html, videoId: '56').video!;
      expect([node.hdUrl, node.sdUrl], ['https://v.fbcdn.net/x_hd.mp4', 'https://v.fbcdn.net/x_sd.mp4']);
    });
  });

  group('raw literals: comments and template literals are skipped', () {
    test('a block-commented wrong playable_url never wins', () {
      const html = '<script>v.init({"id":"123", /* "playable_url":"https://cdn.test/wrong.mp4", */ '
          '"playable_url":"https://cdn.test/right.mp4"});</script>';
      expect(parser.parse(html, videoId: '123').video!.sdUrl, 'https://cdn.test/right.mp4');
    });

    test('a line-commented wrong playable_url never wins', () {
      const html = '<script>v.init({"id":"123",\n// "playable_url":"https://cdn.test/wrong.mp4",\n'
          '"playable_url":"https://cdn.test/right.mp4"});</script>';
      expect(parser.parse(html, videoId: '123').video!.sdUrl, 'https://cdn.test/right.mp4');
    });

    test('an object written inside a template literal is not a candidate', () {
      const html = '<script>const doc = `{"video_id":"123","playable_url":"https://cdn.test/wrong.mp4"} \${x}`;'
          'v.init({"video_id":"123","playable_url":"https://cdn.test/right.mp4"});</script>';
      expect(parser.parse(html, videoId: '123').video!.sdUrl, 'https://cdn.test/right.mp4');
    });

    test('one object writing a playback key twice with different values is ambiguous', () {
      const html = '<script>v({"video_id":"123","playable_url":"https://cdn.test/a.mp4",'
          '"playable_url":"https://cdn.test/b.mp4"})</script>';
      expect(parser.parse(html, videoId: '123').video, isNull);
    });
  });

  group('raw fallback when JSON has no attributable video', () {
    const jsonRecommendation =
        '<script type="application/json">{"v":{"id":"999","playable_url":"https://v.fbcdn.net/999.mp4"}}</script>';

    test('JSON recommendation 999 does not block the inline-JS target 123', () {
      const html = '$jsonRecommendation<script>p({"video_id":"123","playable_url":"https://v.fbcdn.net/123.mp4"})</script>';
      final node = parser.parse(html, videoId: '123').video!;
      expect(node.id, '123');
      expect(node.sdUrl, 'https://v.fbcdn.net/123.mp4');
    });

    test('with JSON media present, an id-less raw object is not credited to the requested id', () {
      const html = '$jsonRecommendation<a href="/reel/123">x</a>'
          '<script>p({"playable_url":"https://v.fbcdn.net/unknown.mp4"})</script>';
      expect(parser.parse(html, videoId: '123').video, isNull);
    });

    test('a JSON block is never re-read as raw JS (its id-less delivery map stays with 999)', () {
      const html = '<a href="/reel/123">x</a><script type="application/json">'
          '{"v":{"id":"999","delivery":{"playable_url":"https://v.fbcdn.net/999.mp4"}}}</script>';
      expect(parser.parse(html, videoId: '123').video, isNull);
    });
  });
}
