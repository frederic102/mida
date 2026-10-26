import 'package:flutter_test/flutter_test.dart';
import 'package:mida/features/download/screens/url_batch.dart';

void main() {
  group('UrlBatch.parse', () {
    test('splits on newlines, spaces and tabs, keeps order, drops repeats', () {
      final batch = UrlBatch.parse(
        ' https://a.example/1\r\nhttps://b.example/2  https://a.example/1\thttp://c.example/3\n\n',
      );
      expect(batch.urls, ['https://a.example/1', 'https://b.example/2', 'http://c.example/3']);
      expect(batch.skipped, 0);
    });

    test('counts non-link tokens as skipped', () {
      final batch = UrlBatch.parse('watch this https://a.example/1 ftp://files.example/x mailto:a@b.c');
      expect(batch.urls, ['https://a.example/1']);
      expect(batch.skipped, 4);
    });

    test('empty and whitespace-only text is empty', () {
      expect(UrlBatch.parse('').isEmpty, isTrue);
      expect(UrlBatch.parse(' \n\t ').skipped, 0);
    });
  });

  group('clipboardSuggestion', () {
    List<String>? suggest(String? clip, {Set<String> queued = const {}, String field = '', String? dismissed}) =>
        clipboardSuggestion(clipboardText: clip, queuedUrls: queued, fieldText: field, dismissedText: dismissed);

    test('offers http and https links', () {
      expect(suggest('https://www.youtube.com/watch?v=abc'), ['https://www.youtube.com/watch?v=abc']);
      expect(suggest('  http://vimeo.com/1  '), ['http://vimeo.com/1']);
    });

    test('ignores anything that is not an http(s) link', () {
      for (final clip in [
        null,
        '',
        'just some copied text',
        'ftp://files.example/movie.mp4',
        'javascript:alert(1)',
        'file:///C:/Users/me/a.mp4',
        'mailto:someone',
        'https://',
        'www.youtube.com/watch?v=abc',
      ]) {
        expect(suggest(clip), isNull, reason: 'clipboard: $clip');
      }
    });

    test('hides links already queued or already in the field', () {
      const url = 'https://a.example/1';
      expect(suggest(url, queued: {url}), isNull);
      expect(suggest(url, field: 'https://z.example/0\n$url'), isNull);
    });

    test('hides clipboard text the user dismissed, until the clipboard changes', () {
      const url = 'https://a.example/1';
      expect(suggest(url, dismissed: url), isNull);
      expect(suggest('https://b.example/2', dismissed: url), ['https://b.example/2']);
    });

    test('with several links, offers only the new ones', () {
      expect(
        suggest('https://a.example/1\nhttps://b.example/2\nhttps://c.example/3', queued: {'https://b.example/2'}),
        ['https://a.example/1', 'https://c.example/3'],
      );
    });

    test('linkHost drops www.', () {
      expect(linkHost('https://www.youtube.com/watch?v=1'), 'youtube.com');
      expect(linkHost('https://m.youtube.com/watch?v=1'), 'm.youtube.com');
    });
  });
}
