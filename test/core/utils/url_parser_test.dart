import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/utils/url_parser.dart';

void main() {
  group('UrlParser.extractYouTubeVideoId', () {
    test('extracts the id from a /shorts/ URL', () {
      expect(
        UrlParser.extractYouTubeVideoId('https://www.youtube.com/shorts/dQw4w9WgXcQ'),
        'dQw4w9WgXcQ',
      );
    });

    test('extracts the id from a /shorts/ URL with a trailing query string', () {
      expect(
        UrlParser.extractYouTubeVideoId('https://www.youtube.com/shorts/dQw4w9WgXcQ?feature=share'),
        'dQw4w9WgXcQ',
      );
    });

    test('still extracts the id from a youtu.be short link', () {
      expect(UrlParser.extractYouTubeVideoId('https://youtu.be/dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
    });

    test('still extracts the id from a watch?v= URL', () {
      expect(
        UrlParser.extractYouTubeVideoId('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
        'dQw4w9WgXcQ',
      );
    });

    test('returns null for a youtube.com URL with neither v= nor /shorts/', () {
      expect(UrlParser.extractYouTubeVideoId('https://www.youtube.com/feed/subscriptions'), isNull);
    });

    test('returns null for a non-YouTube URL', () {
      expect(UrlParser.extractYouTubeVideoId('https://example.com/watch?v=abc'), isNull);
    });

    test('a lookalike host with youtube.com as a prefix, not a suffix, is rejected', () {
      // Plain substring matching would treat this as YouTube; it is not.
      expect(UrlParser.extractYouTubeVideoId('https://youtube.com.evil.example/watch?v=abc'), isNull);
    });

    test('a lookalike host with youtube.com glued on without a dot is rejected', () {
      expect(UrlParser.extractYouTubeVideoId('https://evil-youtube.com/watch?v=abc'), isNull);
    });

    test('a real subdomain of youtube.com is still accepted', () {
      expect(UrlParser.extractYouTubeVideoId('https://m.youtube.com/watch?v=abc'), 'abc');
    });
  });

  group('UrlParser.detectPlatform still recognizes youtube for shorts URLs', () {
    test('shorts host is detected as youtube', () {
      expect(
        UrlParser.detectPlatform('https://www.youtube.com/shorts/dQw4w9WgXcQ'),
        PlatformType.youtube,
      );
    });
  });

  group('UrlParser.detectPlatform host matching (REJECT fix: exact/suffix, not substring)', () {
    test('youtube.com.evil.example is not detected as youtube', () {
      expect(UrlParser.detectPlatform('https://youtube.com.evil.example/watch?v=abc'), isNot(PlatformType.youtube));
    });

    test('evil-youtube.com is not detected as youtube', () {
      expect(UrlParser.detectPlatform('https://evil-youtube.com/watch?v=abc'), isNot(PlatformType.youtube));
    });

    test('a real youtube.com subdomain is still detected as youtube', () {
      expect(UrlParser.detectPlatform('https://music.youtube.com/watch?v=abc'), PlatformType.youtube);
    });

    test('twitter.com.evil.example is not detected as twitter', () {
      expect(UrlParser.detectPlatform('https://twitter.com.evil.example/status/1'), isNot(PlatformType.twitter));
    });
  });

  group('UrlParser.stripQuery / redactUrlsInText', () {
    test('stripQuery removes the query string but keeps the path', () {
      final uri = Uri.parse('https://googlevideo.com/videoplayback?sig=SECRET&itag=137');
      expect(UrlParser.stripQuery(uri).toString(), 'https://googlevideo.com/videoplayback');
    });

    test('redactUrlsInText strips the query string of a URL embedded in a message', () {
      const message = 'Failed: HTTP 403 fetching https://googlevideo.com/videoplayback?sig=SECRET&itag=137 (bytes 0-99)';
      final redacted = UrlParser.redactUrlsInText(message);
      expect(redacted, isNot(contains('SECRET')));
      expect(redacted, contains('https://googlevideo.com/videoplayback'));
    });

    test('redactUrlsInText leaves text with no URL untouched', () {
      const message = 'plain error, no url here';
      expect(UrlParser.redactUrlsInText(message), message);
    });
  });

  group('UrlParser.extractTwitterStatusId', () {
    test('accepts twitter.com, x.com and mobile.twitter.com /status/ URLs', () {
      expect(UrlParser.extractTwitterStatusId(Uri.parse('https://twitter.com/nasa/status/123')), '123');
      expect(UrlParser.extractTwitterStatusId(Uri.parse('https://x.com/nasa/status/123')), '123');
      expect(UrlParser.extractTwitterStatusId(Uri.parse('https://mobile.twitter.com/nasa/status/123')), '123');
    });

    test('accepts the /i/status/ shape', () {
      expect(UrlParser.extractTwitterStatusId(Uri.parse('https://x.com/i/status/123')), '123');
    });

    test('rejects non-status URLs, non-numeric ids and unrelated hosts', () {
      expect(UrlParser.extractTwitterStatusId(Uri.parse('https://x.com/nasa')), isNull);
      expect(UrlParser.extractTwitterStatusId(Uri.parse('https://x.com/nasa/status/abc')), isNull);
      expect(UrlParser.extractTwitterStatusId(Uri.parse('https://evil.example/status/123')), isNull);
    });
  });
}
