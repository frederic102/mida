import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/youtube/youtube_session.dart';

void main() {
  group('YoutubeSession.mergeCookies', () {
    test('merges multiple Set-Cookie values on top of the seed cookies', () {
      final merged = YoutubeSession.mergeCookies(
        const {'SOCS': 'CAI', 'PREF': 'hl=en&tz=UTC'},
        const ['VISITOR_INFO1_LIVE=abc123', 'YSC=xyz789', '__Secure-1PSID=zzz'],
      );

      expect(merged['SOCS'], 'CAI');
      expect(merged['PREF'], 'hl=en&tz=UTC');
      expect(merged['VISITOR_INFO1_LIVE'], 'abc123');
      expect(merged['YSC'], 'xyz789');
      expect(merged['__Secure-1PSID'], 'zzz');
    });

    test('a later Set-Cookie for the same name overwrites the earlier value', () {
      final merged = YoutubeSession.mergeCookies(
        const {'YSC': 'old'},
        const ['YSC=new'],
      );
      expect(merged['YSC'], 'new');
    });

    test('malformed cookie entries (no "=") are skipped, not crashed on', () {
      final merged = YoutubeSession.mergeCookies(
        const {'SOCS': 'CAI'},
        const ['garbage-no-equals-sign', 'YSC=ok'],
      );
      expect(merged.length, 2);
      expect(merged['YSC'], 'ok');
    });

    test('no Set-Cookie values returns just the seed', () {
      final merged = YoutubeSession.mergeCookies(const {'SOCS': 'CAI'}, const []);
      expect(merged, {'SOCS': 'CAI'});
    });
  });

  group('YoutubeSessionData.cookieHeader', () {
    test('joins cookies as a single semicolon-separated header value', () {
      const data = YoutubeSessionData(
        cookies: {'SOCS': 'CAI', 'YSC': 'abc'},
        watchPageStatusCode: 200,
      );
      expect(data.cookieHeader, 'SOCS=CAI; YSC=abc');
    });
  });

  group('YoutubeSession.extractVisitorData', () {
    test('extracts visitorData embedded in watch page HTML', () {
      const html = '<script>var x = {"visitorData":"CgtabcDEF123"};</script>';
      expect(YoutubeSession.extractVisitorData(html), 'CgtabcDEF123');
    });

    test('returns null when visitorData is absent from the page', () {
      const html = '<html><body>no visitor data here</body></html>';
      expect(YoutubeSession.extractVisitorData(html), isNull);
    });
  });
}
