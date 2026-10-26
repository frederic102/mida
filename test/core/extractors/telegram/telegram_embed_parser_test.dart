import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/telegram/telegram_embed_parser.dart';

String _player(String video, {String time = '0:10', String href = 'https://t.me/chan_x/5'}) =>
    '<div class="tgme_widget_message" data-post="chan_x/5">'
    '<a class="tgme_widget_message_video_player" href="$href">$video<time>$time</time></a></div>';

void main() {
  const parser = TelegramEmbedParser();

  group('TelegramEmbedParser', () {
    test('round video (video message) player is read like a normal one', () {
      const html = '<div class="tgme_widget_message" data-post="chan_x/6">'
          '<a class="tgme_widget_message_roundvideo_player js-message_roundvideo_player" href="https://t.me/chan_x/6">'
          '<video src="https://cdn4.cdn-telegram.org/file/round.mp4" class="tgme_widget_message_roundvideo"></video>'
          '<time class="tgme_widget_message_roundvideo_duration">0:07</time></a></div>';
      final embed = parser.parse(html);
      expect(embed.state, TelegramEmbedState.post);
      expect(embed.messages.single.videos.single.url, endsWith('round.mp4'));
      expect(embed.messages.single.videos.single.duration, const Duration(seconds: 7));
      expect(embed.messages.single.videos.single.linkedPost, 'chan_x/6');
    });

    test('a plain http source is upgraded to https; other schemes are dropped', () {
      final upgraded = parser.parse(_player('<video src="http://cdn4.cdn-telegram.org/f.mp4"></video>'));
      expect(upgraded.messages.single.videos.single.url, 'https://cdn4.cdn-telegram.org/f.mp4');
      final dropped = parser.parse(_player('<video src="javascript:alert(1)"></video>'));
      expect(dropped.messages.single.videos, isEmpty);
      expect(dropped.messages.single.hasVideoPlayerWithoutSource, isTrue);
    });

    test('implausible clock text yields no duration instead of a wrong one', () {
      for (final time in ['0:75', 'abc', '', '1:2:3:4']) {
        final embed = parser.parse(_player('<video src="https://c.example/f.mp4"></video>', time: time));
        expect(embed.messages.single.videos.single.duration, isNull, reason: 'time "$time"');
      }
    });

    test('a player linking to a foreign host is not trusted as a post link', () {
      final embed = parser.parse(_player('<video src="https://c.example/f.mp4"></video>', href: 'https://evil.test/chan_x/5'));
      expect(embed.messages.single.videos.single.linkedPost, isNull);
    });

    test('error box wording decides notFound vs restricted vs unknown', () {
      String box(String text) => '<div class="tgme_widget_message_error">$text</div>';
      expect(parser.parse(box('Post not found')).state, TelegramEmbedState.notFound);
      expect(parser.parse(box('This channel is private')).state, TelegramEmbedState.restricted);
      expect(parser.parse(box('Restricted for sensitive content')).state, TelegramEmbedState.noPreview);
      expect(parser.parse('<div class="tgme_page">Welcome to channel foo</div>').state, TelegramEmbedState.noPreview);
      expect(parser.parse('<div class="tgme_page">This group is private</div>').state, TelegramEmbedState.restricted);
      expect(parser.parse(box('Something odd happened')).state, TelegramEmbedState.unknown);
      expect(parser.parse('').state, TelegramEmbedState.unknown);
    });
  });
}
