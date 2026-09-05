import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/net/cookie_scope.dart';

void main() {
  group('CookieScope.headerFor', () {
    const cookie = CookieEntry(domain: 'cdn.example.com', path: '/', secure: false, name: 'sid', value: 'abc');

    test('an exact host match is included', () {
      final header = CookieScope.headerFor(
        Uri.parse('https://cdn.example.com/video.mp4'),
        {'cdn.example.com': [cookie]},
      );
      expect(header, 'sid=abc');
    });

    test('a subdomain of a DOMAIN cookie (leading-dot key) is included', () {
      final header = CookieScope.headerFor(
        Uri.parse('https://edge1.cdn.example.com/video.mp4'),
        {'.cdn.example.com': [cookie]},
      );
      expect(header, 'sid=abc');
    });

    test('guard can fail: a HOST-ONLY cookie (no leading-dot key) never widens to match a subdomain', () {
      // A cookie set with no `Domain=` attribute at all is host-only and
      // must only ever be sent back to that exact host - CDP reports it
      // with no leading dot. Stripping the dot before comparing (the
      // bug this fixes) would wrongly widen this to every subdomain too.
      final header = CookieScope.headerFor(
        Uri.parse('https://edge1.cdn.example.com/video.mp4'),
        {'cdn.example.com': [cookie]},
      );
      expect(header, isEmpty);
    });

    test('a HOST-ONLY cookie still matches its own exact host', () {
      final header = CookieScope.headerFor(
        Uri.parse('https://cdn.example.com/video.mp4'),
        {'cdn.example.com': [cookie]},
      );
      expect(header, 'sid=abc');
    });

    test('guard can fail: an unrelated domain never receives this cookie', () {
      // Proves the domain suffix match, not just "any cookie exists", is
      // what gates inclusion - the exact bug class item D exists to fix
      // (format B's cookies sent to format A's unrelated host).
      final header = CookieScope.headerFor(
        Uri.parse('https://other-cdn.example.net/video.mp4'),
        {'cdn.example.com': [cookie]},
      );
      expect(header, isEmpty);
    });

    test('guard can fail: a host that merely ends with the domain as a substring (not a dot-boundary) is rejected', () {
      // "evilcdn.example.com" contains "cdn.example.com" as a raw
      // substring but is not a subdomain of it - a naive `contains`/
      // `endsWith` check without the dot-boundary would wrongly match.
      final header = CookieScope.headerFor(
        Uri.parse('https://evilcdn.example.com/video.mp4'),
        {'cdn.example.com': [cookie]},
      );
      expect(header, isEmpty);
    });

    test('a DOMAIN cookie (leading-dot key) still matches its own exact host too', () {
      final header = CookieScope.headerFor(
        Uri.parse('https://cdn.example.com/video.mp4'),
        {'.cdn.example.com': [cookie]},
      );
      expect(header, 'sid=abc');
    });

    group('path prefix', () {
      const scopedCookie = CookieEntry(domain: 'cdn.example.com', path: '/api', secure: false, name: 'sid', value: 'abc');

      test('an exact path match is included', () {
        final header = CookieScope.headerFor(
          Uri.parse('https://cdn.example.com/api'),
          {'cdn.example.com': [scopedCookie]},
        );
        expect(header, 'sid=abc');
      });

      test('a path nested under the cookie path is included', () {
        final header = CookieScope.headerFor(
          Uri.parse('https://cdn.example.com/api/videos/1.mp4'),
          {'cdn.example.com': [scopedCookie]},
        );
        expect(header, 'sid=abc');
      });

      test('guard can fail: a path that merely starts with the same characters (no "/" boundary) is rejected', () {
        // "/apix" starts with "/api" as a raw string but is not under it -
        // a bare `startsWith` without the boundary rule would wrongly match.
        final header = CookieScope.headerFor(
          Uri.parse('https://cdn.example.com/apix'),
          {'cdn.example.com': [scopedCookie]},
        );
        expect(header, isEmpty);
      });

      test('guard can fail: a sibling path outside the cookie path is rejected', () {
        final header = CookieScope.headerFor(
          Uri.parse('https://cdn.example.com/other'),
          {'cdn.example.com': [scopedCookie]},
        );
        expect(header, isEmpty);
      });

      test('a cookie scoped to "/" matches every path', () {
        const rootCookie = CookieEntry(domain: 'cdn.example.com', path: '/', secure: false, name: 'sid', value: 'abc');
        final header = CookieScope.headerFor(
          Uri.parse('https://cdn.example.com/anything/here'),
          {'cdn.example.com': [rootCookie]},
        );
        expect(header, 'sid=abc');
      });
    });

    test('guard can fail: a secure cookie is withheld from a plain-http request', () {
      const secureCookie = CookieEntry(domain: 'cdn.example.com', path: '/', secure: true, name: 'sid', value: 'abc');
      final header = CookieScope.headerFor(
        Uri.parse('http://cdn.example.com/video.mp4'),
        {'cdn.example.com': [secureCookie]},
      );
      expect(header, isEmpty);
    });

    test('a secure cookie is included over https', () {
      const secureCookie = CookieEntry(domain: 'cdn.example.com', path: '/', secure: true, name: 'sid', value: 'abc');
      final header = CookieScope.headerFor(
        Uri.parse('https://cdn.example.com/video.mp4'),
        {'cdn.example.com': [secureCookie]},
      );
      expect(header, 'sid=abc');
    });

    test('multiple matching cookies join with "; "', () {
      const a = CookieEntry(domain: 'cdn.example.com', path: '/', secure: false, name: 'a', value: '1');
      const b = CookieEntry(domain: 'cdn.example.com', path: '/', secure: false, name: 'b', value: '2');
      final header = CookieScope.headerFor(
        Uri.parse('https://cdn.example.com/video.mp4'),
        {'cdn.example.com': [a, b]},
      );
      expect(header, 'a=1; b=2');
    });

    test('an empty cookiesByDomain yields an empty string', () {
      expect(CookieScope.headerFor(Uri.parse('https://cdn.example.com/v.mp4'), const {}), isEmpty);
    });
  });
}
