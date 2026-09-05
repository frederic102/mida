import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/oembed_scanner.dart';

void main() {
  group('OembedScanner.findOembedUrl', () {
    test('finds and resolves a relative oEmbed discovery link', () {
      const html = '''
        <html><head>
          <link rel="alternate" type="application/json+oembed" href="/oembed?url=https%3A%2F%2Fexample.com%2Fp%2F1">
        </head><body></body></html>
      ''';
      final result = OembedScanner.findOembedUrl(html, Uri.parse('https://example.com/p/1'));

      expect(result, Uri.parse('https://example.com/oembed?url=https%3A%2F%2Fexample.com%2Fp%2F1'));
    });

    test('single-quoted link tag is also recognized', () {
      const html = '''<link type='application/json+oembed' href='https://example.com/oembed?url=1'>''';
      final result = OembedScanner.findOembedUrl(html, Uri.parse('https://example.com/p/1'));

      expect(result, Uri.parse('https://example.com/oembed?url=1'));
    });

    test('no oembed link on the page returns null', () {
      const html = '<html><head><title>Plain</title></head><body></body></html>';
      expect(OembedScanner.findOembedUrl(html, Uri.parse('https://example.com/p/1')), isNull);
    });

    test('a non-http(s) href (e.g. javascript:) is rejected', () {
      const html = '''<link type="application/json+oembed" href="javascript:void(0)">''';
      expect(OembedScanner.findOembedUrl(html, Uri.parse('https://example.com/p/1')), isNull);
    });
  });

  group('OembedScanner.findIframeSrcInOembedJson', () {
    test('extracts and resolves the iframe src from the html field', () {
      const json = r'{"type":"video","html":"<iframe src=\"https://player.example.com/embed/42\" '
          r'width=\"640\" height=\"360\" frameborder=\"0\"></iframe>"}';
      final result = OembedScanner.findIframeSrcInOembedJson(json, Uri.parse('https://example.com/oembed'));

      expect(result, Uri.parse('https://player.example.com/embed/42'));
    });

    test('a protocol-relative iframe src is resolved against the oEmbed URL', () {
      const json = r'{"html":"<iframe src=\"//player.example.com/embed/42\"></iframe>"}';
      final result = OembedScanner.findIframeSrcInOembedJson(json, Uri.parse('https://example.com/oembed'));

      expect(result, Uri.parse('https://player.example.com/embed/42'));
    });

    test('malformed JSON returns null instead of throwing', () {
      expect(
        () => OembedScanner.findIframeSrcInOembedJson('not json at all {', Uri.parse('https://example.com/oembed')),
        returnsNormally,
      );
      expect(
        OembedScanner.findIframeSrcInOembedJson('not json at all {', Uri.parse('https://example.com/oembed')),
        isNull,
      );
    });

    test('a JSON body with no html field returns null', () {
      const json = '{"type":"video","title":"A Video"}';
      expect(OembedScanner.findIframeSrcInOembedJson(json, Uri.parse('https://example.com/oembed')), isNull);
    });

    test('an html field with no iframe inside it returns null', () {
      const json = '{"html":"<p>No player here</p>"}';
      expect(OembedScanner.findIframeSrcInOembedJson(json, Uri.parse('https://example.com/oembed')), isNull);
    });
  });
}
