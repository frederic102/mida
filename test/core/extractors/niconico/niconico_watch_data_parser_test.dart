import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/niconico/niconico_watch_data_parser.dart';

void main() {
  group('NiconicoWatchDataParser.tryParse against the legacy js-initial-watch-data shape', () {
    test('reads title/author/thumbnail/duration and the session_api fields', () async {
      final html = await File('test/fixtures/niconico_watch_data.html').readAsString();
      final data = const NiconicoWatchDataParser().tryParse(html)!;

      expect(data.id, 'sm9');
      expect(data.title, 'Example Niconico Video');
      expect(data.author, 'ExampleUploader');
      expect(data.duration, const Duration(seconds: 213));
      expect(data.sessionApi['contentId'], 'example-content-id');
      expect(data.sessionApi['token'], 'example-token');
      expect(data.sessionApi['videos'], ['archive_h264_1080p']);
    });

    test('returns null when the page has no js-initial-watch-data at all', () {
      final data = const NiconicoWatchDataParser().tryParse('<html><body>a react app shell</body></html>');
      expect(data, isNull);
    });

    test('throws PARSE_ERROR (fall-through eligible) when the attribute decodes but has no video object', () {
      const html = '<div id="js-initial-watch-data" data-api-data="{&quot;other&quot;:1}"></div>';
      expect(
        () => const NiconicoWatchDataParser().tryParse(html),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR')),
      );
    });

    test('throws UNSUPPORTED_MEDIA when video exists but has no session data', () {
      const html = '<div id="js-initial-watch-data" '
          'data-api-data="{&quot;video&quot;:{&quot;id&quot;:&quot;sm1&quot;,&quot;title&quot;:&quot;t&quot;}}"></div>';
      expect(
        () => const NiconicoWatchDataParser().tryParse(html),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_MEDIA')),
      );
    });
  });
}
