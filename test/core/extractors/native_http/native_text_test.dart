import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/native_http/native_text.dart';

void main() {
  group('NativeText.decodeEntities', () {
    test('decodes named, decimal and hex entities in one pass', () {
      expect(NativeText.decodeEntities('&quot;a&quot; &amp; &#39;b&#x27; &lt;c&gt;'), '"a" & \'b\' <c>');
    });

    test('is a single pass: &amp;quot; becomes &quot;, not a quote', () {
      expect(NativeText.decodeEntities('&amp;quot;'), '&quot;');
    });

    test('leaves unknown and malformed entities alone', () {
      expect(NativeText.decodeEntities('&bogus; &#0; &#xD800; & x'), '&bogus; &#0; &#xD800; & x');
    });
  });

  group('NativeText.attributes', () {
    test('reads double and single quoted values, lowercases names, decodes entities', () {
      final attrs = NativeText.attributes('''<video DATA-Sources='[{"src":"a&amp;b"}]' data-poster-url="https://x/p.jpg?a=1&amp;b=2" controls>''');
      expect(attrs['data-sources'], '[{"src":"a&b"}]');
      expect(attrs['data-poster-url'], 'https://x/p.jpg?a=1&b=2');
      expect(attrs.containsKey('controls'), isFalse);
    });
  });

  group('NativeText.httpsUrl', () {
    test('forces https and accepts protocol-relative URLs', () {
      expect(NativeText.httpsUrl('http://a.test/x.mp4'), 'https://a.test/x.mp4');
      expect(NativeText.httpsUrl('//a.test/x.mp4'), 'https://a.test/x.mp4');
      expect(NativeText.httpsUrl(' https://a.test/x.mp4 '), 'https://a.test/x.mp4');
    });

    test('rejects non-URLs, other schemes, whitespace and non-strings', () {
      for (final bad in ['', 'a.test/x', 'ftp://a.test/x', 'javascript:alert(1)', 'https://', 'https://a.test/a b', 'https://a.test/\nx','data:video/mp4;base64,AAAA']) {
        expect(NativeText.httpsUrl(bad), isNull, reason: bad);
      }
      expect(NativeText.httpsUrl(42), isNull);
      expect(NativeText.httpsUrl(null), isNull);
    });
  });

  test('positiveInt accepts numbers and digit strings, rejects zero, negatives and junk', () {
    expect(NativeText.positiveInt(720), 720);
    expect(NativeText.positiveInt(720.0), 720);
    expect(NativeText.positiveInt('1080'), 1080);
    expect(NativeText.positiveInt(0), isNull);
    expect(NativeText.positiveInt(-3), isNull);
    expect(NativeText.positiveInt('abc'), isNull);
    expect(NativeText.positiveInt(double.nan), isNull);
    expect(NativeText.positiveInt(null), isNull);
  });

  test('clip keeps whole runes', () {
    expect(NativeText.clip('abcdef', 3), 'abc');
    expect(NativeText.clip('ab', 3), 'ab');
    expect(NativeText.clip('\u{1F600}\u{1F600}x', 2), '\u{1F600}\u{1F600}');
  });
}
