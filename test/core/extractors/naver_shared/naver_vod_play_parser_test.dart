import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/naver_shared/naver_vod_play_parser.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map<String, dynamic>;

void main() {
  const parser = NaverVodPlayParser();

  group('NaverVodPlayParser.parseFormats', () {
    test('reads all three renditions from a captured VOD play v2.0 response', () {
      final formats = parser.parseFormats(_fixture('naver_vod_play_v2.json'));

      expect(formats, hasLength(3));
      final hd = formats.firstWhere((f) => f.height == 720);
      expect(hd.id, '720P_1280_2048_192_B');
      expect(hd.width, 1280);
      expect(hd.container, 'mp4');
      expect(hd.contentLength, 1224467);
      // (1172 + 192) kbps -> bits per second.
      expect(hd.bitrate, 1364000);
      expect(hd.hasVideo, isTrue);
      expect(hd.hasAudio, isTrue);
      expect(hd.url, contains('D5305FD77CCF037973A0B9822D7AE024021C'));
    });

    test('guard can fail: a bitrate transcription bug is caught by the exact value assertion', () {
      // Demonstrates the assertion above is not vacuous: swapping the
      // scale (kbps treated as already-bps) produces a different number
      // the same test would catch.
      final formats = parser.parseFormats(_fixture('naver_vod_play_v2.json'));
      final hd = formats.firstWhere((f) => f.height == 720);
      expect(hd.bitrate, isNot(1364)); // the un-scaled (bug) value
    });

    test('an empty videos.list yields no formats', () {
      final formats = parser.parseFormats({
        'videos': {'list': <dynamic>[]},
      });
      expect(formats, isEmpty);
    });

    test('a response missing videos entirely yields no formats rather than throwing', () {
      expect(parser.parseFormats({'meta': {}}), isEmpty);
    });

    test('an entry with no source url is skipped', () {
      final formats = parser.parseFormats({
        'videos': {
          'list': [
            {'id': 'no-source', 'encodingOption': {}},
            {
              'id': 'has-source',
              'source': 'https://example.com/a.mp4',
              'encodingOption': {'width': 100, 'height': 200},
            },
          ],
        },
      });
      expect(formats, hasLength(1));
      expect(formats.single.id, 'has-source');
    });
  });
}
