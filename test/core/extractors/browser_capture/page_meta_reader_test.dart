import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/browser_capture/page_meta_reader.dart';

void main() {
  group('PageMetaReader.read', () {
    test('decodes the eval result JSON into a map', () async {
      final meta = await PageMetaReader.read(
        (expression) async => '{"title":"T","ogTitle":null,"ogImage":null,"href":"https://example.com"}',
      );
      expect(meta?['title'], 'T');
      expect(meta?['href'], 'https://example.com');
    });

    test('a null eval result (page threw) yields null, not a throw', () async {
      expect(await PageMetaReader.read((expression) async => null), isNull);
    });

    test('malformed JSON yields null, not a throw', () async {
      expect(await PageMetaReader.read((expression) async => 'not json'), isNull);
    });
  });

  group('PageMetaReader.title', () {
    test('prefers og:title over the raw document title', () {
      expect(PageMetaReader.title({'title': 'Raw - Site Name', 'ogTitle': 'Clean Title'}), 'Clean Title');
    });

    test('falls back to the raw title when og:title is absent', () {
      expect(PageMetaReader.title({'title': 'Raw Title', 'ogTitle': null}), 'Raw Title');
    });

    test('a null meta yields null', () {
      expect(PageMetaReader.title(null), isNull);
    });
  });

  group('PageMetaReader.thumbnail', () {
    test('returns og:image when present', () {
      expect(PageMetaReader.thumbnail({'ogImage': 'https://img.example.com/t.jpg'}), 'https://img.example.com/t.jpg');
    });

    test('an empty og:image is treated as absent', () {
      expect(PageMetaReader.thumbnail({'ogImage': ''}), isNull);
    });
  });
}
