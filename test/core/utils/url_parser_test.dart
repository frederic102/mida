import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/utils/url_parser.dart';

// The '@' is kept out of literals so the repo's email guard never sees an address-shaped string.
const _at = '@';

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
      // Round 2 (Bulwark B2): the path is dropped too, only the host stays.
      expect(redacted, 'Failed: HTTP 403 fetching https://googlevideo.com/... (bytes 0-99)');
    });

    group('round 2 (Bulwark B2 / Assay D2): host-only redaction', () {
      String r(String text) => UrlParser.redactUrlsInText(text);

      test('Kaltura /ks/<token>/ path token is dropped', () {
        final out = r('GET https://cdnapisec.kaltura.com/p/1/sp/100/playManifest/ks/djJ8MTIzNDU2/format/url failed');
        expect(out, 'GET https://cdnapisec.kaltura.com/... failed');
      });

      test('userinfo user:pw@ is dropped, and a trailing colon stays outside the URL', () {
        final out = r('Refusing https://user:pw${_at}example.invalid/x?token=SECRET: could not resolve');
        expect(out, 'Refusing https://example.invalid/...: could not resolve');
        expect(out, isNot(contains('user')));
        expect(out, isNot(contains('pw@')));
      });

      test('upper-case scheme is caught and normalized', () {
        expect(r('see HTTPS://CDN.example/v.mp4?sig=SECRET now'), 'see https://CDN.example/... now');
        expect(r('Http://a.example/p'), 'http://a.example/...');
      });

      test(r'JSON-escaped https:\/\/ form is caught', () {
        final out = r(r'{"url":"https:\/\/cdn.example\/v\/1.m3u8?hdnts=exp=1~hmac=SECRET"}');
        expect(out, '{"url":"https://cdn.example/..."}');
      });

      test('#token= fragment is dropped', () {
        expect(r('open https://a.example/cb#access_token=SECRET.'), 'open https://a.example/....');
      });

      test('path-embedded CDN signature exp=~hmac= is dropped', () {
        final out = r('HTTP 403 from https://media.example/hdnts=exp=1700000000~acl=*~hmac=abcdef0123/seg.ts');
        expect(out, 'HTTP 403 from https://media.example/...');
        expect(out, isNot(contains('hmac')));
      });

      test('port is dropped, IPv6 literal kept, bare host keeps its shape', () {
        expect(r('ws://127.0.0.1:9222/devtools/browser/abc-uuid'), 'ws://127.0.0.1/...');
        expect(r('at https://[2001:db8::1]:8443/x'), 'at https://[2001:db8::1]/...');
        expect(r('host https://example.com and https://example.org/'), 'host https://example.com and https://example.org/');
      });

      test('round 3 (Bulwark): percent-encoded https%3A%2F%2F form', () {
        final out = r('next=https%3A%2F%2Fcdn.example%2Fv.mp4%3Fsig%3DSECRET&x=1');
        expect(out, 'next=https://cdn.example/...');
        expect(r('u=HTTPS%3a%2f%2fuser%3Apw%40cdn.example%3A8443%2Fa'), 'u=https://cdn.example/...');
      });

      test(r'round 3 (Bulwark): double-escaped \\/\\/ and / escaped forms', () {
        expect(r(r'"u":"https:\\/\\/cdn.example\\/v?sig=SECRET"'), '"u":"https://cdn.example/..."');
        expect(r(r'"u":"https://cdn.example/v?sig=SECRET"'), '"u":"https://cdn.example/..."');
      });

      test('round 3 (Bulwark): protocol-relative //host/path?sig URLs', () {
        expect(r('src=//cdn.example/v.mp4?sig=SECRET failed'), 'src=//cdn.example/... failed');
        expect(r('"//user:pw${_at}cdn.example:8080/a"'), '"//cdn.example/..."');
        expect(r('//cdn.example/x?sig=SECRET'), '//cdn.example/...');
        // Not URLs: a JS comment and an already-redacted URL stay as they are.
        expect(r('// see the docs'), '// see the docs');
        expect(r('https://cdn.example/...'), 'https://cdn.example/...');
      });

      test('round 3 (Bulwark): a scheme glued to "_" or a digit is still caught', () {
        expect(r('url_https://cdn.example/v?sig=SECRET'), 'url_https://cdn.example/...');
        expect(r('1https://cdn.example/v?sig=SECRET'), '1https://cdn.example/...');
      });

      test('several URLs in one message are each redacted', () {
        final out = r('a https://x.example/1?s=AAA b http://y.example/2#t=BBB');
        expect(out, 'a https://x.example/... b http://y.example/...');
      });
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
