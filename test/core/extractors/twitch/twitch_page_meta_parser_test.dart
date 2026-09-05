import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/twitch/twitch_page_meta_parser.dart';

void main() {
  group('TwitchPageMetaParser.parse against a real captured watch-page snippet', () {
    test('splits og:title into title + author and reads duration/thumbnail', () {
      const html = '<html><head>'
          '<meta property="og:title" content="i play witcher vampire r P g - shroud on Twitch">'
          '<meta property="og:image" content="https://static-cdn.jtvnw.net/cf_vods/thumb0-640x360.jpg">'
          '<meta property="og:video:duration" content="26228">'
          '</head></html>';

      final meta = const TwitchPageMetaParser().parse(html);
      expect(meta.title, 'i play witcher vampire r P g');
      expect(meta.author, 'shroud');
      expect(meta.thumbnailUrl, 'https://static-cdn.jtvnw.net/cf_vods/thumb0-640x360.jpg');
      expect(meta.duration, const Duration(seconds: 26228));
    });

    test('falls back to the raw title and null author/duration when the page has none', () {
      final meta = const TwitchPageMetaParser().parse('<html><head></head></html>');
      expect(meta.title, isNull);
      expect(meta.author, isNull);
      expect(meta.duration, isNull);
    });

    test('unescapes HTML entities in the title', () {
      const html = '<meta property="og:title" content="Rock &amp; Roll - streamer on Twitch">';
      final meta = const TwitchPageMetaParser().parse(html);
      expect(meta.title, 'Rock & Roll');
    });
  });
}
